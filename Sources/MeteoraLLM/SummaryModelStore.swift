import Foundation
import MeteoraASR

/// The language model used for meeting summaries.
///
/// Qwen3.5-4B (Alibaba Qwen team, Apache-2.0), GGUF Q4_K_M quantization by
/// Unsloth. Chosen for Russian quality at 4B parameters and for its hybrid
/// attention (Gated DeltaNet + 1 attention layer in 4): long contexts need
/// only a small cache, so 16–32k tokens fit next to the weights on an 8 GB
/// Mac. Pinned to an exact repository revision AND to the file's SHA-256
/// (taken from the Hugging Face LFS index; the revision's git object id of
/// the LFS pointer was cross-checked against this hash and size).
public enum SummaryModel {
    public static let id = "qwen3.5-4b-q4km"
    public static let displayName = "Qwen3.5-4B"
    public static let license = "Apache-2.0"
    public static let repo = "unsloth/Qwen3.5-4B-GGUF"
    public static let revision = "e87f176479d0855a907a41277aca2f8ee7a09523"
    public static let fileName = "Qwen3.5-4B-Q4_K_M.gguf"
    public static let fileSize: Int64 = 2_740_937_888
    public static let sha256 = "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4"
    /// Download hosts tried in order. Integrity comes from the hash, not the host.
    public static let hosts = ["https://huggingface.co", "https://hf-mirror.com"]

    public static var totalSize: Int64 { fileSize }

    public static var urls: [URL] {
        hosts.compactMap { URL(string: "\($0)/\(repo)/resolve/\(revision)/\(fileName)") }
    }
}

public enum SummaryModelError: Error, LocalizedError {
    case notInstalled
    case diskSpace(needed: Int64)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "Модель для резюме встреч не загружена."
        case .diskSpace(let n):
            return "Недостаточно места на диске: для модели нужно \(ByteCountFormatter.string(fromByteCount: n, countStyle: .file))."
        }
    }
}

/// Where the summary model lives and how it gets there. Same rules as the
/// speech model: HTTPS only, size-capped download, SHA-256 verified before
/// the file is ever opened by llama.cpp, fail closed.
public final class SummaryModelStore: @unchecked Sendable {
    public static let shared = SummaryModelStore()

    public let directory: URL
    private let fm = FileManager.default

    public init(directory: URL? = nil) {
        let base = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                               appropriateFor: nil, create: true))!
            .appendingPathComponent("Meteora", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        self.directory = base.appendingPathComponent(SummaryModel.id, isDirectory: true)
    }

    private var marker: URL { directory.appendingPathComponent(".verified") }
    public var modelURL: URL { directory.appendingPathComponent(SummaryModel.fileName) }

    /// Installed = file present with the expected size and the marker
    /// written after the full hash check.
    public var isInstalled: Bool {
        guard let m = try? String(contentsOf: marker, encoding: .utf8), m == SummaryModel.sha256 else { return false }
        let size = (try? fm.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?.int64Value
        return size == SummaryModel.fileSize
    }

    public var installedBytes: Int64 { ModelStore.directorySize(directory) }

    public func remove() throws {
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
    }

    /// Downloads the model if needed, verifies it, marks it installed. Safe to
    /// call again after a failure or cancellation (a verified file is kept).
    public func install(progress: @escaping @Sendable (Double) -> Void,
                        isCancelled: @escaping @Sendable () -> Bool) async throws {
        try prepare()
        if try adoptExistingFile() { progress(1); return }
        try checkDiskSpace()
        var lastError: Error = ModelError.network("нет доступа к серверам")
        for url in SummaryModel.urls {
            if isCancelled() { throw ModelError.cancelled }
            do {
                let tmp = try await Downloader.download(url, expectedSize: SummaryModel.fileSize,
                                                        isCancelled: isCancelled) { got in
                    progress(min(0.99, Double(got) / Double(SummaryModel.fileSize)))
                }
                if try verifyAndPlace(tmp) {
                    progress(1)
                    return
                }
                lastError = ModelError.integrity(SummaryModel.fileName)  // try the next host
            } catch ModelError.cancelled {
                throw ModelError.cancelled
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Installs from a file the user (or CI) already downloaded, e.g. with a
    /// browser. The file is copied (never moved or modified), and the COPY is
    /// hash-checked before it is accepted, so a file changed during the copy
    /// can't slip through.
    public func installFromLocalFile(_ source: URL) throws {
        try prepare()
        if try adoptExistingFile() { return }
        let attrs = try fm.attributesOfItem(atPath: source.path)
        guard (attrs[.type] as? FileAttributeType) == .typeRegular,
              (attrs[.size] as? NSNumber)?.int64Value == SummaryModel.fileSize else {
            throw ModelError.integrity(source.lastPathComponent)
        }
        try checkDiskSpace()
        let tmp = directory.appendingPathComponent(".incoming-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: source, to: tmp)  // APFS clone when on the same volume
        } catch {
            try? fm.removeItem(at: tmp)
            throw ModelError.io(error.localizedDescription)
        }
        guard try verifyAndPlace(tmp) else { throw ModelError.integrity(source.lastPathComponent) }
    }

    // MARK: Internals

    private func prepare() throws {
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ModelError.io(error.localizedDescription)
        }
        try? fm.removeItem(at: marker)
    }

    /// A complete file from an earlier, interrupted install: accept it only
    /// after a full hash check.
    private func adoptExistingFile() throws -> Bool {
        let size = (try? fm.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?.int64Value
        guard size == SummaryModel.fileSize else {
            try? fm.removeItem(at: modelURL)
            return false
        }
        guard (try? ModelStore.sha256(of: modelURL)) == SummaryModel.sha256 else {
            try? fm.removeItem(at: modelURL)
            return false
        }
        try writeMarker()
        return true
    }

    /// Hash-checks `tmp`; on success moves it into place and marks the model
    /// installed. A mismatching file is deleted.
    private func verifyAndPlace(_ tmp: URL) throws -> Bool {
        let size = (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value
        guard size == SummaryModel.fileSize, (try? ModelStore.sha256(of: tmp)) == SummaryModel.sha256 else {
            try? fm.removeItem(at: tmp)
            return false
        }
        do {
            try? fm.removeItem(at: modelURL)
            try fm.moveItem(at: tmp, to: modelURL)
        } catch {
            try? fm.removeItem(at: tmp)
            throw ModelError.io(error.localizedDescription)
        }
        try writeMarker()
        return true
    }

    private func writeMarker() throws {
        do {
            try SummaryModel.sha256.write(to: marker, atomically: true, encoding: .utf8)
        } catch {
            throw ModelError.io(error.localizedDescription)
        }
    }

    private func checkDiskSpace() throws {
        let needed = SummaryModel.fileSize + 512 * 1024 * 1024
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < needed {
            throw SummaryModelError.diskSpace(needed: needed)
        }
    }
}
