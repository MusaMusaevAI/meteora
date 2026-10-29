import SwiftUI
import AppKit
import MeteoraCore
import MeteoraASR
import MeteoraLLM

/// Everything Meteora keeps on disk, so the user can see it and clean up.
struct StorageItem: Identifiable, Hashable {
    enum Section: Int, CaseIterable {
        case model, summaryModel, transcripts, exports, temp
        var title: String {
            switch self {
            case .model: return "Модель распознавания речи"
            case .summaryModel: return "Модель для резюме встреч"
            case .transcripts: return "Сохранённые расшифровки"
            case .exports: return "Переданный звук — «Загрузки/Meteora»"
            case .temp: return "Временные файлы"
            }
        }
        var note: String? {
            switch self {
            case .model: return "Без неё расшифровка не работает — придётся скачать заново."
            case .summaryModel: return "Без неё резюме встреч не составляются — придётся скачать заново."
            case .transcripts: return "Meteora показывает их при повторном открытии записи."
            case .exports: return "Файлы будут перемещены в Корзину."
            case .temp: return nil
            }
        }
    }

    var id: String
    var section: Section
    var title: String
    var detail: String
    var bytes: Int64
    var urls: [URL]
}

@MainActor
final class StorageModel: ObservableObject {
    @Published private(set) var items: [StorageItem] = []
    @Published var selected: Set<String> = []
    @Published private(set) var loading = true
    @Published private(set) var deleting = false

    var selectedBytes: Int64 { items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    func reload() {
        loading = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { Self.scan() }.value
            items = found
            selected = selected.intersection(Set(found.map(\.id)))
            loading = false
        }
    }

    func toggleSection(_ s: StorageItem.Section) {
        let ids = Set(items.filter { $0.section == s }.map(\.id))
        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }

    func deleteSelected() async {
        deleting = true
        let doomed = items.filter { selected.contains($0.id) }
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for item in doomed {
                for url in item.urls {
                    switch item.section {
                    case .exports:
                        // User-visible files go to the Trash, not into oblivion.
                        if (try? fm.trashItem(at: url, resultingItemURL: nil)) == nil { try? fm.removeItem(at: url) }
                    default:
                        try? fm.removeItem(at: url)
                    }
                }
            }
        }.value
        SpeechModelController.shared.refresh()
        if doomed.contains(where: { $0.section == .summaryModel }) { SummaryModelController.shared.summarizer.unload() }
        SummaryModelController.shared.refresh()
        selected = []
        deleting = false
        reload()
    }

    nonisolated(unsafe) private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    nonisolated static func scan() -> [StorageItem] {
        let fm = FileManager.default
        var out: [StorageItem] = []

        // 1. Speech model
        let modelDir = ModelStore.shared.directory
        if fm.fileExists(atPath: modelDir.path) {
            out.append(StorageItem(id: "model", section: .model, title: "\(SpeechModel.displayName) — русская речь",
                                   detail: ModelStore.shared.isInstalled ? "Установлена и проверена" : "Загружена не полностью",
                                   bytes: ModelStore.directorySize(modelDir), urls: [modelDir]))
        }

        // 1b. Summary model
        let summaryDir = SummaryModelStore.shared.directory
        if fm.fileExists(atPath: summaryDir.path) {
            out.append(StorageItem(id: "summary-model", section: .summaryModel,
                                   title: "\(SummaryModel.displayName) — резюме встреч",
                                   detail: SummaryModelStore.shared.isInstalled ? "Установлена и проверена" : "Загружена не полностью",
                                   bytes: ModelStore.directorySize(summaryDir), urls: [summaryDir]))
        }

        // 2. Cached transcripts
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let files = try? fm.contentsOfDirectory(at: TranscriptStore.directory, includingPropertiesForKeys: [.fileSizeKey]) {
            for f in files where f.pathExtension == "json" {
                let size = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let tr = (try? Data(contentsOf: f)).flatMap { try? dec.decode(Transcript.self, from: $0) }
                let name = tr.map { sanitizedBaseName(URL(fileURLWithPath: $0.sourceName)) } ?? f.lastPathComponent
                let detail = tr.map { "\(ru($0.segments.count, "фраза", "фразы", "фраз")) · \(dateFormatter.string(from: $0.created))" } ?? "повреждённый файл"
                out.append(StorageItem(id: "tr:" + f.lastPathComponent, section: .transcripts, title: name,
                                       detail: detail, bytes: size, urls: [f]))
            }
        }

        // 3. Exported audio in ~/Downloads/Meteora
        if let files = try? fm.contentsOfDirectory(at: Folders.exports,
                                                   includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                                                   options: [.skipsHiddenFiles]) {
            for f in files {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard v?.isRegularFile == true else { continue }
                out.append(StorageItem(id: "ex:" + f.lastPathComponent, section: .exports,
                                       title: f.deletingPathExtension().lastPathComponent,
                                       detail: (v?.contentModificationDate).map { dateFormatter.string(from: $0) } ?? "",
                                       bytes: Int64(v?.fileSize ?? 0), urls: [f]))
            }
        }

        // 4. Temporary files left by exports and downloads
        var tempURLs: [URL] = []
        var tempBytes: Int64 = 0
        if let files = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for f in files where f.lastPathComponent.hasPrefix("meteora-") {
                tempURLs.append(f)
                tempBytes += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let size = ModelStore.directorySize(caches)
            if size > 0, let entries = try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
                tempURLs += entries
                tempBytes += size
            }
        }
        if tempBytes > 0 {
            out.append(StorageItem(id: "temp", section: .temp, title: "Временные файлы и кэш",
                                   detail: "\(tempURLs.count) объектов", bytes: tempBytes, urls: tempURLs))
        }
        return out.sorted { ($0.section.rawValue, -$0.bytes) < ($1.section.rawValue, -$1.bytes) }
    }
}

