import AppKit
import Combine

/// Meteora's own menu-bar item for background work (auto-folders). Shown
/// while at least one auto-folder is enabled, so the app stays reachable
/// after its window is closed.
///
/// It is separate from `RecordingStatusItem` (red dot + time, exists only
/// while a meeting is being recorded): during a recording both are shown
/// side by side, each with its own menu, so recording controls never move
/// or hide behind auto-folder status.
///
/// Icon: a template waveform glyph; while a file is processed, a progress
/// ring around a small dot, filling with the job's progress.
@MainActor
final class AppStatusItem: NSObject, NSMenuDelegate {
    private static var installed: AppStatusItem?

    private let store: AutoFolderStore
    private let openMain: () -> Void
    private let openSettings: () -> Void
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var watch: Set<AnyCancellable> = []
    private var shownPercent = -1

    /// Installs the item and keeps it in sync with the store. Call once at
    /// launch. `openMain` shows the main window, `openSettings` the
    /// auto-folder settings.
    static func install(store: AutoFolderStore? = nil, openMain: @escaping () -> Void,
                        openSettings: @escaping () -> Void) {
        guard installed == nil else { return }
        installed = AppStatusItem(store: store ?? AutoFolderStore.shared, openMain: openMain, openSettings: openSettings)
    }

    private init(store: AutoFolderStore, openMain: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.store = store
        self.openMain = openMain
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
            .store(in: &watch)
        sync()
    }

    // MARK: Item

    private func sync() {
        if store.hasEnabledFolders {
            if item == nil {
                let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                i.menu = menu
                i.button?.imagePosition = .imageOnly
                item = i
                shownPercent = -2
            }
            updateIcon()
        } else if let i = item {
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
    }

    private func updateIcon() {
        guard let button = item?.button else { return }
        let percent = store.current?.percent ?? (store.isPaused ? -3 : -1)
        button.setAccessibilityLabel("Meteora. \(store.statusLine)")
        button.toolTip = store.statusLine
        guard percent != shownPercent else { return }
        shownPercent = percent
        if let current = store.current {
            button.image = Self.ring(current.fraction)
        } else {
            button.image = store.isPaused ? Self.pausedImage : Self.idleImage
        }
    }

    private static let idleImage: NSImage = {
        let image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Meteora")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    private static let pausedImage: NSImage = {
        let image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Meteora — пауза")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    /// A thin ring that fills clockwise from the top, a faint track and a
    /// dot in the middle. Template, so it follows the menu-bar appearance.
    private static func ring(_ fraction: Double) -> NSImage {
        let f = CGFloat(min(max(fraction, 0), 1))
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6.5
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.6
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            if f > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * f, clockwise: true)
                arc.lineWidth = 1.8
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Meteora — обработка"
        return image
    }

    // MARK: Menu

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        // AppKit calls this on the main thread, right before showing the menu.
        MainActor.assumeIsolated { () -> Void in self.rebuildMenu() }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let status = NSMenuItem(title: store.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let c = store.current {
            let stage = NSMenuItem(title: "\(c.stage) · папка «\(c.folderName)»", action: nil, keyEquivalent: "")
            stage.isEnabled = false
            menu.addItem(stage)
            menu.addItem(action("Пропустить эту запись", #selector(skip)))
        }
        if store.queuedCount > 0, store.current != nil || store.isPaused {
            let q = NSMenuItem(title: "В очереди: \(ru(store.queuedCount, "запись", "записи", "записей"))", action: nil, keyEquivalent: "")
            q.isEnabled = false
            menu.addItem(q)
        }
        if !store.recent.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Недавние", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for r in store.recent.prefix(5) {
                let mi = action(r.title, #selector(openRecent(_:)))
                mi.representedObject = r.recordingPath
                mi.image = NSImage(systemSymbolName: r.succeeded ? "checkmark.circle" : "exclamationmark.circle",
                                   accessibilityDescription: r.succeeded ? "Готово" : "Ошибка")
                mi.toolTip = r.message
                menu.addItem(mi)
            }
        }
        menu.addItem(.separator())
        menu.addItem(action("Открыть Meteora", #selector(openMeteora)))
        menu.addItem(action(store.isPaused ? "Возобновить автопапки" : "Приостановить автопапки", #selector(togglePause)))
        menu.addItem(action("Настройки автопапок…", #selector(settings)))
        menu.addItem(.separator())
        menu.addItem(action("Выйти из Meteora", #selector(quit)))
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        mi.target = self
        mi.isEnabled = true
        return mi
    }

    @objc private func skip() { store.skipCurrent() }
    @objc private func togglePause() { store.togglePause() }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSApp.activate()
        store.openRecording(path: path)
    }

    @objc private func openMeteora() {
        NSApp.activate()
        openMain()
    }

    @objc private func settings() {
        NSApp.activate()
        openSettings()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
