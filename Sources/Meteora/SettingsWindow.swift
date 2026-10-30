import SwiftUI
import AppKit
import MeteoraCore
import MeteoraASR

// MARK: - Appearance settings

enum AppearanceSettings {
    static let meteorsKey = "ui.meteors"
    static let skyKey = "ui.animatedSky"
    static let themeKey = "ui.theme"

    enum ThemeChoice: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "Как в системе"
            case .light: return "Светлая"
            case .dark: return "Тёмная"
            }
        }
    }

    static var theme: ThemeChoice {
        UserDefaults.standard.string(forKey: themeKey).flatMap(ThemeChoice.init(rawValue:)) ?? .system
    }

    @MainActor static func apply(_ choice: ThemeChoice = theme) {
        switch choice {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, library
    case transcription, speakers, summaries
    case recording, autoFolders, export
    case storage, updates, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Оформление"
        case .library: return "Список записей"
        case .transcription: return "Расшифровка"
        case .speakers: return "Говорящие"
        case .summaries: return "Итоги встречи"
        case .recording: return "Запись"
        case .autoFolders: return "Автопапки"
        case .export: return "Экспорт"
        case .storage: return "Хранилище"
        case .updates: return "Обновления"
        case .privacy: return "Конфиденциальность"
        }
    }

    var subtitle: String {
        switch self {
        case .appearance: return "Тема, звёздное небо и метеоры"
        case .library: return "Порядок записей в левой колонке"
        case .transcription: return "Модель речи, подсказки и словарь"
        case .speakers: return "Кто говорит: число участников и модель голосов"
        case .summaries: return "Чем составлять краткое содержание, решения и задачи"
        case .recording: return "Формат файла, источник звука и папка"
        case .autoFolders: return "Новые записи в выбранных папках обрабатываются сами"
        case .export: return "Форматы и вид документов по умолчанию"
        case .storage: return "Модели и кэш: сколько места занимают и что удалить"
        case .updates: return "Версия Meteora и проверка новых сборок"
        case .privacy: return "Что остаётся на этом Mac и что может уйти в сеть"
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "sparkles"
        case .library: return "list.bullet.rectangle"
        case .transcription: return "waveform"
        case .speakers: return "person.2.wave.2"
        case .summaries: return "text.badge.star"
        case .recording: return "record.circle"
        case .autoFolders: return "folder.badge.gearshape"
        case .export: return "square.and.arrow.up"
        case .storage: return "internaldrive"
        case .updates: return "arrow.down.circle"
        case .privacy: return "lock.shield"
        }
    }

    /// Icon tile colour: one hue per group.
    var tint: Color {
        switch self {
        case .appearance, .library: return Color(nsColor: NSColor(hex: 0x8A7BD1))
        case .transcription, .speakers, .summaries: return Color(nsColor: NSColor(hex: 0x4F86C6))
        case .recording, .autoFolders, .export: return Color(nsColor: NSColor(hex: 0xD0766A))
        case .storage, .updates, .privacy: return Color(nsColor: NSColor(hex: 0x5E9E8A))
        }
    }

    static let groups: [(String, [SettingsSection])] = [
        ("Интерфейс", [.appearance, .library]),
        ("Распознавание", [.transcription, .speakers, .summaries]),
        ("Запись и файлы", [.recording, .autoFolders, .export]),
        ("Система", [.storage, .updates, .privacy]),
    ]
}

