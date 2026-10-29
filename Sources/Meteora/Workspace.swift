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

    /// The strip at the top of the work area: pane toggles at its edges and
    /// the recording's name in the middle, with a close button — like a tab.
    /// The window's own title is hidden, so a long name never runs over the
    /// list of recordings.
    private func paneBar(libraryShown: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    if libraryShown {
                        libraryVisible = false
                    } else if libraryVisible {
                        // Hidden for lack of room: make room by folding the parameters.
                        inspectorVisible = false
                    } else {
                        libraryVisible = true
                    }
                }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(IconButtonStyle())
            .help(libraryShown ? "Скрыть список записей (⌥⌘L)" : "Показать список записей (⌥⌘L)")
            .padding(.leading, libraryShown ? 0 : 70) // clear of the window buttons

            Spacer(minLength: 8)
            if model.loadState != .empty {
                TitleTab(model: model)
            }
            Spacer(minLength: 8)

            Button {
                withAnimation(.easeOut(duration: 0.2)) { inspectorVisible.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(IconButtonStyle())
            .help(inspectorVisible ? "Скрыть параметры (⌥⌘I)" : "Показать параметры (⌥⌘I)")
            .opacity(ready ? 1 : 0)
            .disabled(!ready)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
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

/// Side panes: tinted glass. Translucent enough for a passing meteor to
/// show through, without a live blur (that kept the GPU busy).
struct PaneBackground: View {
    var body: some View {
        Theme.inspector.opacity(0.74)
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
            // Room for the window buttons.
            Color.clear.frame(height: 40)

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

            HStack(spacing: 6) {
                Text(query.isEmpty ? "Записи" : "Найдено: \(results.count)")
                    .font(Theme.ui(11.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                Spacer()
                Menu {
                    Picker("Порядок", selection: $journal.order) {
                        ForEach(MeetingJournal.Order.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 3) {
                        Text(journal.order == .meetingDate ? "по дате встречи" : "по добавлению")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(Theme.ui(11)).foregroundStyle(Theme.tertiary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Порядок списка. Закреплённые записи всегда сверху.")
            }
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
                                   togglePin: { withAnimation(.easeOut(duration: 0.2)) { journal.setPinned(!entry.isPinned, entry) } },
                                   remove: { pendingRemoval = entry })
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Hairline()
            HStack(spacing: 2) {
                footerButton("gearshape", "Настройки (⌘,)") { SettingsWindow.show(model: model) }
                footerButton("square.stack.3d.up", "Пакетная обработка (⌘⇧B)") { BatchWindow.show() }
                footerButton("character.book.closed", "Словарь (⌘⇧D)") { DictionaryWindow.show() }
                footerButton("internaldrive", "Хранилище") { SettingsWindow.show(.storage, model: model) }
                Spacer()
                UpdateBadge(model: model)
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
    var togglePin: () -> Void
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
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if entry.isPinned {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                            .accessibilityLabel("Закреплена")
                    }
                    Text(entry.customTitle ?? entry.title)
                        .font(Theme.ui(13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(missing ? Theme.tertiary : Theme.text)
                        .lineLimit(2)
                }
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
                    Button(entry.isPinned ? "Открепить" : "Закрепить вверху", action: togglePin)
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
            Button(entry.isPinned ? "Открепить" : "Закрепить вверху", action: togglePin)
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


/// The open recording's name with a close button, centred in the top strip.
struct TitleTab: View {
    @ObservedObject var model: MeetingModel
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.hasVideo ? "play.rectangle" : "waveform")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            Text(model.title)
                .font(Theme.ui(12.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.title)
            Button { model.requestClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.text.opacity(hover ? 0.10 : 0.0)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .onHover { hover = $0 }
            .help("Закрыть запись (⌘W)")
            .accessibilityLabel("Закрыть запись")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(Capsule().fill(Theme.surface.opacity(0.75)))
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .frame(maxWidth: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shown in the library footer when a newer build is out.
private struct UpdateBadge: View {
    let model: MeetingModel
    @ObservedObject var updates = UpdateChecker.shared
    var body: some View {
        if case .available(let build) = updates.state {
            Button { SettingsWindow.show(.updates, model: model) } label: {
                HStack(spacing: 4) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text("Обновление").font(Theme.ui(11, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 8).frame(height: 22)
                .background(Capsule().fill(Theme.accentSoft))
            }
            .buttonStyle(.plain)
            .help("Доступна сборка \(build)")
        }
    }
}