struct StorageView: View {
    @StateObject private var store = StorageModel()
    @State private var confirming = false
    var onChange: () -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Хранилище").titleStyle(22).foregroundStyle(Theme.text)
                Text("Отметьте, что можно удалить. Сами записи встреч Meteora не копирует и не трогает.")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.loading && store.items.isEmpty {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(30)
                    } else if store.items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.accent)
                            Text("Meteora ничего не хранит — всё чисто.").font(Theme.ui(13)).foregroundStyle(Theme.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(40)
                    }
                    ForEach(StorageItem.Section.allCases, id: \.self) { section in
                        let rows = store.items.filter { $0.section == section }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(section.title)
                                        .font(Theme.ui(13, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                    Spacer()
                                    if rows.count > 1 {
                                        Button("Отметить все") { store.toggleSection(section) }
                                            .buttonStyle(LinkButtonStyle())
                                    }
                                }
                                VStack(spacing: 0) {
                                    ForEach(rows) { item in row(item); if item.id != rows.last?.id { Hairline().padding(.leading, 36) } }
                                }
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
                                if let note = section.note {
                                    Text(note).font(Theme.ui(11)).foregroundStyle(Theme.tertiary)
                                }
                            }
                        }
                    }
                }
            }

            HStack {
                Text(store.selected.isEmpty ? "Всего: \(FileSizeText.string(store.totalBytes))"
                                            : "Выбрано: \(FileSizeText.string(store.selectedBytes))")
                    .font(Theme.ui(12.5).monospacedDigit()).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Готово") { close() }
                    .controlSize(.large)
                    .fixedSize()
                    .keyboardShortcut(.cancelAction)
                Button("Удалить выбранное", role: .destructive) { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.danger)
                    .controlSize(.large)
                    .fixedSize()
                    .disabled(store.selected.isEmpty || store.deleting)
            }
        }
        .padding(22)
        .frame(width: 580, height: 560)
        .background(Theme.background)
        .onAppear { store.reload() }
        .confirmationDialog("Удалить выбранное (\(FileSizeText.string(store.selectedBytes)))?", isPresented: $confirming) {
            Button("Удалить", role: .destructive) {
                Task {
                    await store.deleteSelected()
                    onChange()
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Звук из «Загрузки/Meteora» попадёт в Корзину. Модель и расшифровки удаляются сразу.")
        }
    }

    private func row(_ item: StorageItem) -> some View {
        let binding = Binding(get: { store.selected.contains(item.id) },
                              set: { on in if on { store.selected.insert(item.id) } else { store.selected.remove(item.id) } })
        return Toggle(isOn: binding) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(Theme.ui(13)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Text(item.detail).font(Theme.ui(11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(FileSizeText.string(item.bytes)).font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.secondary)
                    .monospacedDigit()
            }
        }
        .toggleStyle(.checkbox)
        .tint(Theme.accent)
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

/// Hosts the storage view in its own small window (from the sidebar or menu).
@MainActor
enum StorageWindow {
    private static var window: NSWindow?

    static func show(model: MeetingModel) {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Хранилище"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: StorageView(onChange: { [weak model] in model?.transcriptCacheDidChange() },
                                                           close: { window?.close() }))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
