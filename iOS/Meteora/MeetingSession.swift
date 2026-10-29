import Foundation
import AVFoundation
import SwiftUI
import UIKit
import MeteoraCore
import MeteoraASR
import MeteoraLLM

/// Where decoded audio comes from: the Opus track of a WebM (our demuxer)
/// or anything AVFoundation reads.
enum AudioOrigin: @unchecked Sendable {
    case webm(WebMDemuxer, AudioTrackInfo)
    case asset(URL)

    func make() async throws -> PCMSource {
        switch self {
        case .webm(let d, let a): return try OpusTrackDecoder(demuxer: d, info: a)
        case .asset(let url): return try await AssetAudioDecoder.make(url: url)
        }
    }
}

/// One open recording: playback, transcript, speakers, summary.
@MainActor
final class MeetingSession: ObservableObject {
    let id: UUID
    @Published private(set) var recording: Recording
    @Published private(set) var fileURL: URL?
    @Published private(set) var loadError: String?
    @Published private(set) var isLoading = true

    // Playback
    @Published private(set) var player: AVPlayer?
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published var rate: Float = 1 { didSet { if isPlaying { player?.rate = rate } } }
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// WebM audio decoded into a temporary .m4a (AVFoundation can't play WebM).
    private var playbackCopy: URL?

    // Content
    @Published private(set) var transcript: Transcript?
    @Published private(set) var liveSegments: [TranscriptSegment] = []
    @Published private(set) var summary: MeetingSummary?

    // Jobs
    @Published private(set) var transcribeProgress: Double?
    @Published private(set) var speakersProgress: Double?
    @Published private(set) var summaryProgress: Double?
    @Published private(set) var summaryStage: String?
    @Published var jobError: String?
    @Published var notice: String?
    private var jobToken: CancelToken?
    private var origin: AudioOrigin?

    var isBusy: Bool { transcribeProgress != nil || speakersProgress != nil || summaryProgress != nil }
    var segments: [TranscriptSegment] { transcript?.segments ?? liveSegments.sorted { $0.start < $1.start } }
    var speakers: [String] { transcript?.speakers ?? [] }

    init(recording: Recording) {
        id = recording.id
        self.recording = recording
        transcript = Library.shared.transcript(recording.id)
        summary = Library.shared.summary(recording.id)
        duration = recording.duration
    }

    // MARK: Opening

