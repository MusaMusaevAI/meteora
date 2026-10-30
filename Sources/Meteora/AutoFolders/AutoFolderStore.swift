import Foundation
import AppKit
import MeteoraCore

/// A finished (or finally failed) recording, for the menu-bar menu and the
/// settings window.
struct AutoFolderResult: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var recordingPath: String
    var folderID: UUID
    var date: Date
    var succeeded: Bool
    /// «52 мин · Word, TXT» or the error.
    var message: String
    var outputs: [URL]
    var recordingURL: URL { URL(fileURLWithPath: recordingPath) }
}

/// What is being processed right now.
struct AutoFolderProgress: Equatable {
    var title: String
    var folderName: String
    /// «Чтение файла», «Расшифровка», «Разделение по говорящим», «Итоги…», «Сохранение».
    var stage: String
    /// «Расшифровываю», «Разделяю говорящих», «Составляю итоги», «Сохраняю».
    var verb: String
    /// The whole job, 0…1.
    var fraction: Double
    var percent: Int { Int((min(max(fraction, 0), 1) * 100).rounded(.down)) }
}

/// Auto-folders: watches the chosen folders, waits until a new recording is
/// fully written or downloaded, then transcribes it (plus speakers and
/// summary if asked), saves the folder's formats and tells the user.
///
/// One file at a time; the ledger makes sure each file is processed once.
/// Folder access comes from security-scoped bookmarks made in the Open panel
/// and stays open while the folder is enabled.
@MainActor
final class AutoFolderStore: ObservableObject {
    static let shared = AutoFolderStore()

    // MARK: Published state (for the settings window and the status item)

    @Published private(set) var folders: [WatchedFolder] = []
    @Published private(set) var isPaused: Bool
    @Published private(set) var current: AutoFolderProgress?
    /// Files ready and waiting for their turn.
    @Published private(set) var queuedCount = 0
    /// Files seen but still being written or downloaded.
    @Published private(set) var settlingCount = 0
    @Published private(set) var settlingTitle: String?
    /// Newest first, at most 10.
    @Published private(set) var recent: [AutoFolderResult] = []
    /// Folders that can't be reached right now (deleted, unplugged, access lost), with a reason.
    @Published private(set) var unavailable: [UUID: String] = [:]
    /// Files wait because the speech model isn't downloaded.
    @Published private(set) var waitingForSpeechModel = false

    // MARK: Hooks set by the app

    /// Opens a recording in the main window (status-item menu, notification).
    var onOpenRecording: ((URL) -> Void)?
    /// Opens the auto-folder settings (menu-bar item «Настройки автопапок…»).
    /// Until set, that menu item shows the main window.
    var onOpenSettings: (() -> Void)?
    /// True while the main window is already transcribing this file; the
    /// auto-folder then waits and reuses that transcript.
    var isBusyElsewhere: ((URL) -> Bool)?
    /// Self-test only: «detected», «ready», «started», «done», «failed»,
    /// «duplicate», «skipped», «requeued».
    var testObserver: ((String, URL) -> Void)?

    // MARK: Configuration

    /// A file must keep its size and modification date this long.
    let stableSeconds: TimeInterval
    static let rescanInterval: TimeInterval = 20
    static let pollInterval: TimeInterval = 1
    /// Downloads in progress and temporary files.
    static let partialExtensions: Set<String> = ["crdownload", "part", "partial", "download", "tmp", "temp", "opdownload", "filepart"]

    private let isShared: Bool
    private let postsNotifications: Bool
    private let stateFile: URL
    private let ledger: AutoFolderLedger
    private static let pausedKey = "autofolders.paused"
    private static let telemostSuggestedKey = "autofolders.telemostSuggested"

    // MARK: Engine state

    private struct Candidate {
        var folderID: UUID
        var url: URL
        var size: Int64
        var modified: Date
        var stableSince: Date
        var force: Bool
    }

