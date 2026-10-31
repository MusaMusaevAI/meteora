import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeteoraCore

/// Export choices, remembered between launches and shared by single and
/// batch export.
@MainActor
final class ExportSettings: ObservableObject {
    static let shared = ExportSettings()
    private static let key = "exportSettings.v1"

    @Published var formats: Set<ExportFormat> { didSet { save() } }
    @Published var options: TranscriptExportOptions { didSet { save() } }
    /// How the transcript panel shows text: paragraphs or single phrases.
    @Published var showParagraphs: Bool { didSet { save() } }

    private struct Stored: Codable {
        var formats: [String]
        var options: TranscriptExportOptions
        var showParagraphs: Bool?
    }

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        let f = Set((stored?.formats ?? []).compactMap(ExportFormat.init(rawValue:)))
        formats = f.isEmpty ? [.docx] : f
        options = stored?.options ?? .standard
        showParagraphs = stored?.showParagraphs ?? true
    }

    var ordered: [ExportFormat] { ExportFormat.allCases.filter(formats.contains) }

    private func save() {
        let s = Stored(formats: ordered.map(\.rawValue), options: options, showParagraphs: showParagraphs)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension TimestampMode: Identifiable {
    public var id: String { rawValue }
}

extension ExportFormat {
    /// Short label for chips.
    var short: String {
        switch self {
        case .txt: return "TXT"
        case .md: return "Markdown"
        case .docx: return "Word"
        case .pdf: return "PDF"
        case .rtf: return "RTF"
        case .html: return "HTML"
        case .srt: return "SRT"
        case .vtt: return "WebVTT"
        case .csv: return "CSV"
        case .json: return "JSON"
        }
    }

    var hint: String {
        switch self {
        case .txt: return "Простой текст"
        case .md: return "Для заметок и ИИ"
        case .docx: return "С картинками кадров"
        case .pdf: return "Для отправки"
        case .rtf: return "Pages, TextEdit"
        case .html: return "Открыть в браузере"
        case .srt: return "Субтитры"
        case .vtt: return "Субтитры для веба"
        case .csv: return "Таблица фраз"
        case .json: return "Для программ"
        }
    }
}

/// Picks formats and text layout, then saves.
struct ExportSheet: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var settings = ExportSettings.shared
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Экспорт").titleStyle(20).foregroundStyle(Theme.text)
            Text(subtitle).font(Theme.ui(12)).foregroundStyle(Theme.secondary).padding(.top, 3)

            ExportOptionsForm(settings: settings, hasFrames: !model.frames.isEmpty, hasTranscript: model.transcript != nil, showsFrames: model.hasVideo)
                .padding(.top, 18)

            HStack {
                Spacer()
                Button("Отмена", action: dismiss)
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(width: 110)
                    .keyboardShortcut(.cancelAction)
                Button(settings.formats.count > 1 ? "Сохранить \(ru(settings.formats.count, "файл", "файла", "файлов"))…" : "Сохранить…") {
                    dismiss()
                    DispatchQueue.main.async { model.presentExportPanel() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(width: 190)
                .keyboardShortcut(.defaultAction)
                .disabled(settings.formats.isEmpty)
            }
            .padding(.top, 22)
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.background)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let tr = model.transcript { parts.append(ru(tr.segments.count, "фраза", "фразы", "фраз")) }
        if !model.frames.isEmpty { parts.append(ru(model.frames.count, "кадр", "кадра", "кадров")) }
        return model.title + (parts.isEmpty ? "" : " · " + parts.joined(separator: ", "))
    }
}

/// The format grid and text options; also used by batch processing.
struct ExportOptionsForm: View {
    @ObservedObject var settings: ExportSettings
    var hasFrames: Bool
    var hasTranscript: Bool = true
    /// Batch processing and audio-only recordings have no key frames at all.
    var showsFrames: Bool = true

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Форматы").font(Theme.ui(12, weight: .semibold)).foregroundStyle(Theme.secondary)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(ExportFormat.allCases, id: \.self) { f in
                        FormatChip(format: f, selected: settings.formats.contains(f)) {
                            if settings.formats.contains(f) { settings.formats.remove(f) } else { settings.formats.insert(f) }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Текст").font(Theme.ui(12, weight: .semibold)).foregroundStyle(Theme.secondary)
                Toggle(isOn: $settings.options.paragraphs) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Делить на абзацы по паузам").font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                        Text("Иначе — каждая фраза с новой строки").font(Theme.ui(11)).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
                .disabled(!hasTranscript)
                PillPicker(options: TimestampMode.allCases, selection: $settings.options.timestamps) { $0.title.capitalizedFirst }
                    .disabled(!hasTranscript)
            }

