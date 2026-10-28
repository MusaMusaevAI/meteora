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
    @Published private(set) var loadState: LoadState = .empty
    @Published private(set) var info: MediaInfo?
    @Published private(set) var player: PlayerController?
    private var demuxer: WebMDemuxer?
    private var scopedURL: URL?

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
    var canTranscribe: Bool { info?.audio?.codecID == "A_OPUS" && transcribeProgress == nil }
    /// Rough time estimate (GigaAM-v3 INT8 on Apple Silicon ≈ 0.1× real time).
    var transcribeEstimate: String {
        let minutes = max(1, Int(((info?.duration ?? 0) * 0.1 / 60).rounded(.up)))
        return "≈ \(minutes) мин"
    }

    var title: String { url.map { sanitizedBaseName($0) } ?? "Meteora" }
    var hasVideo: Bool { info?.video != nil }
    var canExportAudio: Bool { info?.audio?.codecID == "A_OPUS" && exportProgress == nil }
    var isBusy: Bool { exportProgress != nil || sceneProgress != nil }

    /// Threshold for the scene detector derived from the UI slider.
    var sceneThreshold: Double { 0.05 * pow(0.1, sensitivity) } // 5 % … 0.5 % of the picture

    // MARK: Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "webm") ?? .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Выберите запись встречи (.webm)"
        panel.prompt = "Открыть"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
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
                    self.player = PlayerController(fileURL: url, audioOnly: info.video == nil)
                    self.loadState = .ready
                    self.transcript = TranscriptStore.load(for: url)
                    if self.transcript != nil { self.bottomTab = .transcript }
                    self.startAudioAnalysis()
                    action?()
                }
            } catch {
                await MainActor.run {
                    guard let self, !token.isCancelled else { return }
                    self.loadState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
    }

    func close() {
        loadToken?.cancel(); exportToken?.cancel(); sceneToken?.cancel(); audioToken?.cancel(); transcribeToken?.cancel()
        transcript = nil
        liveSegments = []
        transcribeProgress = nil
        transcribeError = nil
        bottomTab = .frames
        player?.tearDown()
        player = nil
        demuxer = nil
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
        guard let demuxer, let a = info?.audio else { return }
        guard a.codecID == "A_OPUS" else {
            audioError = MediaError.unsupportedAudioCodec(a.codecName).errorDescription
            return
        }
        let token = CancelToken()
        audioToken = token
        Task.detached(priority: .utility) { [weak self] in
            do {
                let dec = try OpusTrackDecoder(demuxer: demuxer, info: a)
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
        guard let demuxer, let a = info?.audio, exportProgress == nil else { return false }
        let token = CancelToken()
        exportToken = token
        exportProgress = 0
        exportLabel = "Готовлю звук…"
        let options = AudioExportOptions(quality: quality, normalize: normalize)
        let analysis = audioAnalysis
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) { [weak self] in
            Result {
                let dec = try OpusTrackDecoder(demuxer: demuxer, info: a)
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
    /// and opens it in MacWhisper.
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
            toast = Toast(message: "Открыто в MacWhisper · файл в буфере обмена", revealURL: dest)
        } else {
            toast = Toast(message: "MacWhisper не найден. Файл в «Загрузки/Meteora» и в буфере обмена — вставьте его в любое приложение.",
                          revealURL: dest)
        }
    }

    // MARK: Transcription

    func transcribe() async {
        guard canTranscribe, let demuxer, let a = info?.audio, let url else { return }
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
            Result {
                let recognizer = try SpeechRecognizer(store: .shared, vadModel: vad)
                let decoder = try OpusTrackDecoder(demuxer: demuxer, info: a)
                return try recognizer.transcribe(decoder: decoder, isCancelled: { token.isCancelled }, progress: { p in
                    Task { @MainActor in if self?.transcribeProgress != nil { self?.transcribeProgress = p } }
                }, onSegment: { seg in
                    Task { @MainActor in self?.liveSegments.append(seg) }
                })
            }
        }.value

        transcribeProgress = nil
        transcribeToken = nil
        switch result {
        case .success(let segments):
            let tr = Transcript(sourceName: url.lastPathComponent, duration: duration,
                                engine: SpeechRecognizer.engineName, segments: segments)
            transcript = tr
            liveSegments = []
            TranscriptStore.save(tr, for: url)
            toast = Toast(message: segments.isEmpty ? "Речи в записи не найдено" : "Расшифровка готова: \(segments.count) фраз")
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
            let primary = ScenePlanner.primaryTimes(packets: info.videoPackets, duration: info.duration)
            let spikes = ScenePlanner.spikes(packets: info.videoPackets, width: info.video!.width, height: info.video!.height)
            var times = primary
            if thorough { times = (primary + ScenePlanner.secondaryTimes(primary: primary, spikes: spikes)).sorted() }
            let collector = SceneCollector(threshold: sceneThreshold)
            let video = info.video!
            // Preferred: decode frames ourselves via WebCodecs (exact, full
            // resolution, doesn't touch the player). Fallback: seek + snapshot.
            var codec: String?
            if let c = video.webCodecsCodec, await player.canDecode(codec: c, width: video.width, height: video.height) {
                codec = c
            } else {
                player.pause()
            }
            usedDecoder = codec != nil
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
                if let change = collector.consider(time: t, thumb: thumb, spikes: spikes),
                   let image = try await (codec != nil ? player.grabDecoded() : player.grabFrame()) {
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
        toast = Toast(message: "Текст \(frames.count) кадров скопирован")
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
