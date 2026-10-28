import SwiftUI
import WebKit
import UniformTypeIdentifiers
import VolantCore

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: MeetingModel
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch model.loadState {
            case .empty:
                EmptyStateView(model: model, dropTargeted: dropTargeted)
            case .loading(let p):
                LoadingView(title: model.title, progress: p)
            case .failed(let message):
                FailureView(message: message, model: model)
            case .ready:
                if let player = model.player {
                    MainView(model: model, player: player)
                }
            }
        }
        .frame(minWidth: 940, minHeight: 620)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL, url.pathExtension.lowercased() == "webm" else { return }
                DispatchQueue.main.async { model.open(url) }
            }
            return true
        }
        .overlay(alignment: .bottom) { ToastView(model: model) }
    }
}

// MARK: - Empty / loading / failure

struct EmptyStateView: View {
    @ObservedObject var model: MeetingModel
    var dropTargeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            LogoMark().frame(width: 76, height: 76)
            Text("Volant")
                .font(Theme.display(40))
                .foregroundStyle(Theme.text)
                .padding(.top, 10)
            Text("Verba volant, scripta manent")
                .font(Theme.display(14).italic())
                .foregroundStyle(Theme.secondary)
                .padding(.top, 2)

            VStack(spacing: 14) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(dropTargeted ? Theme.accent : Theme.tertiary)
                Text("Перетащите сюда запись встречи из Телемоста")
                    .font(Theme.ui(14, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text("Файл .webm — видео со звуком или только звук")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.secondary)
                Button("Выбрать запись…") { model.presentOpenPanel() }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(width: 200)
                    .keyboardShortcut("o", modifiers: .command)
                    .padding(.top, 4)
            }
            .padding(.vertical, 28)
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(dropTargeted ? Theme.accentSoft : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(dropTargeted ? Theme.accent : Theme.border,
                              style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [6, 5])))
            .padding(.top, 32)
            .animation(.easeOut(duration: 0.15), value: dropTargeted)

            HStack(spacing: 22) {
                Feature(icon: "play.rectangle", text: "Посмотреть или послушать")
                Feature(icon: "waveform", text: "Звук для MacWhisper в один клик")
                Feature(icon: "rectangle.on.rectangle", text: "Ключевые кадры с текстом")
            }
            .padding(.top, 26)
            Spacer()
            PrivacyNote().padding(.bottom, 18)
        }
        .padding(.horizontal, 40)
    }

    private struct Feature: View {
        var icon: String
        var text: String
        var body: some View {
            HStack(spacing: 7) {
                Image(systemName: icon).foregroundStyle(Theme.accent)
                Text(text).foregroundStyle(Theme.secondary)
            }
            .font(Theme.ui(12.5))
        }
    }
}

struct PrivacyNote: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
            Text("Всё обрабатывается на этом Mac. Приложение не выходит в интернет.")
        }
        .font(Theme.ui(11.5))
        .foregroundStyle(Theme.tertiary)
    }
}

struct LoadingView: View {
    var title: String
    var progress: Double
    var body: some View {
        VStack(spacing: 14) {
            LogoMark().frame(width: 44, height: 44)
            Text(title).font(Theme.display(20)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.center)
            ThinProgress(value: progress).frame(width: 260)
            Text("Читаю структуру записи…").font(Theme.ui(12.5)).foregroundStyle(Theme.secondary)
        }
        .padding(40)
    }
}

struct FailureView: View {
    var message: String
    @ObservedObject var model: MeetingModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.danger)
            Text("Не получилось открыть запись").font(Theme.display(22)).foregroundStyle(Theme.text)
            Text(message).font(Theme.ui(13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Выбрать другой файл…") { model.presentOpenPanel() }
                .buttonStyle(PrimaryButtonStyle()).frame(width: 220)
        }
        .padding(40)
    }
}

// MARK: - Main layout

