import AppKit
import UniformTypeIdentifiers

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
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        // Fallback: any installed app that opens audio and is called "…Whisper…".
        return NSWorkspace.shared.urlsForApplications(toOpen: .audio).first { url in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            return name.contains("macwhisper") || name.contains("whisper transcription")
        }
    }

    static var isInstalled: Bool { appURL() != nil }

    /// Puts the file on the clipboard (so it can be pasted in Finder or any
    /// app) and opens it in MacWhisper.
    @MainActor
    static func handOff(_ file: URL) async -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
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
            .appendingPathComponent("Volant", isDirectory: true)
    }

    static func ensureExports() throws -> URL {
        let dir = exports
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
