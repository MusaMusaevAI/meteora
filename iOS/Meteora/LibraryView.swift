import SwiftUI
import UniformTypeIdentifiers

/// The list of recordings: the iPhone's start screen.
struct LibraryView: View {
    @EnvironmentObject var router: Router
    @ObservedObject var library = Library.shared
    @ObservedObject var recorder = Recorder.shared
    @ObservedObject var shared = SharedFolder.shared
    @State private var query = ""
    @State private var importing = false
    @State private var renaming: Recording?
    @State private var newName = ""
    @State private var deleting: Recording?

    private var results: [Recording] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = library.ordered
        guard !q.isEmpty else { return all }
        return all.filter { $0.displayTitle.lowercased().contains(q) || $0.title.lowercased().contains(q) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            NebulaBackground(intensity: library.items.isEmpty ? 1 : 0.7).ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 10) {
                    header
                    if library.items.isEmpty {
                        empty
                    } else {
                        ForEach(results) { r in
                            Button { router.open(r.id) } label: { RecordingRow(recording: r) }
                                .buttonStyle(.plain)
                                .contextMenu { menu(r) }
                        }
                        if results.isEmpty {
                            Text("Ничего не найдено").font(Theme.ui(15)).foregroundStyle(Theme.secondary).padding(.top, 30)
                        }
                    }
                    Color.clear.frame(height: 110)
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable {
                await library.scanDocuments()
                await shared.scan()
            }
            recordBar
        }
        .navigationBarHidden(true)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie, UTType(filenameExtension: "webm") ?? .data],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                var last: Recording?
                for u in urls { last = await library.importFile(u) ?? last }
                if urls.count == 1, let last { router.open(last.id) }
            }
        }
        .alert("Переименовать", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Название", text: $newName)
            Button("Готово") { if let r = renaming { library.rename(r.id, to: newName) }; renaming = nil }
            Button("Отмена", role: .cancel) { renaming = nil }
        } message: {
            Text("Название меняется в Meteora и в экспорте. Сам файл не переименовывается.")
        }
        .confirmationDialog(deleting.map { "Удалить «\($0.displayTitle)»?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let r = deleting { withAnimation { library.delete(r.id) } }
                deleting = nil
            }
        } message: {
            Text(deleting?.place == .shared
                 ? "Запись уберётся из списка, файл в общей папке останется."
                 : "Файл записи и его расшифровка будут удалены с iPhone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LogoMark().frame(width: 32, height: 32).background(GlowHalo(size: 44))
                Text("Meteora").font(Theme.display(24, weight: .medium)).foregroundStyle(Theme.text)
                Spacer()
                Menu {
                    Picker("Порядок", selection: $library.order) {
                        ForEach(Library.Order.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 16, weight: .medium))
                        .frame(width: 40, height: 40)
                }
                Button { importing = true } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
                }
                .accessibilityLabel("Добавить запись из Файлов")
                Button { router.showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 17, weight: .medium)).frame(width: 40, height: 40)
                }
                .accessibilityLabel("Настройки")
            }
            .foregroundStyle(Theme.accent)
            if !library.items.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                    TextField("Поиск по записям", text: $query).font(Theme.ui(16))
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(Theme.tertiary)
                    }
                }
                .padding(.horizontal, 12).frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface.opacity(0.85)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline.opacity(0.8)))
            }
            if let p = shared.problem {
                Label(p, systemImage: "exclamationmark.icloud").font(Theme.ui(13)).foregroundStyle(Theme.danger)
            }
        }
        .padding(.top, 8).padding(.bottom, 6)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 60)
            LogoMark().frame(width: 72, height: 72).background(GlowHalo(size: 96))
            Text("Пока нет записей").titleStyle(24).foregroundStyle(Theme.text)
            Text("Запишите встречу или добавьте файл из «Файлов» — Meteora расшифрует его прямо на iPhone.")
                .font(Theme.ui(15)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            Button { importing = true } label: { Label("Добавить из Файлов", systemImage: "folder") }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 6)
            if !shared.isSet {
                Button("Подключить общую папку с Mac") { router.showSettings = true }
                    .font(Theme.ui(15, weight: .medium)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 20)
    }

    private var recordBar: some View {
        Button { router.showRecorder = true } label: {
            HStack(spacing: 10) {
                if recorder.isActive {
                    RecordingDot(paused: recorder.state == .paused, size: 10)
                    Text(ActivityTimer.format(recorder.elapsed)).monospacedDigit()
                    Text("· идёт запись").foregroundStyle(Theme.onAccent.opacity(0.8))
                } else {
                    Circle().fill(Theme.record).frame(width: 12, height: 12)
                    Text("Записать встречу")
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .background(alignment: .bottom) {
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .bottom)
                .frame(height: 120).ignoresSafeArea().allowsHitTesting(false)
        }
    }

    @ViewBuilder private func menu(_ r: Recording) -> some View {
        Button { library.togglePin(r.id) } label: {
            Label(r.pinned ? "Открепить" : "Закрепить вверху", systemImage: r.pinned ? "pin.slash" : "pin")
        }
        Button { newName = r.displayTitle; renaming = r } label: { Label("Переименовать", systemImage: "pencil") }
        Button(role: .destructive) { deleting = r } label: { Label("Удалить", systemImage: "trash") }
    }
}

struct RecordingRow: View {
    var recording: Recording

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentSoft)
                Image(systemName: recording.hasVideo ? "play.rectangle" : "waveform")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if recording.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                    Text(recording.displayTitle).font(Theme.ui(16, weight: .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(2)
                }
                Text("\(Format.date(recording.date)) · \(Format.duration(recording.duration))")
                    .font(Theme.ui(13)).foregroundStyle(Theme.secondary)
                HStack(spacing: 6) {
                    if let w = recording.words {
                        Badge(text: w > 0 ? ru(w, "слово", "слова", "слов") : "без речи", icon: "text.alignleft")
                    }
                    if recording.hasSummary == true { Badge(text: "итоги", icon: "sparkles") }
                    if recording.place == .shared { Badge(text: "общая папка", icon: "icloud") }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.tertiary)
                .padding(.top, 14)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface.opacity(0.86)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline.opacity(0.8)))
        .contentShape(Rectangle())
    }
}

struct Badge: View {
    var text: String
    var icon: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(Theme.ui(11.5, weight: .medium))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 7).frame(height: 20)
        .background(Capsule().fill(Theme.accentSoft))
    }
}
