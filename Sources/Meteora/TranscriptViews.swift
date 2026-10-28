import SwiftUI
import MeteoraCore
import MeteoraASR

// MARK: - Bottom panel: key frames | transcript

struct BottomPanel: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: PlayerController

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
                    TabTitle(title: "Расшифровка", count: model.displayedSegments.count, selected: tab == .transcript) {
                        model.bottomTab = .transcript
                    }
                }
                Spacer()
                if tab == .transcript, let p = model.transcribeProgress {
                    HStack(spacing: 8) {
                        ThinProgress(value: p).frame(width: 80)
                        Text("\(Int(p * 100)) %").font(Theme.ui(11.5).monospacedDigit()).foregroundStyle(Theme.secondary)
                    }
                }
            }
            Group {
                switch tab {
                case .frames: FramesStrip(model: model, player: player)
                case .transcript: TranscriptList(model: model, player: player)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(height: 220)
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

    var body: some View {
        let segments = model.displayedSegments
        let hours = (model.info?.duration ?? 0) >= 3600
        let current = model.transcript?.segmentIndex(at: player.currentTime)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if segments.isEmpty {
                        Text(model.transcribeProgress != nil ? "Слушаю запись… первые фразы появятся через несколько секунд."
                                                             : "Речь не найдена.")
                            .font(Theme.ui(12.5)).foregroundStyle(Theme.secondary).padding(.vertical, 6)
                    }
                    ForEach(Array(segments.enumerated()), id: \.element.id) { i, seg in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Button { player.seek(to: seg.start) } label: {
                                Text(Timecode.string(seg.start, alwaysHours: hours))
                                    .font(Theme.mono).foregroundStyle(i == current ? Theme.accent : Theme.tertiary)
                                    .frame(width: hours ? 64 : 46, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help("Перейти к этому месту")
                            Text(seg.text)
                                .font(Theme.ui(13)).foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(i == current ? Theme.accentSoft : .clear))
                        .id(seg.id)
                    }
                }
            }
            .onChange(of: current) { _, new in
                if player.isPlaying, let new, new < segments.count {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(segments[new].id, anchor: .center) }
                }
            }
            .onChange(of: model.liveSegments.count) { _, _ in
                if model.transcribeProgress != nil, let last = segments.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
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
            Menu {
                Button("Текст с таймкодами (.txt)") { model.presentSaveTranscriptPanel(.txt) }
                Button("Субтитры (.srt)") { model.presentSaveTranscriptPanel(.srt) }
                Button("Markdown с кадрами — для Claude (.md)") { model.presentSaveTranscriptPanel(.markdown) }
            } label: {
                Text("Сохранить…").font(Theme.ui(13, weight: .medium)).frame(maxWidth: .infinity)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        }
        Button("Расшифровать заново") { Task { await model.transcribe() } }
            .buttonStyle(LinkButtonStyle())
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
