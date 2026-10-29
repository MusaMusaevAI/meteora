import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeteoraCore
import MeteoraASR

/// A recording read far enough to decode its audio: used where no player
/// is needed (batch processing).
struct LoadedMedia: @unchecked Sendable {
    var info: MediaInfo
    var origin: AudioOrigin?
    /// A temporary converted copy to delete afterwards, if any.
    var temporary: URL?

    static func load(_ url: URL, isCancelled: @escaping @Sendable () -> Bool,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> LoadedMedia {
        if url.pathExtension.lowercased() == "webm" {
            let (info, demuxer) = try await Task.detached(priority: .userInitiated) {
                try WebMDemuxer.analyze(url: url, progress: progress, isCancelled: isCancelled)
            }.value
            let origin = info.audio.flatMap { $0.codecID == "A_OPUS" ? AudioOrigin.webm(demuxer, $0) : nil }
            return LoadedMedia(info: info, origin: origin, temporary: nil)
        }
        if !(await MediaConverterSupport.needsConversion(url)),
           let info = try? await AssetProbe.analyze(url: url) {
            return LoadedMedia(info: info, origin: info.audio != nil ? .asset(url) : nil, temporary: nil)
        }
        let converted = try await MediaConverterSupport.convert(url, keepVideo: false, progress: progress, isCancelled: isCancelled)
        do {
            var info = try await AssetProbe.analyze(url: converted)
            info.fileSize = UInt64(max(0, (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
            return LoadedMedia(info: info, origin: info.audio != nil ? .asset(converted) : nil, temporary: converted)
        } catch {
            try? FileManager.default.removeItem(at: converted)
            throw error
        }
    }
}

/// Many recordings in a row: transcribe each on this Mac and save the
/// chosen formats into one folder.
@MainActor
final class BatchQueue: ObservableObject {
    static let shared = BatchQueue()

    enum Status: Equatable {
        case waiting
        case reading(Double)
        case transcribing(Double)
        case saving
        case done(files: Int, reused: Bool)
        case failed(String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var url: URL
        var status: Status = .waiting
        var title: String { sanitizedBaseName(url) }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var destination: URL?
    /// Keep a transcript made earlier instead of transcribing again.
    @Published var reuseTranscripts = true { didSet { UserDefaults.standard.set(reuseTranscripts, forKey: "batch.reuse") } }

    private var token: CancelToken?
    private static let destinationKey = "batch.destination"

    init() {
        reuseTranscripts = UserDefaults.standard.object(forKey: "batch.reuse") as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: Self.destinationKey) {
            var stale = false
            destination = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                   relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    var pending: Int { items.filter { !$0.status.isFinished }.count }
    var finished: Int { items.filter { if case .done = $0.status { return true }; return false }.count }

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.url.path))
        for u in urls where MediaFormats.isSupported(u) && !known.contains(u.path) {
            _ = u.startAccessingSecurityScopedResource()
            items.append(Item(url: u))
        }
    }

    func remove(_ item: Item) {
        guard !isRunning || item.status == .waiting || item.status.isFinished else { return }
        items.removeAll { $0.id == item.id }
        item.url.stopAccessingSecurityScopedResource()
    }

    func clearFinished() {
        for i in items where i.status.isFinished { i.url.stopAccessingSecurityScopedResource() }
        items.removeAll { $0.status.isFinished }
    }

    func chooseDestination() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Куда сохранять расшифровки"
        if let destination { panel.directoryURL = destination }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        destination = url
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.destinationKey)
        }
        return true
    }

    func cancel() { token?.cancel() }

    func start() {
        guard !isRunning, items.contains(where: { $0.status == .waiting }) else { return }
        guard destination != nil || chooseDestination(), let dest = destination else { return }
        guard SpeechModelController.shared.isInstalled, let vad = SpeechModelController.vadModelURL else { return }
        let token = CancelToken()
        self.token = token
        isRunning = true
        Task {
            let scoped = dest.startAccessingSecurityScopedResource()
            var recognizer: SpeechRecognizer?
            while let index = items.firstIndex(where: { $0.status == .waiting }) {
                if token.isCancelled { break }
                await process(index, dest: dest, vad: vad, recognizer: &recognizer, token: token)
                updateBadge()
            }
            for i in items.indices where items[i].status == .waiting && token.isCancelled { items[i].status = .cancelled }
            if scoped { dest.stopAccessingSecurityScopedResource() }
            isRunning = false
            self.token = nil
            updateBadge()
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    private func set(_ id: UUID, _ status: Status) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = status }
    }

    private func process(_ index: Int, dest: URL, vad: URL, recognizer: inout SpeechRecognizer?, token: CancelToken) async {
        let item = items[index]
        let id = item.id
        let url = item.url
        set(id, .reading(0))
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            let media = try await LoadedMedia.load(url, isCancelled: { token.isCancelled }, progress: { p in
                Task { @MainActor in BatchQueue.shared.set(id, .reading(p)) }
            })
            temporary = media.temporary
            MeetingJournal.shared.record(url: url, info: media.info, transcript: TranscriptStore.load(for: url))
            guard let origin = media.origin else { throw MediaError.unplayable }

            var transcript = reuseTranscripts ? TermDictionaryStore.shared.correct(TranscriptStore.load(for: url)) : nil
            let reused = transcript != nil
            if transcript == nil {
                set(id, .transcribing(0))
                if recognizer == nil {
                    recognizer = try SpeechRecognizer(store: .shared, vadModel: vad,
                                                      hotwords: TermDictionaryStore.shared.recognizerHints)
                }
                let rec = recognizer!
                let segments: [TranscriptSegment] = try await Task.detached(priority: .userInitiated) {
                    let decoder = try await origin.make()
                    return try rec.transcribe(decoder: decoder, isCancelled: { token.isCancelled }, progress: { p in
                        Task { @MainActor in BatchQueue.shared.set(id, .transcribing(p)) }
                    }, onSegment: { _ in })
                }.value
                if token.isCancelled { set(id, .cancelled); return }
                let tr = TermDictionaryStore.shared.corrector.correct(
                    Transcript(sourceName: url.lastPathComponent, duration: media.info.duration,
                               engine: SpeechRecognizer.engineName, segments: segments))
                TranscriptStore.save(tr, for: url)
                MeetingJournal.shared.updateTranscript(for: url, transcript: tr)
                transcript = tr
            }

            set(id, .saving)
            let settings = ExportSettings.shared
            let formats = settings.ordered
            let options = settings.options
            let meta = ReportExporter.Meta(title: item.title, sourceName: url.lastPathComponent, duration: media.info.duration)
            let base = item.title
            let tr = transcript
            let written = try await Task.detached(priority: .userInitiated) { () -> Int in
                var n = 0
                for f in formats {
                    let result = try TranscriptExporter.export(tr, frames: [], meta: meta, format: f, options: options, baseName: base)
                    try TranscriptExporter.write(result, to: dest, baseName: base, format: f)
                    n += 1
                }
                return n
            }.value
            set(id, .done(files: written, reused: reused))
        } catch {
            if token.isCancelled {
                set(id, .cancelled)
            } else if (error as? ExportError) == .nothingToExport {
                set(id, .failed("Речи в записи не найдено"))
            } else {
                set(id, .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    private func updateBadge() {
        let left = isRunning ? pending : 0
        NSApp.dockTile.badgeLabel = left > 0 ? "\(left)" : nil
    }
}

// MARK: - Window

@MainActor
enum BatchWindow {
    private static var window: NSWindow?

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Пакетная обработка"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 560, height: 480)
        w.backgroundColor = Theme.windowNS
        let host = NSHostingView(rootView: BatchView())
        // The window decides its size; long lists scroll instead of
        // stretching it past the screen.
        host.sizingOptions = []
        w.contentView = host
        w.setContentSize(NSSize(width: 640, 600))
        w.setFrameAutosaveName("MeteoraBatch2")
        if !w.setFrameUsingName("MeteoraBatch2") { w.center() }
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    static func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaFormats.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Выберите записи — они расшифруются по очереди"
        panel.prompt = "Добавить"
        guard panel.runModal() == .OK else { return }
        BatchQueue.shared.add(panel.urls)
        show()
    }
}

struct BatchView: View {
    @ObservedObject var queue = BatchQueue.shared
    @ObservedObject var settings = ExportSettings.shared
    @ObservedObject var speech = SpeechModelController.shared
    @State private var showOptions = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Пакетная обработка").titleStyle(22).foregroundStyle(Theme.text)
                Text(summary).font(Theme.ui(12)).foregroundStyle(Theme.secondary)
            }
            .padding(.top, 34)

            if !speech.isInstalled { modelBanner.padding(.top, 16) }

            list.padding(.top, 16)

            settingsPanel.padding(.top, 14)

            HStack(spacing: 10) {
                Button("Добавить записи…") { BatchWindow.presentOpenPanel() }
                    .buttonStyle(LinkButtonStyle())
                if queue.items.contains(where: { $0.status.isFinished }) && !queue.isRunning {
                    Button("Убрать готовые") { queue.clearFinished() }.buttonStyle(LinkButtonStyle())
                }
                Spacer()
                if queue.isRunning {
                    Button("Остановить") { queue.cancel() }
                        .buttonStyle(SecondaryButtonStyle()).frame(width: 140)
                } else {
                    Button("Начать") { queue.start() }
                        .buttonStyle(PrimaryButtonStyle()).frame(width: 140)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!speech.isInstalled || settings.formats.isEmpty || !queue.items.contains { $0.status == .waiting })
                }
            }
            .padding(.vertical, 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NebulaBackground(intensity: 0.6))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in BatchQueue.shared.add([url]) }
                }
            }
            return true
        }
        .overlay { if dropTargeted { DropOverlay() } }
    }

    private var summary: String {
        if queue.items.isEmpty { return "Записи расшифровываются по очереди, файлы сохраняются в одну папку." }
        var s = ru(queue.items.count, "запись", "записи", "записей")
        if queue.finished > 0 { s += " · готово \(queue.finished)" }
        return s
    }

    private var modelBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform").foregroundStyle(Theme.accent)
            Text("Для расшифровки нужна модель речи — \(speech.sizeText), один раз.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.text)
            Spacer()
            if let p = speech.progress {
                ThinProgress(value: p).frame(width: 90)
            } else {
                Button("Загрузить") { Task { await speech.download() } }.buttonStyle(SecondaryButtonStyle()).frame(width: 110)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accentSoft))
    }

    @ViewBuilder private var list: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
        if queue.items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.tertiary)
                Text("Перетащите сюда записи").font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.text)
                Button("Выбрать записи…") { BatchWindow.presentOpenPanel() }
                    .buttonStyle(PrimaryButtonStyle()).frame(width: 180).padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(Theme.surface))
            .overlay(shape.strokeBorder(Theme.hairline))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queue.items) { item in
                        BatchRow(item: item, canRemove: !queue.isRunning || item.status == .waiting) { queue.remove(item) }
                        if item.id != queue.items.last?.id { Hairline().padding(.leading, 48) }
                    }
                }
            }
            .background(shape.fill(Theme.surface))
            .overlay(shape.strokeBorder(Theme.hairline))
            .clipShape(shape)
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(Theme.tertiary)
                Text("Папка").foregroundStyle(Theme.secondary)
                Text(queue.destination?.lastPathComponent ?? "выбор при запуске")
                    .foregroundStyle(queue.destination == nil ? Theme.secondary : Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Button(queue.destination == nil ? "Выбрать…" : "Изменить…") { _ = queue.chooseDestination() }
                    .buttonStyle(LinkButtonStyle()).disabled(queue.isRunning)
                Spacer()
            }
            .font(Theme.ui(12.5))
            HStack(spacing: 6) {
                Image(systemName: "doc").foregroundStyle(Theme.tertiary)
                Text("Форматы").foregroundStyle(Theme.secondary)
                Text(settings.ordered.map(\.short).joined(separator: ", ").ifEmpty("не выбраны"))
                    .foregroundStyle(settings.formats.isEmpty ? Theme.danger : Theme.text).lineLimit(1)
                Button(showOptions ? "Скрыть" : "Настроить…") { withAnimation(.easeOut(duration: 0.18)) { showOptions.toggle() } }
                    .buttonStyle(LinkButtonStyle())
                Spacer()
            }
            .font(Theme.ui(12.5))
            Toggle("Использовать готовые расшифровки", isOn: $queue.reuseTranscripts)
                .toggleStyle(.checkbox).tint(Theme.accent).font(Theme.ui(12.5)).foregroundStyle(Theme.text)
            if showOptions {
                ExportOptionsForm(settings: settings, hasFrames: false, showsFrames: false)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
                    .transition(.opacity)
            }
        }
        .disabled(queue.isRunning)
    }
}

