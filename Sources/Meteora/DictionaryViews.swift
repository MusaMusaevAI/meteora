import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeteoraCore
import MeteoraASR

/// The user's terms, stored in the app's container. Applied to every
/// transcript as it is made and when it is shown, so edits take effect on
/// old meetings too.
@MainActor
final class TermDictionaryStore: ObservableObject {
    static let shared = TermDictionaryStore()

    @Published private(set) var terms: [Term] = [] {
        didSet { corrector = TermCorrector(terms: terms) }
    }
    private(set) var corrector = TermCorrector(terms: [])
    /// Called after every change (the open meeting re-applies the terms).
    var onChange: (() -> Void)?
    private let file: URL

    init(file: URL? = nil) {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        self.file = file ?? base.appendingPathComponent("Meteora/dictionary.json")
        if let data = try? Data(contentsOf: self.file), data.count < 8 << 20,
           let saved = try? JSONDecoder().decode([Term].self, from: data) {
            terms = saved
        } else {
            terms = StarterTerms.pensions
        }
        corrector = TermCorrector(terms: terms)
    }

    func correct(_ t: Transcript?) -> Transcript? { t.map { corrector.correct($0) } }

    func add(_ text: String = "", variants: [String] = []) -> Term {
        let t = Term(text: text, variants: variants)
        terms.insert(t, at: 0)
        save()
        return t
    }

    func update(_ term: Term) {
        guard let i = terms.firstIndex(where: { $0.id == term.id }) else { return }
        terms[i] = term
        save()
    }

    func remove(_ ids: Set<Term.ID>) {
        terms.removeAll { ids.contains($0.id) }
        save()
    }

    func restoreStarter() {
        let have = Set(terms.map { $0.text.lowercased() })
        terms.append(contentsOf: StarterTerms.pensions.filter { !have.contains($0.text.lowercased()) })
        save()
    }

    /// Adds new terms; an existing term gets the imported variants merged in.
    func merge(_ imported: [Term]) -> Int {
        var added = 0
        for t in imported {
            if let i = terms.firstIndex(where: { $0.text.lowercased() == t.text.lowercased() }) {
                let merged = Array(Set(terms[i].variants + t.variants)).sorted()
                terms[i].variants = merged
            } else {
                terms.append(t)
                added += 1
            }
        }
        save()
        return added
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(terms) { try? data.write(to: file, options: .atomic) }
        onChange?()
    }
}

// MARK: - Window

@MainActor
enum DictionaryWindow {
    private static var window: NSWindow?

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Словарь"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 420)
        w.backgroundColor = Theme.windowNS
        let host = NSHostingView(rootView: DictionaryView())
        // The window decides its size; long lists scroll instead of
        // stretching it past the screen.
        host.sizingOptions = []
        w.contentView = host
        w.setContentSize(NSSize(width: 600, 560))
        w.setFrameAutosaveName("MeteoraDictionary2")
        if !w.setFrameUsingName("MeteoraDictionary2") { w.center() }
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

struct DictionaryView: View {
    @ObservedObject var store = TermDictionaryStore.shared
    @AppStorage("asr.hints") private var asrHints = true
    @State private var hintsMissing = false
    @State private var hintsLoading = false
    @State private var query = ""
    @State private var selection: Set<Term.ID> = []
    @State private var message: String?
    @FocusState private var focusedTerm: Term.ID?

