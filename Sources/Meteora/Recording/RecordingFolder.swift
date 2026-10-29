import Foundation
import AppKit

/// The folder recordings are saved to. The sandbox only lets Meteora write
/// where the user pointed, so the folder is chosen once in an Open panel and
/// remembered as a security-scoped bookmark (app-scope, read-write) in the
/// app's own preferences. Access stays open for the app's lifetime, so the
/// finished file can be opened and transcribed right away.
@MainActor
enum RecordingFolder {
    private static let bookmarkKey = "recorder.folderBookmark"
    private static var accessed: URL?

    /// The remembered folder with access started, or nil if none is set or it
    /// is gone (deleted, on an unplugged drive).
    static func current() -> URL? {
        if let accessed { return accessed }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        accessed = url
        return url
    }

    /// Asks for a folder. Returns nil if the user cancels.
    @discardableResult
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = current() ?? Folders.realHome.appendingPathComponent("Documents", isDirectory: true)
        panel.message = "Выберите папку для записей встреч. Её можно сменить в окне записи."
        panel.prompt = "Выбрать"
        guard panel.runModal() == .OK, let picked = panel.url else { return nil }
        guard let data = try? picked.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return nil
        }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
        return current() ?? picked
    }

    /// The remembered folder, or asks for one.
    static func ensure() -> URL? {
        current() ?? choose()
    }

    /// Forgets the folder (when writing there fails).
    static func forget() {
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    /// Name for the UI, as Finder shows it («Документы»).
    static var displayName: String? {
        guard let url = current() else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }

    /// «Запись 29.10.26 14-05-31.webm» — the Telemost naming scheme, which the
    /// meeting journal parses for the date. A clash gets « (2)», « (3)»…
    static func newFileURL(in folder: URL, date: Date = Date(), fileExtension: String) -> URL {
        let base = "Запись " + fileDateFormatter.string(from: date)
        var url = folder.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path), n < 1000 {
            url = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(fileExtension)
            n += 1
        }
        return url
    }

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd.MM.yy HH-mm-ss"
        return f
    }()
}
