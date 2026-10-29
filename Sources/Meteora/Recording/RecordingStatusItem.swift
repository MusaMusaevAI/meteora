import AppKit

/// Menu-bar indicator while a meeting is being recorded: a red dot and the
/// elapsed time (a pause sign when paused), with Pause/Resume and Stop in its
/// menu. Exists only while recording.
@MainActor
final class RecordingStatusItem: NSObject {
    private unowned let recorder: MeetingRecorder
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let infoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Пауза", action: nil, keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Остановить", action: nil, keyEquivalent: "")
    private let showItem = NSMenuItem(title: "Показать окно записи", action: nil, keyEquivalent: "")

    /// The red of `Theme.danger`, drawn for the current menu-bar appearance.
    private static let dot: NSImage = {
        let color = Theme.dynamicNS(light: 0xA6432F, dark: 0xE38C76)
        let image = NSImage(size: NSSize(width: 9, height: 9), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Идёт запись"
        return image
    }()

    private static let pauseImage: NSImage? = {
        let image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Пауза")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        image?.isTemplate = true
        return image
    }()

    init(recorder: MeetingRecorder) {
        self.recorder = recorder
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        infoItem.isEnabled = false
        for (menuItem, action) in [(pauseItem, #selector(togglePause)), (stopItem, #selector(stop)), (showItem, #selector(showWindow))] {
            menuItem.target = self
            menuItem.action = action
        }
        menu.autoenablesItems = false
        menu.items = [infoItem, .separator(), pauseItem, stopItem, .separator(), showItem]
        item.menu = menu
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        update()
    }

    func update() {
        let time = RecordingTime.string(recorder.elapsed)
        let button = item.button
        switch recorder.state {
        case .paused:
            button?.image = Self.pauseImage
            infoItem.title = "Пауза · \(time)"
            pauseItem.title = "Продолжить"
        case .finishing:
            button?.image = Self.pauseImage
            infoItem.title = "Сохранение записи…"
            pauseItem.title = "Пауза"
        case .starting:
            button?.image = Self.dot
            infoItem.title = "Подготовка записи…"
            pauseItem.title = "Пауза"
        default:
            button?.image = Self.dot
            infoItem.title = "Идёт запись · \(time)"
            pauseItem.title = "Пауза"
        }
        button?.title = " " + time
        button?.setAccessibilityLabel("\(infoItem.title). Meteora")
        let controllable = recorder.state == .recording || recorder.state == .paused
        pauseItem.isEnabled = controllable
        stopItem.isEnabled = controllable
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func togglePause() { recorder.togglePause() }
    @objc private func stop() { recorder.stop() }
    @objc private func showWindow() {
        NSApp.activate()
        RecordingWindow.show(recorder: recorder)
    }
}