    private var filtered: [Term] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.terms }
        return store.terms.filter { ($0.text + " " + $0.variants.joined(separator: " ")).lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Словарь").titleStyle(22).foregroundStyle(Theme.text)
                Text("Как писать аббревиатуры, названия и термины. Расшифровки исправляются автоматически — и новые, и уже сделанные.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 34)

            Toggle(isOn: $asrHints) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Подсказывать термины распознавателю").font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.text)
                    Text("Модель речи заранее знает слова из словаря и чаще пишет их верно. Расшифровка идёт чуть дольше.")
                        .font(Theme.ui(11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
            .padding(.top, 14)
            .onAppear { hintsMissing = !ModelStore.shared.missingExtras.isEmpty }
            if asrHints, hintsMissing, SpeechModelController.shared.isInstalled {
                Button(hintsLoading ? "Загружаю…" : "Скачать файл подсказок (255 КБ)") {
                    hintsLoading = true
                    Task {
                        try? await ModelStore.shared.installExtras(isCancelled: { false })
                        hintsMissing = !ModelStore.shared.missingExtras.isEmpty
                        hintsLoading = false
                    }
                }
                .buttonStyle(LinkButtonStyle())
                .disabled(hintsLoading)
                .padding(.top, 4)
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                    TextField("Найти термин", text: $query).textFieldStyle(.plain).font(Theme.ui(13))
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                Button {
                    query = ""
                    let t = store.add()
                    DispatchQueue.main.async { focusedTerm = t.id }
                } label: { Label("Термин", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle()).frame(width: 120)
            }
            .padding(.top, 16)

            HStack {
                Text("Термин").frame(width: 170, alignment: .leading)
                Text("Как ещё может прозвучать — через запятую")
                Spacer()
            }
            .font(Theme.ui(11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { term in
                        TermRow(term: term, focused: $focusedTerm) { store.update($0) } remove: { store.remove([term.id]) }
                        if term.id != filtered.last?.id { Hairline().padding(.leading, 14) }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

            HStack(spacing: 14) {
                Button("Загрузить CSV…") { importCSV() }.buttonStyle(LinkButtonStyle())
                Button("Сохранить CSV…") { exportCSV() }.buttonStyle(LinkButtonStyle())
                Button("Вернуть стартовый набор") { store.restoreStarter(); message = "Стартовые термины на месте" }
                    .buttonStyle(LinkButtonStyle())
                Spacer()
                if let message { Text(message).font(Theme.ui(11.5)).foregroundStyle(Theme.secondary) }
                Text(ru(store.terms.count, "термин", "термина", "терминов"))
                    .font(Theme.ui(11.5).monospacedDigit()).foregroundStyle(Theme.tertiary)
            }
            .padding(.vertical, 14)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NebulaBackground(intensity: 0.5))
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, UTType(filenameExtension: "csv") ?? .data]
        panel.message = "CSV: термин; варианты через «|». Первая строка может быть заголовком."
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url), data.count < 4 << 20 else { return }
        let terms = TermCSV.parse(data)
        let added = store.merge(terms)
        message = terms.isEmpty ? "В файле не нашлось терминов" : "Добавлено: \(added)"
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "csv") ?? .commaSeparatedText]
        panel.nameFieldStringValue = "Словарь Meteora.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TermCSV.export(store.terms).write(to: url, options: .atomic)
            message = "Сохранено"
        } catch {
            message = "Не удалось сохранить"
        }
    }
}

private struct TermRow: View {
    @State var term: Term
    var focused: FocusState<Term.ID?>.Binding
    var commit: (Term) -> Void
    var remove: () -> Void
    @State private var variantsText = ""
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            TextField("Термин", text: $term.text)
                .textFieldStyle(.plain)
                .font(Theme.ui(13, weight: .medium))
                .frame(width: 160, alignment: .leading)
                .focused(focused, equals: term.id)
                .onSubmit { save() }
            TextField(automatic, text: $variantsText)
                .textFieldStyle(.plain)
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.secondary)
                .onSubmit { save() }
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(IconButtonStyle())
                .opacity(hover ? 1 : 0)
                .help("Удалить термин")
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .onHover { hover = $0 }
        .onAppear { variantsText = term.variants.joined(separator: ", ") }
        .onChange(of: focused.wrappedValue) { old, _ in if old == term.id { save() } }
        .onDisappear { save() }
    }

    /// Placeholder: what Meteora already understands without variants.
    private var automatic: String {
        let spoken = TermCorrector.spokenForms(of: term.text).dropFirst().first
        return spoken.map { "например, «\($0)» — распознаётся само" } ?? "варианты, если распознаётся неверно"
    }

    private func save() {
        var t = term
        t.text = t.text.trimmingCharacters(in: .whitespaces)
        t.variants = variantsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        commit(t)
    }
}