    func open() async {
        defer { isLoading = false }
        guard let url = Library.shared.url(of: recording) else {
            loadError = "Общая папка недоступна. Выберите её заново в настройках."
            return
        }
        if recording.place == .shared, !(await SharedFolder.shared.ensureDownloaded(url)) {
            loadError = "Файл ещё не скачался из iCloud. Попробуйте позже."
            return
        }
        fileURL = url
        do {
            if url.pathExtension.lowercased() == "webm" {
                let (info, opus) = try await Task.detached(priority: .userInitiated) { () -> (MediaInfo, AudioOrigin?) in
                    let (info, demuxer) = try WebMDemuxer.analyze(url: url)
                    guard let audio = info.audio, audio.codecID == "A_OPUS" else { return (info, nil) }
                    return (info, AudioOrigin.webm(demuxer, audio))
                }.value
                guard let o = opus else {
                    loadError = "В записи нет звука, который Meteora может прочитать."
                    return
                }
                origin = o
                duration = info.duration
                // WebM isn't playable by AVFoundation: decode the audio once.
                let copy = try await Task.detached(priority: .userInitiated) { () -> URL in
                    let source = try await o.make()
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("meteora-play-\(UUID().uuidString).m4a")
                    try AudioExporter.export(decoder: source, analysis: nil,
                                             options: AudioExportOptions(quality: .high, normalize: false), to: dest)
                    return dest
                }.value
                playbackCopy = copy
                setUpPlayer(copy)
                if info.video != nil { notice = "Видео из WebM на iPhone не показывается — только звук." }
            } else {
                origin = .asset(url)
                setUpPlayer(url)
            }
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func setUpPlayer(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = t.seconds.isFinite ? t.seconds : 0
                if let d = self.player?.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                self.isPlaying = (self.player?.rate ?? 0) > 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        player = p
    }

    func close() {
        jobToken?.cancel()
        player?.pause()
        if let o = timeObserver { player?.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        timeObserver = nil
        endObserver = nil
        player = nil
        if let c = playbackCopy { try? FileManager.default.removeItem(at: c); playbackCopy = nil }
    }

    // MARK: Transport

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            if duration > 0, currentTime >= duration - 0.2 { seek(to: 0) }
            player.playImmediately(atRate: rate)
            isPlaying = true
        }
    }

    func seek(to t: Double) {
        let c = min(max(0, t), max(0, duration))
        player?.seek(to: CMTime(seconds: c, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = c
    }

    func skip(_ d: Double) { seek(to: currentTime + d) }

    // MARK: Transcription

    func transcribe() async {
        guard !isBusy, let origin else { return }
        let models = Models.shared
        if !models.speechInstalled {
            guard await models.download(.speech) else { jobError = models.error; return }
        }
        guard let vad = Models.vadURL else { jobError = "В приложении нет детектора речи — переустановите Meteora."; return }
        let token = CancelToken()
        jobToken = token
        jobError = nil
        liveSegments = []
        transcript = nil
        transcribeProgress = 0
        let background = beginBackground("Расшифровка")
        defer { endBackground(background) }
        let hints = HintsSettings.recognizerHints
        let result: Result<[TranscriptSegment], Error> = await Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let recognizer = try SpeechRecognizer(store: .shared, vadModel: vad, hotwords: hints)
                let decoder = try await origin.make()
                let segs = try recognizer.transcribe(decoder: decoder, isCancelled: { token.isCancelled }, progress: { p in
                    Task { @MainActor in if self?.transcribeProgress != nil { self?.transcribeProgress = p } }
                }, onSegment: { s in
                    Task { @MainActor in self?.liveSegments.append(s) }
                })
                return .success(segs)
            } catch {
                return .failure(error)
            }
        }.value
        transcribeProgress = nil
        jobToken = nil
        switch result {
        case .success(let segs):
            let tr = Transcript(sourceName: fileURL?.lastPathComponent ?? recording.title, duration: duration,
                                engine: SpeechRecognizer.engineName, segments: segs)
            transcript = tr
            liveSegments = []
            Library.shared.saveTranscript(tr, for: id)
            refreshRecording()
            if recording.place == .shared {
                SharedFolder.shared.writeTranscriptText(plainText(tr), for: recording.path)
            }
            notice = segs.isEmpty ? "Речи в записи не найдено" : "Расшифровка готова: \(ru(segs.count, "фраза", "фразы", "фраз"))"
            Haptics.success()
        case .failure(let e):
            if token.isCancelled {
                jobError = liveSegments.isEmpty ? nil : "Остановлено — показана расшифрованная часть."
            } else {
                jobError = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
            }
        }
    }

    func cancelJob() { jobToken?.cancel() }

    // MARK: Speakers

    func separateSpeakers(count: Int?) async {
        guard !isBusy, let origin, let tr = transcript else { return }
        let models = Models.shared
        if !models.speakersInstalled {
            guard await models.download(.speakers) else { jobError = models.error; return }
        }
        let tier = SpeakerModel.defaultTier
        let options = SpeakerDiarizer.Options(tier: tier, numSpeakers: count, maxSpeakers: 10)
        let token = CancelToken()
        jobToken = token
        jobError = nil
        speakersProgress = 0
        let background = beginBackground("Говорящие")
        defer { endBackground(background) }
        let expected = duration
        let result: Result<[SpeakerTurn], Error> = await Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let d = try SpeakerDiarizer(tier: tier, options: options)
                let decoder = try await origin.make()
                let turns = try d.diarize(decoder: decoder, expectedDuration: expected, isCancelled: { token.isCancelled },
                                          progress: { p in
                    Task { @MainActor in if self?.speakersProgress != nil { self?.speakersProgress = p } }
                })
                return .success(turns)
            } catch {
                return .failure(error)
            }
        }.value
        speakersProgress = nil
        jobToken = nil
        switch result {
        case .success(let turns):
            let labelled = tr.assigningSpeakers(turns)
            transcript = labelled
            Library.shared.saveTranscript(labelled, for: id)
            let n = labelled.speakers.count
            notice = n <= 1 ? "Слышен один голос" : "Говорящих: \(n)"
            Haptics.success()
        case .failure(let e):
            if !token.isCancelled { jobError = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription }
        }
    }

    func renameSpeaker(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old, var tr = transcript else { return }
        tr.segments = tr.segments.map { s in
            var s = s
            if s.speaker == old { s.speaker = name }
            return s
        }
        transcript = tr
        Library.shared.saveTranscript(tr, for: id)
    }

    /// Manual correction of one phrase; empty text removes it.
    func editSegment(start: Double, text: String) {
        guard var tr = transcript, let i = tr.segments.firstIndex(where: { abs($0.start - start) < 0.001 }) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { tr.segments.remove(at: i) } else { tr.segments[i].text = t }
        transcript = tr
        Library.shared.saveTranscript(tr, for: id)
    }

    // MARK: Summary

    func summarize() async {
        guard !isBusy, let tr = transcript, !tr.segments.isEmpty else { return }
        let settings = SummarySettings.shared
        let token = CancelToken()
        jobError = nil
        summaryProgress = 0
        summaryStage = "Готовлю…"
        let background = beginBackground("Итоги")
        defer { endBackground(background) }
        let date = recording.meetingDate
        let report: @Sendable (SummaryProgress) -> Void = { [weak self] p in
            Task { @MainActor in
                guard let self, self.summaryProgress != nil else { return }
                self.summaryProgress = p.fraction
                self.summaryStage = Self.stageText(p.stage)
            }
        }
        jobToken = token
        do {
            let s: MeetingSummary
            switch settings.engine {
            case .local:
                let models = Models.shared
                let tier = models.summaryTier
                if !models.summaryInstalled.contains(tier) {
                    summaryStage = "Загрузка модели…"
                    guard await models.download(.summary(tier)) else {
                        summaryProgress = nil; summaryStage = nil; jobToken = nil
                        jobError = models.error
                        return
                    }
                }
                var options = LLMOptions()
                #if targetEnvironment(simulator)
                options.useGPU = false // the simulator's Metal can't run the model
                #endif
                let summarizer = MeetingSummarizer(store: SummaryModelStore.store(for: tier), options: options)
                s = try await summarizer.summarize(tr, meetingDate: date, progress: report, isCancelled: { token.isCancelled })
                summarizer.unload()
            case .cloud(let p):
                guard let config = settings.config(for: p) else {
                    throw CloudError.noKey
                }
                s = try await CloudSummarizer(config: config).summarize(tr, meetingDate: date, progress: report,
                                                                       isCancelled: { token.isCancelled })
            }
            summary = s
            Library.shared.saveSummary(s, for: id)
            refreshRecording()
            Haptics.success()
        } catch {
            if !token.isCancelled { jobError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
        summaryProgress = nil
        summaryStage = nil
        jobToken = nil
    }

    nonisolated static func stageText(_ s: SummaryProgress.Stage) -> String {
        switch s {
        case .loadingModel: return "Загружаю модель…"
        case .protectingData: return "Скрываю личные данные…"
        case .readingPart(let i, let n): return "Читаю часть \(i) из \(n)…"
        case .combining: return "Свожу части…"
        case .writing: return "Пишу итоги…"
        }
    }

    // MARK: Export

    var exportBaseName: String { sanitizedBaseName(URL(fileURLWithPath: "/" + recording.displayTitle + ".x")) }

    /// Files for the share sheet: the chosen formats (plus the summary as
    /// Markdown when there is one), in a fresh temporary folder.
    func exportFiles(_ formats: [ExportFormat]) throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = ReportExporter.Meta(title: recording.displayTitle, sourceName: fileURL?.lastPathComponent ?? recording.path,
                                       duration: duration)
        var out: [URL] = []
        for f in formats {
            let r = try TranscriptExporter.export(transcript, frames: [], meta: meta, format: f, baseName: exportBaseName)
            out.append(try TranscriptExporter.write(r, to: dir, baseName: exportBaseName, format: f))
        }
        if let summary {
            let u = dir.appendingPathComponent(exportBaseName + " — итоги.md")
            try Data(summary.markdown().utf8).write(to: u)
            out.append(u)
        }
        return out
    }

    func plainText(_ tr: Transcript) -> String {
        let meta = ReportExporter.Meta(title: recording.displayTitle, sourceName: recording.path, duration: duration)
        if let r = try? TranscriptExporter.export(tr, frames: [], meta: meta, format: .txt),
           let s = String(data: r.primary, encoding: .utf8) { return s }
        return tr.segments.map(\.text).joined(separator: "\n")
    }

    private func refreshRecording() {
        if let r = Library.shared.recording(id) { recording = r }
    }

    func rename(_ name: String) {
        Library.shared.rename(id, to: name)
        refreshRecording()
    }

    // MARK: Background time

    /// Asks iOS for a little more time if the app is switched away mid-job,
    /// and keeps the screen on while it runs.
    private func beginBackground(_ name: String) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.isIdleTimerDisabled = true
        return UIApplication.shared.beginBackgroundTask(withName: name) { }
    }

    private func endBackground(_ id: UIBackgroundTaskIdentifier) {
        UIApplication.shared.isIdleTimerDisabled = false
        if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
    }
}

enum Haptics {
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

/// Dictionary hints for the recognizer: terms typed in Settings.
enum HintsSettings {
    static let key = "asr.terms"
    static var terms: [String] {
        (UserDefaults.standard.string(forKey: key) ?? "")
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    static var recognizerHints: [String] { terms }
}
