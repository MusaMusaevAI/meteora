import AppKit
import SwiftUI

/// Checks whether a newer build of Meteora exists. Every green CI build is
/// published to the repository's `build-output` branch with its number in
/// `BUILD` and the results of all checks in `STATUS`; a build counts as an
/// update only when every check passed. Nothing is downloaded or installed
/// silently: the user gets a link to the disk image.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(build: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date? {
        didSet { UserDefaults.standard.set(lastChecked, forKey: Keys.lastChecked) }
    }
    /// Check once a day on launch.
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: Keys.automatic) }
    }

    static let base = URL(string: "https://raw.githubusercontent.com/MusaMusaevAI/meteora/build-output/")!
    static let downloadURL = URL(string: "https://github.com/MusaMusaevAI/meteora/raw/build-output/Meteora.dmg")!
    static let projectURL = URL(string: "https://github.com/MusaMusaevAI/meteora")!

    private enum Keys {
        static let automatic = "updates.automatic"
        static let lastChecked = "updates.lastChecked"
        static let announced = "updates.announcedBuild"
    }

    private init() {
        automatic = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true
        lastChecked = UserDefaults.standard.object(forKey: Keys.lastChecked) as? Date
    }

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
    var versionText: String { "\(currentVersion) (сборка \(currentBuild))" }

    /// On launch: quietly, at most once a day; speaks up only about a build
    /// it hasn't announced before.
    func checkOnLaunchIfNeeded() {
        guard automatic, ProcessInfo.processInfo.environment["METEORA_SELFTEST"] != "1" else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 20 * 3600 { return }
        Task {
            await check()
            if case .available(let build) = state, UserDefaults.standard.integer(forKey: Keys.announced) != build {
                UserDefaults.standard.set(build, forKey: Keys.announced)
                presentAvailable(build)
            }
        }
    }

    /// From the menu or Settings: always tells the result.
    func checkInteractively() {
        Task {
            await check()
            switch state {
            case .available(let build): presentAvailable(build)
            case .upToDate:
                let a = NSAlert()
                a.messageText = "У вас последняя версия"
                a.informativeText = "Meteora \(versionText) — новее сборки нет."
                a.runModal()
            case .failed(let message):
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "Не удалось проверить обновления"
                a.informativeText = message
                a.runModal()
            case .idle, .checking: break
            }
        }
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        do {
            async let buildText = Self.fetch("BUILD")
            async let statusText = Self.fetch("STATUS")
            let (b, s) = try await (buildText, statusText)
            guard let build = Int(b.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw URLError(.cannotParseResponse)
            }
            let parts = s.split(whereSeparator: \.isWhitespace)
            let green = !parts.isEmpty && parts.allSatisfy { $0.hasSuffix("=success") }
            state = green && build > currentBuild ? .available(build: build) : .upToDate
            lastChecked = Date()
        } catch {
            state = .failed("Нет связи с GitHub. Проверьте интернет и попробуйте ещё раз.")
        }
    }

    func openDownload() { NSWorkspace.shared.open(Self.downloadURL) }

    private func presentAvailable(_ build: Int) {
        let a = NSAlert()
        a.messageText = "Доступна новая версия Meteora"
        a.informativeText = "Сборка \(build) (у вас \(currentBuild)). Скачается образ диска: откройте его и перетащите Meteora в «Программы» вместо старой. Записи, расшифровки и настройки сохранятся."
        a.addButton(withTitle: "Скачать")
        a.addButton(withTitle: "Позже")
        if a.runModal() == .alertFirstButtonReturn { openDownload() }
    }

    private static func fetch(_ name: String) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent(name), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.setValue("Meteora", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4096,
              let text = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
        return text
    }
}
