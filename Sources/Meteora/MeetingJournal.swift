import Foundation
import AppKit
import MeteoraCore

/// One meeting the user has opened. The file itself stays where it is; we
/// keep a security-scoped bookmark so it can be reopened from the journal
/// without asking again, plus what's needed to show and search the list.
struct JournalEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var bookmark: Data
    var path: String
    var fileName: String
    var title: String
    /// When the meeting happened: from a Telemost-style name
    /// («… 28.10.26 14-05-31»), else the file's creation date.
    var date: Date
    var openedAt: Date
    var duration: Double
    var hasVideo: Bool
    var hasTranscript: Bool
    var excerpt: String
    /// Lower-cased transcript text for search (capped).
    var searchText: String

}

@MainActor
final class MeetingJournal: ObservableObject {
    static let shared = MeetingJournal()

    @Published private(set) var entries: [JournalEntry] = []
    /// Entries whose file can't be found any more (moved off the disk,
    /// deleted, on an unplugged drive).
    @Published private(set) var missing: Set<UUID> = []

    static let maxEntries = 500
    static let searchCap = 60_000

    private let file: URL

    init(file: URL? = nil) {
        if let file {
            self.file = file
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
            self.file = base.appendingPathComponent("Meteora/journal.json")
        }
        load()
    }

    // MARK: Recording

    func record(url: URL, info: MediaInfo, transcript: Transcript?) {
        guard let bookmark = (try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                    includingResourceValuesForKeys: nil, relativeTo: nil))
                ?? (try? url.bookmarkData()) else { return }
        var entry = entries.first(where: { $0.path == url.path }) ?? JournalEntry(
            id: UUID(), bookmark: bookmark, path: url.path, fileName: url.lastPathComponent,
            title: sanitizedBaseName(url), date: Self.meetingDate(for: url), openedAt: Date(),
            duration: info.duration, hasVideo: info.video != nil, hasTranscript: false, excerpt: "", searchText: "")
        entry.bookmark = bookmark
        entry.openedAt = Date()
        entry.duration = info.duration
        entry.hasVideo = info.video != nil
        if let transcript { Self.apply(transcript, to: &entry) }
        upsert(entry)
    }

    func updateTranscript(for url: URL, transcript: Transcript) {
        guard var entry = entries.first(where: { $0.path == url.path }) else { return }
        Self.apply(transcript, to: &entry)
        upsert(entry)
    }

    private static func apply(_ tr: Transcript, to entry: inout JournalEntry) {
        let text = tr.segments.map(\.text).joined(separator: " ")
        entry.hasTranscript = !tr.segments.isEmpty
        entry.excerpt = String(text.prefix(220))
        entry.searchText = String(text.lowercased().prefix(searchCap))
    }

    private func upsert(_ entry: JournalEntry) {
        entries.removeAll { $0.id == entry.id || $0.path == entry.path }
        entries.insert(entry, at: 0)
        entries.sort { $0.openedAt > $1.openedAt }
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        save()
    }

    // MARK: Using

    /// Resolves the bookmark. The caller opens the URL (and starts access).
    func resolve(_ entry: JournalEntry) -> URL? {
        var stale = false
        let url = (try? URL(resolvingBookmarkData: entry.bookmark, options: [.withSecurityScope, .withoutUI],
                            relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: entry.bookmark, options: [.withoutUI],
                         relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url else { missing.insert(entry.id); return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        let exists = FileManager.default.fileExists(atPath: url.path)
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard exists else { missing.insert(entry.id); return nil }
        missing.remove(entry.id)
        if url.path != entry.path, var e = entries.first(where: { $0.id == entry.id }) {
            // The file was moved or renamed: follow it.
            e.path = url.path
            e.fileName = url.lastPathComponent
            upsert(e)
        }
        return url
    }

    /// Forgets the meeting and its saved transcript. Never touches the
    /// recording itself.
    func remove(_ entry: JournalEntry) {
        if let url = resolve(entry) {
            let scoped = url.startAccessingSecurityScopedResource()
            try? FileManager.default.removeItem(at: TranscriptStore.file(for: url))
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        entries.removeAll { $0.id == entry.id }
        save()
    }

    /// Re-checks which files are still reachable.
    func refreshAvailability() {
        for e in entries { _ = resolve(e) }
    }

    func removeAll() {
        entries = []
        save()
    }

    func search(_ query: String) -> [JournalEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { e in
            let hay = (e.title + " " + e.fileName).lowercased() + " " + e.searchText
            return words.allSatisfy { hay.contains($0) }
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: file), data.count < 128 << 20 else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        entries = (try? dec.decode([JournalEntry].self, from: data)) ?? []
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(entries) { try? data.write(to: file, options: .atomic) }
    }

    var storageBytes: Int64 { Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }

    // MARK: Dates

    static func meetingDate(for url: URL) -> Date {
        if let d = parseTelemostDate(url.deletingPathExtension().lastPathComponent) { return d }
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return v?.creationDate ?? v?.contentModificationDate ?? Date()
    }

    /// Finds «dd.MM.yy HH-mm-ss» (or with a four-digit year) in a name.
    static func parseTelemostDate(_ name: String) -> Date? {
        let pattern = #"(\d{2})\.(\d{2})\.(\d{2,4})[ _T](\d{2})[-:.](\d{2})(?:[-:.](\d{2}))?"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
        func n(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: name) else { return nil }
            return Int(name[r])
        }
        guard let day = n(1), let month = n(2), var year = n(3), let hour = n(4), let minute = n(5) else { return nil }
        if year < 100 { year += 2000 }
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute; c.second = n(6) ?? 0
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60 else { return nil }
        return Calendar.current.date(from: c)
    }
}
