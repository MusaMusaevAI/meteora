import SwiftUI
import WebKit
import UniformTypeIdentifiers
import MeteoraCore

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var journal = MeetingJournal.shared
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            if model.loadState == .ready {
                Theme.background.ignoresSafeArea()
            } else {
                NebulaBackground().ignoresSafeArea()
            }
            switch model.loadState {
            case .empty:
                if journal.entries.isEmpty {
                    EmptyStateView(model: model, dropTargeted: dropTargeted)
                } else {
                    HomeView(model: model, dropTargeted: dropTargeted)
                }
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
            guard !providers.isEmpty else { return false }
            let group = DispatchGroup()
            var urls: [URL] = []
            let lock = NSLock()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { model.openMany(urls) }
            return true
        }
        .overlay(alignment: .bottom) {
            if model.loadState != .ready { ToastView(model: model) }
        }
    }
}

// MARK: - Empty / loading / failure

struct EmptyStateView: View {
    @ObservedObject var model: MeetingModel
    var dropTargeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            LogoMark().frame(width: 92, height: 92)
                .background(GlowHalo(size: 120))
            Text("Meteora")
                .titleStyle(34)
                .foregroundStyle(Theme.text)
                .padding(.top, 14)
            Text("Записи встреч — в текст, кадры и звук. Прямо на этом Mac.")
                .font(Theme.ui(14))
                .foregroundStyle(Theme.secondary)
                .padding(.top, 6)

            DropZone(model: model, targeted: dropTargeted)
                .frame(maxWidth: 560)
                .padding(.top, 34)

            Text("Посмотреть или послушать  ·  Расшифровка  ·  Ключевые кадры с текстом  ·  Звук")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.tertiary)
                .padding(.top, 18)
            Spacer(minLength: 24)
            PrivacyNote().padding(.bottom, 18)
        }
        .padding(.horizontal, 40)
    }
}

/// The place a recording goes. The whole window accepts drops; this zone
/// answers visibly when a file is over it.
struct DropZone: View {
    @ObservedObject var model: MeetingModel
    var targeted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 10) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(targeted ? Theme.accent : Theme.tertiary)
                .contentTransition(.symbolEffect(.replace))
            Text(targeted ? "Отпустите, чтобы открыть" : "Перетащите сюда запись встречи")
                .font(Theme.ui(14, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("Запись из Телемоста или любой видео- и аудиофайл")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.secondary)
            Button("Выбрать запись…") { model.presentOpenPanel() }
                .buttonStyle(PrimaryButtonStyle())
                .frame(width: 190)
                .keyboardShortcut("o", modifiers: .command)
                .padding(.top, 8)
            Button("или записать встречу") { RecordingWindow.show() }
                .buttonStyle(LinkButtonStyle())
                .help("Микрофон и звук Mac (⌘⇧R)")
        }
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity)
        .background(shape.fill(targeted ? Theme.accentSoft : Theme.surface))
        .overlay {
            if targeted {
                shape.strokeBorder(Nacre.gradient(.leading, .trailing), lineWidth: 2)
            } else {
                shape.strokeBorder(Theme.hairline, lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .animation(.easeOut(duration: 0.16), value: targeted)
    }
}

struct PrivacyNote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock")
            Text("Записи не покидают этот Mac. Интернет нужен один раз — скачать модель речи.")
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
            LogoMark().frame(width: 52, height: 52)
                .background(GlowHalo(size: 70))
            Text(title).titleStyle(20).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.center)
            ThinProgress(value: progress).frame(width: 260)
            Text("Чтение записи…").font(Theme.ui(12.5)).foregroundStyle(Theme.secondary)
        }
        .padding(40)
    }
}

struct FailureView: View {
    var message: String
    @ObservedObject var model: MeetingModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.danger)
            Text("Не получилось открыть запись").titleStyle(20).foregroundStyle(Theme.text)
            Text(message).font(Theme.ui(13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Выбрать другой файл…") { model.presentOpenPanel() }
                .buttonStyle(PrimaryButtonStyle()).frame(width: 220).padding(.top, 6)
        }
        .padding(40)
    }
}

// MARK: - Main layout

