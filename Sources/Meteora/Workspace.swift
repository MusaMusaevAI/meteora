import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeteoraCore

// MARK: - Root: library | work area | parameters

/// Three panes, like the chat apps people already know: all recordings on
/// the left, the recording itself in the middle (player above, text below),
/// its parameters on the right. Both side panes can be hidden.
struct ContentView: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var journal = MeetingJournal.shared
    @AppStorage("layout.libraryVisible") private var libraryVisible = true
    @AppStorage("layout.inspectorVisible") private var inspectorVisible = true
    @AppStorage("layout.libraryWidth") private var libraryWidth: Double = 272
    @AppStorage("layout.inspectorWidth") private var inspectorWidth: Double = 440
    @State private var dropTargeted = false
    @State private var libraryDragStart: Double?
    @State private var inspectorDragStart: Double?

    static let libraryRange: ClosedRange<Double> = 220...380
    static let inspectorRange: ClosedRange<Double> = 320...480

    private var ready: Bool { model.loadState == .ready && model.player != nil }
    private var showLibrary: Bool { libraryVisible && !model.cinema }
    private var showInspector: Bool { ready && inspectorVisible && !model.cinema }

    var body: some View {
        GeometryReader { g in
            layout(width: g.size.width)
        }
        .background(NebulaBackground(intensity: ready ? 0.6 : 1, animated: !ready).ignoresSafeArea())
        .frame(minWidth: 760, minHeight: 600)
    }

    /// Fits the panes into the window: the centre keeps at least 440 pt,
    /// the parameters give way first, then the list steps aside.
    @ViewBuilder private func layout(width W: CGFloat) -> some View {
        let centerMin: CGFloat = 440, handles: CGFloat = 22
        let wantLib = showLibrary ? CGFloat(libraryWidth) : 0
        let wantInsp = showInspector ? CGFloat(inspectorWidth) : 0
        let fitsBoth = W - wantLib - wantInsp - handles >= centerMin
        let insp: CGFloat = showInspector ? max(CGFloat(Self.inspectorRange.lowerBound), min(wantInsp, W - wantLib - handles - centerMin)) : 0
        let libVisible = showLibrary && (fitsBoth || W - insp - wantLib - handles >= centerMin)
        let lib: CGFloat = libVisible ? wantLib : 0
        HStack(spacing: 0) {
            if libVisible {
                LibrarySidebar(model: model, hide: { withAnimation(.easeOut(duration: 0.2)) { libraryVisible = false } })
                    .frame(width: lib)
                    .background(PaneBackground().ignoresSafeArea())
                    .transition(.move(edge: .leading).combined(with: .opacity))
                SplitHandle(axis: .horizontal, collapsed: false, help: "Потяните, чтобы изменить ширину списка") { delta in
                    let start = libraryDragStart ?? libraryWidth
                    if libraryDragStart == nil { libraryDragStart = libraryWidth }
                    libraryWidth = min(max(Self.libraryRange.lowerBound, start + delta), Self.libraryRange.upperBound)
                } onEnd: {
                    libraryDragStart = nil
                } onDoubleClick: {
                    withAnimation(.easeOut(duration: 0.2)) { libraryVisible = false }
                }
            }

            VStack(spacing: 0) {
                if !model.cinema { paneBar(libraryShown: libVisible) }
                center
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) { if model.loadState != .ready { ToastView(model: model) } }
            }
            .frame(minWidth: 420)

            if showInspector, let player = model.player {
                SplitHandle(axis: .horizontal, collapsed: false, help: "Потяните, чтобы изменить ширину параметров") { delta in
                    let start = inspectorDragStart ?? inspectorWidth
                    if inspectorDragStart == nil { inspectorDragStart = inspectorWidth }
                    inspectorWidth = min(max(Self.inspectorRange.lowerBound, start - delta), Self.inspectorRange.upperBound)
                } onEnd: {
                    inspectorDragStart = nil
                } onDoubleClick: {
                    withAnimation(.easeOut(duration: 0.2)) { inspectorVisible = false }
                }
                Sidebar(model: model, player: player)
                    .frame(width: insp)
                    .background(PaneBackground().ignoresSafeArea())
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.22), value: showLibrary)
        .animation(.easeOut(duration: 0.22), value: showInspector)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard !providers.isEmpty else { return false }
            let group = DispatchGroup()
            var urls: [URL] = []
            let lock = NSLock()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { model.openMany(urls) }
            return true
        }
        .overlay { if dropTargeted { DropOverlay() } }
        .sheet(isPresented: $model.exportSheetShown) {
            ExportSheet(model: model) { model.exportSheetShown = false }
        }
        .sheet(isPresented: $model.summarySettingsShown) {
            SummarySettingsSheet { model.summarySettingsShown = false }
        }
        .background {
            // Keyboard: ⌥⌘L — list, ⌥⌘I — parameters.
            Button("") { withAnimation(.easeOut(duration: 0.2)) { libraryVisible.toggle() } }
                .keyboardShortcut("l", modifiers: [.command, .option]).hidden()
            Button("") { withAnimation(.easeOut(duration: 0.2)) { inspectorVisible.toggle() } }
                .keyboardShortcut("i", modifiers: [.command, .option]).hidden()
            Button("") { if model.hasVideo, model.loadState == .ready { model.toggleCinema() } }
                .keyboardShortcut("f", modifiers: [.command, .control]).hidden()
            if model.cinema {
                Button("") { model.toggleCinema() }.keyboardShortcut(.escape, modifiers: []).hidden()
            }
        }
    }

    /// The strip under the title bar: toggles for the side panes.
    private func paneBar(libraryShown: Bool) -> some View {
        HStack(spacing: 4) {
            if !libraryShown {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        // Hidden for lack of room: make room by folding the parameters.
                        if libraryVisible { inspectorVisible = false } else { libraryVisible = true }
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(IconButtonStyle())
                .help("Показать все записи (⌥⌘L)")
                .padding(.leading, 70) // clear of the window buttons
            }
            Spacer()
            if ready {
                Button { withAnimation(.easeOut(duration: 0.2)) { inspectorVisible.toggle() } } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(IconButtonStyle())
                .help(inspectorVisible ? "Скрыть параметры (⌥⌘I)" : "Показать параметры (⌥⌘I)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    @ViewBuilder private var center: some View {
        switch model.loadState {
        case .empty:
            if journal.entries.isEmpty {
                EmptyStateView(model: model, dropTargeted: dropTargeted)
            } else {
                CenterPlaceholder(model: model)
            }
        case .loading(let p):
            LoadingView(title: model.title, progress: p)
        case .failed(let message):
            FailureView(message: message, model: model)
        case .ready:
            if let player = model.player {
                WorkArea(model: model, player: player)
            }
        }
    }
}

/// Side panes: a quiet solid layer. (A live blur over the animated sky
/// looked nice but kept the GPU busy all the time.)
struct PaneBackground: View {
    var body: some View {
        Theme.inspector.opacity(0.94)
    }
}

// MARK: - Work area: player above, text below

struct WorkArea: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: PlayerController
    /// Share of the height given to the text panel under the player.
    @AppStorage("layout.bottomFraction") private var bottomFraction: Double = 0.55
    @AppStorage("layout.bottomCollapsed") private var bottomCollapsed = false
    @State private var dragStartFraction: Double?

    static let minStage: Double = 200
    static let minBottom: Double = 140

    var body: some View {
        GeometryReader { g in
            let hasPanel = !model.cinema && (model.showsFramesTab || model.showsTranscriptTab || model.showsSummaryTab)
            let available = max(1, g.size.height - (model.cinema ? 0 : 18) - 14)
            let maxBottom = max(Self.minBottom, available - Self.minStage)
            let height = min(max(Self.minBottom, available * bottomFraction), maxBottom)
            VStack(spacing: 0) {
                Stage(model: model, player: player)
                if hasPanel {
                    SplitHandle(axis: .vertical, collapsed: bottomCollapsed,
                                help: bottomCollapsed ? "Показать панель текста (двойной щелчок)"
                                                      : "Потяните, чтобы изменить размер; двойной щелчок — скрыть панель") { delta in
                        if bottomCollapsed {
                            bottomCollapsed = false
                            bottomFraction = Self.minBottom / available
                        }
                        let start = dragStartFraction ?? height / available
                        if dragStartFraction == nil { dragStartFraction = height / available }
                        bottomFraction = min(max(Self.minBottom, start * available - delta), maxBottom) / available
                    } onEnd: {
                        dragStartFraction = nil
                    } onDoubleClick: {
                        withAnimation(.easeOut(duration: 0.22)) { bottomCollapsed.toggle() }
                    }
                    if !bottomCollapsed {
                        BottomPanel(model: model, player: player, height: height)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, model.cinema ? 0 : 16)
            .padding(.bottom, model.cinema ? 0 : 18)
        }
        .overlay(alignment: .bottom) { ToastView(model: model).padding(.bottom, 8) }
        .animation(.easeOut(duration: 0.2), value: model.frames.count)
    }
}

// MARK: - Nothing open (but there is history)

struct CenterPlaceholder: View {
    @ObservedObject var model: MeetingModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            LogoMark().frame(width: 64, height: 64)
                .background(GlowHalo(size: 84))
            Text("Выберите запись слева").titleStyle(22).foregroundStyle(Theme.text)
            Text("или перетащите сюда новую — видео или звук")
                .font(Theme.ui(13)).foregroundStyle(Theme.secondary)
            HStack(spacing: 10) {
                Button { RecordingWindow.show() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.danger).frame(width: 8, height: 8)
                        Text("Записать встречу")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 180)
                Button("Открыть запись…") { model.presentOpenPanel() }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(width: 180)
            }
            .padding(.top, 8)
            Spacer()
            PrivacyNote().padding(.bottom, 18)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Library (left pane)

struct LibrarySidebar: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var journal = MeetingJournal.shared
    var hide: () -> Void
    @State private var query = ""
    @State private var pendingRemoval: JournalEntry?
    @State private var renaming: JournalEntry?
    @State private var newName = ""
    @State private var highlighted: JournalEntry.ID?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let results = journal.search(query)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                Button(action: hide) { Image(systemName: "sidebar.left") }
                    .buttonStyle(IconButtonStyle())
                    .help("Скрыть список (⌥⌘L)")
            }
            .frame(height: 38)
            .padding(.horizontal, 8)

            HStack(spacing: 9) {
                LogoMark().frame(width: 26, height: 26)
                    .background(GlowHalo(size: 34))
                Text("Meteora").font(Theme.display(18, weight: .medium)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)

            HStack(spacing: 8) {
                Button { RecordingWindow.show() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.danger).frame(width: 7, height: 7)
                        Text("Записать")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("Записать встречу: микрофон и звук Mac (⌘⇧R)")
                Button { model.presentOpenPanel() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Открыть")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Открыть запись (⌘O); несколько — пакетом")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            SearchField(text: $query, focused: $searchFocused) {
                if let e = (highlighted.flatMap { id in results.first { $0.id == id } } ?? results.first),
                   !journal.missing.contains(e.id) { open(e) }
            }
            .onKeyPress(.downArrow) { move(1, in: results); return .handled }
            .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
            .onChange(of: query) { _, _ in highlighted = nil }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Text(query.isEmpty ? "Записи" : "Найдено: \(results.count)")
                .font(Theme.ui(11.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)

            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    if results.isEmpty {
                        Text(journal.entries.isEmpty ? "Здесь появятся открытые и записанные встречи."
                                                     : "Ничего не нашлось. Поиск идёт по названиям и тексту расшифровок.")
                            .font(Theme.ui(12)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 6).padding(.vertical, 8)
                    }
                    ForEach(results) { entry in
                        LibraryRow(entry: entry, query: query,
                                   missing: journal.missing.contains(entry.id),
                                   selected: model.url?.path == entry.path,
                                   highlighted: highlighted == entry.id,
                                   open: { open(entry) },
                                   rename: { newName = entry.customTitle ?? entry.title; renaming = entry },
                                   remove: { pendingRemoval = entry })
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Hairline()
            HStack(spacing: 2) {
                footerButton("square.stack.3d.up", "Пакетная обработка (⌘⇧B)") { BatchWindow.show() }
                footerButton("character.book.closed", "Словарь (⌘⇧D)") { DictionaryWindow.show() }
                footerButton("internaldrive", "Хранилище (⌘,)") { StorageWindow.show(model: model) }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .onAppear { journal.refreshAvailability() }
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
        .confirmationDialog(pendingRemoval.map { "Убрать «\($0.customTitle ?? $0.title)» из списка?" } ?? "",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Убрать", role: .destructive) {
                if let e = pendingRemoval {
                    if model.url?.path == e.path { model.close() }
                    withAnimation(.easeOut(duration: 0.2)) { journal.remove(e) }
                }
                pendingRemoval = nil
            }
            Button("Отмена", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Сохранённая расшифровка будет удалена. Сам файл записи останется на месте.")
        }
        .alert("Переименовать запись", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Название", text: $newName)
            Button("Готово") {
                if let e = renaming { rename(e, to: newName) }
                renaming = nil
            }
            Button("Отмена", role: .cancel) { renaming = nil }
        } message: {
            Text("Название меняется в Meteora и в экспорте. Сам файл не переименовывается.")
        }
    }

    private func footerButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(IconButtonStyle())
            .foregroundStyle(Theme.secondary)
            .help(help)
    }

    private func move(_ step: Int, in results: [JournalEntry]) {
        guard !results.isEmpty else { return }
        let i = highlighted.flatMap { id in results.firstIndex { $0.id == id } } ?? (step > 0 ? -1 : results.count)
        highlighted = results[max(0, min(results.count - 1, i + step))].id
    }

    private func open(_ entry: JournalEntry) {
        guard model.url?.path != entry.path else { return }
        if model.isWorking {
            model.requestClose()
            guard model.loadState == .empty else { return }
        }
        guard let url = journal.resolve(entry) else { return }
        model.open(url)
    }

    private func rename(_ entry: JournalEntry, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let url = journal.resolve(entry) else { return }
        if model.url?.path == entry.path {
            model.rename(t)
        } else {
            MeetingJournal.shared.setTitle(t, for: url)
        }
    }
}

struct LibraryRow: View {
    var entry: JournalEntry
    var query: String
    var missing: Bool
    var selected: Bool
    var highlighted: Bool
    var open: () -> Void
    var rename: () -> Void
    var remove: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.hasVideo ? "play.rectangle" : "waveform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Theme.accent : missing ? Theme.tertiary : Theme.secondary)
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.customTitle ?? entry.title)
                    .font(Theme.ui(13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(missing ? Theme.tertiary : Theme.text)
                    .lineLimit(2)
                Text(subtitle)
                    .font(Theme.ui(11).monospacedDigit())
                    .foregroundStyle(missing ? Theme.danger : Theme.tertiary)
                    .lineLimit(1)
                if let snippet {
                    Text(snippet).font(Theme.ui(11.5)).foregroundStyle(Theme.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if hover && !missing {
                Menu {
                    Button("Переименовать…", action: rename)
                    Button("Показать в Finder") { reveal() }
                    Divider()
                    Button("Убрать из списка…", role: .destructive, action: remove)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(Theme.secondary)
            } else if missing {
                Button(action: remove) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Theme.tertiary)
                    .help("Убрать из списка")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(shape.fill(selected ? Theme.accentSoft : highlighted ? Theme.accentSoft.opacity(0.7)
                                : hover ? Theme.text.opacity(0.05) : .clear))
        .overlay(shape.strokeBorder(selected ? Theme.accent.opacity(0.25) : .clear))
        .contentShape(shape)
        .onHover { hover = $0 }
        .onTapGesture { if !missing { open() } }
        .contextMenu {
            Button("Открыть", action: open).disabled(missing)
            Button("Переименовать…", action: rename).disabled(missing)
            Button("Показать в Finder") { reveal() }.disabled(missing)
            Divider()
            Button("Убрать из списка…", role: .destructive, action: remove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if !missing { open() } }
    }

    private var subtitle: String {
        if missing { return "Файл не найден" }
        var parts = [LibraryRow.dateText(entry.date), LibraryRow.durationText(entry.duration)]
        if entry.hasTranscript { parts.append("текст") }
        return parts.joined(separator: " · ")
    }

    private var snippet: String? {
        let q = query.lowercased().split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard !q.isEmpty, !(entry.customTitle ?? entry.title).lowercased().contains(q),
              let r = entry.searchText.range(of: q) else { return nil }
        let t = entry.searchText
        let start = t.index(r.lowerBound, offsetBy: -40, limitedBy: t.startIndex) ?? t.startIndex
        let end = t.index(r.upperBound, offsetBy: 70, limitedBy: t.endIndex) ?? t.endIndex
        return (start > t.startIndex ? "…" : "") + String(t[start..<end]).trimmingCharacters(in: .whitespaces) + (end < t.endIndex ? "…" : "")
    }

    private func reveal() {
        guard let url = MeetingJournal.shared.resolve(entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func dateText(_ d: Date) -> String {
        let cal = Calendar.current
        let ru = Locale(identifier: "ru_RU")
        let time = d.formatted(.dateTime.hour().minute().locale(ru))
        if cal.isDateInToday(d) { return "Сегодня, \(time)" }
        if cal.isDateInYesterday(d) { return "Вчера, \(time)" }
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: Date())
        return sameYear ? d.formatted(.dateTime.day().month(.abbreviated).locale(ru))
                        : d.formatted(.dateTime.day().month(.abbreviated).year().locale(ru))
    }

    static func durationText(_ s: Double) -> String {
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h) ч \(m) мин" : "\(h) ч" }
        if m > 0 { return "\(m) мин" }
        return "\(total) с"
    }
}