// MARK: - Window

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static let selection = SettingsSelection()

    static func show(_ section: SettingsSection? = nil, model: MeetingModel) {
        if let section { selection.section = section }
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Настройки"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 720, height: 480)
        w.backgroundColor = Theme.windowNS
        let host = NSHostingView(rootView: SettingsView(selection: selection, model: model))
        host.sizingOptions = []
        w.contentView = host
        w.setContentSize(NSSize(width: 820, height: 600))
        w.setFrameAutosaveName("MeteoraSettings1")
        if !w.setFrameUsingName("MeteoraSettings1") { w.center() }
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsSelection: ObservableObject {
    @Published var section: SettingsSection = .appearance
}

// MARK: - Root view

struct SettingsView: View {
    @ObservedObject var selection: SettingsSelection
    let model: MeetingModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 236)
                .background(PaneBackground())
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    content
                }
                .padding(.horizontal, 30).padding(.top, 40).padding(.bottom, 30)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(selection.section)
        }
        .background(NebulaBackground(intensity: 0.45, animated: false).ignoresSafeArea())
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill").foregroundStyle(Theme.accent)
                    Text("Настройки").titleStyle(17).foregroundStyle(Theme.text)
                }
                .padding(.leading, 10).padding(.top, 40).padding(.bottom, 4)
                ForEach(SettingsSection.groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.0.uppercased())
                            .font(Theme.ui(10, weight: .semibold)).kerning(0.6)
                            .foregroundStyle(Theme.tertiary)
                            .padding(.leading, 10).padding(.bottom, 4)
                        ForEach(group.1) { s in row(s) }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 16)
        }
    }

    private func row(_ s: SettingsSection) -> some View {
        let selected = selection.section == s
        return Button { selection.section = s } label: {
            HStack(spacing: 10) {
                IconTile(icon: s.icon, tint: s.tint, size: 24)
                Text(s.title).font(Theme.ui(13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Theme.accentSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 14) {
            IconTile(icon: selection.section.icon, tint: selection.section.tint, size: 44)
                .shadow(color: selection.section.tint.opacity(0.45), radius: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(selection.section.title).titleStyle(22).foregroundStyle(Theme.text)
                Text(selection.section.subtitle).font(Theme.ui(12.5)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder private var content: some View {
        switch selection.section {
        case .appearance: AppearancePane()
        case .library: LibraryPane()
        case .transcription: TranscriptionPane()
        case .speakers: SpeakersPane()
        case .summaries: SettingsCard { SummarySettingsSheet(dismiss: {}, embedded: true) }
        case .recording: RecordingPane()
        case .autoFolders: AutoFoldersPane()
        case .export:
            SettingsCard {
                ExportOptionsForm(settings: ExportSettings.shared, hasFrames: true)
            }
        case .storage:
            SettingsCard {
                StorageView(onChange: { [weak model] in model?.transcriptCacheDidChange() }, close: {}, embedded: true)
            }
        case .updates: UpdatesPane()
        case .privacy: PrivacyPane()
        }
    }
}

// MARK: - Building blocks

/// A rounded, softly coloured square with an SF Symbol — like System Settings.
struct IconTile: View {
    var icon: String
    var tint: Color
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18)))
            .overlay(Image(systemName: icon).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

/// A translucent card holding one group of settings.
struct SettingsCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(Theme.ui(12, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// A switch with a title and a one-line explanation.
struct SettingsToggle: View {
    var title: String
    var detail: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.text)
                Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
    }
}

/// Title + explanation on the left, a control on the right.
struct SettingsRow<Control: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.text)
                if let detail {
                    Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
    }
}

/// A choice between a few options, each with a short explanation.
struct ChoiceList<Value: Hashable & Identifiable>: View {
    var options: [Value]
    @Binding var selection: Value
    var title: (Value) -> String
    var detail: (Value) -> String
    var body: some View {
        VStack(spacing: 6) {
            ForEach(options) { o in
                let on = o == selection
                Button { selection = o } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: on ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(on ? Theme.accent : Theme.tertiary)
                            .font(.system(size: 14))
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(o)).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.text)
                            Text(detail(o)).font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? Theme.accentSoft : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(on ? Theme.accent.opacity(0.5) : Theme.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Panes

private struct AppearancePane: View {
    @AppStorage(AppearanceSettings.themeKey) private var theme = AppearanceSettings.ThemeChoice.system.rawValue
    @AppStorage(AppearanceSettings.meteorsKey) private var meteors = true
    @AppStorage(AppearanceSettings.skyKey) private var sky = true

    var body: some View {
        SettingsCard(title: "Тема") {
            PillPicker(options: AppearanceSettings.ThemeChoice.allCases,
                       selection: Binding(get: { AppearanceSettings.ThemeChoice(rawValue: theme) ?? .system },
                                          set: { theme = $0.rawValue; AppearanceSettings.apply($0) })) { $0.title }
                .frame(width: 360)
        }
        SettingsCard(title: "Небо") {
            SettingsToggle(title: "Метеоры",
                           detail: "Раз в полминуты через небо пролетает метеор — фирменный знак Meteora.",
                           isOn: $meteors)
            Divider()
            SettingsToggle(title: "Живое небо",
                           detail: "Мягкое свечение туманности медленно дрейфует, звёзды мерцают. Выключите, чтобы беречь батарею.",
                           isOn: $sky)
        }
        Text("При включённом в системе «Уменьшении движения» анимаций нет в любом случае.")
            .font(Theme.ui(11.5)).foregroundStyle(Theme.tertiary)
    }
}

private struct LibraryPane: View {
    @ObservedObject var journal = MeetingJournal.shared
    var body: some View {
        SettingsCard(title: "Порядок записей") {
            ChoiceList(options: MeetingJournal.Order.allCases, selection: $journal.order, title: \.title) { o in
                switch o {
                case .meetingDate: return "Когда прошла встреча — по дате в имени файла Телемоста или в метаданных записи."
                case .added: return "Когда запись впервые открыли в Meteora. Новые сверху, порядок не прыгает."
                }
            }
        }
        SettingsCard(title: "Закреплённые") {
            Text("Закреплённые записи всегда стоят наверху списка. Закрепить — правый щелчок по записи → «Закрепить вверху».")
                .font(Theme.ui(12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TranscriptionPane: View {
    @ObservedObject var speech = SpeechModelController.shared
    @ObservedObject var export = ExportSettings.shared
    @AppStorage("asr.hints") private var hints = true

    var body: some View {
        SettingsCard(title: "Модель речи") {
            SettingsRow(title: "GigaAM-v3 · русский",
                        detail: speech.isInstalled ? "Установлена. Работает на этом Mac без интернета."
                                                   : "Скачается один раз (\(speech.sizeText)), дальше всё офлайн.") {
                if let p = speech.progress {
                    HStack(spacing: 8) {
                        ProgressView(value: p).frame(width: 90)
                        Button("Отменить") { speech.cancel() }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                    }
                } else if speech.isInstalled {
                    Label("Готово", systemImage: "checkmark.circle.fill").font(Theme.ui(12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                } else {
                    Button("Скачать") { Task { await speech.download() } }.buttonStyle(SecondaryButtonStyle())
                }
            }
            if let e = speech.error { Text(e).font(Theme.ui(11.5)).foregroundStyle(Theme.danger) }
        }
        SettingsCard(title: "Точность") {
            SettingsToggle(title: "Подсказывать термины распознавателю",
                           detail: "Слова из словаря модель знает заранее и чаще пишет верно. Расшифровка идёт чуть дольше.",
                           isOn: $hints)
            Divider()
            SettingsRow(title: "Словарь терминов", detail: "Аббревиатуры, названия, имена — как их писать.") {
                Button("Открыть…") { DictionaryWindow.show() }.buttonStyle(SecondaryButtonStyle())
            }
        }
        SettingsCard(title: "Вид расшифровки") {
            PillPicker(options: TranscriptLayout.allCases,
                       selection: Binding(get: { export.showParagraphs ? .paragraphs : .phrases },
                                          set: { export.showParagraphs = $0 == .paragraphs })) { $0.title }
                .frame(width: 220)
            Text("Двойной щелчок по фразе в расшифровке — исправить текст вручную.")
                .font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)
        }
    }
}

private struct SpeakersPane: View {
    @ObservedObject var speakers = SpeakerModelController.shared
    @AppStorage("speakers.count") private var count = 0

    var body: some View {
        SettingsCard(title: "Модель голосов") {
            ChoiceList(options: SpeakerModelTier.allCases, selection: $speakers.tier,
                       title: { t in "\(t.title) · \(t.embeddingName)\(speakers.isReady(t) ? "  ✓" : "")" },
                       detail: { t in "\(t.detail) \(speakers.isReady(t) ? "Установлена." : "Скачается \(speakers.downloadSizeText(t)).")" })
            if let p = speakers.progress, let t = speakers.downloading {
                ProgressStatus(text: "Загрузка «\(t.title)» · \(Int(p * 100)) %", action: "Отменить") { speakers.cancel() }
            } else if !speakers.isInstalled {
                Button("Скачать «\(speakers.tier.title)»") { Task { await speakers.download() } }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        SettingsCard(title: "Участников по умолчанию") {
            SettingsRow(title: "Сколько человек говорит",
                        detail: "«Авто» определяет само. Если число известно заранее — разделение точнее.") {
                Picker("", selection: $count) {
                    Text("авто").tag(0)
                    ForEach(2...SpeakerModelController.maxSpeakers, id: \.self) { n in Text("\(n)").tag(n) }
                }
                .labelsHidden().frame(width: 90)
            }
        }
    }
}

private struct RecordingPane: View {
    @ObservedObject var recorder = MeetingRecorder.shared
    @AppStorage(RecordingFileFormat.key) private var format = RecordingFileFormat.m4a.rawValue
    @State private var folder = RecordingFolder.displayName

    var body: some View {
        SettingsCard(title: "Формат файла") {
            ChoiceList(options: RecordingFileFormat.allCases,
                       selection: Binding(get: { RecordingFileFormat(rawValue: format) ?? .m4a }, set: { format = $0.rawValue }),
                       title: \.title, detail: \.subtitle)
        }
        SettingsCard(title: "Источник звука") {
            if recorder.availableSources.count > 1 {
                PillPicker(options: recorder.availableSources, selection: $recorder.source) { $0.title }
                    .frame(width: 300)
                Text("«Звук Mac» — то, что слышно из динамиков: собеседники в Телемосте, Zoom, браузере.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)
            } else {
                Text("Микрофон. Запись звука Mac доступна с macOS 14.2.").font(Theme.ui(12)).foregroundStyle(Theme.secondary)
            }
        }
        SettingsCard(title: "Папка для записей") {
            SettingsRow(title: folder ?? "Не выбрана", detail: "Сюда сохраняются новые записи.") {
                Button("Выбрать…") {
                    if RecordingFolder.choose() != nil { folder = RecordingFolder.displayName }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(recorder.isActive)
            }
        }
    }
}

private struct UpdatesPane: View {
    @ObservedObject var updates = UpdateChecker.shared

    var body: some View {
        SettingsCard(title: "Версия") {
            SettingsRow(title: "Meteora \(updates.versionText)", detail: statusText) {
                Button(updates.state == .checking ? "Проверяю…" : "Проверить сейчас") { updates.checkInteractively() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(updates.state == .checking)
            }
            if case .available = updates.state {
                Button("Скачать новую версию") { updates.openDownload() }.buttonStyle(PrimaryButtonStyle()).frame(width: 220)
            }
        }
        SettingsCard(title: "Подлинность") {
            HStack(spacing: 10) {
                Image(systemName: provenanceIcon).font(.system(size: 18)).foregroundStyle(provenanceColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provenanceTitle).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.text)
                    Text(provenanceDetail).font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await updates.checkProvenance() }
        SettingsCard {
            SettingsToggle(title: "Проверять автоматически",
                           detail: "Раз в день при запуске. Meteora только сообщит о новой сборке — ничего не скачает без вас.",
                           isOn: $updates.automatic)
        }
    }

    private var provenanceIcon: String {
        switch updates.provenance {
        case .official: return "checkmark.seal.fill"
        case .unofficial: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    private var provenanceColor: Color {
        updates.provenance == .unofficial ? Theme.danger : Theme.accent
    }
    private var provenanceTitle: String {
        switch updates.provenance {
        case .official: return "Официальная сборка"
        case .unofficial: return "Неофициальная сборка"
        case .unknown: return "Подлинность не проверена"
        }
    }
    private var provenanceDetail: String {
        switch updates.provenance {
        case .official: return "Эта копия Meteora собрана из репозитория автора и не изменялась после сборки."
        case .unofficial: return "Эта копия собрана не в репозитории автора или изменена после сборки. Скачайте Meteora из официального источника."
        case .unknown: return "Нужен интернет: Meteora сверяет себя со списком официальных сборок на GitHub."
        }
    }

    private var statusText: String {
        switch updates.state {
        case .available(let b): return "Доступна сборка \(b)."
        case .upToDate: return "Это последняя версия."
        case .failed(let m): return m
        case .checking: return "Проверяю…"
        case .idle:
            if let d = updates.lastChecked {
                return "Последняя проверка: \(d.formatted(date: .abbreviated, time: .shortened))."
            }
            return "Ещё не проверялось."
        }
    }
}

private struct PrivacyPane: View {
    @ObservedObject var llm = SummaryModelController.shared

    var body: some View {
        SettingsCard(title: "На этом Mac") {
            bullet("lock.fill", "Расшифровка, говорящие, кадры и локальные итоги работают без интернета. Файлы встреч никуда не отправляются.")
            bullet("archivebox", "Расшифровки и итоги хранятся в папке приложения; удалить их можно в «Хранилище».")
        }
        SettingsCard(title: "Итоги по ключу API") {
            bullet("network", "Только если вы сами выбрали облачную модель: текст расшифровки уходит выбранному провайдеру. Перед первой отправкой Meteora спросит.")
            SettingsToggle(title: "Скрывать личные данные перед отправкой",
                           detail: "Телефоны, почта, паспорта, счета и имена заменяются метками прямо на Mac, ответ возвращается с исходными данными.",
                           isOn: $llm.guardrailsEnabled)
        }
        SettingsCard(title: "Сеть") {
            bullet("arrow.down.circle", "Meteora выходит в сеть, только чтобы скачать модели, проверить обновления и — по вашему выбору — к облачной модели итогов.")
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 18)
            Text(text).font(Theme.ui(12.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Filled in once the folder watcher lands (see AutoFolders/).
private struct AutoFoldersPane: View {
    var body: some View {
        AutoFoldersSettings()
    }
}
