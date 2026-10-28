import SwiftUI
import AppKit
import AVKit

/// First-run introduction: five short steps, each with a small animation
/// rendered from motion/onboarding (Remotion) into Resources/Onboarding.
/// It never blocks the app: the main window is open behind it, every step
/// can be skipped, and the model download here is the real one.
struct OnboardingStep: Identifiable {
    let id: Int
    let clip: String
    let title: String
    let text: String
}

enum Onboarding {
    static let version = 1
    static let defaultsKey = "onboardingVersion"
    static var isDone: Bool { UserDefaults.standard.integer(forKey: defaultsKey) >= version }
    static func markDone() { UserDefaults.standard.set(version, forKey: defaultsKey) }

    static let steps: [OnboardingStep] = [
        .init(id: 0, clip: "intro",
              title: "Слова улетают. Meteora их ловит.",
              text: "Записи встреч превращаются в текст, ключевые кадры и звук для MacWhisper. Всё — на этом Mac, без облака."),
        .init(id: 1, clip: "open",
              title: "Откройте запись встречи",
              text: "Перетащите файл .webm из Телемоста в окно или нажмите ⌘O. Видео и звук можно сразу смотреть и слушать."),
        .init(id: 2, clip: "listen",
              title: "Научите Meteora слушать",
              text: "Расшифровку делает открытая модель GigaAM-v3 от Сбера: русская речь с пунктуацией, прямо на Mac. Модель скачивается один раз, каждый файл сверяется по контрольной сумме."),
        .init(id: 3, clip: "frames",
              title: "Слайды — тоже в текст",
              text: "Meteora находит моменты, когда меняется картинка на экране, сохраняет кадры и распознаёт на них текст. Кадры сохраняются в PDF или в папку."),
        .init(id: 4, clip: "intro",
              title: "Всё остаётся у вас",
              text: "Записи не покидают этот Mac. Meteora работает в песочнице macOS и видит только те файлы, которые вы открыли сами."),
    ]
}

struct OnboardingView: View {
    var model: MeetingModel
    var close: () -> Void
    /// Static artwork instead of video (Reduce Motion, CI screenshots).
    var stillsOnly = false
    @State var step = 0
    @ObservedObject private var speech = SpeechModelController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var current: OnboardingStep { Onboarding.steps[step] }
    private var isLast: Bool { step == Onboarding.steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            ClipPanel(name: current.clip, dark: scheme == .dark,
                      still: stillsOnly || reduceMotion || isLast)
                .id("\(current.id)-\(scheme == .dark)")
                .frame(width: 600, height: 350)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
                .padding(.top, 38)
                .transition(.opacity)

            VStack(spacing: 8) {
                Text(current.title).titleStyle(22).foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                Text(current.text).font(Theme.ui(13.5)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
            }
            .padding(.top, 26)
            .id(current.id)
            .transition(.opacity)

            if step == 2 { modelControls.padding(.top, 16) }

            Spacer(minLength: 16)

            HStack(spacing: 12) {
                StepDots(count: Onboarding.steps.count, current: step)
                Spacer()
                if !isLast {
                    Button("Пропустить") { finish() }.buttonStyle(LinkButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
                if step > 0 {
                    Button("Назад") { go(step - 1) }.buttonStyle(SecondaryButtonStyle(fill: false))
                }
                if isLast {
                    Button("Открыть запись…") { finish(); model.presentOpenPanel() }
                        .buttonStyle(PrimaryButtonStyle()).frame(width: 170)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(step == 0 ? "Начать" : "Далее") { go(step + 1) }
                        .buttonStyle(PrimaryButtonStyle()).frame(width: 120)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
        .frame(width: 680, height: 610)
        .background(Theme.background)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: step)
    }

    @ViewBuilder private var modelControls: some View {
        if speech.isInstalled {
            Label("Модель на месте — можно расшифровывать", systemImage: "checkmark.circle.fill")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.accent)
        } else if let p = speech.progress {
            VStack(spacing: 6) {
                ThinProgress(value: p)
                ProgressStatus(text: "Загружаю GigaAM-v3… \(Int(p * 100)) % из \(speech.sizeText)", action: "Отменить") { speech.cancel() }
            }
            .frame(width: 320)
        } else {
            VStack(spacing: 8) {
                Button { Task { await speech.download() } } label: { Text("Скачать модель · \(speech.sizeText)") }
                    .buttonStyle(PrimaryButtonStyle()).frame(width: 240)
                Text("Можно позже: кнопка будет в окне записи.").font(Theme.ui(11.5)).foregroundStyle(Theme.tertiary)
                if let e = speech.error { Text(e).font(Theme.ui(11.5)).foregroundStyle(Theme.danger) }
            }
        }
    }

    private func go(_ s: Int) { step = min(max(0, s), Onboarding.steps.count - 1) }

    private func finish() {
        Onboarding.markDone()
        close()
    }
}

private struct StepDots: View {
    var count: Int
    var current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< count, id: \.self) { i in
                Capsule().fill(i == current ? Theme.accent : Theme.hairline)
                    .frame(width: i == current ? 18 : 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .accessibilityElement()
        .accessibilityLabel("Шаг \(current + 1) из \(count)")
    }
}

/// Plays Resources/Onboarding/<name>-<light|dark>.mp4 once and holds the last
/// frame; falls back to the matching still.
struct ClipPanel: View {
    var name: String
    var dark: Bool
    var still: Bool

    private var base: String { "\(name)-\(dark ? "dark" : "light")" }

    var body: some View {
        ZStack {
            Theme.surface
            if !still, let url = Self.resource(base, "mp4") {
                ClipPlayerView(url: url)
            } else if let url = Self.resource(base, "png"), let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                LogoMark().frame(width: 120, height: 120)
            }
        }
    }

    static func resource(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Onboarding")
    }
}

private struct ClipPlayerView: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.videoGravity = .resizeAspectFill
        v.allowsMagnification = false
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = false
        v.player = player
        player.play()
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) {
        v.player?.pause()
        v.player = nil
    }
}

@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?

    static func show(model: MeetingModel, step: Int = 0, stillsOnly: Bool = false) {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 610),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Знакомство с Meteora"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.backgroundColor = Theme.windowNS
        w.contentView = NSHostingView(rootView: OnboardingView(model: model, close: { close() },
                                                              stillsOnly: stillsOnly, step: step))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
        window = nil
    }

    static var isVisible: Bool { window?.isVisible == true }
}
