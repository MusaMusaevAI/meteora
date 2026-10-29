import Foundation
import MeteoraCore
import MeteoraASR
import MeteoraLLM

/// One recording to process without a window: read it, transcribe it (or
/// reuse a saved transcript), optionally separate speakers and write a
/// summary, then save the chosen formats. Shared by batch processing and
/// auto-folders.
struct MeetingJob {
    var url: URL
    /// Base name of the written files («<title>.docx»).
    var title: String
    var destination: URL
    var formats: [ExportFormat]
    var options: TranscriptExportOptions
    var reuseTranscript = true
    var separateSpeakers = false
    var summarize = false
    var addToJournal = true
}

enum MeetingStage: Equatable, Sendable {
    case reading(Double)
    case transcribing(Double)
    case speakers(Double)
    case summary(Double, String)
    case saving

    var text: String {
        switch self {
        case .reading: return "Чтение файла"
        case .transcribing: return "Расшифровка"
        case .speakers: return "Разделение по говорящим"
        case .summary(_, let s): return s.isEmpty ? "Итоги" : s
        case .saving: return "Сохранение"
        }
    }

    /// For a status line: «Расшифровываю «…» · 42 %».
    var verb: String {
        switch self {
        case .reading, .transcribing: return "Расшифровываю"
        case .speakers: return "Разделяю говорящих"
        case .summary: return "Составляю итоги"
        case .saving: return "Сохраняю"
        }
    }

    var fraction: Double? {
        switch self {
        case .reading(let p), .transcribing(let p), .speakers(let p), .summary(let p, _): return p
        case .saving: return nil
        }
    }

    fileprivate var kind: Int {
        switch self {
        case .reading: return 0
        case .transcribing: return 1
        case .speakers: return 2
        case .summary: return 3
        case .saving: return 4
        }
    }
}

struct MeetingOutcome {
    var written: [URL] = []
    var reusedTranscript = false
    var duration: Double = 0
    var segments = 0
    var speakers = 0
    var summary: MeetingSummary?
    /// Optional steps that were skipped or failed (the job itself succeeded).
    var warnings: [String] = []
}

enum MeetingProcessorError: Error, LocalizedError, Equatable {
    case speechModelMissing
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .speechModelMissing: return "Модель речи не загружена."
        case .noSpeech: return "Речи в записи не найдено"
        }
    }
}

/// Passes stage updates from background work to the main actor, dropping
/// updates that change less than half a percent.
final class MeetingStageRelay: @unchecked Sendable {
    private let handler: @MainActor (MeetingStage) -> Void
    private let lock = NSLock()
    private var lastKind = -1
    private var lastValue = -1.0

    init(_ handler: @escaping @MainActor (MeetingStage) -> Void) { self.handler = handler }

    func send(_ stage: MeetingStage) {
        lock.lock()
        let value = stage.fraction ?? -1
        let skip = stage.kind == lastKind && abs(value - lastValue) < 0.005
        if !skip { lastKind = stage.kind; lastValue = value }
        lock.unlock()
        if skip { return }
        let h = handler
        Task { @MainActor in h(stage) }
    }
}

/// Runs `MeetingJob`s one at a time. Keeps the speech recognizer loaded
/// between jobs; drop the processor to free it.
@MainActor
final class MeetingProcessor {
    private var recognizer: SpeechRecognizer?

