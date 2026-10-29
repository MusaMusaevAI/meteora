import Foundation
import AppKit
import ServiceManagement

/// «Открывать при входе в систему» via `SMAppService.mainApp`. Lets
/// auto-folders work after a restart without the user opening Meteora.
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    enum State: Equatable {
        case off
        case on
        /// Registered, but the user must allow it in System Settings →
        /// General → Login Items.
        case needsApproval
        /// macOS can't find the app to register (e.g. run from the disk image).
        case unavailable
    }

    @Published private(set) var state: State = .off
    /// The last error, in Russian, for the settings window.
    @Published private(set) var error: String?

    init() { refresh() }

    var isEnabled: Bool { state == .on || state == .needsApproval }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled: state = .on
        case .requiresApproval: state = .needsApproval
        case .notFound: state = .unavailable
        default: state = .off
        }
    }

    /// Turns opening at login on or off. Returns whether it worked.
    @discardableResult
    func setEnabled(_ on: Bool) -> Bool {
        error = nil
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            }
            refresh()
            if on, state == .needsApproval {
                error = "Разрешите Meteora в Системных настройках → Основные → Объекты входа."
            }
            return true
        } catch {
            refresh()
            self.error = Self.describe(error, turningOn: on)
            return false
        }
    }

    /// System Settings → General → Login Items.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func describe(_ error: Error, turningOn: Bool) -> String {
        let path = Bundle.main.bundlePath
        if turningOn, !path.hasPrefix("/Applications/") {
            return "Не удалось включить: переместите Meteora в папку «Программы» и попробуйте снова."
        }
        return (turningOn ? "Не удалось включить открытие при входе: " : "Не удалось выключить открытие при входе: ")
            + error.localizedDescription
    }

    /// The app was started by macOS at login (not by the user). Check in
    /// `applicationDidFinishLaunching`, while the launch event is current.
    static var wasLaunchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication),
              let property = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)) else { return false }
        return property.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
