import SwiftUI
import MeteoraCore
import MeteoraASR

// MARK: - Bottom panel: key frames | transcript

struct BottomPanel: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: PlayerController
    var height: Double = 220

    private var tab: MeetingModel.BottomTab {
        if model.bottomTab == .transcript, model.showsTranscriptTab { return .transcript }
        if model.showsFramesTab { return .frames }
        return .transcript
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                if model.showsFramesTab {
                    TabTitle(title: "Ключевые кадры", count: model.frames.count, selected: tab == .frames) {
                        model.bottomTab = .frames
                    }
                }
                if model.showsTranscriptTab {
                    TabTitle(title: "Расшифровка", count: transcriptRowCount(model.displayedSegments), selected: tab == .transcript) {
                        model.bottomTab = .transcript
                    }
                }
                Spacer()
                if tab == .transcript, !model.displayedSegments.isEmpty {
                    TranscriptLayoutPicker()
                }
                if tab == .transcript, let p = model.transcribeProgress {
                    HStack(spacing: 8) {
                        ThinProgress(value: p).frame(width: 80)
                        Text("\(Int(p * 100)) %").font(Theme.ui(11.5).monospacedDigit()).foregroundStyle(Theme.secondary)
                    }
                }
            }
            Group {
                switch tab {
                case .frames: FramesStrip(model: model, player: player,
                                          thumbHeight: min(300, max(70, height - 92 - (model.sceneError == nil ? 0 : 22))))
                case .transcript: TranscriptList(model: model, player: player)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
    }

    private struct TabTitle: View {
        var title: String
        var count: Int
        var selected: Bool
        var action: () -> Void
        @State private var hover = false
        var body: some View {
            Button(action: action) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(Theme.ui(13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.text : hover ? Theme.text.opacity(0.75) : Theme.secondary)
                    if count > 0 {
                        Text("\(count)").font(Theme.ui(11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(selected ? Theme.accent : Theme.tertiary)
                    }
                }
                .padding(.bottom, 7)
                .overlay(alignment: .bottom) {
                    Capsule().fill(selected ? Theme.accent : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

struct TranscriptList: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: PlayerController
    @ObservedObject var settings = ExportSettings.shared

    /// One row: a paragraph, or a single phrase in phrase mode.
    private struct Row: Identifiable {
        var id: Double { start }
        var start: Double
        var end: Double
        var text: String
        var speaker: String?
    }

    private var rows: [Row] {
        let segments = model.displayedSegments
        guard settings.showParagraphs else {
            return segments.map { Row(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker) }
        }
        var opts = settings.options
        opts.paragraphs = true
        return TranscriptExporter.paragraphs(segments, options: opts).map {
            Row(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker)
        }
    }

    var body: some View {
        let rows = self.rows
        let speakerList = model.speakers
        let hours = (model.info?.duration ?? 0) >= 3600
        let now = player.currentTime
        let current = rows.lastIndex { $0.start <= now + 0.05 }.flatMap { rows[$0].end + 1.5 >= now ? $0 : nil }
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: settings.showParagraphs ? 6 : 2) {
                    if rows.isEmpty {
                        Text(model.transcribeProgress != nil ? "Идёт расшифровка — первые фразы появятся через несколько секунд."
                                                             : "Речь не найдена.")
                            .font(Theme.ui(12.5)).foregroundStyle(Theme.secondary).padding(.vertical, 6)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Button { player.seek(to: row.start) } label: {
                                Text(Timecode.string(row.start, alwaysHours: hours))
                                    .font(Theme.mono).foregroundStyle(i == current ? Theme.accent : Theme.tertiary)
                                    .frame(width: hours ? 64 : 46, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help("Перейти к этому месту")
                            VStack(alignment: .leading, spacing: 2) {
                                if let sp = row.speaker, i == 0 || rows[i - 1].speaker != sp {
                                    Text(sp)
                                        .font(Theme.ui(11.5, weight: .semibold))
                                        .foregroundStyle(Theme.speakerColor(speakerList.firstIndex(of: sp) ?? 0))
                                }
                                Text(row.text)
                                    .font(Theme.ui(13)).foregroundStyle(Theme.text)
                                    .lineSpacing(settings.showParagraphs ? 3 : 0)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, settings.showParagraphs ? 7 : 5).padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(i == current && !settings.showParagraphs ? Theme.accentSoft : .clear))
                        .overlay(alignment: .leading) {
                            if i == current && settings.showParagraphs {
                                Capsule().fill(Theme.accent).frame(width: 2).padding(.vertical, 6)
                            }
                        }
                        .id(row.id)
                    }
                }
            }
            .onChange(of: current) { _, new in
                if player.isPlaying, let new, new < rows.count {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(rows[new].id, anchor: .center) }
                }
            }
            .onChange(of: model.liveSegments.count) { _, _ in
                if model.transcribeProgress != nil, let last = rows.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

enum TranscriptLayout: String, CaseIterable, Identifiable {
    case paragraphs, phrases
    var id: String { rawValue }
    var title: String { self == .paragraphs ? "Абзацы" : "Фразы" }
}

/// Paragraphs | phrases switch in the transcript tab header.
struct TranscriptLayoutPicker: View {
    @ObservedObject var settings = ExportSettings.shared
    var body: some View {
        PillPicker(options: TranscriptLayout.allCases,
                   selection: Binding(get: { settings.showParagraphs ? .paragraphs : .phrases },
                                      set: { settings.showParagraphs = $0 == .paragraphs })) { $0.title }
            .frame(width: 160)
            .help("Абзацы — фразы склеены по паузам")
    }
}

/// How many rows the transcript panel shows in the current layout.
@MainActor
func transcriptRowCount(_ segments: [TranscriptSegment]) -> Int {
    let settings = ExportSettings.shared
    guard settings.showParagraphs else { return segments.count }
    var opts = settings.options
    opts.paragraphs = true
    return TranscriptExporter.paragraphs(segments, options: opts).count
}

// MARK: - Sidebar card

struct TranscriptCard: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var speech = SpeechModelController.shared

    var body: some View {
        InspectorSection("Расшифровка") {
            if !speech.isInstalled {
                notInstalled
            } else if let p = model.transcribeProgress {
                running(p)
            } else if let tr = model.transcript {
                done(tr)
            } else {
                ready
            }
            if let e = model.transcribeError ?? speech.error {
                Text(e).font(Theme.ui(11.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var notInstalled: some View {
        Text("Русская речь в текст с пунктуацией — открытая модель GigaAM-v3 от Сбера. Работает прямо на Mac, без интернета.")
            .font(Theme.ui(12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        if let p = speech.progress {
            VStack(alignment: .leading, spacing: 6) {
                ThinProgress(value: p)
                HStack {
                    Text("Загружаю GigaAM-v3… \(Int(p * 100))% из \(speech.sizeText)")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Отменить") { speech.cancel() }.buttonStyle(LinkButtonStyle())
                }
            }
        } else {
            Button { Task { await speech.download() } } label: {
                Text("Научить Meteora слушать")
            }
            .buttonStyle(PrimaryButtonStyle())
            .help("Скачать модель распознавания речи GigaAM-v3 (\(speech.sizeText))")
            Text("Скачается модель GigaAM-v3 · \(speech.sizeText), один раз. Каждый файл проверяется по контрольной сумме.")
                .font(Theme.ui(11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var ready: some View {
        Button { Task { await model.transcribe() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                Text("Расшифровать запись")
            }
        }
        .help("Расшифровать запись на этом Mac (⌘T)")
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!model.canTranscribe)
        Text("Займёт \(model.transcribeEstimate). Можно смотреть запись, пока идёт расшифровка.")
            .font(Theme.ui(11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func running(_ p: Double) -> some View {
        let total = model.info?.duration ?? 0
        VStack(alignment: .leading, spacing: 6) {
            ThinProgress(value: p)
            HStack {
                Text("Расшифровываю… \(Timecode.string(p * total)) из \(Timecode.string(total))")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Остановить") { model.cancelTranscription() }.buttonStyle(LinkButtonStyle())
            }
        }
    }

    @ViewBuilder private func done(_ tr: Transcript) -> some View {
        Text("Готово: \(ru(tr.segments.count, "фраза", "фразы", "фраз")), \(ru(tr.wordCount, "слово", "слова", "слов"))")
            .font(Theme.ui(12.5).monospacedDigit()).foregroundStyle(Theme.text)
        HStack(spacing: 8) {
            Button("Скопировать") { model.copyTranscript() }.buttonStyle(SecondaryButtonStyle())
            Button("Экспорт…") { model.exportSheetShown = true }
                .buttonStyle(PrimaryButtonStyle())
                .help("Word, PDF, Markdown, субтитры и другие форматы (⌘E)")
        }
        HStack(spacing: 14) {
            Button("Расшифровать заново") { Task { await model.transcribe() } }
                .buttonStyle(LinkButtonStyle())
            Button("Словарь…") { DictionaryWindow.show() }
                .buttonStyle(LinkButtonStyle())
                .help("Как писать термины и аббревиатуры (⌘⇧D)")
        }
    }
}

struct StorageButton: View {
    var model: MeetingModel
    @State private var hover = false
    var body: some View {
        Button { StorageWindow.show(model: model) } label: {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                Text("Хранилище")
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
            .font(Theme.ui(12.5))
            .foregroundStyle(hover ? Theme.text : Theme.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Что Meteora хранит на диске и что можно удалить (⌘,)")
    }
}

// MARK: - Speakers

/// Who spoke: colour, editable name, share of phrases.
struct SpeakersSection: View {
    @ObservedObject var model: MeetingModel

    var body: some View {
        let speakers = model.speakers
        let counts = Dictionary(grouping: model.displayedSegments.compactMap(\.speaker), by: { $0 }).mapValues(\.count)
        InspectorSection("Говорящие") {
            VStack(spacing: 6) {
                ForEach(Array(speakers.enumerated()), id: \.element) { i, name in
                    SpeakerRow(name: name, color: Theme.speakerColor(i), phrases: counts[name] ?? 0) { new in
                        model.renameSpeaker(name, to: new)
                    }
                }
            }
            Text("Нажмите на имя, чтобы переименовать — везде в расшифровке и в экспорте.")
                .font(Theme.ui(11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SpeakerRow: View {
    var name: String
    var color: Color
    var phrases: Int
    var rename: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.6), radius: 3)
            TextField("Имя", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.ui(12.5, weight: .medium))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onSubmit { rename(text) }
                .padding(.horizontal, 6).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(focused ? Theme.surface : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.5) : Color.clear))
            Text(ru(phrases, "фраза", "фразы", "фраз"))
                .font(Theme.ui(11).monospacedDigit()).foregroundStyle(Theme.tertiary)
        }
        .onAppear { text = name }
        .onChange(of: name) { _, n in text = n }
        .onChange(of: focused) { _, f in if !f, text != name { rename(text) } }
    }
}
