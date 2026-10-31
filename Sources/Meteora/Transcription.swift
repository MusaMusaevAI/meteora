import Foundation
import CryptoKit
import MeteoraCore
import MeteoraASR

/// State of the downloadable speech model, shared by all windows.
@MainActor
final class SpeechModelController: ObservableObject {
    static let shared = SpeechModelController()

    @Published private(set) var isInstalled = ModelStore.shared.isInstalled
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    private var token: CancelToken?

    var sizeText: String { FileSizeText.string(SpeechModel.totalSize) }

    func refresh() { isInstalled = ModelStore.shared.isInstalled }

    @discardableResult
    func download() async -> Bool {
        guard progress == nil else { return false }
        let t = CancelToken()
        token = t
        error = nil
        progress = 0
        defer { progress = nil; token = nil; refresh() }
        do {
            try await ModelStore.shared.install(progress: { p in
                Task { @MainActor in if SpeechModelController.shared.progress != nil { SpeechModelController.shared.progress = p } }
            }, isCancelled: { t.isCancelled })
            return true
        } catch ModelError.cancelled {
            return false
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func cancel() { token?.cancel() }

    func remove() {
        try? ModelStore.shared.remove()
        refresh()
    }

    static var vadModelURL: URL? { Bundle.main.url(forResource: "silero_vad", withExtension: "onnx") }
}

/// The speaker-separation models, downloaded on demand: the shared pyannote
/// segmentation plus one voice model per tier (`SpeakerModelTier`:
/// `.standard` TitaNet-S 46 MB in total, `.accurate` TitaNet-L 107 MB).
///
/// API for the UI:
/// - `tier` — chosen tier, persisted in UserDefaults "speakers.tier";
/// - `installed` (set of tiers) / `isReady(_:)` / `isInstalled` (chosen tier);
/// - `downloading` + `progress` (0…1) while a download runs, `error` after
///   a failure; `download(_:)` (nil = chosen tier), `cancel()`;
/// - `remove(_:)` deletes a tier's voice model (the shared segmentation goes
///   with the last tier);
/// - `sizeText` (chosen tier) / `downloadSizeText(_:)` — download size; `tier.title`,
///   `tier.detail`, `tier.embeddingName` for labels;
/// - `maxSpeakers` (10) — upper bound for a "number of speakers" picker
///   (nil = automatic, else 2…maxSpeakers), passed to
///   `MeetingModel.separateSpeakers(count:)`.
@MainActor
final class SpeakerModelController: ObservableObject {
    static let shared = SpeakerModelController()
    static let tierKey = "speakers.tier"
    /// Largest exact count the UI should offer.
    static let maxSpeakers = 10

    @Published var tier: SpeakerModelTier {
        didSet { UserDefaults.standard.set(tier.rawValue, forKey: Self.tierKey) }
    }
    @Published private(set) var installed: Set<SpeakerModelTier> = []
    /// The tier being downloaded.
    @Published private(set) var downloading: SpeakerModelTier?
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    private var token: CancelToken?

    init() {
        tier = UserDefaults.standard.string(forKey: Self.tierKey).flatMap(SpeakerModelTier.init(rawValue:))
            ?? SpeakerModel.defaultTier
        // The old pyannote + CAM++ folder: keep the segmentation file, drop CAM++.
        ModelStore.migrateLegacySpeakerModels()
        refresh()
    }

    /// The chosen tier is ready to use.
    var isInstalled: Bool { installed.contains(tier) }
    func isReady(_ t: SpeakerModelTier) -> Bool { installed.contains(t) }

    /// Download size of the chosen tier (what is still missing, or the full
    /// size once installed).
    var sizeText: String { downloadSizeText(tier) }
    func downloadSizeText(_ t: SpeakerModelTier) -> String {
        let missing = t.missingSize
        return FileSizeText.string(missing > 0 ? missing : t.totalSize)
    }

    func refresh() {
        installed = Set(SpeakerModelTier.allCases.filter { $0.isInstalled })
    }

    /// Downloads and verifies a tier (nil = the chosen one).
    @discardableResult
    func download(_ which: SpeakerModelTier? = nil) async -> Bool {
        guard progress == nil else { return false }
        let target = which ?? tier
        let t = CancelToken()
        token = t
        error = nil
        downloading = target
        progress = 0
        defer { progress = nil; downloading = nil; token = nil; refresh() }
        do {
            try await target.install(progress: { p in
                Task { @MainActor in if SpeakerModelController.shared.progress != nil { SpeakerModelController.shared.progress = p } }
            }, isCancelled: { t.isCancelled })
            return true
        } catch ModelError.cancelled {
            return false
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func cancel() { token?.cancel() }

    /// Deletes a tier's voice model. Not during a download (the shared
    /// segmentation model may be removed with the last tier).
    func remove(_ t: SpeakerModelTier) {
        guard downloading == nil else { return }
        try? t.remove()
        refresh()
    }
}

/// Saved transcripts, so reopening a recording shows its text instantly.
/// Stored inside the app's sandbox container (Application Support).
enum TranscriptStore {
    static var directory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Meteora/Transcripts", isDirectory: true)
    }

    /// Key = hash of path + size + modification date: a different file with
    /// the same name never picks up someone else's transcript.
    static func key(for url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let id = "\(url.path)|\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func file(for url: URL) -> URL { directory.appendingPathComponent(key(for: url) + ".json") }

    static func load(for url: URL) -> Transcript? {
        let f = file(for: url)
        guard let data = try? Data(contentsOf: f), data.count < 64 << 20 else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Transcript.self, from: data)
    }

    static func save(_ tr: Transcript, for url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let storeKey = Self.key(for: url)
        if let data = try? enc.encode(tr) { try? data.write(to: directory.appendingPathComponent(storeKey + ".json"), options: .atomic) }
        Task { @MainActor in MeetingJournal.shared.rememberStoreKey(storeKey, for: url) }
    }
}
