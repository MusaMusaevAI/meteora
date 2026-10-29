import SwiftUI
import MeteoraLLM

struct SettingsView: View {
    @ObservedObject var models = Models.shared
    @ObservedObject var summary = SummarySettings.shared
    @ObservedObject var shared = SharedFolder.shared
    @ObservedObject var library = Library.shared
    @AppStorage(AppearanceSettings.meteorsKey) private var meteors = true
    @AppStorage(AppearanceSettings.skyKey) private var sky = true
    @AppStorage(HintsSettings.key) private var terms = ""
    @Environment(\.dismiss) private var dismiss
    @State private var pickingFolder = false
    @State private var keyDraft = ""
    @State private var keyProvider: CloudProvider?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    folderRows
                } header: {
                    Text("Общая папка с Mac")
                } footer: {
                    Text("Папка в iCloud Drive, которую видит и Mac: записи с iPhone попадают туда, Mac расшифровывает их автопапкой; записи с Mac появляются здесь.")
                }

                Section("Модели на iPhone") {
                    modelRow("Речь · GigaAM-v3", installed: models.speechInstalled, size: models.speechSize, kind: .speech)
                    modelRow("Голоса · говорящие", installed: models.speakersInstalled, size: models.speakersSize, kind: .speakers)
                    if let e = models.error { Text(e).foregroundStyle(Theme.danger).font(Theme.ui(13)) }
                }

                Section {
                    Picker("Чем составлять", selection: engineBinding) {
                        Text("Модель на iPhone").tag("local")
                        ForEach(CloudProvider.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if case .local = summary.engine {
                        Picker("Модель", selection: $models.summaryTier) {
                            ForEach(Models.summaryTiers) { t in
                                Text("\(t.title) · \(models.summarySize(t))\(models.summaryInstalled.contains(t) ? " ✓" : "")").tag(t)
                            }
                        }
                        modelRow("Модель итогов", installed: models.summaryInstalled.contains(models.summaryTier),
                                 size: models.summarySize(models.summaryTier), kind: .summary(models.summaryTier))
                    } else if case .cloud(let p) = summary.engine {
                        HStack {
                            Text("Ключ API")
                            Spacer()
                            Text(APIKeychain.key(for: p) == nil ? "не задан" : "сохранён").foregroundStyle(Theme.secondary)
                            Button("Изменить") { keyDraft = ""; keyProvider = p }
                        }
                        TextField("Модель", text: Binding(get: { summary.model(for: p) }, set: { summary.setModel($0, for: p) }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if p == .compatible {
                            TextField("Адрес сервера", text: Binding(get: { summary.baseURL(for: p) }, set: { summary.setBaseURL($0, for: p) }))
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        }
                        Toggle("Скрывать личные данные", isOn: $summary.protectPersonalData)
                    }
                } header: {
                    Text("Итоги встречи")
                } footer: {
                    Text("Модель на iPhone работает без интернета. С ключом API текст расшифровки уходит выбранному провайдеру; телефоны, почта, документы и имена перед отправкой заменяются метками.")
                }

                Section {
                    TextField("Например: ПДС, ОПС, Газфонд, Телемост", text: $terms, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Термины для распознавания")
                } footer: {
                    Text("Через запятую или с новой строки. Модель речи заранее знает эти слова и чаще пишет их верно.")
                }

                Section("Оформление") {
                    Toggle("Метеоры", isOn: $meteors)
                    Toggle("Живое небо", isOn: $sky)
                    Picker("Порядок записей", selection: $library.order) {
                        ForEach(Library.Order.allCases) { Text($0.title).tag($0) }
                    }
                }

                Section {
                    Button("Показать знакомство ещё раз") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Router.shared.showOnboarding = true }
                    }
                    LabeledContent("Версия", value: Self.version)
                } footer: {
                    Text("Расшифровка, говорящие и локальные итоги работают на iPhone без интернета. Записи хранятся в Файлах → На iPhone → Meteora или в общей папке.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(NebulaBackground(intensity: 0.5, animated: false).ignoresSafeArea())
            .font(Theme.ui(16))
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .sheet(isPresented: $pickingFolder) {
                FolderPicker { url in shared.choose(url) }.ignoresSafeArea()
            }
            .alert("Ключ API", isPresented: Binding(get: { keyProvider != nil }, set: { if !$0 { keyProvider = nil } })) {
                SecureField(keyProvider?.keyHint ?? "ключ", text: $keyDraft)
                Button("Сохранить") {
                    if let p = keyProvider { APIKeychain.set(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines), for: p) }
                    summary.objectWillChange.send()
                    keyProvider = nil
                }
                Button("Отмена", role: .cancel) { keyProvider = nil }
            } message: {
                Text("Ключ хранится в Связке ключей только на этом iPhone.")
            }
        }
    }

    private var engineBinding: Binding<String> {
        Binding(get: {
            switch summary.engine {
            case .local: return "local"
            case .cloud(let p): return p.rawValue
            }
        }, set: { raw in
            summary.engine = CloudProvider(rawValue: raw).map { .cloud($0) } ?? .local
        })
    }

    @ViewBuilder private var folderRows: some View {
        if let name = shared.name {
            LabeledContent("Папка", value: name)
            Toggle("Сохранять новые записи туда", isOn: $shared.saveRecordingsHere)
            Toggle("Класть расшифровку рядом (.txt)", isOn: $shared.writeTranscripts)
            Button("Выбрать другую папку") { pickingFolder = true }
            Button("Отключить", role: .destructive) { shared.forget() }
        } else {
            Button { pickingFolder = true } label: { Label("Выбрать папку в iCloud Drive", systemImage: "icloud") }
        }
        if let p = shared.problem { Text(p).foregroundStyle(Theme.danger).font(Theme.ui(13)) }
    }

    @ViewBuilder private func modelRow(_ title: String, installed: Bool, size: String, kind: Models.Kind) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(installed ? "Установлена · \(size)" : "Не загружена · \(size)").font(Theme.ui(13)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if models.downloading == kind {
                ProgressView(value: models.progress).frame(width: 70)
                Button("Стоп") { models.cancel() }.font(Theme.ui(14))
            } else if installed {
                Button("Удалить", role: .destructive) { models.remove(kind) }.font(Theme.ui(14))
            } else {
                Button("Скачать") { Task { await models.download(kind) } }.font(Theme.ui(14, weight: .semibold))
                    .disabled(models.downloading != nil)
            }
        }
    }

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