struct MainView: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: PlayerController

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 12) {
                PlayerArea(model: model, player: player)
                TransportBar(model: model, player: player)
                if model.hasVideo, !model.frames.isEmpty || model.sceneProgress != nil || model.scenesDone {
                    FramesStrip(model: model, player: player)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            Sidebar(model: model, player: player)
                .frame(width: 300)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 6)
        .animation(.easeOut(duration: 0.2), value: model.frames.count)
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct PlayerArea: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: PlayerController

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Color.black)
            if model.hasVideo {
                WebViewHost(webView: player.webView)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .onTapGesture { player.togglePlay() }
                if player.mediaErrorCode != 0 {
                    unsupported
                } else if !player.isReady {
                    ProgressView().controlSize(.small).tint(.white)
                }
            } else {
                AudioOnlyView(model: model, player: player)
                // Keep the (invisible) web view alive for audio playback.
                WebViewHost(webView: player.webView).frame(width: 2, height: 2).opacity(0.01).allowsHitTesting(false)
            }
            if let p = model.sceneProgress {
                VStack {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini).tint(.white)
                        Text("Ищу смену кадров · \(Int(p * 100))%")
                    }
                    .font(Theme.ui(12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.62)))
                    .padding(12)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private var unsupported: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack").font(.system(size: 26, weight: .light))
            Text("Это видео не воспроизводится на этом Mac").font(Theme.ui(13, weight: .medium))
            Text("Звук для расшифровки всё равно можно сохранить справа").font(Theme.ui(12)).opacity(0.7)
        }
        .foregroundStyle(.white)
    }
}

struct AudioOnlyView: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: PlayerController
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent)
            Text("Только звук").font(Theme.display(24)).foregroundStyle(.white)
            Text("В записи нет видео — можно послушать и сразу отправить на расшифровку")
                .font(Theme.ui(12.5)).foregroundStyle(.white.opacity(0.6))
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20)).foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Theme.accent))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Transport