private struct BatchRow: View {
    var item: BatchQueue.Item
    var canRemove: Bool
    var remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if let p = progress { ThinProgress(value: p, active: true).frame(width: 120) }
                    Text(statusText).font(Theme.ui(11.5).monospacedDigit()).foregroundStyle(statusColor).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if hover && canRemove {
                Button(action: remove) { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle()).help("Убрать из очереди")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private var progress: Double? {
        switch item.status {
        case .reading(let p): return p
        case .transcribing(let p): return p
        default: return nil
        }
    }

    @ViewBuilder private var icon: some View {
        switch item.status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.danger)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(Theme.tertiary)
        case .waiting: Image(systemName: "clock").foregroundStyle(Theme.tertiary)
        default: ProgressView().controlSize(.small)
        }
    }

    private var statusText: String {
        switch item.status {
        case .waiting: return "В очереди"
        case .reading: return "Чтение файла…"
        case .transcribing(let p): return "Расшифровка · \(Int(p * 100)) %"
        case .saving: return "Сохранение…"
        case .done(let n, let reused):
            return "Готово · \(ru(n, "файл", "файла", "файлов"))" + (reused ? " · расшифровка была готова" : "")
        case .failed(let m): return m
        case .cancelled: return "Остановлено"
        }
    }

    private var statusColor: Color {
        if case .failed = item.status { return Theme.danger }
        return Theme.secondary
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
