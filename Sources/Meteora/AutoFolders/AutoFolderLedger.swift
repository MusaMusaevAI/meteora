import Foundation
import CryptoKit

/// Which recordings were already handled, so each file is processed once.
/// A file is identified by path + size + modification date (the same rule as
/// saved transcripts): a recording that keeps growing after it was processed
/// counts as a new file and is processed again with the fuller content.
/// Also keeps a content fingerprint, so a copy of a processed recording in
/// the same folder is recognised and skipped.
struct AutoFolderLedgerEntry: Codable, Equatable {
    enum State: String, Codable {
        case done
        case failed
        /// A copy of a recording already processed in this folder.
        case duplicate
        /// The user stopped it («Пропустить»); not retried automatically.
        case skipped
    }

    var key: String
    var path: String
    var folderID: UUID
    var state: State
    var attempts: Int
    var fingerprint: String?
    var date: Date
    var message: String?
    var outputs: [String]
}

@MainActor
final class AutoFolderLedger {
    /// One try plus two retries.
    static let maxAttempts = 3
    /// Pause before a failed file is tried again.
    static let retryDelay: TimeInterval = 90
    static let maxEntries = 3000

    private let file: URL
    private(set) var entries: [String: AutoFolderLedgerEntry] = [:]

    init(file: URL) {
        self.file = file
        load()
    }

    static func key(path: String, size: Int64, modified: Date) -> String {
        let id = "\(path)|\(size)|\(modified.timeIntervalSince1970)"
        return SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func entry(_ key: String) -> AutoFolderLedgerEntry? { entries[key] }

    /// Whether a file with this key should be left alone right now.
    func isSettled(_ key: String, now: Date = Date()) -> Bool {
        guard let e = entries[key] else { return false }
        switch e.state {
        case .done, .duplicate, .skipped: return true
        case .failed:
            if e.attempts >= Self.maxAttempts { return true }
            return now.timeIntervalSince(e.date) < Self.retryDelay
        }
    }

    /// A processed recording in `folderID` with the same content, if any.
    func original(fingerprint: String, folderID: UUID, otherThan path: String) -> AutoFolderLedgerEntry? {
        entries.values.first { $0.state == .done && $0.fingerprint == fingerprint && $0.folderID == folderID && $0.path != path }
    }

    func markDone(_ key: String, path: String, folderID: UUID, fingerprint: String?, outputs: [URL], message: String? = nil) {
        put(AutoFolderLedgerEntry(key: key, path: path, folderID: folderID, state: .done, attempts: (entries[key]?.attempts ?? 0) + 1,
                                  fingerprint: fingerprint, date: Date(), message: message, outputs: outputs.map(\.path)))
    }

    @discardableResult
    func markFailed(_ key: String, path: String, folderID: UUID, fingerprint: String?, message: String) -> Int {
        let attempts = (entries[key]?.attempts ?? 0) + 1
        put(AutoFolderLedgerEntry(key: key, path: path, folderID: folderID, state: .failed, attempts: attempts,
                                  fingerprint: fingerprint, date: Date(), message: message, outputs: []))
        return attempts
    }

    func mark(_ state: AutoFolderLedgerEntry.State, _ key: String, path: String, folderID: UUID, fingerprint: String?, message: String?) {
        put(AutoFolderLedgerEntry(key: key, path: path, folderID: folderID, state: state, attempts: entries[key]?.attempts ?? 0,
                                  fingerprint: fingerprint, date: Date(), message: message, outputs: []))
    }

    /// Lets failed and skipped files of a folder be tried again («Обработать уже лежащие»).
    func resetUnfinished(folderID: UUID) {
        let stale = entries.values.filter { $0.folderID == folderID && ($0.state == .failed || $0.state == .skipped) }
        guard !stale.isEmpty else { return }
        for e in stale { entries[e.key] = nil }
        save()
    }

    func forget(folderID: UUID) {
        let before = entries.count
        entries = entries.filter { $0.value.folderID != folderID }
        if entries.count != before { save() }
    }

    func removeAll() {
        entries = [:]
        save()
    }

    private func put(_ e: AutoFolderLedgerEntry) {
        entries[e.key] = e
        if entries.count > Self.maxEntries {
            let oldest = entries.values.sorted { $0.date < $1.date }.prefix(entries.count - Self.maxEntries)
            for o in oldest { entries[o.key] = nil }
        }
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: file), data.count < 32 << 20 else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let list = (try? dec.decode([AutoFolderLedgerEntry].self, from: data)) ?? []
        for e in list { entries[e.key] = e }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let list = entries.values.sorted { $0.date < $1.date }
        if let data = try? enc.encode(list) { try? data.write(to: file, options: .atomic) }
    }

    // MARK: Fingerprint

    /// Size + SHA-256 of the first and last megabyte. Cheap even for
    /// multi-gigabyte recordings; reads through the open file only.
    nonisolated static func fingerprint(of url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let chunk = 1 << 20
        var hasher = SHA256()
        guard let head = try? h.read(upToCount: chunk) else { return nil }
        hasher.update(data: head)
        if size > Int64(chunk) * 2 {
            do {
                try h.seek(toOffset: UInt64(size - Int64(chunk)))
                if let tail = try h.read(upToCount: chunk) { hasher.update(data: tail) }
            } catch {
                return nil
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(size)-\(digest)"
    }
}