struct TransportBar: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: PlayerController
    private let rates: [Double] = [1, 1.25, 1.5, 2]

    var duration: Double { max(player.duration, model.info?.duration ?? 0) }

    var body: some View {
        HStack(spacing: 10) {
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(IconButtonStyle())
            .help(player.isPlaying ? "Пауза (пробел)" : "Воспроизвести (пробел)")

            Text(Timecode.string(player.currentTime, alwaysHours: duration >= 3600))
                .font(Theme.mono).foregroundStyle(Theme.text).frame(minWidth: 58, alignment: .trailing)

            WaveformScrubber(envelope: model.audioAnalysis?.envelope, step: model.audioAnalysis?.envelopeStep ?? 0.1,
                             duration: duration, current: player.currentTime,
                             markers: model.frames.map(\.frame.time)) { t in player.seek(to: t) }
                .frame(height: 34)

            Text(Timecode.string(duration, alwaysHours: duration >= 3600))
                .font(Theme.mono).foregroundStyle(Theme.secondary).frame(minWidth: 58, alignment: .leading)

            Menu {
                ForEach(rates, id: \.self) { r in
                    Button(rateLabel(r)) { player.setRate(r) }
                }
            } label: {
                Text(rateLabel(player.rate)).font(Theme.ui(12, weight: .semibold)).foregroundStyle(Theme.text)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Скорость воспроизведения")

            Button { player.setVolume(player.volume > 0 ? 0 : 1) } label: {
                Image(systemName: player.volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .buttonStyle(IconButtonStyle())
            .help("Звук")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
    }

    private func rateLabel(_ r: Double) -> String {
        r == 1 ? "1×" : String(format: "%g×", r).replacingOccurrences(of: ".", with: ",")
    }
}

/// Scrubber drawn as the loudness envelope of the meeting: you can see at a
/// glance where people talk. Key frames are marked with ticks.
struct WaveformScrubber: View {
    var envelope: [Float]?
    var step: Double
    var duration: Double
    var current: Double
    var markers: [Double]
    var onSeek: (Double) -> Void
    @State private var hover: Double?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Canvas { ctx, size in
                let progressX = duration > 0 ? CGFloat(current / duration) * size.width : 0
                let barW: CGFloat = 2, gap: CGFloat = 1.5
                let count = max(1, Int(size.width / (barW + gap)))
                for i in 0 ..< count {
                    let x = CGFloat(i) * (barW + gap)
                    var level: CGFloat = 0.08
                    if let env = envelope, !env.isEmpty {
                        let a = Int(Double(i) / Double(count) * Double(env.count))
                        let b = max(a + 1, Int(Double(i + 1) / Double(count) * Double(env.count)))
                        var m: Float = 0
                        for k in a ..< min(b, env.count) { m = max(m, env[k]) }
                        level = max(0.08, CGFloat(m))
                    }
                    let bh = max(2, level * (size.height - 6))
                    let rect = CGRect(x: x, y: (size.height - bh) / 2, width: barW, height: bh)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(x <= progressX ? Theme.accent : Theme.tertiary.opacity(0.55)))
                }
                for m in markers where duration > 0 {
                    let x = CGFloat(m / duration) * size.width
                    ctx.fill(Path(roundedRect: CGRect(x: x - 1, y: 0, width: 2, height: 5), cornerRadius: 1), with: .color(Theme.accent))
                }
                // playhead
                ctx.fill(Path(roundedRect: CGRect(x: progressX - 1, y: 1, width: 2, height: size.height - 2), cornerRadius: 1),
                         with: .color(Theme.text))
            }
            .overlay(alignment: .topLeading) {
                if let hover, duration > 0 {
                    Text(Timecode.string(hover, alwaysHours: duration >= 3600))
                        .font(Theme.ui(10.5, weight: .medium)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accent))
                        .offset(x: min(max(0, CGFloat(hover / duration) * w - 22), w - 48), y: -18)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard duration > 0 else { return }
                let t = Double(min(max(0, v.location.x / w), 1)) * duration
                hover = t
                onSeek(t)
            }.onEnded { _ in hover = nil })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = duration > 0 ? Double(min(max(0, p.x / w), 1)) * duration : nil
                case .ended: hover = nil
                }
            }
            .frame(width: w, height: h)
        }
        .accessibilityElement()
        .accessibilityLabel("Позиция воспроизведения")
        .accessibilityValue(Timecode.string(current))
        .accessibilityAdjustableAction { dir in
            onSeek(dir == .increment ? current + 10 : max(0, current - 10))
        }
    }
}

// MARK: - Frames strip

struct FramesStrip: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: PlayerController
    @State private var detail: FrameItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ключевые кадры")
                    .font(Theme.ui(11, weight: .semibold)).tracking(0.6).textCase(.uppercase)
                    .foregroundStyle(Theme.secondary)
                if !model.frames.isEmpty {
                    Text("\(model.frames.count)").font(Theme.ui(11, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                Spacer()
                if let e = model.sceneError { Text(e).font(Theme.ui(11.5)).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 10) {
                        ForEach(model.frames) { item in
                            FrameThumbView(item: item, selected: model.selectedFrame == item.id,
                                           showHours: (model.info?.duration ?? 0) >= 3600)
                                .id(item.id)
                                .onTapGesture(count: 2) { detail = item }
                                .onTapGesture {
                                    model.selectedFrame = item.id
                                    player.seek(to: item.frame.time)
                                }
                        }
                        if model.sceneProgress != nil {
                            RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceSunken)
                                .frame(width: 150, height: 94)
                                .overlay(ProgressView().controlSize(.small))
                        }
                    }
                    .padding(.bottom, 6)
                }
                .onChange(of: model.frames.count) { _, _ in
                    if model.sceneProgress != nil, let last = model.frames.last { withAnimation { proxy.scrollTo(last.id, anchor: .trailing) } }
                }
            }
        }
        .padding(14)
        .frame(height: 188)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
        .sheet(item: $detail) { FrameDetailView(item: $0, showHours: (model.info?.duration ?? 0) >= 3600) }
    }
}

