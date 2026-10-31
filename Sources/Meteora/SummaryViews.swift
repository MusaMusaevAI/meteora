import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeteoraCore
import MeteoraLLM

/// Saved meeting summaries, keyed like transcripts.
enum SummaryStore {
    static var directory: URL {
        TranscriptStore.directory.deletingLastPathComponent().appendingPathComponent("Summaries", isDirectory: true)
    }

    static func file(for url: URL) -> URL { directory.appendingPathComponent(TranscriptStore.key(for: url) + ".json") }

    static func load(for url: URL) -> MeetingSummary? {
        guard let data = try? Data(contentsOf: file(for: url)), data.count < 4 << 20 else { return nil }
        return try? JSONDecoder().decode(MeetingSummary.self, from: data)
    }

    static func save(_ s: MeetingSummary, for url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: file(for: url), options: .atomic) }
        let storeKey = TranscriptStore.key(for: url)
        Task { @MainActor in MeetingJournal.shared.rememberStoreKey(storeKey, for: url) }
    }

    static func remove(for url: URL) { try? FileManager.default.removeItem(at: file(for: url)) }
}

extension SummaryProgress {
    var text: String {
        switch stage {
        case .loadingModel: return "Загрузка модели…"
        case .protectingData: return "Скрытие персональных данных…"
        case .readingPart(let i, let n): return "Чтение части \(i) из \(n)…"
        case .combining: return "Сведение заметок…"
        case .writing: return "Составление итогов…"
        }
    }
}

// MARK: - Model

extension MeetingModel {
    func summarize() async {
        guard let url, let tr = transcript, summaryProgress == nil else { return }
        let controller = SummaryModelController.shared
        switch controller.engine {
        case .local(let tier):
            if !controller.installed.contains(tier) {
                guard await controller.download(tier) else { summaryError = controller.error; return }
            }
        case .cloud(let p):
            guard controller.isReady else { summarySettingsShown = true; return }
            if !controller.hasConsent(p) {
                let alert = NSAlert()
                alert.messageText = "Отправить расшифровку в \(p.title)?"
                let server = p == .compatible ? " (\(URL(string: controller.baseURL)?.host ?? controller.baseURL))" : ""
                alert.informativeText = "Для итогов текст встречи уйдёт на серверы провайдера\(server) по вашему ключу. Записи и звук остаются на этом Mac. Спрашиваем один раз для каждого провайдера и адреса."
                alert.addButton(withTitle: "Отправить")
                alert.addButton(withTitle: "Отмена")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                controller.giveConsent(p)
            }
        }
        let token = CancelToken()
        summaryToken = token
        summaryError = nil
        summaryProgress = SummaryProgress(stage: .loadingModel, fraction: 0)
        bottomTab = .summary
        let date = MeetingJournal.meetingDate(for: url)
        do {
            let s = try await controller.summarize(tr, meetingDate: date, progress: { p in
                Task { @MainActor [weak self] in if self?.summaryProgress != nil { self?.summaryProgress = p } }
            }, isCancelled: { token.isCancelled })
            summary = s
            SummaryStore.save(s, for: url)
            toast = Toast(message: "Итоги готовы")
        } catch {
            if !token.isCancelled {
                summaryError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        summaryProgress = nil
        summaryToken = nil
    }

    func cancelSummary() { summaryToken?.cancel() }

    /// The summary's topic becomes the meeting's name in the list and in
    /// exported files. The recording file itself is not renamed.
    func useSummaryTitle() {
        guard let url, let s = summary else { return }
        let topic = MeetingModel.cleanTitle(s.title)
        guard !topic.isEmpty else { return }
        customTitle = topic
        MeetingJournal.shared.setTitle(topic, for: url)
        toast = Toast(message: "Название: \(topic)")
    }

    func copySummary() {
        guard let s = summary else { return }
        NSPasteboard.general.prepareForNewContents(with: .currentHostOnly)
        NSPasteboard.general.setString(s.markdown(), forType: .string)
        toast = Toast(message: "Итоги скопированы")
    }

    // MARK: Mail

    /// The meeting title made safe for a file name (it may come from the model).
    var mailFileBase: String { fileTitle }

    /// A fresh temporary folder named so the storage cleanup finds it.
    static func mailTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meteora-mail-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The summary as an e-mail; the transcript goes along as Word.
    func meetingMail() -> MeetingMail? {
        guard let s = summary else { return nil }
        var attachments: [MeetingMail.Attachment] = []
        if let tr = transcript,
           let r = try? TranscriptExporter.export(tr, frames: [], meta: ReportExporter.Meta(title: title, sourceName: url?.lastPathComponent ?? "", duration: info?.duration ?? 0), format: .docx) {
            attachments.append(MeetingMail.Attachment(fileName: "\(mailFileBase) — расшифровка.docx",
                                                      mimeType: MeetingMail.mimeType(forExtension: "docx"), data: r.primary))
        }
        return MeetingMail(summary: s, attachments: attachments,
                           footer: attachments.isEmpty ? "Итоги составлены в Meteora." : "Полная расшифровка — во вложении. Итоги составлены в Meteora.")
    }

    /// A new message in the default mail app. With an attachment through the
    /// system's «Compose e-mail» service when the mail app supports it,
    /// otherwise a plain mailto link (text only).
    func mailSummary() {
        guard let mail = meetingMail() else { return }
        var items: [Any] = [mail.plainText]
        var files: [URL] = []
        for a in mail.attachments {
            let u = Self.mailTempDir().appendingPathComponent(a.fileName)
            if (try? a.data.write(to: u)) != nil { files.append(u) }
        }
        items.append(contentsOf: files)
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) {
            service.subject = mail.subject
            service.perform(withItems: items)
        } else {
            NSWorkspace.shared.open(mail.mailtoURL)
        }
    }

    /// A complete draft (.eml) opened in the app that handles .eml (Outlook,
    /// Thunderbird, МойОфис…), or saved where the user picks.
    func openMailDraft(save: Bool) {
        guard let mail = meetingMail() else { return }
        let data = mail.eml()
        if save {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.init(filenameExtension: "eml") ?? .data]
            panel.nameFieldStringValue = "\(mailFileBase) — итоги.eml"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            do {
                try data.write(to: dest, options: .atomic)
                toast = Toast(message: "Письмо сохранено — откройте его в почтовой программе", revealURL: dest)
            } catch {
                toast = Toast(message: "Не удалось сохранить: \(error.localizedDescription)", isError: true)
            }
            return
        }
        let u = Self.mailTempDir().appendingPathComponent("\(mailFileBase) — итоги.eml")
        guard (try? data.write(to: u)) != nil else { return }
        if !NSWorkspace.shared.open(u) {
            toast = Toast(message: "Нет программы для писем .eml — сохраните письмо и откройте его в почте", isError: true)
        }
    }