    private struct Pending {
        var folderID: UUID
        var url: URL
        var key: String
        var size: Int64
        var modified: Date
        var fingerprint: String?
        var force: Bool
    }

    private enum CancelIntent { case requeue, skip, drop }

    private var accessed: [UUID: URL] = [:]
    private var scoped: Set<UUID> = []
    private var watchers: [UUID: AutoFolderWatcher] = [:]
    private var candidates: [String: Candidate] = [:]
    private var queue: [Pending] = []
    private var processing: Pending?
    private var processor: MeetingProcessor?
    private var token: CancelToken?
    private var cancelIntent: CancelIntent = .skip
    private var loopRunning = false
    private var started = false
    private var pollTimer: Timer?
    private var rescanTimer: Timer?
    private var scanScheduled: Set<UUID> = []
    private var downloadRequested: Set<String> = []

    /// - Parameters:
    ///   - stateDirectory: where autofolders.json and the ledger live
    ///     (default: Application Support/Meteora). The self-test uses its own.
    init(stateDirectory: URL? = nil, postsNotifications: Bool = true, stableSeconds: TimeInterval = 6) {
        let shared = stateDirectory == nil
        let base: URL
        if let stateDirectory {
            base = stateDirectory
        } else {
            let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
            base = support.appendingPathComponent("Meteora", isDirectory: true)
        }
        isShared = shared
        stateFile = base.appendingPathComponent("autofolders.json")
        ledger = AutoFolderLedger(file: base.appendingPathComponent("autofolders-ledger.json"))
        self.postsNotifications = postsNotifications
        self.stableSeconds = stableSeconds
        isPaused = shared ? UserDefaults.standard.bool(forKey: Self.pausedKey) : false
        load()
    }

    // MARK: - Public API

    var enabledCount: Int { folders.filter(\.isEnabled).count }
    var hasEnabledFolders: Bool { enabledCount > 0 }
    /// Background mode: closing the main window keeps Meteora running.
    var keepsAppRunning: Bool { hasEnabledFolders }
    var isWorking: Bool { current != nil }

    func folder(_ id: UUID) -> WatchedFolder? { folders.first { $0.id == id } }

    /// The folder asks for speakers, but the voice model isn't downloaded
    /// (the settings UI can offer `SpeakerModelController.shared.download()`).
    func needsSpeakerModel(_ id: UUID) -> Bool {
        folder(id)?.separateSpeakers == true && !SpeakerModelController.shared.isInstalled
    }

    /// The folder asks for a summary, but the chosen engine can't run
    /// unattended (local model missing, or cloud key/consent missing).
    func needsSummarySetup(_ id: UUID) -> Bool {
        guard folder(id)?.summarize == true else { return false }
        let c = SummaryModelController.shared
        switch c.engine {
        case .local(let tier): return !c.installed.contains(tier)
        case .cloud(let p): return !(c.isReady && c.hasConsent(p))
        }
    }

    /// One line for the status item and the settings window.
    var statusLine: String {
        let n = enabledCount
        if n == 0 { return folders.isEmpty ? "Автопапки не настроены" : "Автопапки выключены" }
        if isPaused {
            return queuedCount > 0 ? "Автопапки на паузе · ждут \(ru(queuedCount, "запись", "записи", "записей"))" : "Автопапки на паузе"
        }
        if let c = current { return "\(c.verb) «\(c.title)» · \(c.percent) %" }
        if waitingForSpeechModel { return "Нужна модель речи · ждут \(ru(queuedCount, "запись", "записи", "записей"))" }
        if let t = settlingTitle { return "Жду, пока допишется «\(t)»" }
        return "Слежу за " + ru(n, "папкой", "папками", "папками")
    }

