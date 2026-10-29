import AppKit
import UserNotifications
import MeteoraCore

/// Auto-folder wiring of the app delegate: background mode, the menu-bar
/// item, notifications. `MeteoraApp.swift` only calls `installAutoFolders`
/// and asks `AutoFolderStore.shared.keepsAppRunning` when the last window
/// closes.
extension AppDelegate {
    /// Call early in `applicationDidFinishLaunching` (the notification
    /// delegate must be set before launching finishes, so a click on a
    /// notification that launched the app is delivered).
    func installAutoFolders(isSelfTest: Bool) {
        UNUserNotificationCenter.current().delegate = self
        let store = AutoFolderStore.shared
        store.onOpenRecording = { [weak self] url in self?.openFromBackground(url) }
        store.isBusyElsewhere = { [weak self] url in
            guard let model = self?.model else { return false }
            return model.url?.standardizedFileURL.path == url.standardizedFileURL.path && model.transcribeProgress != nil
        }
        // CI runs its own temporary auto-folder (AutoFolderStore.runSelfTest).
        guard !isSelfTest else { return }
        store.start()
        AppStatusItem.install(openMain: { [weak self] in self?.showMainWindow() },
                              openSettings: { [weak self] in
            if let open = AutoFolderStore.shared.onOpenSettings { open() } else { self?.showMainWindow() }
        })
    }

    /// Shows a recording from the menu bar or a notification. Asks first if
    /// the window is busy with another recording.
    func openFromBackground(_ url: URL) {
        showMainWindow()
        NSApp.activate()
        if model.url?.standardizedFileURL.path == url.standardizedFileURL.path { return }
        if model.isWorking {
            let alert = NSAlert()
            alert.messageText = "Открыть «\(sanitizedBaseName(url))»?"
            alert.informativeText = "Текущая обработка в окне остановится."
            alert.addButton(withTitle: "Открыть")
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.open(url)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Banners also while Meteora is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A click on «Готово: …» opens that recording in Meteora.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let path = response.notification.request.content.userInfo[AutoFolderNotifier.pathKey] as? String else { return }
        await MainActor.run {
            AutoFolderStore.shared.openRecording(path: path)
        }
    }
}