struct MainView: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: PlayerController
    /// Height of the frames/transcript panel; the player takes the rest.
    @AppStorage("layout.bottomHeight") private var bottomHeight: Double = 220
    @AppStorage("layout.sidebarWidth") private var sidebarWidth: Double = 304
    @AppStorage("layout.bottomCollapsed") private var bottomCollapsed = false
    @State private var dragStartHeight: Double?
    @State private var dragStartWidth: Double?

    static let minStage: Double = 220
    static let minBottom: Double = 120

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { g in
                let hasPanel = model.showsFramesTab || model.showsTranscriptTab
                let available = g.size.height - 4 - 18
                let maxBottom = max(Self.minBottom, available - Self.minStage - 14)
                let height = min(max(Self.minBottom, bottomHeight), maxBottom)
                VStack(spacing: 0) {
                    Stage(model: model, player: player)
                    if hasPanel {
                        SplitHandle(axis: .vertical, collapsed: bottomCollapsed,
                                    help: bottomCollapsed ? "Показать панель (двойной щелчок)" : "Потяните, чтобы изменить размер; двойной щелчок — скрыть панель") { delta in
                            if bottomCollapsed { bottomCollapsed = false; bottomHeight = Self.minBottom }
                            let start = dragStartHeight ?? height
                            if dragStartHeight == nil { dragStartHeight = height }
                            bottomHeight = min(max(Self.minBottom, start - delta), maxBottom)
                        } onEnd: {
                            dragStartHeight = nil
                        } onDoubleClick: {
                            withAnimation(.easeOut(duration: 0.22)) { bottomCollapsed.toggle() }
                        }
                        if !bottomCollapsed {
                            BottomPanel(model: model, player: player, height: height)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .padding(.top, 4)
            }
            .overlay(alignment: .bottom) { ToastView(model: model).padding(.bottom, 8) }
            SplitHandle(axis: .horizontal, collapsed: false, help: "Потяните, чтобы изменить ширину панели") { delta in
                let start = dragStartWidth ?? sidebarWidth
                if dragStartWidth == nil { dragStartWidth = sidebarWidth }
                sidebarWidth = min(max(270, start - delta), 440)
            } onEnd: {
                dragStartWidth = nil
            } onDoubleClick: {
                withAnimation(.easeOut(duration: 0.2)) { sidebarWidth = 304 }
            }
            Sidebar(model: model, player: player)
                .frame(width: sidebarWidth)
                .background(Theme.inspector.ignoresSafeArea())
        }
        .background(NebulaBackground(intensity: 0.55).ignoresSafeArea())
        .animation(.easeOut(duration: 0.2), value: model.frames.count)
        .sheet(isPresented: $model.exportSheetShown) {
            ExportSheet(model: model) { model.exportSheetShown = false }
        }
    }
}

/// A thin draggable divider. Vertical axis = between player and panel,
/// horizontal = between the work area and the inspector.
struct SplitHandle: View {
    enum Axis { case vertical, horizontal }
    var axis: Axis
    var collapsed: Bool
    var help: String
    var onDrag: (Double) -> Void
    var onEnd: () -> Void
    var onDoubleClick: () -> Void
    @State private var hover = false
    @State private var dragging = false