struct FrameThumbView: View {
    var item: FrameItem
    var selected: Bool
    var showHours: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(nsImage: item.preview)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 150, height: 94)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1))
            HStack(spacing: 5) {
                Text(Timecode.string(item.frame.time, alwaysHours: showHours)).font(Theme.ui(11, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if !item.frame.text.isEmpty {
                    Image(systemName: "text.alignleft").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .help("Нажмите — перейти к моменту, дважды — открыть кадр и текст")
    }
}

struct FrameDetailView: View {
    var item: FrameItem
    var showHours: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Кадр \(item.frame.id) · \(Timecode.string(item.frame.time, alwaysHours: showHours))")
                    .font(Theme.display(20)).foregroundStyle(Theme.text)
                Spacer()
                Button("Готово") { dismiss() }.buttonStyle(SecondaryButtonStyle(fill: false)).keyboardShortcut(.defaultAction)
            }
            Image(nsImage: NSImage(cgImage: item.frame.image, size: .zero))
                .resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxHeight: 420)
            if !item.frame.text.isEmpty {
                ScrollView {
                    Text(item.frame.text).font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceSunken))
                Button("Скопировать текст") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.frame.text, forType: .string)
                }
                .buttonStyle(SecondaryButtonStyle(fill: false))
            }
        }
        .padding(20)
        .frame(width: 760)
        .background(Theme.background)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: PlayerController

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                RecordingCard(model: model)
                AudioCard(model: model)
                if model.hasVideo { FramesCard(model: model) }
                PrivacyNote().multilineTextAlignment(.leading).padding(.top, 4).padding(.horizontal, 4)
            }
        }
    }
}

struct RecordingCard: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        Card("Запись", trailing: AnyView(
            Button { model.presentOpenPanel() } label: { Text("Открыть…").font(Theme.ui(12, weight: .medium)) }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
        )) {
            Text(model.title).font(Theme.display(16)).foregroundStyle(Theme.text).lineLimit(3)
                .textSelection(.enabled)
            if let info = model.info {
                VStack(spacing: 6) {
                    KeyValueRow(key: "Длительность", value: Timecode.string(info.duration, alwaysHours: info.duration >= 3600))
                    KeyValueRow(key: "Размер", value: FileSizeText.string(Int64(info.fileSize)))
                    if let v = info.video {
                        KeyValueRow(key: "Видео", value: "\(v.codecName) · \(v.width)×\(v.height)")
                    } else {
                        KeyValueRow(key: "Видео", value: "нет")
                    }
                    if let a = info.audio {
                        KeyValueRow(key: "Звук", value: "\(a.codecName) · \(a.channels == 1 ? "моно" : a.channels == 2 ? "стерео" : "\(a.channels) кан.") · \(Int(a.sampleRate / 1000)) кГц")
                    } else {
                        KeyValueRow(key: "Звук", value: "нет")
                    }
                }
            }
        }
    }
}

struct AudioCard: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        Card("Звук для расшифровки") {
            if model.info?.audio == nil {
                Text("В записи нет звука.").font(Theme.ui(12.5)).foregroundStyle(Theme.secondary)
            } else if let err = model.audioError, model.audioAnalysis == nil, !model.canExportAudio {
                Text(err).font(Theme.ui(12.5)).foregroundStyle(Theme.danger)
            } else {
                PillPicker(options: AudioQuality.allCases, selection: $model.quality) { $0.title }
                    .disabled(model.exportProgress != nil)
                HStack {
                    Text(model.quality.detail)
                    Spacer()
                    Text(model.estimatedAudioSize)
                }
                .font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)