    func process(_ job: MeetingJob, token: CancelToken,
                 stage: @escaping @MainActor (MeetingStage) -> Void) async throws -> MeetingOutcome {
        let url = job.url
        let relay = MeetingStageRelay(stage)
        stage(.reading(0))
        var outcome = MeetingOutcome()
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        let media = try await LoadedMedia.load(url, isCancelled: { token.isCancelled }, progress: { p in
            relay.send(.reading(p))
        })
        temporary = media.temporary
        outcome.duration = media.info.duration
        if job.addToJournal {
            MeetingJournal.shared.record(url: url, info: media.info, transcript: TranscriptStore.load(for: url))
        }
        guard let origin = media.origin else { throw MediaError.unplayable }
        try checkCancelled(token)

        // 1. Transcript: saved earlier, or made now.
        var transcript = job.reuseTranscript ? TermDictionaryStore.shared.correct(TranscriptStore.load(for: url)) : nil
        outcome.reusedTranscript = transcript != nil
        if transcript == nil {
            guard SpeechModelController.shared.isInstalled, let vad = SpeechModelController.vadModelURL else {
                throw MeetingProcessorError.speechModelMissing
            }
            stage(.transcribing(0))
            if recognizer == nil {
                recognizer = try SpeechRecognizer(store: .shared, vadModel: vad,
                                                  hotwords: TermDictionaryStore.shared.recognizerHints)
            }
            guard let rec = recognizer else { throw MeetingProcessorError.speechModelMissing }
            let segments: [TranscriptSegment] = try await Task.detached(priority: .userInitiated) {
                let decoder = try await origin.make()
                return try rec.transcribe(decoder: decoder, isCancelled: { token.isCancelled }, progress: { p in
                    relay.send(.transcribing(p))
                }, onSegment: { _ in })
            }.value
            try checkCancelled(token)
            let tr = TermDictionaryStore.shared.corrector.correct(
                Transcript(sourceName: url.lastPathComponent, duration: media.info.duration,
                           engine: SpeechRecognizer.engineName, segments: segments))
            TranscriptStore.save(tr, for: url)
            if job.addToJournal { MeetingJournal.shared.updateTranscript(for: url, transcript: tr) }
            transcript = tr
        }
        guard var tr = transcript else { throw MeetingProcessorError.noSpeech }
        outcome.segments = tr.segments.count

        // 2. Speakers (optional; a failure here only adds a warning).
        if job.separateSpeakers, !tr.segments.isEmpty, tr.speakers.isEmpty {
            stage(.speakers(0))
            do {
                if let labelled = try await separateSpeakers(tr, origin: origin, duration: media.info.duration,
                                                             url: url, token: token, relay: relay, outcome: &outcome) {
                    tr = labelled
                }
            } catch {
                try checkCancelled(token)
                outcome.warnings.append("Говорящие: " + Self.message(error))
            }
        }
        outcome.speakers = tr.speakers.count

        // 3. Summary (optional, same rule).
        if job.summarize, !tr.segments.isEmpty {
            if let saved = SummaryStore.load(for: url) {
                outcome.summary = saved
            } else {
                stage(.summary(0, ""))
                do {
                    let made = try await summarize(tr, url: url, token: token, relay: relay, outcome: &outcome)
                    outcome.summary = made
                } catch {
                    try checkCancelled(token)
                    outcome.warnings.append("Итоги: " + Self.message(error))
                }
            }
        }
        try checkCancelled(token)

        // 4. Files.
        stage(.saving)
        if tr.segments.isEmpty { throw MeetingProcessorError.noSpeech }
        let meta = ReportExporter.Meta(title: job.title, sourceName: url.lastPathComponent, duration: media.info.duration)
        let base = job.title
        let formats = job.formats
        let options = job.options
        let dest = job.destination
        let summaryText = outcome.summary?.markdown()
        let finalTranscript = tr
        outcome.written = try await Task.detached(priority: .userInitiated) { () -> [URL] in
            var written: [URL] = []
            for f in formats {
                let result = try TranscriptExporter.export(finalTranscript, frames: [], meta: meta, format: f,
                                                           options: options, baseName: base)
                written.append(try TranscriptExporter.write(result, to: dest, baseName: base, format: f))
            }
            if let summaryText {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                let name = sanitizedBaseName(URL(fileURLWithPath: "/").appendingPathComponent(base + " — итоги.md"))
                let file = dest.appendingPathComponent(name + ".md", isDirectory: false)
                try Data(summaryText.utf8).write(to: file, options: .atomic)
                written.append(file)
            }
            return written
        }.value
        return outcome
    }

    private func checkCancelled(_ token: CancelToken) throws {
        if token.isCancelled { throw MediaError.cancelled }
    }

    /// Same steps as `MeetingModel.separateSpeakers`, with the chosen voice
    /// model. Never downloads a model by itself: a missing model is a warning.
    private func separateSpeakers(_ tr: Transcript, origin: AudioOrigin, duration: Double, url: URL,
                                  token: CancelToken, relay: MeetingStageRelay,
                                  outcome: inout MeetingOutcome) async throws -> Transcript? {
        let controller = SpeakerModelController.shared
        let tier = controller.tier
        guard controller.isReady(tier) else {
            outcome.warnings.append("модель голосов не загружена — говорящие не разделены")
            return nil
        }
        let options = SpeakerDiarizer.Options(tier: tier, numSpeakers: nil, maxSpeakers: SpeakerModelController.maxSpeakers)
        let turns: [SpeakerTurn] = try await Task.detached(priority: .userInitiated) {
            let d = try SpeakerDiarizer(tier: tier, options: options)
            let decoder = try await origin.make()
            return try d.diarize(decoder: decoder, expectedDuration: duration,
                                 isCancelled: { token.isCancelled }, progress: { p in relay.send(.speakers(p)) })
        }.value
        try checkCancelled(token)
        let labelled = tr.assigningSpeakers(turns)
        if let saved = TranscriptStore.load(for: url) {
            TranscriptStore.save(saved.assigningSpeakers(turns), for: url)
        } else {
            TranscriptStore.save(labelled, for: url)
        }
        return labelled
    }

    /// Same engine as the «Итоги» tab. Local: only if the model is on disk.
    /// Cloud: only if a key is saved and the user already agreed to send
    /// transcripts to that provider (there is nobody to ask in the background).
    private func summarize(_ tr: Transcript, url: URL, token: CancelToken, relay: MeetingStageRelay,
                           outcome: inout MeetingOutcome) async throws -> MeetingSummary? {
        let controller = SummaryModelController.shared
        switch controller.engine {
        case .local(let tier):
            guard controller.installed.contains(tier) else {
                outcome.warnings.append("модель итогов не загружена — итоги не составлены")
                return nil
            }
        case .cloud(let p):
            guard controller.isReady, controller.hasConsent(p) else {
                outcome.warnings.append("облачные итоги не настроены или не подтверждены — итоги не составлены")
                return nil
            }
        }
        let summary = try await controller.summarize(tr, meetingDate: MeetingJournal.meetingDate(for: url), progress: { p in
            relay.send(.summary(p.fraction, p.text))
        }, isCancelled: { token.isCancelled })
        try checkCancelled(token)
        SummaryStore.save(summary, for: url)
        return summary
    }

    static func message(_ error: Error) -> String {
        if (error as? ExportError) == .nothingToExport { return MeetingProcessorError.noSpeech.errorDescription ?? "" }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// «52 мин», «1 ч 5 мин», «40 с».
    static func durationText(_ s: Double) -> String {
        let total = Int(max(0, s).rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h) ч \(m) мин" : "\(h) ч" }
        if m > 0 { return "\(m) мин" }
        return "\(total) с"
    }
}