    /// For web mail: formatted text in the clipboard, ready to paste.
    func copySummaryForMail() {
        guard let mail = meetingMail() else { return }
        let pb = NSPasteboard.general
        pb.prepareForNewContents(with: .currentHostOnly)
        pb.setString(mail.html, forType: .html)
        pb.setString(mail.plainText, forType: .string)
        toast = Toast(message: "Итоги скопированы — вставьте в письмо")
    }

    func saveSummary() {
        guard let s = summary else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(fileTitle) — итоги.md"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try Data(s.markdown().utf8).write(to: dest, options: .atomic)
            toast = Toast(message: "Итоги сохранены", revealURL: dest)
        } catch {
            toast = Toast(message: "Не удалось сохранить: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Inspector

struct SummarySection: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var llm = SummaryModelController.shared

    var body: some View {
        InspectorSection("Итоги встречи", trailing: AnyView(
            Button { model.summarySettingsShown = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(IconButtonStyle())
                .help("Чем подводить итоги: модель на Mac или по ключу API")
                .padding(.vertical, -8))) {
            if let p = model.summaryProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ThinProgress(value: p.fraction)
                    ProgressStatus(text: p.text, action: "Остановить") { model.cancelSummary() }
                }
            } else if let p = llm.progress, let tier = llm.downloading {
                VStack(alignment: .leading, spacing: 6) {
                    ThinProgress(value: p)
                    ProgressStatus(text: "Загрузка модели · \(Int(p * 100)) % из \(FileSizeText.string(tier.spec.fileSize))",
                                   action: "Отменить") { llm.cancel() }
                }
            } else if model.summary != nil {
                HStack(spacing: 8) {
                    Button("Открыть") { model.bottomTab = .summary }.buttonStyle(SecondaryButtonStyle())
                    Button("Скопировать") { model.copySummary() }.buttonStyle(SecondaryButtonStyle())
                }
                Button("Составить заново") { Task { await model.summarize() } }.buttonStyle(LinkButtonStyle())
            } else {
                Button { Task { await model.summarize() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Подвести итоги")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                Text(note)
                    .font(Theme.ui(11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if let e = model.summaryError ?? llm.error {
                Text(e).font(Theme.ui(11.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var note: String {
        switch llm.engine {
        case .local(let t):
            return llm.installed.contains(t)
                ? "\(t.title) модель · \(t.spec.displayName), на этом Mac, без интернета."
                : "\(t.title) модель · один раз скачается \(FileSizeText.string(t.spec.fileSize)); дальше без интернета."
        case .cloud(let p):
            return llm.isReady ? "Через \(p.title) по вашему ключу: текст встречи уйдёт провайдеру."
                               : "Выбран \(p.title), но ключ не указан — откройте настройки итогов."
        }
    }
}

// MARK: - Settings

/// Where summaries are made: three local models or a cloud model with the
/// user's key.
struct SummarySettingsSheet: View {
    @ObservedObject var llm = SummaryModelController.shared
    var dismiss: () -> Void
    /// Inside the Settings window: no own title, no «Готово».
    var embedded = false
    @State private var provider: CloudProvider = .anthropic
    @State private var key = ""
    @State private var modelName = ""
    @State private var baseURL = ""
    @State private var checking = false
    @State private var checkResult: String?
    @State private var checkOK = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                Text("Итоги встречи").titleStyle(20).foregroundStyle(Theme.text)
                Text("Чем составлять краткое содержание, решения и задачи.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.secondary).padding(.top, 3)
            }

            Text("На этом Mac — без интернета").font(Theme.ui(12, weight: .semibold)).foregroundStyle(Theme.secondary)
                .padding(.top, 18).padding(.bottom, 8)
            VStack(spacing: 8) {
                ForEach(SummaryModelTier.allCases) { tier in tierRow(tier) }
            }

            Text("По ключу API — текст встречи уходит провайдеру").font(Theme.ui(12, weight: .semibold)).foregroundStyle(Theme.secondary)
                .padding(.top, 18).padding(.bottom, 8)
            cloudBlock

            HStack {
                if let e = llm.error { Text(e).font(Theme.ui(11.5)).foregroundStyle(Theme.danger).lineLimit(2) }
                Spacer()
                if !embedded {
                    Button("Готово", action: dismiss)
                        .buttonStyle(PrimaryButtonStyle()).frame(width: 120)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, embedded ? 8 : 20)
        }
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 560)
        .background(embedded ? Color.clear : Theme.background)
        .onAppear {
            if case .cloud(let p) = llm.engine { provider = p }
            loadProvider()
        }
        .onChange(of: provider) { _, _ in loadProvider() }
    }

    private func loadProvider() {
        key = APIKeychain.key(for: provider) ?? ""
        modelName = llm.model(for: provider)
        baseURL = llm.baseURL.isEmpty ? provider.defaultBaseURL : llm.baseURL
        checkResult = nil
    }

    // MARK: Local

    private func tierRow(_ tier: SummaryModelTier) -> some View {
        let selected = llm.engine == .local(tier)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 15)).foregroundStyle(selected ? Theme.accent : Theme.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tier.title).font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("\(tier.spec.displayName) · \(FileSizeText.string(tier.spec.fileSize))")
                        .font(Theme.ui(11.5).monospacedDigit()).foregroundStyle(Theme.secondary)
                }
                Text(tier.detail).font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            if llm.downloading == tier, let p = llm.progress {
                ThinProgress(value: p).frame(width: 70)
                Button { llm.cancel() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle())
            } else if llm.installed.contains(tier) {
                Text("загружена").font(Theme.ui(11)).foregroundStyle(Theme.tertiary)
                Button { llm.remove(tier) } label: { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle()).help("Удалить модель с диска")
            } else {
                Button("Загрузить") { Task { await llm.download(tier) } }
                    .buttonStyle(SecondaryButtonStyle(fill: false))
                    .disabled(llm.progress != nil)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(shape.fill(selected ? Theme.accentSoft : Theme.surface))
        .overlay(shape.strokeBorder(selected ? Theme.accent.opacity(0.35) : Theme.hairline))
        .contentShape(shape)
        .onTapGesture { llm.engine = .local(tier) }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Cloud

    private var cloudBlock: some View {
        let selected = llm.engine == .cloud(provider)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15)).foregroundStyle(selected ? Theme.accent : Theme.tertiary)
                    .onTapGesture { if llm.keyed.contains(provider) { llm.engine = .cloud(provider) } }
                Picker("", selection: $provider) {
                    ForEach(CloudProvider.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                Spacer()
                if llm.keyed.contains(provider) {
                    Label("ключ сохранён", systemImage: "key.fill").font(Theme.ui(11)).foregroundStyle(Theme.tertiary)
                }
            }
            field("Ключ", SecureField(provider.keyHint, text: $key))
            field("Модель", TextField(provider.defaultModel.isEmpty ? "например, deepseek-chat" : provider.defaultModel, text: $modelName))
            if provider == .compatible {
                field("Адрес", TextField("https://…/v1", text: $baseURL))
            }
            HStack(spacing: 12) {
                Button("Сохранить и выбрать") { save() }
                    .buttonStyle(SecondaryButtonStyle(fill: false))
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(checking ? "Проверяю…" : "Проверить") { Task { await check() } }
                    .buttonStyle(LinkButtonStyle())
                    .disabled(checking || !llm.keyed.contains(provider))
                if llm.keyed.contains(provider) {
                    Button("Удалить ключ") {
                        llm.removeKey(for: provider)
                        key = ""
                        if llm.engine == .cloud(provider) { llm.engine = .local(.medium) }
                    }
                    .buttonStyle(LinkButtonStyle())
                }
                Spacer()
            }
            if let r = checkResult {
                Text(r).font(Theme.ui(11.5)).foregroundStyle(checkOK ? Theme.accent : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $llm.guardrailsEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Защита персональных данных (Cloud.ru Guardrails)").font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                    Text("ФИО, телефоны, e-mail, паспорт, СНИЛС, ИНН, карты и счета заменяются метками ещё на этом Mac; в итогах подставляются обратно.")
                        .font(Theme.ui(11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).controlSize(.mini).tint(Theme.accent)
            .help("Правила Cloud.ru Guardrails работают на этом Mac, без сети и ключа. Это правила, а не гарантия: необычные записи могут не распознаться.")
            Text("Ключ хранится в связке ключей этого Mac. Звук и записи никуда не уходят — только текст расшифровки и только когда вы нажимаете «Подвести итоги».")
                .font(Theme.ui(11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(shape.fill(selected ? Theme.accentSoft : Theme.surface))
        .overlay(shape.strokeBorder(selected ? Theme.accent.opacity(0.35) : Theme.hairline))
    }

    private func field<F: View>(_ label: String, _ control: F) -> some View {
        HStack(spacing: 10) {
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.secondary).frame(width: 56, alignment: .leading)
            control.textFieldStyle(.roundedBorder).font(Theme.ui(12.5))
        }
    }

    private func save() {
        llm.saveKey(key, for: provider)
        llm.setModel(modelName, for: provider)
        if provider == .compatible { llm.baseURL = baseURL }
        llm.engine = .cloud(provider)
        checkResult = nil
    }

    private func check() async {
        save()
        checking = true
        let err = await llm.check(provider)
        checking = false
        checkOK = err == nil
        checkResult = err ?? "Ключ работает, модель отвечает."
    }
}

// MARK: - Bottom panel tab

struct SummaryPanel: View {
    @ObservedObject var model: MeetingModel

    var body: some View {
        ScrollView(.vertical) {
            if let s = model.summary {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(s.title).titleStyle(16).foregroundStyle(Theme.text).textSelection(.enabled)
                        Spacer(minLength: 8)
                        if model.customTitle != s.title {
                            Button("Назвать так встречу") { model.useSummaryTitle() }.buttonStyle(LinkButtonStyle())
                        }
                        Button("Сохранить .md…") { model.saveSummary() }.buttonStyle(LinkButtonStyle())
                        MailMenu(model: model)
                    }
                    if !s.summary.isEmpty {
                        Text(s.summary).font(Theme.ui(13)).foregroundStyle(Theme.text).lineSpacing(3).textSelection(.enabled)
                    }
                    block("Главное", s.keyPoints, icon: "circle.fill")
                    block("Решения", s.decisions, icon: "checkmark")
                    block("Задачи", s.actionItems, icon: "arrow.right")
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let p = model.summaryProgress {
                HStack(spacing: 10) {
                    ThinProgress(value: p.fraction).frame(width: 140)
                    Text(p.text).font(Theme.ui(12.5)).foregroundStyle(Theme.secondary)
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private func block(_ title: String, _ items: [String], icon: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.ui(12, weight: .semibold)).foregroundStyle(Theme.secondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon).font(.system(size: icon == "circle.fill" ? 4 : 9, weight: .semibold))
                            .foregroundStyle(Theme.accent).frame(width: 10)
                        Text(item).font(Theme.ui(13)).foregroundStyle(Theme.text).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// «Отправить ▾»: every way a summary can reach any mail client.
struct MailMenu: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        Menu {
            Button("Новое письмо в почтовой программе") { model.mailSummary() }
            Button("Письмо с расшифровкой (.eml) — Outlook, Thunderbird, МойОфис") { model.openMailDraft(save: false) }
            Button("Сохранить письмо .eml…") { model.openMailDraft(save: true) }
            Divider()
            Button("Скопировать для веб-почты") { model.copySummaryForMail() }
        } label: {
            Label("Отправить", systemImage: "envelope")
                .font(Theme.ui(12.5, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .tint(Theme.accent)
        .help("Отправить итоги по почте")
    }
}