                Toggle(isOn: $model.normalize) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Выровнять громкость").font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                        Text("тихие голоса станут разборчивее").font(Theme.ui(11)).foregroundStyle(Theme.secondary)
                    }
                }
                .toggleStyle(.switch).controlSize(.mini).tint(Theme.accent)
                .disabled(model.exportProgress != nil)

                if let p = model.exportProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ThinProgress(value: p)
                        HStack {
                            Text("Готовлю звук… \(Int(p * 100))%").font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)
                            Spacer()
                            Button("Отменить") { model.cancelExport() }.buttonStyle(.plain)
                                .font(Theme.ui(11.5, weight: .medium)).foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.top, 2)
                } else {
                    VStack(spacing: 8) {
                        Button { Task { await model.sendToMacWhisper() } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform.badge.mic")
                                Text("Отправить в MacWhisper")
                                Text("⌘⇧M").font(Theme.ui(11)).opacity(0.7)
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Сохранит звук в «Загрузки/Volant», скопирует файл в буфер обмена и откроет MacWhisper")
                        Button("Сохранить как…") { model.presentSaveAudioPanel() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}

struct FramesCard: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        Card("Ключевые кадры") {
            Text("Снимки экрана в моменты смены картинки и распознанный на них текст — слайды, отчёты, интерфейсы.")
                .font(Theme.ui(12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Чувствительность").font(Theme.ui(12)).foregroundStyle(Theme.text)
                Slider(value: $model.sensitivity, in: 0 ... 1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("меньше").font(Theme.ui(10.5)).foregroundStyle(Theme.tertiary)
                } maximumValueLabel: {
                    Text("больше").font(Theme.ui(10.5)).foregroundStyle(Theme.tertiary)
                }
                .controlSize(.small).tint(Theme.accent)
            }
            .disabled(model.sceneProgress != nil)

            Toggle("Только кадры с текстом", isOn: $model.textOnly)
                .toggleStyle(.switch).controlSize(.mini).tint(Theme.accent).font(Theme.ui(12.5))
                .disabled(model.sceneProgress != nil)
            Toggle(isOn: $model.thorough) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Тщательный поиск").font(Theme.ui(12.5))
                    Text("ловит слайды, показанные пару секунд; дольше").font(Theme.ui(11)).foregroundStyle(Theme.secondary)
                }
            }
            .toggleStyle(.switch).controlSize(.mini).tint(Theme.accent)
            .disabled(model.sceneProgress != nil)

            if let p = model.sceneProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ThinProgress(value: p)
                    HStack {
                        Text("Найдено: \(model.frames.count)").font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)
                        Spacer()
                        Button("Остановить") { model.cancelScenes() }.buttonStyle(.plain)
                            .font(Theme.ui(11.5, weight: .medium)).foregroundStyle(Theme.accent)
                    }
                }
            } else if model.frames.isEmpty {
                Button { Task { await model.analyzeScenes() } } label: {
                    HStack(spacing: 6) { Image(systemName: "sparkle.magnifyingglass"); Text("Найти ключевые кадры") }
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button("PDF…") { model.presentSavePDFPanel() }.buttonStyle(SecondaryButtonStyle())
                            .help("Один PDF: кадры, время и текст (с поиском)")
                        Button("Папка…") { model.presentSaveFolderPanel() }.buttonStyle(SecondaryButtonStyle())
                            .help("Папка: PNG-кадры + кадры.md")
                    }
                    Button("Скопировать текст кадров") { model.copyFramesText() }.buttonStyle(SecondaryButtonStyle())
                        .help("Время + текст каждого кадра — удобно вставить в Claude рядом с расшифровкой")
                    Button("Искать заново") { Task { await model.analyzeScenes() } }
                        .buttonStyle(.plain).font(Theme.ui(11.5, weight: .medium)).foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        Group {
            if let t = model.toast {
                HStack(spacing: 10) {
                    Image(systemName: t.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(t.isError ? Theme.danger : Theme.accent)
                    Text(t.message).font(Theme.ui(12.5)).foregroundStyle(Theme.text).lineLimit(2)
                    if let url = t.revealURL {
                        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(.plain).font(Theme.ui(12.5, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Capsule().fill(Theme.surface).shadow(color: .black.opacity(0.12), radius: 12, y: 4))
                .overlay(Capsule().strokeBorder(Theme.border))
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: t.id) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if model.toast?.id == t.id { model.toast = nil }
                }
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast)
    }
}
