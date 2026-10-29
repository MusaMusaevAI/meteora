import SwiftUI
import AVKit
import MeteoraCore

/// One recording: player, transcript, speakers, summary, export.
struct MeetingView: View {
    static let autoTranscribe = Notification.Name("com.musamusaev.meteora.autoTranscribe")

    @StateObject private var session: MeetingSession
    @ObservedObject var models = Models.shared
    @State private var tab: Tab = .transcript
    @State private var renaming = false
    @State private var newName = ""
    @State private var sharing: [URL]?
    @State private var exportChoice = false
    @State private var editing: TranscriptSegment?
    @State private var editText = ""
    @State private var speakerRename: String?
    @State private var speakerName = ""

    enum Tab: String, CaseIterable, Identifiable {
        case transcript, summary
        var id: String { rawValue }
        var title: String { self == .transcript ? "Расшифровка" : "Итоги" }
    }

    init(recording: Recording) {
        _session = StateObject(wrappedValue: MeetingSession(recording: recording))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    titleBlock
                    PlayerCard(session: session)
                    if let n = session.notice {
                        Text(n).font(Theme.ui(13)).foregroundStyle(Theme.secondary)
                            .transition(.opacity)
                    }
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch tab {
                    case .transcript: transcriptSection
                    case .summary: summarySection
                    }
                    if let e = session.jobError {
                        Text(e).font(Theme.ui(13)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                    }
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: currentIndex) { _, i in
                guard session.isPlaying, tab == .transcript, let i, i < session.segments.count else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(session.segments[i].start, anchor: .center) }
            }
        }
        .background(NebulaBackground(intensity: 0.45, animated: false).ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { exportChoice = true } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(session.transcript == nil)
                    .accessibilityLabel("Поделиться расшифровкой")
            }
        }
        .task {
            await session.open()
            if SelfTest.isRunning { SelfTest.shared.sessionOpened(session) }
        }
        .onDisappear { session.close() }
        .onReceive(NotificationCenter.default.publisher(for: SelfTestHooks.showSummaryTab)) { _ in tab = .summary }
        .onReceive(NotificationCenter.default.publisher(for: SelfTestHooks.showTranscriptTab)) { _ in tab = .transcript }
        .onReceive(NotificationCenter.default.publisher(for: Self.autoTranscribe)) { n in
            if (n.object as? UUID) == session.id, session.transcript == nil { Task { await session.transcribe() } }
        }
        .alert("Название", isPresented: $renaming) {
            TextField("Название", text: $newName)
            Button("Готово") { session.rename(newName) }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Исправить фразу", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Текст", text: $editText, axis: .vertical)
            Button("Сохранить") { if let e = editing { session.editSegment(start: e.start, text: editText) }; editing = nil }
            Button("Отмена", role: .cancel) { editing = nil }
        } message: {
            Text("Пустой текст удалит фразу.")
        }
        .alert("Имя говорящего", isPresented: Binding(get: { speakerRename != nil }, set: { if !$0 { speakerRename = nil } })) {
            TextField("Имя", text: $speakerName)
            Button("Готово") { if let s = speakerRename { session.renameSpeaker(s, to: speakerName) }; speakerRename = nil }
            Button("Отмена", role: .cancel) { speakerRename = nil }
        }
        .sheet(isPresented: $exportChoice) {
            ExportSheet(session: session) { urls in
                exportChoice = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sharing = urls }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            if let sharing { ShareSheet(items: sharing) }
        }
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.recording.displayTitle).titleStyle(22).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Button { newName = session.recording.displayTitle; renaming = true } label: {
                    Image(systemName: "pencil").font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("Переименовать")
            }
            Text("\(Format.date(session.recording.date)) · \(Format.duration(session.duration))")
                .font(Theme.ui(14)).foregroundStyle(Theme.secondary)
            if session.isLoading {
                ProgressRow(text: "Открываю запись…", value: nil)
            }
            if let e = session.loadError {
                Text(e).font(Theme.ui(14)).foregroundStyle(Theme.danger)
            }
        }
        .padding(.top, 6)
    }

    // MARK: Transcript

    private var currentIndex: Int? {
        let t = session.currentTime
        let segs = session.segments
        guard let i = segs.lastIndex(where: { $0.start <= t + 0.05 }), segs[i].end + 1.5 >= t else { return nil }
        return i
    }

    @ViewBuilder private var transcriptSection: some View {
        if let p = session.transcribeProgress {
            Card { ProgressRow(text: "Расшифровка на iPhone", value: p) { session.cancelJob() } }
        } else if session.transcript == nil {
            Card {
                Text("Речь распознаётся прямо на iPhone моделью GigaAM-v3 — запись никуда не отправляется.")
                    .font(Theme.ui(14)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                if case .speech = models.downloading {
                    ProgressRow(text: "Загрузка модели речи", value: models.progress) { models.cancel() }
                } else {
                    Button { Task { await session.transcribe() } } label: {
                        Label("Расшифровать", systemImage: "text.word.spacing")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(session.isLoading || session.loadError != nil)
                    if !models.speechInstalled {
                        Text("Один раз скачается модель (\(models.speechSize)), дальше — без интернета.")
                            .font(Theme.ui(12.5)).foregroundStyle(Theme.tertiary)
                    }
                }
            }
        }
        if session.transcript != nil, session.transcribeProgress == nil {
            speakersCard
        }
        let segs = session.segments
        if !segs.isEmpty {
            let speakers = session.speakers
            let current = currentIndex
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(segs.enumerated()), id: \.element.start) { i, s in
                    PhraseRow(segment: s, showSpeaker: s.speaker != nil && (i == 0 || segs[i - 1].speaker != s.speaker),
                              speakerIndex: s.speaker.flatMap { speakers.firstIndex(of: $0) } ?? 0,
                              isCurrent: i == current, hours: session.duration >= 3600)
                        .id(s.start)
                        .onTapGesture { session.seek(to: s.start); if !session.isPlaying { session.togglePlay() } }
                        .contextMenu {
                            Button { editText = s.text; editing = s } label: { Label("Исправить", systemImage: "pencil") }
                                .disabled(session.transcript == nil)
                            Button { UIPasteboard.general.string = s.text } label: { Label("Скопировать", systemImage: "doc.on.doc") }
                        }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface.opacity(0.86)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline.opacity(0.8)))
        } else if session.transcript != nil {
            Text("Речь в записи не найдена.").font(Theme.ui(14)).foregroundStyle(Theme.secondary)
        }
    }

    @AppStorage("speakers.count") private var speakerCount = 0

    private var speakersCard: some View {
        Card(title: "Говорящие") {
            if let p = session.speakersProgress {
                ProgressRow(text: "Разделяю по голосам", value: p) { session.cancelJob() }
            } else if case .speakers = models.downloading {
                ProgressRow(text: "Загрузка модели голосов", value: models.progress) { models.cancel() }
            } else {
                if !session.speakers.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(session.speakers.enumerated()), id: \.element) { i, sp in
                                Button { speakerName = sp; speakerRename = sp } label: {
                                    HStack(spacing: 6) {
                                        Circle().fill(Theme.speakerColor(i)).frame(width: 8, height: 8)
                                        Text(sp).font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.text)
                                        Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                                    }
                                    .padding(.horizontal, 10).frame(height: 32)
                                    .background(Capsule().fill(Theme.surfaceSunken))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button { Task { await session.separateSpeakers(count: speakerCount == 0 ? nil : speakerCount) } } label: {
                        Label(session.speakers.isEmpty ? "Разделить по голосам" : "Заново", systemImage: "person.2.wave.2")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(session.isBusy)
                    Spacer()
                    Menu {
                        Picker("Участников", selection: $speakerCount) {
                            Text("Определить автоматически").tag(0)
                            ForEach(2...10, id: \.self) { Text("\($0)").tag($0) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Участников:").foregroundStyle(Theme.secondary)
                            Text(speakerCount == 0 ? "авто" : "\(speakerCount)").foregroundStyle(Theme.accent)
                        }
                        .font(Theme.ui(14, weight: .medium))
                    }
                }
                if !models.speakersInstalled {
                    Text("Один раз скачается модель голосов (\(models.speakersSize)).")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    // MARK: Summary

    @ViewBuilder private var summarySection: some View {
        if session.transcript == nil {
            Card {
                Text("Сначала расшифруйте запись — итоги составляются по тексту.")
                    .font(Theme.ui(14)).foregroundStyle(Theme.secondary)
            }
        } else if let p = session.summaryProgress {
            Card {
                if case .summary = models.downloading {
                    ProgressRow(text: "Загрузка модели итогов", value: models.progress) { models.cancel() }
                } else {
                    ProgressRow(text: session.summaryStage ?? "Пишу итоги…", value: p) { session.cancelJob() }
                }
            }
        } else if let s = session.summary {
            SummaryCard(summary: s)
            Button { Task { await session.summarize() } } label: { Label("Составить заново", systemImage: "arrow.clockwise") }
                .buttonStyle(SecondaryButtonStyle())
        } else {
            Card {
                Text(SummaryEngineText.current).font(Theme.ui(14)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { Task { await session.summarize() } } label: { Label("Подвести итоги", systemImage: "sparkles") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(session.isBusy)
            }
        }
    }
}

enum SummaryEngineText {
    @MainActor static var current: String {
        switch SummarySettings.shared.engine {
        case .local:
            let tier = Models.shared.summaryTier
            let ready = Models.shared.summaryInstalled.contains(tier)
            return "Модель «\(tier.title)» на iPhone, без интернета."
                + (ready ? "" : " Один раз скачается \(Models.shared.summarySize(tier)).")
        case .cloud(let p):
            return "\(p.title) по вашему ключу: текст расшифровки уйдёт провайдеру"
                + (SummarySettings.shared.protectPersonalData ? ", личные данные скрываются на iPhone." : ".")
        }
    }
}

// MARK: - Pieces

struct PhraseRow: View {
    var segment: TranscriptSegment
    var showSpeaker: Bool
    var speakerIndex: Int
    var isCurrent: Bool
    var hours: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Timecode.string(segment.start, alwaysHours: hours))
                .font(Theme.mono).foregroundStyle(isCurrent ? Theme.accent : Theme.tertiary)
                .frame(width: hours ? 64 : 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if showSpeaker, let sp = segment.speaker {
                    Text(sp).font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.speakerColor(speakerIndex))
                }
                Text(segment.text).font(Theme.ui(16)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isCurrent ? Theme.accentSoft : .clear))
        .contentShape(Rectangle())
    }
}

struct SummaryCard: View {
    var summary: MeetingSummary
    var body: some View {
        Card {
            Text(summary.title).titleStyle(18).foregroundStyle(Theme.text)
            Text(summary.summary).font(Theme.ui(15)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            section("Главное", summary.keyPoints, "circle.fill")
            section("Решения", summary.decisions, "checkmark.seal")
            section("Задачи", summary.actionItems, "arrow.right.circle")
            Button {
                UIPasteboard.general.string = summary.markdown()
            } label: { Label("Скопировать итоги", systemImage: "doc.on.doc") }
                .font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.accent)
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [String], _ icon: String) -> some View {
        if !items.isEmpty {
            Text(title).font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.top, 4)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon).font(.system(size: icon == "circle.fill" ? 5 : 12)).foregroundStyle(Theme.accent)
                    Text(item).font(Theme.ui(15)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Transport: play/pause, scrubber, ±15 s, speed. Video files show the
/// picture above it.
struct PlayerCard: View {
    @ObservedObject var session: MeetingSession
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 12) {
            if session.recording.hasVideo, let p = session.player, session.fileURL?.pathExtension.lowercased() != "webm" {
                VideoPlayer(player: p)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Slider(value: Binding(get: { scrubbing ?? session.currentTime },
                                  set: { scrubbing = $0 }),
                   in: 0...max(1, session.duration)) { editing in
                if !editing, let s = scrubbing { session.seek(to: s); scrubbing = nil }
            }
            .tint(Theme.stageText)
            HStack {
                Text(Timecode.string(scrubbing ?? session.currentTime, alwaysHours: session.duration >= 3600))
                Spacer()
                Text("−" + Timecode.string(max(0, session.duration - (scrubbing ?? session.currentTime)), alwaysHours: session.duration >= 3600))
            }
            .font(Theme.mono).foregroundStyle(Theme.stageText.opacity(0.7))
            HStack(spacing: 28) {
                Menu {
                    ForEach([0.75, 1, 1.25, 1.5, 1.75, 2] as [Float], id: \.self) { r in
                        Button(r == session.rate ? "✓ \(rateText(r))" : rateText(r)) { session.rate = r }
                    }
                } label: {
                    Text(rateText(session.rate)).font(Theme.ui(15, weight: .semibold)).frame(width: 52, height: 44)
                }
                Button { session.skip(-15) } label: { Image(systemName: "gobackward.15").font(.system(size: 24)) }
                Button { session.togglePlay() } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Theme.stageText))
                        .foregroundStyle(Theme.stage)
                }
                .accessibilityLabel(session.isPlaying ? "Пауза" : "Воспроизвести")
                Button { session.skip(15) } label: { Image(systemName: "goforward.15").font(.system(size: 24)) }
                Color.clear.frame(width: 52, height: 44)
            }
            .foregroundStyle(Theme.stageText)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.stage))
        .disabled(session.player == nil)
    }

    private func rateText(_ r: Float) -> String {
        r == 1 ? "1×" : String(format: "%g×", r).replacingOccurrences(of: ".", with: ",")
    }
}

/// Choose formats, then share.
struct ExportSheet: View {
    @ObservedObject var session: MeetingSession
    var done: ([URL]) -> Void
    @State private var formats: Set<ExportFormat> = Set(
        (UserDefaults.standard.stringArray(forKey: "export.formats") ?? ["docx"]).compactMap(ExportFormat.init(rawValue:)))
    @State private var error: String?

    private let options: [ExportFormat] = [.docx, .pdf, .txt, .md, .srt, .rtf, .html, .vtt, .csv, .json]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Поделиться расшифровкой").titleStyle(20).foregroundStyle(Theme.text)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(options, id: \.self) { f in
                    let on = formats.contains(f)
                    Button {
                        if on { formats.remove(f) } else { formats.insert(f) }
                    } label: {
                        Text(f.fileExtension.uppercased())
                            .font(Theme.ui(14, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundStyle(on ? Theme.onAccent : Theme.text)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Theme.accent : Theme.surfaceSunken))
                    }
                    .buttonStyle(.plain)
                }
            }
            if session.summary != nil {
                Text("Итоги встречи добавятся отдельным файлом (Markdown).").font(Theme.ui(13)).foregroundStyle(Theme.secondary)
            }
            if let error { Text(error).font(Theme.ui(13)).foregroundStyle(Theme.danger) }
            Button("Поделиться") {
                let list = options.filter(formats.contains)
                UserDefaults.standard.set(list.map(\.rawValue), forKey: "export.formats")
                do { done(try session.exportFiles(list)) } catch {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(formats.isEmpty)
        }
        .padding(20)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