    var body: some View {
        let active = hover || dragging
        ZStack {
            if axis == .vertical {
                Color.clear.frame(height: 14)
                Capsule().fill(active ? Theme.accent.opacity(0.7) : Theme.tertiary.opacity(collapsed ? 0.6 : 0.35))
                    .frame(width: active ? 48 : 36, height: 4)
                    .shadow(color: Theme.accent.opacity(active ? 0.45 : 0), radius: 6)
            } else {
                Rectangle().fill(active ? Theme.accent.opacity(0.55) : Theme.hairline).frame(width: active ? 2 : 1)
                Color.clear.frame(width: 8)
            }
        }
        .frame(maxWidth: axis == .vertical ? .infinity : nil, maxHeight: axis == .horizontal ? .infinity : nil)
        .contentShape(Rectangle())
        .ignoresSafeArea(edges: axis == .horizontal ? .vertical : [])
        .onHover { h in
            hover = h
            if h { (axis == .vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { v in
                dragging = true
                onDrag(axis == .vertical ? v.translation.height : v.translation.width)
            }
            .onEnded { _ in dragging = false; onEnd() })
        .onTapGesture(count: 2, perform: onDoubleClick)
        .animation(.easeOut(duration: 0.15), value: active)
        .help(help)
        .accessibilityLabel(axis == .vertical ? "Граница плеера и панели" : "Граница боковой панели")
    }
}

/// Video and transport on one slab of dark metal, like a flacon's collar.
struct Stage: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: PlayerController

    var body: some View {
        VStack(spacing: 0) {
            PlayerArea(model: model, player: player)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius - 5, style: .continuous))
                .padding([.horizontal, .top], 6)
            TransportBar(model: model, player: player)
        }
        .background(Theme.stage)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.06)))
        // While playing, the slab's rim picks up a faint mother-of-pearl
        // light — like a meteor's glow on metal.
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Nacre.gradient(), lineWidth: 1)
            .opacity(player.isPlaying ? 0.55 : 0))
        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
        .shadow(color: Theme.accent.opacity(player.isPlaying ? 0.30 : 0.08), radius: player.isPlaying ? 26 : 16)
        .animation(.easeInOut(duration: 0.6), value: player.isPlaying)
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
            model.hasVideo ? Color.black : Theme.stage
            if model.hasVideo {
                surface
                    .onTapGesture { player.togglePlay() }
                if player.mediaErrorCode != 0 {
                    unsupported
                } else if !player.isReady {
                    ProgressView().controlSize(.small).tint(.white)
                }
            } else {
                AudioOnlyView(model: model, player: player)
                if let web = player as? WebPlayerController {
                    // Keep the (invisible) web view alive for audio playback.
                    WebViewHost(webView: web.webView).frame(width: 2, height: 2).opacity(0.01).allowsHitTesting(false)
                }
            }
            if let p = model.sceneProgress {
                VStack {
                    HStack(spacing: 10) {
                        Text("Ищу смену кадров").font(Theme.ui(12, weight: .medium))
                        ThinProgress(value: p, onStage: true).frame(width: 90)
                        Text("\(Int(p * 100)) %").font(Theme.ui(12).monospacedDigit()).foregroundStyle(Theme.stageSecondary)
                    }
                    .foregroundStyle(Theme.stageText)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Theme.stage.opacity(0.88)))
                    .padding(12)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder private var surface: some View {
        if let web = player as? WebPlayerController {
            WebViewHost(webView: web.webView)
        } else if let native = player as? NativePlayerController {
            NativePlayerHost(player: native.avPlayer)
        }
    }

    private var unsupported: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack").font(.system(size: 26, weight: .light))
            Text("Это видео не воспроизводится на этом Mac").font(Theme.ui(13, weight: .medium))
            Text("Звук и расшифровка всё равно доступны справа").font(Theme.ui(12)).opacity(0.7)
        }
        .foregroundStyle(Theme.stageText)
    }
}

