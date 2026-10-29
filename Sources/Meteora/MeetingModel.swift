import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MeteoraCore
import MeteoraASR

/// Thread-safe cancellation flag shared with background work.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

struct FrameItem: Identifiable {
    var frame: SceneFrame
    var preview: NSImage
    var id: Int { frame.id }
}

/// Where decoded audio comes from: the Opus track of a WebM file (our own
/// demuxer) or any file AVFoundation can read.
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

/// File types Meteora opens.
enum MediaFormats {
    /// Played and decoded by macOS itself.
    static let native = ["mp4", "m4v", "mov", "qt", "m4a", "m4b", "mp3", "wav", "wave", "aif", "aiff", "aifc", "caf",
                         "aac", "adts", "flac", "ac3", "ec3", "eac3", "3gp", "3g2", "au", "snd"]
    static let webm = ["webm"]
    /// Converted in the isolated helper (see MediaConverter).
    static var converted: [String] { MediaConverterSupport.extensions }
    static var all: [String] { Array(Set(native + webm + converted)).sorted() }
    static func isSupported(_ url: URL) -> Bool { all.contains(url.pathExtension.lowercased()) }
    static var contentTypes: [UTType] { all.compactMap { UTType(filenameExtension: $0) } }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var revealURL: URL?
    var isError = false
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

@MainActor
final class MeetingModel: ObservableObject {
    enum LoadState: Equatable {
        case empty
        case loading(Double)
        case ready
        case failed(String)
    }

    // File
    @Published private(set) var url: URL?
    @Published var exportSheetShown = false
    @Published private(set) var loadState: LoadState = .empty
    @Published private(set) var info: MediaInfo?
    @Published private(set) var player: PlayerController?
    private var demuxer: WebMDemuxer?
    private var scopedURL: URL?
    /// The file actually played and decoded: the original, or a converted
    /// copy in our temporary folder for formats macOS can't open.
    private var mediaURL: URL?
    private(set) var audioOrigin: AudioOrigin?
    /// Engine label for diagnostics: webm | native | converted.
    private(set) var engine = ""

    // Audio
    @Published private(set) var audioAnalysis: AudioAnalysis?
    @Published private(set) var audioError: String?
    @Published var quality: AudioQuality = AudioQuality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .medium {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    @Published var normalize: Bool = UserDefaults.standard.object(forKey: "normalize") as? Bool ?? true {
        didSet { UserDefaults.standard.set(normalize, forKey: "normalize") }
    }
    @Published private(set) var exportProgress: Double?
    @Published private(set) var exportLabel = ""
    private var exportToken: CancelToken?

    // Key frames
    @Published private(set) var frames: [FrameItem] = []
    @Published private(set) var sceneProgress: Double?
    @Published private(set) var sceneError: String?
    @Published private(set) var scenesDone = false
    @Published var sensitivity: Double = UserDefaults.standard.object(forKey: "sensitivity") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(sensitivity, forKey: "sensitivity") }
    }
    @Published var textOnly: Bool = UserDefaults.standard.object(forKey: "textOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(textOnly, forKey: "textOnly") }
    }
    @Published var thorough: Bool = UserDefaults.standard.object(forKey: "thorough") as? Bool ?? false {
        didSet { UserDefaults.standard.set(thorough, forKey: "thorough") }
    }
    @Published var selectedFrame: Int?
    private var sceneToken: CancelToken?
    private var loadToken: CancelToken?
    private var audioToken: CancelToken?

    @Published var toast: Toast?

    // Transcription (GigaAM-v3 on this Mac)
    enum BottomTab: Hashable { case frames, transcript }
    @Published var bottomTab: BottomTab = .frames
    @Published private(set) var transcript: Transcript?
    @Published private(set) var liveSegments: [TranscriptSegment] = []
    @Published private(set) var transcribeProgress: Double?
    @Published private(set) var transcribeError: String?
    @Published private(set) var transcribeStarted: Date?
    private var transcribeToken: CancelToken?

