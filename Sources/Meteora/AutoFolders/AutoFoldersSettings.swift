import SwiftUI
import MeteoraCore

/// Settings → Автопапки: which folders Meteora watches, what it makes from
/// each new recording, and how it runs in the background.
struct AutoFoldersSettings: View {
    @ObservedObject var store = AutoFolderStore.shared
    @ObservedObject var login = LoginItem.shared
    @ObservedObject var notifier = AutoFolderNotifier.shared
    @State private var expanded: UUID?
    @State private var message: String?

    var body: some View {
        SettingsCard {
            AutoFolderStatusRow(store: store)
        }

        SettingsCard(title: "Папки") {
            if store.folders.isEmpty {
                Text("Пока ни одной. Добавьте папку, куда сохраняются записи встреч, — например «Документы/Телемост». Каждая новая запись там будет расшифрована сама, без открытия Meteora.")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.folders) { f in
                folderRow(f)
                if f.id != store.folders.last?.id { Divider() }
            }
            HStack(spacing: 10) {
                Button {
                    if let f = store.addFolder() { expanded = f.id; offerExisting(f) }
                } label: { Label("Добавить папку…", systemImage: "plus") }
                    .buttonStyle(SecondaryButtonStyle())
                if store.shouldSuggestTelemost {
                    Button {
                        if let f = store.suggestTelemost() { expanded = f.id; offerExisting(f) }
                    } label: { Label("Документы/Телемост", systemImage: "video") }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Папка, куда Телемост сохраняет записи")
                }
            }
            .padding(.top, 4)
            if let message {
                Text(message).font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)
            }
        }

        SettingsCard(title: "В фоне") {
            SettingsToggle(title: "Уведомлять о готовых расшифровках",
                           detail: notifier.permission == .denied
                               ? "Уведомления запрещены в Системных настройках."
                               : "Короткое уведомление, когда запись обработана или не получилась.",
                           isOn: Binding(get: { notifier.isEnabled }, set: { on in
                               notifier.isEnabled = on
                               if on { notifier.requestAuthorizationIfNeeded() }
                           }))
            if notifier.permission == .denied {
                Button("Открыть настройки уведомлений") { notifier.openSystemSettings() }.buttonStyle(LinkButtonStyle())
            }
            Divider()
            SettingsToggle(title: "Запускать при входе в систему",
                           detail: "Meteora тихо стартует в строке меню и следит за папками, даже если вы её не открывали.",
                           isOn: Binding(get: { login.state == .on || login.state == .needsApproval },
                                         set: { _ = login.setEnabled($0) }))
                .disabled(login.state == .unavailable)
            if let e = login.error {
                HStack {
                    Text(e).font(Theme.ui(11.5)).foregroundStyle(Theme.danger)
                    Button("Открыть") { login.openSystemSettings() }.buttonStyle(LinkButtonStyle())
                }
            }
            Text("Пока включена хотя бы одна папка, значок Meteora в строке меню показывает ход работы; после закрытия окна приложение продолжает следить.")
                .font(Theme.ui(11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }

        if !store.recent.isEmpty {
            SettingsCard(title: "Недавно") {
                ForEach(store.recent.prefix(6)) { r in
                    HStack(spacing: 8) {
                        Image(systemName: r.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(r.succeeded ? Theme.accent : Theme.danger)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.title).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                            Text(r.message).font(Theme.ui(11)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Открыть") { store.openRecording(path: r.recordingPath) }.buttonStyle(LinkButtonStyle())
                    }
                }
            }
        }
    }

    private func offerExisting(_ f: WatchedFolder) {
        let n = store.existingCount(f.id)
        message = n > 0 ? "В папке уже есть записей: \(n). Их можно обработать кнопкой «Обработать имеющиеся»." : nil
    }

    @ViewBuilder private func folderRow(_ f: WatchedFolder) -> some View {
        let open = expanded == f.id
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { f.isEnabled }, set: { store.setEnabled(f.id, $0) }))
                    .toggleStyle(.switch).controlSize(.small).tint(Theme.accent).labelsHidden()
                AutoFolderSummaryText(folder: f, problem: store.unavailable[f.id])
                Spacer(minLength: 8)
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded = open ? nil : f.id } } label: {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0))
                }
                .buttonStyle(IconButtonStyle()).foregroundStyle(Theme.secondary)
                .help(open ? "Свернуть" : "Что делать с новыми записями")
            }
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Форматы").font(Theme.ui(11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                    HStack(spacing: 6) {
                        ForEach(ExportFormat.allCases, id: \.self) { fmt in
                            let on = f.formats.contains(fmt)
                            Button(fmt.short) {
                                var set = f.formats
                                if on { if set.count > 1 { set.remove(fmt) } } else { set.insert(fmt) }
                                store.setFormats(f.id, set)
                            }
                            .buttonStyle(.plain)
                            .font(Theme.ui(11.5, weight: .semibold))
                            .foregroundStyle(on ? Theme.onAccent : Theme.secondary)
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(Capsule().fill(on ? Theme.accent : Theme.surfaceSunken))
                        }
                    }
                    Toggle(isOn: Binding(get: { f.separateSpeakers }, set: { v in store.update(f.id) { $0.separateSpeakers = v } })) {
                        Text("Разделять по говорящим" + (store.needsSpeakerModel(f.id) ? " — сначала скачайте модель голосов" : ""))
                            .font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                    }
                    .toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
                    Toggle(isOn: Binding(get: { f.summarize }, set: { v in store.update(f.id) { $0.summarize = v } })) {
                        Text("Составлять итоги встречи" + (store.needsSummarySetup(f.id) ? " — сначала выберите модель итогов" : ""))
                            .font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                    }
                    .toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
                    HStack(spacing: 8) {
                        Text("Куда класть").font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                        Picker("", selection: Binding(get: { f.output.subfolderName == nil ? 0 : 1 }, set: { v in
                            store.update(f.id) { $0.output = v == 0 ? .besideRecording : .subfolder("Расшифровки") }
                        })) {
                            Text("Рядом с записью").tag(0)
                            Text("В папку «Расшифровки»").tag(1)
                        }
                        .labelsHidden().fixedSize()
                    }
                    HStack(spacing: 12) {
                        let existing = store.existingCount(f.id)
                        if existing > 0 {
                            Button("Обработать имеющиеся (\(existing))") {
                                let n = store.processExisting(f.id)
                                message = n > 0 ? "В очереди: \(n)." : "Новых записей нет."
                            }
                            .buttonStyle(LinkButtonStyle())
                        }
                        Button("Показать в Finder") { store.revealInFinder(f.id) }.buttonStyle(LinkButtonStyle())
                        Spacer()
                        Button("Не следить", role: .destructive) { store.remove(f.id) }
                            .buttonStyle(.plain).foregroundStyle(Theme.danger).font(Theme.ui(12))
                    }
                }
                .padding(.leading, 46)
            }
        }
    }
}
