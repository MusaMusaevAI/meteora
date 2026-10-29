import Foundation
import MeteoraASR

/// One downloadable language model for meeting summaries: a GGUF file
/// pinned to an exact repository revision AND to its SHA-256 (taken from the
/// Hugging Face LFS index and cross-checked against the LFS pointer).
public struct LocalModelSpec: Sendable, Hashable {
    public var id: String
    public var displayName: String
    public var license: String
    public var repo: String
    public var revision: String
    public var fileName: String
    public var fileSize: Int64
    public var sha256: String
    /// Context the model is run with (tokens).
    public var contextTokens: Int

    public var totalSize: Int64 { fileSize }
    public var urls: [URL] {
        SummaryModel.hosts.compactMap { URL(string: "\($0)/\(repo)/resolve/\(revision)/\(fileName)") }
    }
}

/// Three sizes of the same family (Qwen3.5, Alibaba Qwen team, Apache-2.0,
/// GGUF by Unsloth): all speak Russian; bigger = better summaries, more
/// disk and memory, slower.
public enum SummaryModelTier: String, CaseIterable, Codable, Sendable, Identifiable {
    case light, medium, strong
    public var id: String { rawValue }

    public var spec: LocalModelSpec {
        switch self {
        case .light:
            return LocalModelSpec(id: "qwen3.5-0.8b-q6k", displayName: "Qwen3.5-0.8B", license: "Apache-2.0",
                                  repo: "unsloth/Qwen3.5-0.8B-GGUF", revision: "6ab461498e2023f6e3c1baea90a8f0fe38ab64d0",
                                  fileName: "Qwen3.5-0.8B-Q6_K.gguf", fileSize: 639_029_504,
                                  sha256: "8408c5c222111cec253682b49eece2a02ed641ded68490001ec4ee160e71098e",
                                  contextTokens: 16_384)
        case .medium:
            return LocalModelSpec(id: "qwen3.5-2b-q5km", displayName: "Qwen3.5-2B", license: "Apache-2.0",
                                  repo: "unsloth/Qwen3.5-2B-GGUF", revision: "f6d5376be1edb4d416d56da11e5397a961aca8ae",
                                  fileName: "Qwen3.5-2B-Q5_K_M.gguf", fileSize: 1_435_238_656,
                                  sha256: "1885b3a9195f8cc09da9a7a7a75afdc1e8d5cbf9fc4a499c3961dddea37098ac",
                                  contextTokens: 16_384)
        case .strong:
            return LocalModelSpec(id: "qwen3.5-4b-q4km", displayName: "Qwen3.5-4B", license: "Apache-2.0",
                                  repo: "unsloth/Qwen3.5-4B-GGUF", revision: "e87f176479d0855a907a41277aca2f8ee7a09523",
                                  fileName: "Qwen3.5-4B-Q4_K_M.gguf", fileSize: 2_740_937_888,
                                  sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
                                  contextTokens: LLMOptions.recommendedContextTokens)
        }
    }

    public var title: String {
        switch self {
        case .light: return "Лёгкая"
        case .medium: return "Средняя"
        case .strong: return "Сильная"
        }
    }

    public var detail: String {
        switch self {
        case .light: return "Быстро и мало места. Короткие итоги, может упускать детали."
        case .medium: return "Баланс скорости и качества для обычных встреч."
        case .strong: return "Лучшие итоги и поручения. Нужно больше памяти и времени."
        }
    }
}

public enum SummaryModel {
    /// Download hosts tried in order. Integrity comes from the hash, not the host.
    public static let hosts = ["https://huggingface.co", "https://hf-mirror.com"]
    /// The model the self-test and older code paths use.
    public static let defaultTier: SummaryModelTier = .medium

    // Compatibility with code written for a single model.
    public static var displayName: String { defaultTier.spec.displayName }
    public static var fileName: String { defaultTier.spec.fileName }
    public static var revision: String { defaultTier.spec.revision }
    public static var sha256: String { defaultTier.spec.sha256 }
    public static var totalSize: Int64 { defaultTier.spec.fileSize }
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
    public static let light = SummaryModelStore(tier: .light)
    public static let medium = SummaryModelStore(tier: .medium)
    public static let strong = SummaryModelStore(tier: .strong)
    public static var shared: SummaryModelStore { store(for: SummaryModel.defaultTier) }

    public static func store(for tier: SummaryModelTier) -> SummaryModelStore {
        switch tier {
        case .light: return light
        case .medium: return medium
        case .strong: return strong
        }
    }

    public let tier: SummaryModelTier
    public let spec: LocalModelSpec
    public let directory: URL
    private let fm = FileManager.default

    public init(tier: SummaryModelTier, directory: URL? = nil) {
        self.tier = tier
        self.spec = tier.spec
        let base = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                               appropriateFor: nil, create: true))!
            .appendingPathComponent("Meteora", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        self.directory = base.appendingPathComponent(spec.id, isDirectory: true)
    }

    private var marker: URL { directory.appendingPathComponent(".verified") }
    public var modelURL: URL { directory.appendingPathComponent(spec.fileName) }

    /// Installed = file present with the expected size and the marker
    /// written after the full hash check.
    public var isInstalled: Bool {
        guard let m = try? String(contentsOf: marker, encoding: .utf8), m == spec.sha256 else { return false }
        let size = (try? fm.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?.int64Value
        return size == spec.fileSize
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
        for url in spec.urls {
            if isCancelled() { throw ModelError.cancelled }
            do {
                let tmp = try await Downloader.download(url, expectedSize: spec.fileSize,
                                                        isCancelled: isCancelled) { got in
                    progress(min(0.99, Double(got) / Double(spec.fileSize)))
                }
                if try verifyAndPlace(tmp) {
                    progress(1)
                    return
                }
                lastError = ModelError.integrity(spec.fileName)  // try the next host
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
              (attrs[.size] as? NSNumber)?.int64Value == spec.fileSize else {
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
        guard size == spec.fileSize else {
            try? fm.removeItem(at: modelURL)
            return false
        }
        guard (try? ModelStore.sha256(of: modelURL)) == spec.sha256 else {
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
        guard size == spec.fileSize, (try? ModelStore.sha256(of: tmp)) == spec.sha256 else {
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
            try spec.sha256.write(to: marker, atomically: true, encoding: .utf8)
        } catch {
            throw ModelError.io(error.localizedDescription)
        }
    }

    private func checkDiskSpace() throws {
        let needed = spec.fileSize + 512 * 1024 * 1024
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < needed {
            throw SummaryModelError.diskSpace(needed: needed)
        }
    }
}