    var displayedSegments: [TranscriptSegment] {
        transcript?.segments ?? liveSegments.sorted { $0.start < $1.start }
    }
    var canTranscribe: Bool { audioOrigin != nil && transcribeProgress == nil }
    /// Rough time estimate (GigaAM-v3 INT8 on Apple Silicon ≈ 0.1× real time).
    var transcribeEstimate: String {
        let minutes = max(1, Int(((info?.duration ?? 0) * 0.1 / 60).rounded(.up)))
        return "≈ \(minutes) мин"
    }

    var title: String { url.map { sanitizedBaseName($0) } ?? "Meteora" }
    var hasVideo: Bool { info?.video != nil }
    var canExportAudio: Bool { audioOrigin != nil && exportProgress == nil }
    var isBusy: Bool { exportProgress != nil || sceneProgress != nil }

    /// Threshold for the scene detector derived from the UI slider.
    var sceneThreshold: Double { 0.05 * pow(0.1, sensitivity) } // 5 % … 0.5 % of the picture

    // MARK: Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaFormats.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Выберите запись встречи — видео или звук. Несколько записей расшифруются по очереди."
        panel.prompt = "Открыть"
        guard panel.runModal() == .OK else { return }
        openMany(panel.urls)
    }

    /// One file opens here; several go to batch processing.
    func openMany(_ urls: [URL]) {
        let supported = urls.filter(MediaFormats.isSupported)
        if supported.count == 1 {
            open(supported[0])
        } else if supported.count > 1 {
            BatchQueue.shared.add(supported)
            BatchWindow.show()
        }
    }

    func open(_ url: URL, then action: (() -> Void)? = nil) {
        close()
        let scoped = url.startAccessingSecurityScopedResource()
        if scoped { scopedURL = url }
        self.url = url
        loadState = .loading(0)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        let token = CancelToken()
        loadToken = token
        if url.pathExtension.lowercased() == "webm" {
            openWebM(url, token: token, then: action)
        } else {
            Task { await openNative(url, token: token, then: action) }
        }
    }

    private func openWebM(_ url: URL, token: CancelToken, then action: (() -> Void)?) {
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let (info, demuxer) = try WebMDemuxer.analyze(url: url, progress: { p in
                    Task { @MainActor in
                        if case .loading = self?.loadState { self?.loadState = .loading(p) }
                    }
                }, isCancelled: { token.isCancelled })
                await MainActor.run {
                    guard let self, !token.isCancelled else { return }
                    self.info = info
                    self.demuxer = demuxer
                    self.mediaURL = url
                    self.engine = "webm"
                    if let a = info.audio, a.codecID == "A_OPUS" { self.audioOrigin = .webm(demuxer, a) }
                    self.player = WebPlayerController(fileURL: url, audioOnly: info.video == nil)
                    self.finishOpening(url, then: action)
                }
            } catch {
                await MainActor.run {
                    guard let self, !token.isCancelled else { return }
                    self.loadState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
    }

    /// Everything that isn't WebM: macOS opens it directly, or the isolated
    /// converter turns it into a file macOS can open.
    private func openNative(_ url: URL, token: CancelToken, then action: (() -> Void)?) async {
        var playable = url
        var engine = "native"
        var probed: MediaInfo?
        if !(await MediaConverterSupport.needsConversion(url)) {
            probed = try? await AssetProbe.analyze(url: url)
        }
        if token.isCancelled { return }
        if probed == nil {
            do {
                loadState = .loading(0.01)
                let converted = try await MediaConverterSupport.convert(url, keepVideo: true, progress: { [weak self] p in
                    Task { @MainActor in
                        if case .loading = self?.loadState { self?.loadState = .loading(max(0.01, p)) }
                    }
                }, isCancelled: { token.isCancelled })
                if token.isCancelled { try? FileManager.default.removeItem(at: converted); return }
                playable = converted
                engine = "converted"
                probed = try await AssetProbe.analyze(url: converted)
            } catch {
                guard !token.isCancelled else { return }
                loadState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                return
            }
        }
        guard var info = probed, !token.isCancelled else { return }
        if engine == "converted" {
            // Show the original file's size, not the temporary copy's.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            info.fileSize = UInt64(max(0, size))
        }
        self.info = info
        self.mediaURL = playable
        self.engine = engine
        if info.audio != nil { audioOrigin = .asset(playable) }
        player = NativePlayerController(url: playable)
        finishOpening(url, then: action)
    }

    private func finishOpening(_ url: URL, then action: (() -> Void)?) {
        loadState = .ready
        transcript = TermDictionaryStore.shared.correct(TranscriptStore.load(for: url))
        if transcript != nil { bottomTab = .transcript }
        if let info { MeetingJournal.shared.record(url: url, info: info, transcript: transcript) }
        startAudioAnalysis()
        action?()
    }

    func revealInFinder() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Progress of speaker separation, nil when idle.
    @Published var diarizeProgress: Double?
    @Published var diarizeError: String?
    private var diarizeToken: CancelToken?

    /// Finds who spoke when and labels the transcript («Спикер 1, 2…»).
    func separateSpeakers() async {
        guard let origin = audioOrigin, let url, let tr = transcript, diarizeProgress == nil else { return }
        let controller = SpeakerModelController.shared
        if !controller.isInstalled {
            guard await controller.download() else { diarizeError = controller.error; return }
        }
        let token = CancelToken()
        diarizeToken = token
        diarizeError = nil
        diarizeProgress = 0
        let duration = info?.duration
        let result: Result<[SpeakerTurn], Error> = await Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let d = try SpeakerDiarizer()
                let decoder = try await origin.make()
                let turns = try d.diarize(decoder: decoder, expectedDuration: duration,
                                          isCancelled: { token.isCancelled }, progress: { p in
                    Task { @MainActor in if self?.diarizeProgress != nil { self?.diarizeProgress = p } }
                })
                return .success(turns)
            } catch {
                return .failure(error)
            }
        }.value
        diarizeProgress = nil
        diarizeToken = nil
        switch result {
        case .success(let turns):
            guard !token.isCancelled else { return }
            let labelled = tr.assigningSpeakers(turns)
            transcript = labelled
            if let saved = TranscriptStore.load(for: url) {
                TranscriptStore.save(saved.assigningSpeakers(turns), for: url)
            } else {
                TranscriptStore.save(labelled, for: url)
            }
            let n = labelled.speakers.count
            toast = Toast(message: n <= 1 ? "Слышен один голос" : "Говорящих: \(n)")
        case .failure(let e):
            if !token.isCancelled { diarizeError = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription }
        }
    }

    func cancelSpeakers() { diarizeToken?.cancel() }

    /// Speakers in order of first appearance.
    var speakers: [String] {
        var seen: [String] = []
        for s in displayedSegments { if let sp = s.speaker, !seen.contains(sp) { seen.append(sp) } }
        return seen
    }

    func speakerIndex(_ name: String) -> Int { speakers.firstIndex(of: name) ?? 0 }

    /// Renames a speaker everywhere in this meeting's transcript and saves it.
    func renameSpeaker(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old, let url, var tr = transcript else { return }
        tr.segments = tr.segments.map { s in
            var s = s
            if s.speaker == old { s.speaker = name }
            return s
        }
        transcript = tr
        // Save the renamed version of the stored (uncorrected) transcript too.
        if var saved = TranscriptStore.load(for: url) {
            saved.segments = saved.segments.map { s in
                var s = s
                if s.speaker == old { s.speaker = name }
                return s
            }
            TranscriptStore.save(saved, for: url)
        }
    }

    /// Re-reads the saved transcript through the (changed) dictionary.
    func reapplyDictionary() {
        guard let url, transcribeProgress == nil, let saved = TranscriptStore.load(for: url) else { return }
        transcript = TermDictionaryStore.shared.correct(saved)
    }

    var isWorking: Bool { transcribeProgress != nil || sceneProgress != nil || exportProgress != nil || diarizeProgress != nil }

    /// Back to the list of meetings. Asks first if work would be lost.
    func requestClose() {
        if isWorking {
            let alert = NSAlert()
            alert.messageText = transcribeProgress != nil ? "Остановить расшифровку?" : "Остановить обработку?"
            alert.informativeText = "Запись закроется, а начатая работа не сохранится."
            alert.addButton(withTitle: "Остановить и закрыть")
            alert.addButton(withTitle: "Продолжить")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        close()
    }

    func close() {
        loadToken?.cancel(); exportToken?.cancel(); sceneToken?.cancel(); audioToken?.cancel(); transcribeToken?.cancel(); diarizeToken?.cancel()
        diarizeProgress = nil
        diarizeError = nil
        transcript = nil
        liveSegments = []
        transcribeProgress = nil
        transcribeError = nil
        bottomTab = .frames
        player?.tearDown()
        player = nil
        demuxer = nil
        audioOrigin = nil
        if engine == "converted", let m = mediaURL { try? FileManager.default.removeItem(at: m) }
        mediaURL = nil
        engine = ""
        info = nil
        audioAnalysis = nil
        audioError = nil
        exportProgress = nil
        frames = []
        sceneProgress = nil
        sceneError = nil
        scenesDone = false
        selectedFrame = nil
        if let s = scopedURL { s.stopAccessingSecurityScopedResource(); scopedURL = nil }
        url = nil
        loadState = .empty
    }

    // MARK: Audio

    private func startAudioAnalysis() {
        guard info?.audio != nil else { return }
        guard let origin = audioOrigin else {
            audioError = MediaError.unsupportedAudioCodec(info?.audio?.codecName ?? "?").errorDescription
            return
        }
        let token = CancelToken()
        audioToken = token
        Task.detached(priority: .utility) { [weak self] in
            do {
                let dec = try await origin.make()
                let analysis = try dec.analyze(isCancelled: { token.isCancelled })
                await MainActor.run { if !token.isCancelled { self?.audioAnalysis = analysis } }
            } catch {
                await MainActor.run {
                    if !token.isCancelled { self?.audioError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                }
            }
        }
    }

    var suggestedAudioName: String { "\(title) — звук (\(quality.title.lowercased())).m4a" }

    var estimatedAudioSize: String {
        guard let d = info?.duration else { return "" }
        return "≈ " + FileSizeText.string(quality.estimatedSize(duration: d))
    }

    func presentSaveAudioPanel() {
        guard canExportAudio else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = suggestedAudioName
        panel.canCreateDirectories = true
        panel.message = "Звук для расшифровки"
        if panel.runModal() == .OK, let dest = panel.url {
            Task { await exportAudio(to: dest, reveal: true) }
        }
    }

    @discardableResult
    func exportAudio(to dest: URL, reveal: Bool) async -> Bool {
        guard let origin = audioOrigin, exportProgress == nil else { return false }
        let token = CancelToken()
        exportToken = token
        exportProgress = 0
        exportLabel = "Готовлю звук…"
        let options = AudioExportOptions(quality: quality, normalize: normalize)
        let analysis = audioAnalysis
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let dec = try await origin.make()
                var analysisToUse = analysis
                if options.normalize, analysisToUse == nil {
                    analysisToUse = try dec.analyze(isCancelled: { token.isCancelled }, progress: { p in
                        Task { @MainActor in self?.exportProgress = p * 0.3 }
                    })
                }
                let base = analysisToUse == nil || analysis != nil ? 0.0 : 0.3
                try AudioExporter.export(decoder: dec, analysis: analysisToUse, options: options, to: dest,
                                         isCancelled: { token.isCancelled }, progress: { p in
                    Task { @MainActor in self?.exportProgress = base + p * (1 - base) }
                })
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        exportProgress = nil
        exportToken = nil
        switch result {
        case .success:
            if reveal { toast = Toast(message: "Звук сохранён: \(dest.lastPathComponent)", revealURL: dest) }
            return true
        case .failure(let e):
            if (e as? MediaError) != .cancelled {
                toast = Toast(message: (e as? LocalizedError)?.errorDescription ?? e.localizedDescription, isError: true)
            }
            return false
        }
    }

    func cancelExport() { exportToken?.cancel() }

    /// Exports the audio to ~/Downloads/Meteora, copies it to the clipboard
    /// and hands it to another app.
    func sendToMacWhisper() async {
        guard canExportAudio, let src = url else { return }
        let dest: URL
        do {
            dest = try Folders.ensureExports().appendingPathComponent(suggestedAudioName)
        } catch {
            toast = Toast(message: "Нет доступа к папке «Загрузки».", isError: true)
            return
        }
        // Reuse a fresh export of the same recording and settings.
        let fm = FileManager.default
        // Reuse only an export made from *this very file* with the same settings.
        let srcValues = try? src.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey])
        let identity = [
            src.path,
            String(srcValues?.fileSize ?? -1),
            String(srcValues?.contentModificationDate?.timeIntervalSince1970 ?? 0),
            srcValues?.fileResourceIdentifier.map { "\($0)" } ?? "",
            quality.rawValue, String(normalize),
        ].joined(separator: "|")
        let destSize = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        var remembered = UserDefaults.standard.dictionary(forKey: "exportSettings") as? [String: String] ?? [:]
        if !(destSize > 0 && remembered[dest.path] == identity && fm.fileExists(atPath: dest.path)) {
            guard await exportAudio(to: dest, reveal: false) else { return }
            if remembered.count > 200 { remembered.removeAll() }
            remembered[dest.path] = identity
            UserDefaults.standard.set(remembered, forKey: "exportSettings")
        }
        if await MacWhisper.handOff(dest) {
            toast = Toast(message: "Звук передан в приложение расшифровки · файл в буфере обмена", revealURL: dest)
        } else {
            toast = Toast(message: "Звук сохранён в «Загрузки/Meteora» и скопирован в буфер обмена — вставьте его в нужное приложение.",
                          revealURL: dest)
        }
    }

    // MARK: Transcription

    func transcribe() async {
        guard canTranscribe, let origin = audioOrigin, let url else { return }
        guard SpeechModelController.shared.isInstalled else {
            transcribeError = "Сначала загрузите модель GigaAM-v3."
            return
        }
        guard let vad = SpeechModelController.vadModelURL else {
            transcribeError = "В приложении не найден детектор речи — переустановите Meteora."
            return
        }
        let token = CancelToken()
        transcribeToken = token
        transcribeError = nil
        liveSegments = []
        transcript = nil
        transcribeProgress = 0
        transcribeStarted = Date()
        bottomTab = .transcript
        let duration = info?.duration ?? 0

        let result: Result<[TranscriptSegment], Error> = await Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let recognizer = try SpeechRecognizer(store: .shared, vadModel: vad)
                let decoder = try await origin.make()
                let segments = try recognizer.transcribe(decoder: decoder, isCancelled: { token.isCancelled }, progress: { p in
                    Task { @MainActor in if self?.transcribeProgress != nil { self?.transcribeProgress = p } }
                }, onSegment: { seg in
                    Task { @MainActor in self?.liveSegments.append(seg) }
                })
                return .success(segments)
            } catch {
                return .failure(error)
            }
        }.value

        transcribeProgress = nil
        transcribeToken = nil
        switch result {
        case .success(let segments):
            let tr = TermDictionaryStore.shared.corrector.correct(
                Transcript(sourceName: url.lastPathComponent, duration: duration,
                           engine: SpeechRecognizer.engineName, segments: segments))
            transcript = tr
            liveSegments = []
            TranscriptStore.save(tr, for: url)
            MeetingJournal.shared.updateTranscript(for: url, transcript: tr)
            toast = Toast(message: segments.isEmpty ? "Речи в записи не найдено" : "Расшифровка готова: \(ru(segments.count, "фраза", "фразы", "фраз"))")
        case .failure(let e):
            if (e as? RecognizerError) == .cancelled {
                transcribeError = liveSegments.isEmpty ? nil : "Остановлено — показана расшифрованная часть."
            } else {
                transcribeError = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
            }
        }
    }

    func cancelTranscription() { transcribeToken?.cancel() }

    private var currentTranscript: Transcript? {
        if let transcript { return transcript }
        guard !liveSegments.isEmpty else { return nil }
        return Transcript(sourceName: url?.lastPathComponent ?? "", duration: info?.duration ?? 0,
                          engine: SpeechRecognizer.engineName, segments: displayedSegments)
    }

    func copyTranscript() {
        guard let tr = currentTranscript else { return }
        NSPasteboard.general.prepareForNewContents(with: .currentHostOnly)
        NSPasteboard.general.setString(TranscriptExporter.plainText(tr), forType: .string)
        toast = Toast(message: "Расшифровка скопирована")
    }

    enum TranscriptFormat { case txt, srt, markdown }

    func presentSaveTranscriptPanel(_ format: TranscriptFormat) {
        guard let tr = currentTranscript else { return }
        let panel = NSSavePanel()
        let ext: String
        let body: String
        switch format {
        case .txt: ext = "txt"; body = TranscriptExporter.plainText(tr)
        case .srt: ext = "srt"; body = TranscriptExporter.srt(tr)
        case .markdown:
            ext = "md"
            body = TranscriptExporter.markdown(tr, frames: frames.map(\.frame), meta: reportMeta)
        }
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.nameFieldStringValue = "\(title) — расшифровка.\(ext)"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try Data(body.utf8).write(to: dest, options: .atomic)
            toast = Toast(message: "Расшифровка сохранена", revealURL: dest)
        } catch {
            toast = Toast(message: "Не удалось сохранить: \(error.localizedDescription)", isError: true)
        }
    }

    /// Called from the storage window after it deleted cached transcripts.
    func transcriptCacheDidChange() {
        if let url, TranscriptStore.load(for: url) == nil, transcribeProgress == nil { transcript = nil }
    }

    // MARK: Key frames

    func analyzeScenes() async {
        guard let player, let info, info.video != nil, sceneProgress == nil else { return }
        let token = CancelToken()
        sceneToken = token
        sceneError = nil
        scenesDone = false
        frames = []
        sceneProgress = 0
        let resumeAt = player.currentTime
        let wasPlaying = player.isPlaying

        defer {
            sceneProgress = nil
            sceneToken = nil
        }

        do {
            try await player.waitUntilReady()
            let primary = info.videoPackets.isEmpty
                ? AssetProbe.sampleTimes(duration: info.duration, thorough: thorough)
                : ScenePlanner.primaryTimes(packets: info.videoPackets, duration: info.duration)
            let spikes = ScenePlanner.spikes(packets: info.videoPackets, width: info.video!.width, height: info.video!.height)
            var times = primary
            if thorough, !info.videoPackets.isEmpty { times = (primary + ScenePlanner.secondaryTimes(primary: primary, spikes: spikes)).sorted() }
            let collector = SceneCollector(threshold: sceneThreshold)
            let video = info.video!
            // Preferred: decode frames ourselves via WebCodecs (exact, full
            // resolution, doesn't touch the player). Fallback: seek + snapshot.
            var codec: String?
            let independent = player is NativePlayerController
            if !independent, let c = video.webCodecsCodec, await player.canDecode(codec: c, width: video.width, height: video.height) {
                codec = c
            } else if !independent {
                player.pause()
            }
            usedDecoder = codec != nil || independent
            let demuxer = self.demuxer

            for (i, t) in times.enumerated() {
                if token.isCancelled { break }
                if frames.count >= Self.maxFrames {
                    sceneError = "Показаны первые \(Self.maxFrames) кадров — уменьшите чувствительность, чтобы охватить всю запись."
                    break
                }
                // A hair after the keyframe so we land exactly on it.
                let thumb: FrameThumb
                if let codec, let demuxer, let plan = DecodePlan.packets(for: t + 0.02, in: info.videoPackets) {
                    let chunks = try await Task.detached(priority: .userInitiated) {
                        try plan.map { (try demuxer.videoPayload($0), $0.isKey, $0.time) }
                    }.value
                    guard let th = try? await player.decodeSample(codec: codec, width: video.width, height: video.height, chunks: chunks) else {
                        sceneProgress = Double(i + 1) / Double(times.count)
                        continue
                    }
                    thumb = th
                } else {
                    thumb = try await player.sample(at: t + 0.02)
                }
                if var change = collector.consider(time: t, thumb: thumb, spikes: spikes) {
                    // Files without packet timing are sampled on a grid: narrow
                    // the moment of change down by bisection.
                    if independent, i > 0 {
                        var lo = times[i - 1] + 0.02, hi = t + 0.02
                        for _ in 0..<4 where !token.isCancelled {
                            let mid = (lo + hi) / 2
                            if let th = try? await player.sample(at: mid), th.changedFraction(to: thumb) < sceneThreshold / 2 {
                                hi = mid
                            } else {
                                lo = mid
                            }
                        }
                        change = max(0, hi - 0.02)
                        _ = try? await player.sample(at: hi)
                    }
                    guard let image = try await (codec != nil ? player.grabDecoded() : player.grabFrame()) else {
                        sceneProgress = Double(i + 1) / Double(times.count)
                        continue
                    }
                    let text = await Task.detached(priority: .userInitiated) { TextRecognizer.recognize(image) }.value
                    let frame = SceneFrame(id: frames.count + 1, time: change, image: image, text: text)
                    let duplicateText = frames.last.map { !text.isEmpty && textSimilarity($0.frame.text, text) > 0.9 } ?? false
                    if (!textOnly || frame.letterCount >= 12) && !duplicateText {
                        frames.append(FrameItem(frame: frame, preview: Self.preview(image)))
                    }
                }
                sceneProgress = Double(i + 1) / Double(times.count)
            }
            scenesDone = !token.isCancelled
            if scenesDone, frames.isEmpty {
                sceneError = textOnly ? "Кадров с текстом не нашлось. Снимите «Только с текстом» или повысьте чувствительность." :
                    "Смены картинки не обнаружено."
            }
        } catch {
            sceneError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        player.releaseDecoded()
        if !usedDecoder {
            player.seek(to: resumeAt)
            if wasPlaying { player.play() }
        }
    }

    /// Whether the last analysis used WebCodecs (for diagnostics).
    private(set) var usedDecoder = false

    func cancelScenes() { sceneToken?.cancel() }

    static let maxFrames = 300

    static func preview(_ image: CGImage) -> NSImage {
        let scale = min(1, 480.0 / Double(max(1, image.width)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(cgImage: image, size: .zero)
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return NSImage(cgImage: image, size: .zero) }
        return NSImage(cgImage: small, size: NSSize(width: w, height: h))
    }

    private var reportMeta: ReportExporter.Meta {
        ReportExporter.Meta(title: title, sourceName: url?.lastPathComponent ?? "", duration: info?.duration ?? 0)
    }

    func copyFramesText() {
        guard !frames.isEmpty else { return }
        let text = ReportExporter.plainText(frames.map(\.frame), meta: reportMeta)
        NSPasteboard.general.prepareForNewContents(with: .currentHostOnly)
        NSPasteboard.general.setString(text, forType: .string)
        toast = Toast(message: "Скопирован текст: \(ru(frames.count, "кадр", "кадра", "кадров"))")
    }

    func presentSavePDFPanel() {
        guard !frames.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(title) — кадры.pdf"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let frames = self.frames.map(\.frame), meta = reportMeta
        Task {
            let data = await Task.detached { ReportExporter.pdfData(frames, meta: meta) }.value
            do {
                try data.write(to: dest, options: .atomic)
                toast = Toast(message: "PDF сохранён", revealURL: dest)
            } catch {
                toast = Toast(message: "Не удалось сохранить PDF: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func presentSaveFolderPanel() {
        guard !frames.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title) — кадры"
        panel.message = "Будет создана папка с кадрами (PNG) и файлом кадры.md"
        panel.prompt = "Создать"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let frames = self.frames.map(\.frame), meta = reportMeta, tr = currentTranscript
        Task {
            do {
                try await Task.detached { try ReportExporter.writeFolder(frames, meta: meta, to: dest, transcript: tr) }.value
                toast = Toast(message: "Кадры сохранены", revealURL: dest.appendingPathComponent("кадры.md"))
            } catch {
                toast = Toast(message: "Не удалось сохранить: \(error.localizedDescription)", isError: true)
            }
        }
    }
}

extension MeetingModel {
    var showsFramesTab: Bool { hasVideo && (!frames.isEmpty || sceneProgress != nil || scenesDone) }
    var showsTranscriptTab: Bool { transcript != nil || transcribeProgress != nil || !liveSegments.isEmpty }
}
