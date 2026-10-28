import AppKit
import UniformTypeIdentifiers
import Security

/// Hand-off to MacWhisper (or any other transcription app).
enum MacWhisper {
    static let bundleIDs = [
        "com.goodsnooze.macwhisper",
        "com.goodsnooze.MacWhisper",
        "com.goodsnooze.macwhisper.appstore",
        "com.goodsnooze.whispertranscription",
    ]

    static func appURL() -> URL? {
        for id in bundleIDs {
            for url in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id) where isGenuine(url, bundleID: id) {
                return url
            }
        }
        return nil
    }

    /// Meeting audio is sensitive: only hand it to an app whose signature is
    /// valid, issued by Apple to a real developer (Developer ID or Mac App
    /// Store) and whose signing identifier matches the expected bundle ID.
    /// A look-alike app with a copied bundle ID cannot pass this.
    static func isGenuine(_ url: URL, bundleID: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let req = "identifier \"\(bundleID)\" and anchor apple generic and " +
            "(certificate leaf[field.1.2.840.113635.100.6.1.9] or " +
            "(certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]))"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(req as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    static var isInstalled: Bool { appURL() != nil }

    /// Puts the file on the clipboard (so it can be pasted in Finder or any
    /// app) and opens it in MacWhisper.
    @MainActor
    static func handOff(_ file: URL) async -> Bool {
        let pb = NSPasteboard.general
        pb.prepareForNewContents(with: .currentHostOnly) // don't sync to other devices
        pb.writeObjects([file as NSURL])

        guard let app = appURL() else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.promptsUserIfNeeded = false
        do {
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: cfg)
            return true
        } catch {
            return false
        }
    }
}

/// The user's real Downloads folder (inside the sandbox the home-relative
/// path points into the container, so ask the password database instead).
enum Folders {
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var exports: URL {
        realHome.appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("Meteora", isDirectory: true)
    }

    static func ensureExports() throws -> URL {
        let dir = exports
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