struct AudioOnlyView: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: PlayerController
    var body: some View {
        VStack(spacing: 14) {
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22)).foregroundStyle(Theme.stage)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(Theme.stageText))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Воспроизвести")
            Text("Только звук").titleStyle(22).foregroundStyle(Theme.stageText)
            Text("В записи нет видео — слушайте здесь или сразу расшифруйте")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.stageSecondary)
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
            .buttonStyle(IconButtonStyle(onStage: true))
            .help(player.isPlaying ? "Пауза (пробел)" : "Воспроизвести (пробел)")

            Text(Timecode.string(player.currentTime, alwaysHours: duration >= 3600))
                .font(Theme.mono).foregroundStyle(Theme.stageText).frame(minWidth: 52, alignment: .trailing)

            WaveformScrubber(envelope: model.audioAnalysis?.envelope, step: model.audioAnalysis?.envelopeStep ?? 0.1,
                             duration: duration, current: player.currentTime,
                             markers: model.frames.map(\.frame.time)) { t in player.seek(to: t) }
                .frame(height: 30)

            Text(Timecode.string(duration, alwaysHours: duration >= 3600))
                .font(Theme.mono).foregroundStyle(Theme.stageSecondary).frame(minWidth: 52, alignment: .leading)

            Menu {
                ForEach(rates, id: \.self) { r in
                    Button(rateLabel(r)) { player.setRate(r) }
                }
            } label: {
                Text(rateLabel(player.rate)).font(Theme.ui(12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.stageText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Скорость воспроизведения")

            Button { player.setVolume(player.volume > 0 ? 0 : 1) } label: {
                Image(systemName: player.volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .buttonStyle(IconButtonStyle(onStage: true))
            .help(player.volume > 0 ? "Выключить звук" : "Включить звук")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .environment(\.colorScheme, .dark)
    }

    private func rateLabel(_ r: Double) -> String {
        r == 1 ? "1×" : String(format: "%g×", r).replacingOccurrences(of: ".", with: ",")
    }
}

/// Scrubber drawn as the loudness envelope of the meeting: you can see at a
/// glance where people talk. Key frames are marked with pearl ticks.
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
                let hoverX = hover.map { duration > 0 ? CGFloat($0 / duration) * size.width : 0 }
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
                    let bh = max(2, level * (size.height - 8))
                    let rect = CGRect(x: x, y: (size.height - bh) / 2, width: barW, height: bh)
                    let played = x <= progressX
                    let hovered = hoverX.map { x <= $0 && !played } ?? false
                    let color: Color = played ? Theme.stageAccent : Color.white.opacity(hovered ? 0.42 : 0.24)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                }
                for m in markers where duration > 0 {
                    let x = CGFloat(m / duration) * size.width
                    ctx.fill(Path(roundedRect: CGRect(x: x - 1, y: 0, width: 2, height: 4), cornerRadius: 1),
                             with: .color(Theme.nacre[3]))
                }
                ctx.fill(Path(roundedRect: CGRect(x: progressX - 1, y: 0, width: 2, height: size.height), cornerRadius: 1),
                         with: .color(Theme.stageText))
            }
            .overlay(alignment: .topLeading) {
                if let hover, duration > 0 {
                    Text(Timecode.string(hover, alwaysHours: duration >= 3600))
                        .font(Theme.ui(10.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.stage)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.stageText))
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
    /// Thumbnail height; grows with the panel.
    var thumbHeight: Double = 94
    @State private var detail: FrameItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let e = model.sceneError { Text(e).font(Theme.ui(11.5)).foregroundStyle(Theme.secondary).lineLimit(1) }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 12) {
                        ForEach(model.frames) { item in
                            FrameThumbView(item: item, selected: model.selectedFrame == item.id,
                                           showHours: (model.info?.duration ?? 0) >= 3600, height: thumbHeight)
                                .id(item.id)
                                .onTapGesture(count: 2) { detail = item }
                                .onTapGesture {
                                    model.selectedFrame = item.id
                                    player.seek(to: item.frame.time)
                                }
                        }
                        if model.sceneProgress != nil {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceSunken)
                                .frame(width: thumbHeight * 1.6, height: thumbHeight)
                                .overlay(NacreSheen().opacity(0.5).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
                        }
                    }
                    .padding(.bottom, 6)
                }
                .onChange(of: model.frames.count) { _, _ in
                    if model.sceneProgress != nil, let last = model.frames.last { withAnimation { proxy.scrollTo(last.id, anchor: .trailing) } }
                }
            }
        }
        .sheet(item: $detail) { FrameDetailView(item: $0, showHours: (model.info?.duration ?? 0) >= 3600) }
    }
}

struct FrameThumbView: View {
    var item: FrameItem
    var selected: Bool
    var showHours: Bool
    var height: Double = 94
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: item.preview)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: height * 1.6, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : hover ? Theme.tertiary : Theme.hairline, lineWidth: selected ? 2 : 1))
            HStack(spacing: 5) {
                Text(Timecode.string(item.frame.time, alwaysHours: showHours)).font(Theme.ui(11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(selected ? Theme.accent : Theme.text)
                if !item.frame.text.isEmpty {
                    Image(systemName: "text.alignleft").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                        .accessibilityLabel("есть текст")
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help("Нажмите — перейти к моменту, дважды — открыть кадр и текст")
    }
}

struct FrameDetailView: View {
    var item: FrameItem
    var showHours: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Кадр \(item.frame.id)").titleStyle(20).foregroundStyle(Theme.text)
                Text(Timecode.string(item.frame.time, alwaysHours: showHours))
                    .font(Theme.ui(15).monospacedDigit()).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Готово") { dismiss() }.buttonStyle(SecondaryButtonStyle(fill: false)).keyboardShortcut(.defaultAction)
            }
            Image(nsImage: NSImage(cgImage: item.frame.image, size: .zero))
                .resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxHeight: 420)
            if !item.frame.text.isEmpty {
                ScrollView {
                    Text(item.frame.text).font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceSunken))
                Button("Скопировать текст") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.frame.text, forType: .string)
                }
                .buttonStyle(SecondaryButtonStyle(fill: false))
            }
        }
        .padding(22)
        .frame(width: 760)
        .background(Theme.background)
    }
}

// MARK: - Inspector

struct Sidebar: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: PlayerController

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    RecordingSection(model: model)
                    if model.audioOrigin != nil { Hairline(); TranscriptCard(model: model) }
                    if !model.speakers.isEmpty { Hairline(); SpeakersSection(model: model) }
                    Hairline()
                    AudioSection(model: model)
                    if model.hasVideo { Hairline(); FramesSection(model: model) }
                }
            }
            Hairline()
            StorageButton(model: model)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
    }
}

