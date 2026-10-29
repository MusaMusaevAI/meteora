import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A folder shared with the Mac through iCloud Drive (п. 25).
///
/// The user picks it once (for example iCloud Drive/Meteora); Meteora keeps a
/// bookmark. Recordings made on the iPhone can be saved straight into it —
/// the Mac's auto-folder watching the same folder transcribes them there —
/// and recordings put there on the Mac show up in the iPhone's list.
/// Transcripts made on the iPhone can be written next to the recording as
/// text, so they are on the Mac too. No iCloud entitlement is needed: the
/// folder is reached like any folder picked in Files.
@MainActor
final class SharedFolder: ObservableObject {
    static let shared = SharedFolder()

    @Published private(set) var url: URL?
    @Published private(set) var name: String?
    @Published private(set) var lastScan: Date?
    @Published private(set) var problem: String?
    /// New iPhone recordings go to the shared folder instead of Documents.
    @Published var saveRecordingsHere: Bool { didSet { UserDefaults.standard.set(saveRecordingsHere, forKey: Keys.save) } }
    /// After a transcription, write «<name>.txt» next to the recording.
    @Published var writeTranscripts: Bool { didSet { UserDefaults.standard.set(writeTranscripts, forKey: Keys.write) } }

    private enum Keys {
        static let bookmark = "shared.bookmark"
        static let save = "shared.saveRecordings"
        static let write = "shared.writeTranscripts"
    }

    private init() {
        saveRecordingsHere = UserDefaults.standard.object(forKey: Keys.save) as? Bool ?? true
        writeTranscripts = UserDefaults.standard.object(forKey: Keys.write) as? Bool ?? true
        resolve()
    }

    var isSet: Bool { url != nil }

    private func resolve() {
        guard let data = UserDefaults.standard.data(forKey: Keys.bookmark) else { return }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
            problem = "Папка недоступна — выберите её заново."
            return
        }
        guard u.startAccessingSecurityScopedResource() else {
            problem = "Нет доступа к папке — выберите её заново."
            return
        }
        if stale, let fresh = try? u.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Keys.bookmark) }
        url = u
        name = u.lastPathComponent
        problem = nil
    }

    /// From the folder picker.
    func choose(_ picked: URL) {
        guard picked.startAccessingSecurityScopedResource() else {
            problem = "Нет доступа к этой папке."
            return
        }
        do {
            let data = try picked.bookmarkData()
            UserDefaults.standard.set(data, forKey: Keys.bookmark)
            url?.stopAccessingSecurityScopedResource()
            url = picked
            name = picked.lastPathComponent
            problem = nil
            Task { await scan() }
        } catch {
            picked.stopAccessingSecurityScopedResource()
            problem = "Не удалось запомнить папку: \(error.localizedDescription)"
        }
    }

    func forget() {
        url?.stopAccessingSecurityScopedResource()
        UserDefaults.standard.removeObject(forKey: Keys.bookmark)
        url = nil
        name = nil
        let lib = Library.shared
        for r in lib.items where r.place == .shared { lib.delete(r.id) }
    }

    /// Adds recordings that appeared in the folder (also files still only in
    /// iCloud: they are listed now and downloaded when opened).
    func scan() async {
        guard let dir = url else { return }
        let fm = FileManager.default
        var coordinatorError: NSError?
        var names: [String] = []
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [], error: &coordinatorError) { u in
            names = (try? fm.contentsOfDirectory(atPath: u.path)) ?? []
        }
        let lib = Library.shared
        for raw in names {
            // iCloud placeholders: ".name.webm.icloud"
            var name = raw
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
            }
            guard Library.supportedExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            if lib.items.contains(where: { $0.place == .shared && $0.path == name }) { continue }
            let fileURL = dir.appendingPathComponent(name)
            if raw != name { try? fm.startDownloadingUbiquitousItem(at: fileURL) }
            await lib.add(at: fileURL, place: .shared, path: name)
        }
        lastScan = Date()
    }

    /// Makes sure a shared file is on the device before it is opened.
    func ensureDownloaded(_ fileURL: URL) async -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) { return true }
        try? fm.startDownloadingUbiquitousItem(at: fileURL)
        for _ in 0..<600 { // up to 5 minutes
            if fm.fileExists(atPath: fileURL.path),
               let v = try? fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               v.ubiquitousItemDownloadingStatus == .current || v.ubiquitousItemDownloadingStatus == nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return fm.fileExists(atPath: fileURL.path)
    }

    /// «<recording>.txt» next to the recording, for the Mac.
    func writeTranscriptText(_ text: String, for recordingName: String) {
        guard writeTranscripts, let dir = url else { return }
        let base = (recordingName as NSString).deletingPathExtension
        let target = dir.appendingPathComponent(base + ".txt")
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &err) { u in
            try? Data(text.utf8).write(to: u, options: .atomic)
        }
    }
}

/// Folder picker (Files) for the shared folder.
struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        p.allowsMultipleSelection = false
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}