            if showsFrames { VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $settings.options.includeFrames) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ключевые кадры").font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                        Text(hasFrames ? "Картинки в Word, PDF, HTML и Markdown — там, где они были в разговоре"
                                       : "Сначала найдите кадры — тогда они попадут в документ")
                            .font(Theme.ui(11)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
                Toggle(isOn: $settings.options.includeFrameText) {
                    Text("Текст, распознанный на кадрах").font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
                .disabled(!settings.options.includeFrames)
            }
            .disabled(!hasFrames) }
        }
        .onChange(of: settings.options.paragraphs) { _, on in
            if !on, settings.options.timestamps == .paragraph { settings.options.timestamps = .phrase }
        }
    }
}

private struct FormatChip: View {
    var format: ExportFormat
    var selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.accent : Theme.tertiary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(format.short).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.text)
                    Text(format.hint).font(Theme.ui(11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(shape.fill(selected ? Theme.accentSoft : hover ? Theme.surface : Theme.surface.opacity(0.6)))
            .overlay(shape.strokeBorder(selected ? Theme.accent.opacity(0.35) : Theme.hairline))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(format.title)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Model

extension MeetingModel {
    var canExportDocuments: Bool { transcript != nil || !frames.isEmpty }

    /// One file without pictures → a save panel. Several files, or a
    /// Markdown file with an image folder → choose a folder.
    func presentExportPanel() {
        let settings = ExportSettings.shared
        let formats = settings.ordered
        guard !formats.isEmpty, canExportDocuments else { return }
        let needsFolder = formats.count > 1 || (formats == [.md] && settings.options.includeFrames && !frames.isEmpty)
        let directory: URL
        let baseName: String
        if needsFolder {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Сохранить сюда"
            panel.message = "Куда сохранить \(ru(formats.count, "файл", "файла", "файлов")) для «\(title)»"
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            directory = dir
            baseName = title
        } else {
            let panel = NSSavePanel()
            let f = formats[0]
            if let t = UTType(filenameExtension: f.fileExtension) { panel.allowedContentTypes = [t] }
            panel.nameFieldStringValue = "\(TranscriptExporter.safeFileName(title)).\(f.fileExtension)"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            directory = dest.deletingLastPathComponent()
            baseName = dest.deletingPathExtension().lastPathComponent
        }
        exportDocuments(formats: formats, options: settings.options, to: directory, baseName: baseName)
    }

    func exportDocuments(formats: [ExportFormat], options: TranscriptExportOptions, to directory: URL, baseName: String) {
        let transcript = self.transcript
        let frames = options.includeFrames ? self.frames.map(\.frame) : []
        let meta = ReportExporter.Meta(title: title, sourceName: url?.lastPathComponent ?? "", duration: info?.duration ?? 0)
        let scoped = directory.startAccessingSecurityScopedResource()
        Task {
            let outcome: (written: [URL], failed: [String]) = await Task.detached(priority: .userInitiated) {
                var written: [URL] = [], failed: [String] = []
                for f in formats {
                    do {
                        let result = try TranscriptExporter.export(transcript, frames: frames, meta: meta,
                                                                   format: f, options: options, baseName: baseName)
                        written.append(try TranscriptExporter.write(result, to: directory, baseName: baseName, format: f))
                    } catch {
                        failed.append("\(f.short): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                    }
                }
                return (written, failed)
            }.value
            if scoped { directory.stopAccessingSecurityScopedResource() }
            if !outcome.failed.isEmpty {
                toast = Toast(message: "Не сохранено — " + outcome.failed.joined(separator: "; "), isError: true)
            } else if outcome.written.count == 1, let u = outcome.written.first {
                toast = Toast(message: "Сохранено: \(u.lastPathComponent)", revealURL: u)
            } else {
                toast = Toast(message: "Сохранено \(ru(outcome.written.count, "файл", "файла", "файлов"))", revealURL: outcome.written.first)
            }
        }
    }
}
