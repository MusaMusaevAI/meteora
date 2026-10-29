import Foundation
import AppKit
import UserNotifications

/// «Готово» notifications for auto-folders. Permission is asked once, when
/// the first auto-folder is added. A click on a notification opens the
/// recording in Meteora (handled by the app delegate, see
/// `AppDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`).
@MainActor
final class AutoFolderNotifier: ObservableObject {
    static let shared = AutoFolderNotifier()

    enum Permission: Equatable {
        case notDetermined
        case denied
        case allowed
    }

    /// What macOS allows.
    @Published private(set) var permission: Permission = .notDetermined
    /// The user's own switch in Meteora (on by default).
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    static let categoryDone = "autofolder.done"
    static let categoryFailed = "autofolder.failed"
    /// userInfo key with the recording's path.
    nonisolated static let pathKey = "recordingPath"
    private static let enabledKey = "autofolders.notifications"
    private static let askedKey = "autofolders.notificationsAsked"

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        refresh()
    }

    var hasAsked: Bool { UserDefaults.standard.bool(forKey: Self.askedKey) }

    /// Re-reads the system setting (call when the settings window appears).
    func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in AutoFolderNotifier.shared.apply(status) }
        }
    }

    private func apply(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional: permission = .allowed
        case .denied: permission = .denied
        default: permission = .notDetermined
        }
    }

    /// Shows the system prompt the first time; later calls only refresh.
    func requestAuthorizationIfNeeded() {
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in AutoFolderNotifier.shared.refresh() }
        }
    }

    /// System Settings → Notifications → Meteora.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.musamusaev.meteora"
        let urls = ["x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
                    "x-apple.systempreferences:com.apple.preference.notifications"]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    func postDone(title: String, body: String, recordingPath: String, outputFolder: URL?) {
        var info: [String: String] = [Self.pathKey: recordingPath]
        if let outputFolder { info["outputFolder"] = outputFolder.path }
        post(title: "Готово: \(title)", body: body, category: Self.categoryDone, info: info)
    }

    func postFailure(title: String, message: String, recordingPath: String) {
        post(title: "Не удалось обработать: \(title)", body: message, category: Self.categoryFailed,
             info: [Self.pathKey: recordingPath])
    }

    private func post(title: String, body: String, category: String, info: [String: String]) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = info
        content.threadIdentifier = "autofolders"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