struct RecordingSection: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        InspectorSection {
            Button { model.requestClose() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Все записи")
                }
            }
            .buttonStyle(BackPillStyle())
            .help("Вернуться ко всем записям (⌘W)")
            .padding(.bottom, 4)
            HStack(alignment: .top, spacing: 8) {
                Text(model.title).titleStyle(17).foregroundStyle(Theme.text).lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { model.revealInFinder() } label: { Image(systemName: "folder") }
                    .buttonStyle(IconButtonStyle())
                    .help("Показать в Finder")
                    .padding(.top, -6)
            }
            if let info = model.info {
                VStack(spacing: 5) {
                    KeyValueRow(key: "Длительность", value: Timecode.string(info.duration, alwaysHours: info.duration >= 3600))
                    KeyValueRow(key: "Размер", value: FileSizeText.string(Int64(info.fileSize)))
                    KeyValueRow(key: "Видео", value: info.video.map { "\($0.codecName) · \($0.width)×\($0.height)" } ?? "нет")
                    if let a = info.audio {
                        KeyValueRow(key: "Звук", value: "\(a.codecName) · \(a.channels == 1 ? "моно" : a.channels == 2 ? "стерео" : "\(a.channels) кан.") · \(Int(a.sampleRate / 1000)) кГц")
                    } else {
                        KeyValueRow(key: "Звук", value: "нет")
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

struct AudioSection: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        InspectorSection("Звук для расшифровки") {
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
                    Text(model.estimatedAudioSize).monospacedDigit()
                }
                .font(Theme.ui(11.5)).foregroundStyle(Theme.secondary)

                Toggle(isOn: $model.normalize) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Выровнять громкость").font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                        Text("Тихие голоса станут разборчивее").font(Theme.ui(11)).foregroundStyle(Theme.secondary)
                    }
                }
                .toggleStyle(.switch).controlSize(.mini).tint(Theme.accent)
                .disabled(model.exportProgress != nil)

                if let p = model.exportProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ThinProgress(value: p)
                        ProgressStatus(text: "Готовлю звук… \(Int(p * 100)) %", action: "Отменить") { model.cancelExport() }
                    }
                    .padding(.top, 2)
                } else {
                    VStack(spacing: 8) {
                        Button("Сохранить звук как…") { model.presentSaveAudioPanel() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}

struct FramesSection: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        InspectorSection("Ключевые кадры") {
            Text("Снимки экрана в моменты смены картинки и распознанный на них текст: слайды, отчёты, интерфейсы.")
                .font(Theme.ui(12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Чувствительность").font(Theme.ui(12.5)).foregroundStyle(Theme.text)
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
                    Text("Ловит слайды, показанные пару секунд; дольше").font(Theme.ui(11)).foregroundStyle(Theme.secondary)
                }
            }
            .toggleStyle(.switch).controlSize(.mini).tint(Theme.accent)
            .disabled(model.sceneProgress != nil)

            if let p = model.sceneProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ThinProgress(value: p)
                    ProgressStatus(text: "Найдено: \(model.frames.count)", action: "Остановить") { model.cancelScenes() }
                }
            } else if model.frames.isEmpty {
                Button("Найти ключевые кадры") { Task { await model.analyzeScenes() } }
                .buttonStyle(SecondaryButtonStyle())
                .help("Найти моменты, когда меняется картинка (⌘K)")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button("PDF…") { model.presentSavePDFPanel() }.buttonStyle(SecondaryButtonStyle())
                            .help("Один PDF: кадры, время и текст (с поиском)")
                        Button("Папка…") { model.presentSaveFolderPanel() }.buttonStyle(SecondaryButtonStyle())
                            .help("Папка: PNG-кадры и кадры.md")
                    }
                    Button("Скопировать текст кадров") { model.copyFramesText() }.buttonStyle(SecondaryButtonStyle())
                        .help("Время и текст каждого кадра — удобно вставить в Claude рядом с расшифровкой")
                    Button("Искать заново") { Task { await model.analyzeScenes() } }
                        .buttonStyle(LinkButtonStyle())
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
                            .buttonStyle(LinkButtonStyle())
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(Theme.surface).shadow(color: .black.opacity(0.14), radius: 14, y: 5))
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: t.id) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if model.toast?.id == t.id { model.toast = nil }
                }
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: model.toast)
    }
}
