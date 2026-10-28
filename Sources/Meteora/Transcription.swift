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
        if let data = try? enc.encode(tr) { try? data.write(to: file(for: url), options: .atomic) }
    }
}
