import SwiftUI
import AppKit
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
    }

    static func remove(for url: URL) { try? FileManager.default.removeItem(at: file(for: url)) }
}

extension SummaryProgress {
    var text: String {
        switch stage {
        case .loadingModel: return "Загрузка модели…"
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
        if !controller.isInstalled {
            guard await controller.download() else { summaryError = controller.error; return }
        }
        let token = CancelToken()
        summaryToken = token
        summaryError = nil
        summaryProgress = SummaryProgress(stage: .loadingModel, fraction: 0)
        bottomTab = .summary
        let date = MeetingJournal.meetingDate(for: url)
        do {
            let s = try await SummaryModelController.shared.summarizer.summarize(tr, meetingDate: date, progress: { p in
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
        let topic = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func saveSummary() {
        guard let s = summary else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(title) — итоги.md"
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
        InspectorSection("Итоги встречи") {
            if let p = model.summaryProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ThinProgress(value: p.fraction)
                    ProgressStatus(text: p.text, action: "Остановить") { model.cancelSummary() }
                }
            } else if let p = llm.progress {
                VStack(alignment: .leading, spacing: 6) {
                    ThinProgress(value: p)
                    ProgressStatus(text: "Загрузка модели · \(Int(p * 100)) % из \(llm.sizeText)", action: "Отменить") { llm.cancel() }
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
                Text(llm.isInstalled
                     ? "Краткое содержание, решения и задачи — локальной моделью, без интернета."
                     : "Краткое содержание, решения и задачи. Один раз скачается языковая модель · \(llm.sizeText); дальше всё работает без интернета.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if let e = model.summaryError ?? llm.error {
                Text(e).font(Theme.ui(11.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
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
