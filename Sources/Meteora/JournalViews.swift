import SwiftUI
import AppKit
import MeteoraCore

/// Start screen once there is history: meetings first, opening a new file
/// one click away. With an empty journal the classic drop screen is shown.
struct HomeView: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var journal = MeetingJournal.shared
    var dropTargeted: Bool
    @State private var query = ""
    @State private var pendingRemoval: JournalEntry?
    @State private var highlighted: JournalEntry.ID?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let results = journal.search(query)
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, 34)
            SearchField(text: $query, focused: $searchFocused) {
                if let e = (highlighted.flatMap { id in results.first { $0.id == id } } ?? results.first),
                   !journal.missing.contains(e.id) { open(e) }
            }
            .onKeyPress(.downArrow) { move(1, in: results); return .handled }
            .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
            .onChange(of: query) { _, _ in highlighted = nil }
                .padding(.top, 22)
            HStack(alignment: .firstTextBaseline) {
                Text(query.isEmpty ? "Недавние записи" : "Найдено")
                    .font(Theme.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Text("\(results.count)")
                    .font(Theme.ui(12).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.top, 22)
            .padding(.bottom, 6)
            .padding(.horizontal, 2)

            if results.isEmpty {
                VStack(spacing: 6) {
                    Text("Ничего не нашлось").font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.text)
                    Text("Поиск идёт по названиям и тексту расшифровок.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                Spacer()
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { entry in
                            JournalRow(entry: entry, query: query,
                                       missing: journal.missing.contains(entry.id),
                                       highlighted: highlighted == entry.id,
                                       open: { open(entry) },
                                       remove: { pendingRemoval = entry })
                            if entry.id != results.last?.id { Hairline().padding(.leading, 58) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.automatic)
            }
            PrivacyNote()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
        .overlay { if dropTargeted { DropOverlay() } }
        .animation(.easeOut(duration: 0.16), value: dropTargeted)
        .onAppear { journal.refreshAvailability() }
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .confirmationDialog(pendingRemoval.map { "Убрать «\($0.title)» из списка?" } ?? "",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Убрать", role: .destructive) {
                if let e = pendingRemoval { withAnimation(.easeOut(duration: 0.2)) { journal.remove(e) } }
                pendingRemoval = nil
            }
            Button("Отмена", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Сохранённая расшифровка будет удалена. Сам файл записи останется на месте.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            LogoMark().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Meteora").titleStyle(22).foregroundStyle(Theme.text)
                Text("Перетащите запись в окно или выберите файл")
                    .font(Theme.ui(12)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button("Открыть запись…") { model.presentOpenPanel() }
                .buttonStyle(PrimaryButtonStyle())
                .frame(width: 170)
                .keyboardShortcut("o", modifiers: .command)
        }
    }

    private func move(_ step: Int, in results: [JournalEntry]) {
        guard !results.isEmpty else { return }
        let i = highlighted.flatMap { id in results.firstIndex { $0.id == id } } ?? (step > 0 ? -1 : results.count)
        highlighted = results[max(0, min(results.count - 1, i + step))].id
    }

    private func open(_ entry: JournalEntry) {
        guard let url = journal.resolve(entry) else { return }
        model.open(url)
    }
}

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
            TextField("Поиск по названиям и расшифровкам", text: $text)
                .onSubmit(onSubmit)
                .textFieldStyle(.plain)
                .font(Theme.ui(13.5))
                .focused(focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiary)
                    .help("Очистить")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(focused.wrappedValue ? Theme.accent.opacity(0.55) : Theme.hairline, lineWidth: 1))
    }
}

struct JournalRow: View {
    var entry: JournalEntry
    var query: String
    var missing: Bool
    var highlighted: Bool = false
    var open: () -> Void
    var remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(missing ? Theme.surfaceSunken : Theme.accentSoft)
                Image(systemName: entry.hasVideo ? "play.rectangle" : "waveform")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(missing ? Theme.tertiary : Theme.accent)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(Theme.ui(13.5, weight: .medium))
                    .foregroundStyle(missing ? Theme.tertiary : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(Theme.ui(11.5).monospacedDigit())
                    .foregroundStyle(missing ? Theme.danger : Theme.secondary)
                    .lineLimit(1)
                if let snippet {
                    Text(snippet)
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hover || missing {
                Button(action: remove) { Image(systemName: missing ? "xmark" : "trash") }
                    .buttonStyle(IconButtonStyle())
                    .help(missing ? "Убрать из списка" : "Убрать из списка и удалить расшифровку")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(highlighted ? Theme.accentSoft : hover && !missing ? Theme.accentSoft.opacity(0.45) : Color.clear)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture { if !missing { open() } }
        .contextMenu {
            Button("Открыть") { open() }.disabled(missing)
            Button("Показать в Finder") { reveal() }.disabled(missing)
            Divider()
            Button("Убрать из списка…", role: .destructive) { remove() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !missing { open() } }
    }

    private var subtitle: String {
        if missing { return "Файл не найден — его переместили или удалили" }
        var parts = [Self.dateText(entry.date), Self.durationText(entry.duration)]
        if entry.hasTranscript { parts.append("есть расшифровка") }
        return parts.joined(separator: "  ·  ")
    }

    /// Where the search hit is in the transcript, or the opening lines.
    private var snippet: String? {
        let q = query.lowercased().split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard !q.isEmpty else { return nil }
        guard !entry.title.lowercased().contains(q) else { return nil }
        guard let r = entry.searchText.range(of: q) else { return nil }
        let start = entry.searchText.index(r.lowerBound, offsetBy: -60, limitedBy: entry.searchText.startIndex) ?? entry.searchText.startIndex
        let end = entry.searchText.index(r.upperBound, offsetBy: 100, limitedBy: entry.searchText.endIndex) ?? entry.searchText.endIndex
        let text = String(entry.searchText[start..<end]).trimmingCharacters(in: .whitespaces)
        return (start > entry.searchText.startIndex ? "…" : "") + text + (end < entry.searchText.endIndex ? "…" : "")
    }

    private func reveal() {
        guard let url = MeetingJournal.shared.resolve(entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func dateText(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(.dateTime.hour().minute().locale(Locale(identifier: "ru_RU")))
        if cal.isDateInToday(d) { return "Сегодня, \(time)" }
        if cal.isDateInYesterday(d) { return "Вчера, \(time)" }
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: Date())
        let day = sameYear
            ? d.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "ru_RU")))
            : d.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU")))
        return "\(day), \(time)"
    }

    static func durationText(_ s: Double) -> String {
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h) ч \(m) мин" : "\(h) ч" }
        if m > 0 { return "\(m) мин" }
        return "\(total) с"
    }
}

struct DropOverlay: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            shape.fill(Theme.background.opacity(0.92))
            shape.strokeBorder(Nacre.gradient(.leading, .trailing), lineWidth: 2)
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Отпустите, чтобы открыть").font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.text)
            }
        }
        .padding(16)
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}
