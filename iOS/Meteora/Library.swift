import Foundation
import SwiftUI
import CryptoKit
import MeteoraCore

/// A cancellation flag shared with background work.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

/// One recording in the list.
struct Recording: Codable, Identifiable, Hashable {
    enum Place: String, Codable { case local, shared }

    var id: UUID
    /// File name in the app's Documents, or the path relative to the shared folder.
    var path: String
    var place: Place
    var title: String
    var customTitle: String?
    var addedAt: Date
    var meetingDate: Date?
    var duration: Double
    var hasVideo: Bool
    var fileSize: Int64
    var pinned: Bool
    /// Number of words once transcribed.
    var words: Int?
    var hasSummary: Bool?

    var displayTitle: String { customTitle ?? title }
    var date: Date { meetingDate ?? addedAt }
}

/// The recordings list, their files and what Meteora made from them.
///
/// Files live in the app's Documents — visible in Files → On My iPhone →
/// Meteora, so recordings can be added or taken out by hand — or in the
/// shared iCloud Drive folder (SharedFolder). Transcripts and summaries are
/// stored in Application Support, keyed by the recording's id.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var items: [Recording] = []
    @Published var order: Order {
        didSet { UserDefaults.standard.set(order.rawValue, forKey: "library.order") }
    }

    enum Order: String, CaseIterable, Identifiable {
        case meetingDate, added
        var id: String { rawValue }
        var title: String { self == .meetingDate ? "По дате встречи" : "По времени добавления" }
    }

    static let supportedExtensions: Set<String> = [
        "webm", "mp4", "m4v", "mov", "m4a", "mp3", "wav", "aif", "aiff", "caf", "aac", "flac", "3gp",
    ]

    private init() {
        order = Order(rawValue: UserDefaults.standard.string(forKey: "library.order") ?? "") ?? .meetingDate
        load()
    }

    // MARK: Places

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var support: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Meteora", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var listFile: URL { support.appendingPathComponent("library.json") }

    /// Where a recording's file is right now (nil: the shared folder is gone).
    func url(of r: Recording) -> URL? {
        switch r.place {
        case .local: return Self.documents.appendingPathComponent(r.path)
        case .shared: return SharedFolder.shared.url?.appendingPathComponent(r.path)
        }
    }

    // MARK: List

    var ordered: [Recording] {
        items.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            switch order {
            case .meetingDate: return a.date > b.date
            case .added: return a.addedAt > b.addedAt
            }
        }
    }

    func recording(_ id: UUID) -> Recording? { items.first { $0.id == id } }

    func update(_ id: UUID, _ change: (inout Recording) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        save()
    }

    func togglePin(_ id: UUID) { update(id) { $0.pinned.toggle() } }

    func rename(_ id: UUID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.customTitle = t.isEmpty ? nil : t }
    }

    /// Removes from the list; a local file is deleted too (it lives only here).
    func delete(_ id: UUID) {
        guard let r = recording(id) else { return }
        if r.place == .local, let u = url(of: r) { try? FileManager.default.removeItem(at: u) }
        try? FileManager.default.removeItem(at: Self.transcriptFile(id))
        try? FileManager.default.removeItem(at: Self.summaryFile(id))
        items.removeAll { $0.id == id }
        save()
    }

    // MARK: Adding

    /// Copies a file the user picked or shared into Documents and adds it.
    @discardableResult
    func importFile(_ source: URL) async -> Recording? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard Self.supportedExtensions.contains(source.pathExtension.lowercased()) else { return nil }
        let dest = Self.uniqueURL(in: Self.documents, name: source.lastPathComponent)
        do {
            if source.standardizedFileURL.deletingLastPathComponent() == Self.documents.standardizedFileURL {
                return await add(at: Self.documents.appendingPathComponent(source.lastPathComponent), place: .local,
                                 path: source.lastPathComponent)
            }
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            return nil
        }
        return await add(at: dest, place: .local, path: dest.lastPathComponent)
    }

    /// Adds a file that is already in place (Documents, the shared folder,
    /// a new recording). Reads duration and kind first.
    @discardableResult
    func add(at url: URL, place: Recording.Place, path: String) async -> Recording? {
        if let existing = items.first(where: { $0.place == place && $0.path == path }) { return existing }
        let info = await Self.probe(url)
        let base = url.deletingPathExtension().lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        let r = Recording(id: UUID(), path: path, place: place, title: base, customTitle: nil, addedAt: Date(),
                          meetingDate: Self.parseDate(base) ?? info?.created, duration: info?.duration ?? 0,
                          hasVideo: info?.hasVideo ?? false, fileSize: size, pinned: false, words: nil, hasSummary: nil)
        items.append(r)
        save()
        return r
    }

    /// Picks up files dropped into Documents through the Files app.
    func scanDocuments() async {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.documents.path) else { return }
        for name in names where Self.supportedExtensions.contains((name as NSString).pathExtension.lowercased()) {
            if !items.contains(where: { $0.place == .local && $0.path == name }) {
                await add(at: Self.documents.appendingPathComponent(name), place: .local, path: name)
            }
        }
        // Files removed in Files disappear from the list (their transcripts too).
        for r in items where r.place == .local && !fm.fileExists(atPath: Self.documents.appendingPathComponent(r.path).path) {
            delete(r.id)
        }
    }

    // MARK: Transcripts and summaries

    static func transcriptFile(_ id: UUID) -> URL {
        let dir = support.appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(id.uuidString + ".json")
    }

    static func summaryFile(_ id: UUID) -> URL {
        let dir = support.appendingPathComponent("Summaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(id.uuidString + ".json")
    }

    func transcript(_ id: UUID) -> Transcript? { Self.read(Transcript.self, Self.transcriptFile(id)) }
    func summary(_ id: UUID) -> MeetingSummary? { Self.read(MeetingSummary.self, Self.summaryFile(id)) }

    func saveTranscript(_ tr: Transcript, for id: UUID) {
        Self.write(tr, Self.transcriptFile(id))
        let words = tr.segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
        update(id) { $0.words = words }
    }

    func saveSummary(_ s: MeetingSummary, for id: UUID) {
        Self.write(s, Self.summaryFile(id))
        update(id) { $0.hasSummary = true }
    }

    // MARK: Storage

    private func load() {
        items = Self.read([Recording].self, Self.listFile) ?? []
    }

    private func save() {
        Self.write(items, Self.listFile)
    }

    static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, _ url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(value) { try? data.write(to: url, options: .atomic) }
    }

    static func uniqueURL(in dir: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    struct Probe { var duration: Double; var hasVideo: Bool; var created: Date? }

    static func probe(_ url: URL) async -> Probe? {
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        if url.pathExtension.lowercased() == "webm" {
            return await Task.detached(priority: .utility) { () -> Probe? in
                guard let analyzed = try? WebMDemuxer.analyze(url: url) else { return nil }
                let info = analyzed.0
                return Probe(duration: info.duration, hasVideo: info.video != nil, created: created)
            }.value
        }
        guard let info = try? await AssetProbe.analyze(url: url) else { return nil }
        return Probe(duration: info.duration, hasVideo: info.video != nil, created: created)
    }

    /// «Запись 29.10.26 14-05-31», Telemost and Meteora names.
    static func parseDate(_ name: String) -> Date? {
        let pattern = #"(\d{2})\.(\d{2})\.(\d{2,4})[ _T](\d{2})[-:.](\d{2})(?:[-:.](\d{2}))?"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
        func n(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: name) else { return nil }
            return Int(name[r])
        }
        guard let day = n(1), let month = n(2), var year = n(3), let hour = n(4), let minute = n(5) else { return nil }
        if year < 100 { year += 2000 }
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60 else { return nil }
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute; c.second = n(6) ?? 0
        return Calendar.current.date(from: c)
    }
}

enum Format {
    static func duration(_ s: Double) -> String {
        let t = Int(max(0, s))
        if t >= 3600 { return String(format: "%d ч %02d мин", t / 3600, t / 60 % 60) }
        if t >= 60 { return "\(t / 60) мин" }
        return "\(t) с"
    }

    static func date(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "Сегодня, \(time)" }
        if cal.isDateInYesterday(d) { return "Вчера, \(time)" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "d MMMM, HH:mm" : "d MMMM yyyy, HH:mm"
        return f.string(from: d)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