    /// Starts watching the enabled folders. Call once at launch.
    func start() {
        guard !started else { return }
        started = true
        for f in folders where f.isEnabled { activate(f.id) }
        let rescan = Timer(timeInterval: Self.rescanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescanAll() }
        }
        RunLoop.main.add(rescan, forMode: .common)
        rescanTimer = rescan
        rescanAll()
    }

    /// Stops watching and releases folder access (self-test cleanup).
    func shutdown() {
        cancelCurrent(.drop)
        rescanTimer?.invalidate(); rescanTimer = nil
        pollTimer?.invalidate(); pollTimer = nil
        for id in Array(accessed.keys) { deactivate(id) }
        candidates = [:]
        queue = []
        started = false
        updateCounts()
    }

    /// Asks for a folder in the Open panel and starts watching it.
    @discardableResult
    func addFolder() -> WatchedFolder? {
        let telemost = WatchedFolder.telemostURL
        let watchingTelemost = folders.contains(where: { $0.path == telemost.path })
        return presentPanel(directory: watchingTelemost ? nil : telemost,
                            message: "Выберите папку, за которой следить: новые записи в ней Meteora расшифрует сама. Подойдёт и папка в iCloud Drive.")
    }

    /// First-run suggestion: the panel opens at «Документы/Телемост». macOS
    /// only lets Meteora read the folder after the user confirms it here.
    @discardableResult
    func suggestTelemost() -> WatchedFolder? {
        if isShared { UserDefaults.standard.set(true, forKey: Self.telemostSuggestedKey) }
        return presentPanel(directory: WatchedFolder.telemostURL,
                            message: "Телемост сохраняет записи встреч в «Документы/Телемост». Нажмите «Следить» — и каждая новая запись расшифруется сама, даже если окно Meteora закрыто.")
    }

    /// Whether to offer «Следить за папкой Телемоста» (not added, not offered yet).
    var shouldSuggestTelemost: Bool {
        let path = WatchedFolder.telemostURL.path
        return !folders.contains(where: { $0.path == path }) && !UserDefaults.standard.bool(forKey: Self.telemostSuggestedKey)
    }

    /// Adds a folder the app can already reach (self-test, or a URL that
    /// came from a panel elsewhere). Makes a bookmark when possible.
    @discardableResult
    func addAccessibleFolder(_ url: URL, formats: Set<ExportFormat>? = nil, separateSpeakers: Bool = false,
                             summarize: Bool = false, output: OutputPlacement = .default) -> WatchedFolder? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return insert(url: url, bookmark: bookmark, formats: formats, separateSpeakers: separateSpeakers,
                      summarize: summarize, output: output)
    }

    func remove(_ id: UUID) {
        dropWork(for: id)
        deactivate(id)
        folders.removeAll { $0.id == id }
        unavailable[id] = nil
        ledger.forget(folderID: id)
        save()
        updateCounts()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = folders.firstIndex(where: { $0.id == id }), folders[i].isEnabled != on else { return }
        folders[i].isEnabled = on
        save()
        if on {
            activate(id)
            scanFolder(id)
        } else {
            dropWork(for: id)
            deactivate(id)
            unavailable[id] = nil
        }
        updateCounts()
    }

    func setFormats(_ id: UUID, _ formats: Set<ExportFormat>) {
        guard !formats.isEmpty else { return }
        update(id) { $0.formats = formats }
    }

    func setOptions(_ id: UUID, _ options: AutoFolderOptions) {
        update(id) { $0.options = options }
    }

    /// Any other change to a folder's settings (formats, options, output).
    /// Applies to recordings that start processing after the change.
    func update(_ id: UUID, _ change: (inout WatchedFolder) -> Void) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        var f = folders[i]
        let keep = (f.id, f.bookmark, f.path, f.addedAt, f.isEnabled)
        change(&f)
        // Identity, access and history are not editable here.
        f.id = keep.0; f.bookmark = keep.1; f.path = keep.2; f.addedAt = keep.3; f.isEnabled = keep.4
        if f.formats.isEmpty { f.formats = folders[i].formats }
        guard f != folders[i] else { return }
        folders[i] = f
        save()
    }

    /// Stops the current file and holds the queue. Watching continues, so
    /// new recordings are noticed and wait. Survives relaunch.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        if isShared { UserDefaults.standard.set(true, forKey: Self.pausedKey) }
        if processing != nil { cancelCurrent(.requeue) }
        updateCounts()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if isShared { UserDefaults.standard.set(false, forKey: Self.pausedKey) }
        kick()
        updateCounts()
    }

    func togglePause() { isPaused ? resume() : pause() }

    /// Stops the current file and doesn't retry it automatically
    /// («Обработать уже лежащие» picks it up again).
    func skipCurrent() { cancelCurrent(.skip) }

    /// Queues the recordings that were already in the folder (older than
    /// the moment it was added), plus earlier failures. Returns how many.
    @discardableResult
    func processExisting(_ id: UUID) -> Int {
        guard let f = folder(id), f.isEnabled else { return 0 }
        ledger.resetUnfinished(folderID: id)
        let n = scan(f, includeExisting: true)
        startPollingIfNeeded()
        updateCounts()
        return n
    }

    /// How many recordings in the folder have not been processed (for a
    /// «В папке 12 записей — обработать?» prompt).
    func existingCount(_ id: UUID) -> Int {
        guard let f = folder(id), let root = accessed[id] else { return 0 }
        return mediaFiles(in: root).filter { item in
            guard let a = attributes(item.path) else { return false }
            let key = AutoFolderLedger.key(path: item.path, size: a.size, modified: a.modified)
            if let e = ledger.entry(key), e.state == .done || e.state == .duplicate { return false }
            return f.isEnabled
        }.count
    }

    /// Rescans every enabled folder now.
    func rescanNow() { rescanAll() }

    func revealInFinder(_ id: UUID) {
        guard let f = folder(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([accessed[id] ?? f.url])
    }

    /// Opens a processed recording in Meteora (from the menu or a notification).
    func openRecording(path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            onOpenRecording?(url)
            return
        }
        // Folder access may be closed: the journal keeps a read bookmark.
        if let entry = MeetingJournal.shared.entries.first(where: { $0.path == path }),
           let resolved = MeetingJournal.shared.resolve(entry) {
            onOpenRecording?(resolved)
        }
    }

    // MARK: - Folders and access

    private func presentPanel(directory: URL?, message: String) -> WatchedFolder? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Следить"
        panel.message = message
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK, let picked = panel.url else { return nil }
        guard let bookmark = try? picked.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                                      relativeTo: nil) else {
            let alert = NSAlert()
            alert.messageText = "Не удалось запомнить папку"
            alert.informativeText = "macOS не дала доступ к «\(picked.lastPathComponent)». Попробуйте выбрать её ещё раз."
            alert.runModal()
            return nil
        }
        return insert(url: picked, bookmark: bookmark, formats: nil, separateSpeakers: false, summarize: false, output: .default)
    }

    private func insert(url: URL, bookmark: Data?, formats: Set<ExportFormat>?, separateSpeakers: Bool,
                        summarize: Bool, output: OutputPlacement) -> WatchedFolder? {
        let path = url.standardizedFileURL.path
        if let i = folders.firstIndex(where: { $0.path == path }) {
            // Already there: refresh access and switch it on.
            if let bookmark { folders[i].bookmark = bookmark }
            deactivate(folders[i].id)
            folders[i].isEnabled = true
            save()
            activate(folders[i].id)
            scanFolder(folders[i].id)
            updateCounts()
            return folders[i]
        }
        let first = folders.isEmpty
        let f = WatchedFolder(url: url, bookmark: bookmark, formats: formats ?? ExportSettings.shared.formats,
                              separateSpeakers: separateSpeakers, summarize: summarize, output: output)
        folders.append(f)
        save()
        if started { activate(f.id); scanFolder(f.id) }
        updateCounts()
        if postsNotifications, first || !AutoFolderNotifier.shared.hasAsked {
            AutoFolderNotifier.shared.requestAuthorizationIfNeeded()
        }
        return f
    }

    /// Opens access to the folder and starts its watcher.
    private func activate(_ id: UUID) {
        guard let root = access(id) else { return }
        if watchers[id] == nil {
            watchers[id] = AutoFolderWatcher(url: root) { [weak self] in self?.scheduleScan(id) }
        }
        if watchers[id]?.isRunning != true { watchers[id]?.start() }
    }

    private func deactivate(_ id: UUID) {
        watchers[id]?.stop()
        watchers[id] = nil
        if let url = accessed[id], scoped.contains(id) { url.stopAccessingSecurityScopedResource() }
        accessed[id] = nil
        scoped.remove(id)
    }

    /// The folder's URL with security scope started, or nil (and a reason
    /// in `unavailable`).
    private func access(_ id: UUID) -> URL? {
        if let url = accessed[id] {
            if Self.isDirectory(url) { return url }
            deactivate(id)
        }
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return nil }
        var url = folders[i].url
        var didScope = false
        if let bookmark = folders[i].bookmark {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                          relativeTo: nil, bookmarkDataIsStale: &stale) else {
                unavailable[id] = "Папка не найдена — возможно, её удалили или переименовали."
                return nil
            }
            url = resolved
            didScope = url.startAccessingSecurityScopedResource()
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                folders[i].bookmark = fresh
                save()
            }
        }
        guard Self.isDirectory(url) else {
            if didScope { url.stopAccessingSecurityScopedResource() }
            unavailable[id] = didScope || folders[i].bookmark == nil
                ? "Папка недоступна — диск отключён или папку удалили."
                : "Нет доступа к папке — добавьте её заново."
            return nil
        }
        let path = url.standardizedFileURL.path
        if path != folders[i].path {
            // Moved or renamed: follow it.
            folders[i].path = path
            folders[i].displayName = WatchedFolder.displayName(for: url)
            save()
        }
        accessed[id] = url
        if didScope { scoped.insert(id) }
        unavailable[id] = nil
        return url
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func dropWork(for id: UUID) {
        candidates = candidates.filter { $0.value.folderID != id }
        queue.removeAll { $0.folderID == id }
        if processing?.folderID == id { cancelCurrent(.drop) }
    }

    // MARK: - Scanning

    private func scheduleScan(_ id: UUID) {
        guard !scanScheduled.contains(id) else { return }
        scanScheduled.insert(id)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.scanScheduled.remove(id)
            self?.scanFolder(id)
        }
    }

    private func scanFolder(_ id: UUID) {
        guard let f = folder(id), f.isEnabled else { return }
        if watchers[id]?.folderVanished == true { deactivate(id) }
        if accessed[id] == nil || watchers[id]?.isRunning != true { activate(id) }
        _ = scan(f)
        startPollingIfNeeded()
        updateCounts()
    }

    private func rescanAll() {
        for f in folders where f.isEnabled { scanFolder(f.id) }
        if waitingForSpeechModel, SpeechModelController.shared.isInstalled, SpeechModelController.vadModelURL != nil {
            waitingForSpeechModel = false
        }
        kick()
        updateCounts()
    }

    private static let scanKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                                     .creationDateKey, .addedToDirectoryDateKey]

    /// Supported media files directly inside the folder (not in subfolders).
    private func mediaFiles(in root: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Self.scanKeys,
                                                                  options: [])) ?? []
        return items.filter { item in
            let name = item.lastPathComponent
            guard !name.hasPrefix("."), !Self.partialExtensions.contains(item.pathExtension.lowercased()),
                  MediaFormats.isSupported(item) else { return false }
            return (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }

    /// Adds new files of a folder as candidates. Returns how many were added.
    @discardableResult
    private func scan(_ folder: WatchedFolder, includeExisting: Bool = false) -> Int {
        guard let root = accessed[folder.id] else { return 0 }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Self.scanKeys, options: [])) ?? []
        let threshold = folder.addedAt.addingTimeInterval(-2)
        var added = 0
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix(".") {
                // «.Запись.webm.icloud»: an old-style iCloud placeholder.
                if name.hasSuffix(".icloud"), name.count > 8 {
                    let real = root.appendingPathComponent(String(name.dropFirst().dropLast(7)))
                    let v = try? item.resourceValues(forKeys: Set(Self.scanKeys))
                    if MediaFormats.isSupported(real), includeExisting || Self.appeared(v) >= threshold {
                        requestDownload(real)
                    }
                }
                continue
            }
            if Self.partialExtensions.contains(item.pathExtension.lowercased()) { continue }
            guard MediaFormats.isSupported(item) else { continue }
            let path = item.standardizedFileURL.path
            if candidates[path] != nil || queue.contains(where: { $0.url.path == path }) || processing?.url.path == path { continue }
            guard let v = try? item.resourceValues(forKeys: Set(Self.scanKeys)), v.isRegularFile == true else { continue }
            let size = Int64(v.fileSize ?? 0)
            let modified = v.contentModificationDate ?? .distantPast
            let key = AutoFolderLedger.key(path: path, size: size, modified: modified)
            if ledger.isSettled(key) { continue }
            let retrying = ledger.entry(key)?.state == .failed
            guard includeExisting || retrying || Self.appeared(v) >= threshold else { continue }
            candidates[path] = Candidate(folderID: folder.id, url: URL(fileURLWithPath: path), size: size,
                                         modified: modified, stableSince: Date(), force: includeExisting)
            added += 1
            testObserver?("detected", item)
        }
        return added
    }

    /// When the file showed up in the folder: the latest of created, added
    /// to this folder (a copy keeps its old creation date) and modified.
    private static func appeared(_ v: URLResourceValues?) -> Date {
        [v?.creationDate, v?.addedToDirectoryDate, v?.contentModificationDate].compactMap { $0 }.max() ?? .distantPast
    }

    private func requestDownload(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !downloadRequested.contains(path) else { return }
        downloadRequested.insert(path)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    // MARK: - Waiting until a file is complete

    private func startPollingIfNeeded() {
        if candidates.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func attributes(_ path: String) -> (size: Int64, modified: Date)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (a[.modificationDate] as? Date) ?? .distantPast
        return (size, modified)
    }

    /// Cloud-only file that still has to come down from iCloud.
    private func isCloudOnly(_ path: String) -> Bool {
        // A fresh URL: URL objects cache resource values.
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              v.isUbiquitousItem == true else { return false }
        return v.ubiquitousItemDownloadingStatus != .current
    }

    private static func canRead(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        return ((try? h.read(upToCount: 16))?.count ?? 0) > 0
    }

    private func isBeingRecordedHere(_ path: String) -> Bool {
        let recorder = MeetingRecorder.shared
        return recorder.isActive && recorder.fileURL?.standardizedFileURL.path == path
    }

    private func poll() {
        let now = Date()
        for (path, c) in candidates {
            var c = c
            guard folder(c.folderID)?.isEnabled == true, let a = attributes(path) else {
                candidates[path] = nil
                continue
            }
            if isCloudOnly(path) {
                requestDownload(c.url)
                c.stableSince = now
                candidates[path] = c
                continue
            }
            if a.size != c.size || a.modified != c.modified {
                c.size = a.size
                c.modified = a.modified
                c.stableSince = now
                candidates[path] = c
                continue
            }
            guard now.timeIntervalSince(c.stableSince) >= stableSeconds, a.size > 0 else { continue }
            guard Self.canRead(path), !isBeingRecordedHere(path) else {
                c.stableSince = now
                candidates[path] = c
                continue
            }
            candidates[path] = nil
            enqueue(c)
        }
        startPollingIfNeeded()
        updateCounts()
        kick()
    }

    private func enqueue(_ c: Candidate) {
        let path = c.url.path
        let key = AutoFolderLedger.key(path: path, size: c.size, modified: c.modified)
        if ledger.isSettled(key) { return }
        let fingerprint = AutoFolderLedger.fingerprint(of: c.url, size: c.size)
        if let fingerprint, let original = ledger.original(fingerprint: fingerprint, folderID: c.folderID, otherThan: path) {
            ledger.mark(.duplicate, key, path: path, folderID: c.folderID, fingerprint: fingerprint,
                        message: "Копия «\((original.path as NSString).lastPathComponent)»")
            testObserver?("duplicate", c.url)
            return
        }
        queue.append(Pending(folderID: c.folderID, url: c.url, key: key, size: c.size, modified: c.modified,
                             fingerprint: fingerprint, force: c.force))
        testObserver?("ready", c.url)
    }

    // MARK: - Processing

    private func kick() {
        guard !loopRunning, !isPaused, !queue.isEmpty else { return }
        loopRunning = true
        Task { @MainActor [weak self] in await self?.runLoop() }
    }

    private func runLoop() async {
        // Without a window macOS would nap the app and slow transcription
        // to a crawl; keep it running until the queue is done.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                                                             reason: "Meteora: расшифровка записей из автопапок")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        while !isPaused, !queue.isEmpty {
            guard SpeechModelController.shared.isInstalled, SpeechModelController.vadModelURL != nil else {
                waitingForSpeechModel = true
                break
            }
            waitingForSpeechModel = false
            let item = queue.removeFirst()
            updateCounts()
            guard let f = folder(item.folderID), f.isEnabled, let root = accessed[f.id] else { continue }
            // Changed since it settled, or the main window is on it: wait again.
            let a = attributes(item.url.path)
            if a == nil { continue }
            if a?.size != item.size || a?.modified != item.modified || isBusyElsewhere?(item.url) == true {
                candidates[item.url.path] = Candidate(folderID: item.folderID, url: item.url, size: a?.size ?? 0,
                                                      modified: a?.modified ?? .distantPast, stableSince: Date(), force: item.force)
                testObserver?("requeued", item.url)
                startPollingIfNeeded()
                continue
            }
            processing = item
            await process(item, folder: f, root: root)
            processing = nil
            token = nil
            if waitingForSpeechModel { break }
        }
        current = nil
        loopRunning = false
        if queue.isEmpty { processor = nil } // frees the speech model's memory
        updateCounts()
        // Resumed while the last file was being cancelled.
        if !isPaused, !queue.isEmpty, !waitingForSpeechModel { kick() }
    }

    private struct Weights {
        var speakers: Bool
        var summary: Bool
        func overall(_ stage: MeetingStage) -> Double {
            let reading = 0.05, transcribing = 0.75, extra = 0.15, saving = 0.05
            let total = reading + transcribing + (speakers ? extra : 0) + (summary ? extra : 0) + saving
            var offset = 0.0
            let value: Double
            switch stage {
            case .reading(let p): value = reading * p
            case .transcribing(let p): offset = reading; value = transcribing * p
            case .speakers(let p): offset = reading + transcribing; value = extra * p
            case .summary(let p, _): offset = reading + transcribing + (speakers ? extra : 0); value = extra * p
            case .saving: offset = total - saving; value = 0
            }
            return min(1, (offset + value) / total)
        }
    }

    private func process(_ item: Pending, folder f: WatchedFolder, root: URL) async {
        let token = CancelToken()
        self.token = token
        cancelIntent = .skip
        let title = sanitizedBaseName(item.url)
        let weights = Weights(speakers: f.separateSpeakers, summary: f.summarize)
        current = AutoFolderProgress(title: title, folderName: f.displayName, stage: MeetingStage.reading(0).text,
                                     verb: MeetingStage.reading(0).verb, fraction: 0)
        testObserver?("started", item.url)
        let job = MeetingJob(url: item.url, title: title, destination: f.destination(for: item.url, root: root),
                             formats: f.orderedFormats, options: f.exportOptions ?? ExportSettings.shared.options,
                             reuseTranscript: true, separateSpeakers: f.separateSpeakers, summarize: f.summarize,
                             addToJournal: isShared)
        let processor = self.processor ?? MeetingProcessor(background: true)
        self.processor = processor
        do {
            let outcome = try await processor.process(job, token: token) { [weak self] stage in
                guard let self, self.token === token else { return }
                self.current = AutoFolderProgress(title: title, folderName: f.displayName, stage: stage.text,
                                                  verb: stage.verb, fraction: weights.overall(stage))
            }
            ledger.markDone(item.key, path: item.url.path, folderID: f.id, fingerprint: item.fingerprint, outputs: outcome.written,
                            message: outcome.warnings.isEmpty ? nil : outcome.warnings.joined(separator: "; "))
            var parts = [MeetingProcessor.durationText(outcome.duration)]
            let saved = f.orderedFormats.map(\.short) + (outcome.summary != nil ? ["итоги"] : [])
            if !saved.isEmpty { parts.append("сохранено: " + saved.joined(separator: ", ")) }
            if outcome.speakers > 1 { parts.append(ru(outcome.speakers, "говорящий", "говорящих", "говорящих")) }
            let message = parts.joined(separator: " · ")
            addResult(AutoFolderResult(title: title, recordingPath: item.url.path, folderID: f.id, date: Date(), succeeded: true,
                                       message: message, outputs: outcome.written))
            if postsNotifications {
                AutoFolderNotifier.shared.postDone(title: title, body: ([message] + outcome.warnings.prefix(1)).joined(separator: "\n"),
                                                   recordingPath: item.url.path, outputFolder: job.destination)
            }
            testObserver?("done", item.url)
        } catch {
            if token.isCancelled {
                switch cancelIntent {
                case .requeue:
                    queue.insert(item, at: 0)
                    testObserver?("requeued", item.url)
                case .skip:
                    ledger.mark(.skipped, item.key, path: item.url.path, folderID: f.id, fingerprint: item.fingerprint, message: "Пропущено")
                    testObserver?("skipped", item.url)
                case .drop:
                    break
                }
            } else if (error as? MeetingProcessorError) == .speechModelMissing {
                queue.insert(item, at: 0)
                waitingForSpeechModel = true
            } else {
                let message = MeetingProcessor.message(error)
                var attempts = ledger.markFailed(item.key, path: item.url.path, folderID: f.id, fingerprint: item.fingerprint, message: message)
                // Retrying can't help a recording without speech.
                if (error as? MeetingProcessorError) == .noSpeech || (error as? ExportError) == .nothingToExport {
                    while attempts < AutoFolderLedger.maxAttempts {
                        attempts = ledger.markFailed(item.key, path: item.url.path, folderID: f.id, fingerprint: item.fingerprint, message: message)
                    }
                }
                if attempts >= AutoFolderLedger.maxAttempts {
                    addResult(AutoFolderResult(title: title, recordingPath: item.url.path, folderID: f.id, date: Date(), succeeded: false,
                                               message: message, outputs: []))
                    if postsNotifications {
                        AutoFolderNotifier.shared.postFailure(title: title, message: message, recordingPath: item.url.path)
                    }
                }
                testObserver?("failed", item.url)
            }
        }
        current = nil
    }

    private func cancelCurrent(_ intent: CancelIntent) {
        guard processing != nil, let token else { return }
        cancelIntent = intent
        token.cancel()
    }

    private func addResult(_ r: AutoFolderResult) {
        recent.insert(r, at: 0)
        if recent.count > 10 { recent.removeLast(recent.count - 10) }
    }

    private func updateCounts() {
        if queuedCount != queue.count { queuedCount = queue.count }
        if settlingCount != candidates.count { settlingCount = candidates.count }
        let title = candidates.values.sorted { $0.stableSince < $1.stableSince }.first.map { sanitizedBaseName($0.url) }
        if settlingTitle != title { settlingTitle = title }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: stateFile), data.count < 4 << 20 else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        folders = (try? dec.decode([WatchedFolder].self, from: data)) ?? []
    }

    private func save() {
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(folders) { try? data.write(to: stateFile, options: .atomic) }
    }
}
