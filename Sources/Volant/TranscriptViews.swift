import SwiftUI
import VolantCore
import VolantASR

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
            HStack(spacing: 18) {
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
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("\(Int(p * 100))%").font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)
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
        .padding(14)
        .frame(height: 210)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
    }

    private struct TabTitle: View {
        var title: String
        var count: Int
        var selected: Bool
        var action: () -> Void
        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Theme.ui(11, weight: .semibold)).tracking(0.6).textCase(.uppercase)
                        .foregroundStyle(selected ? Theme.text : Theme.tertiary)
                    if count > 0 {
                        Text("\(count)").font(Theme.ui(11, weight: .semibold))
                            .foregroundStyle(selected ? Theme.accent : Theme.tertiary)
                    }
                }
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? Theme.accent : .clear).frame(height: 2)
                }
            }
            .buttonStyle(.plain)
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
                                    .font(Theme.mono).foregroundStyle(Theme.accent)
                                    .frame(width: hours ? 64 : 46, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help("Перейти к этому месту")
                            Text(seg.text)
                                .font(Theme.ui(13)).foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(i == current ? Theme.accentSoft : .clear))
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
        Card("Расшифровка на этом Mac") {
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
        Text("Русская речь в текст с пунктуацией — открытая модель GigaAM-v3 от Сбера. Работает прямо на Mac, без интернета и без MacWhisper.")
            .font(Theme.ui(12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        if let p = speech.progress {
            VStack(alignment: .leading, spacing: 6) {
                ThinProgress(value: p)
                HStack {
                    Text("Загружаю GigaAM-v3… \(Int(p * 100))% из \(speech.sizeText)")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Отменить") { speech.cancel() }.buttonStyle(.plain)
                        .font(Theme.ui(11.5, weight: .medium)).foregroundStyle(Theme.accent)
                }
            }
        } else {
            Button { Task { await speech.download() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                    Text("Научить Volant слушать")
                }
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
                Text("⌘T").font(Theme.ui(11)).opacity(0.7)
            }
        }
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
                Button("Остановить") { model.cancelTranscription() }.buttonStyle(.plain)
                    .font(Theme.ui(11.5, weight: .medium)).foregroundStyle(Theme.accent)
            }
        }
    }

    @ViewBuilder private func done(_ tr: Transcript) -> some View {
        Text("Готово: \(tr.segments.count) фраз, \(tr.wordCount) слов")
            .font(Theme.ui(12.5)).foregroundStyle(Theme.text)
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
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
        }
        Button("Расшифровать заново") { Task { await model.transcribe() } }
            .buttonStyle(.plain).font(Theme.ui(11.5, weight: .medium)).foregroundStyle(Theme.accent)
    }
}

struct StorageButton: View {
    var model: MeetingModel
    var body: some View {
        Button { StorageWindow.show(model: model) } label: {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                Text("Хранилище Volant")
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .font(Theme.ui(12.5))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceSunken))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Что Volant хранит на диске — и что можно удалить")
    }
}
