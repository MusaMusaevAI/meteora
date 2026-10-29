import Foundation
import CryptoKit

/// One file of the speech model with its pinned SHA-256.
public struct ModelFile: Sendable {
    public var name: String
    public var size: Int64
    public var sha256: String
}

/// GigaAM-v3 end-to-end RNN-T (Sber, MIT license), exported to ONNX by the
/// sherpa-onnx authors. Produces punctuated, normalised Russian text.
/// Every file is verified against the SHA-256 pinned below before use, so a
/// tampered mirror or a man-in-the-middle cannot slip in a different model.
public enum SpeechModel {
    public static let id = "gigaam-v3-e2e-rnnt"
    public static let displayName = "GigaAM-v3"
    public static let repo = "csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16"
    /// Download hosts tried in order. Integrity is guaranteed by the hashes,
    /// not by the host.
    public static let hosts = ["https://huggingface.co", "https://hf-mirror.com"]

    public static let files: [ModelFile] = [
        ModelFile(name: "encoder.int8.onnx", size: 224_570_820,
                  sha256: "369f35a71bf288d3b8e0391fabd8dba5f2314088d440bca474056b7b4b6e66bf"),
        ModelFile(name: "decoder.onnx", size: 4_600_132,
                  sha256: "38fc7475443ea2a26f63211ca350f73ac50fff824ab7a3876ee2bd610c53bbc4"),
        ModelFile(name: "joiner.onnx", size: 2_712_896,
                  sha256: "602ff7017a93311aad34df1437c8d7f49911353c13d6eae7a6ee7b041339465c"),
        ModelFile(name: "tokens.txt", size: 13_354,
                  sha256: tokensSHA256),
    ]

    public static var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    static func urls(for file: ModelFile) -> [URL] {
        hosts.compactMap { URL(string: "\($0)/\(repo)/resolve/main/\(file.name)") }
    }
}

public enum ModelError: Error, LocalizedError {
    case network(String)
    case integrity(String)
    case notInstalled
    case cancelled
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .network(let s): return "Не удалось скачать модель: \(s)"
        case .integrity(let f): return "Файл модели \(f) не прошёл проверку контрольной суммы и был удалён."
        case .notInstalled: return "Модель распознавания речи не загружена."
        case .cancelled: return "Загрузка отменена."
        case .io(let s): return "Ошибка записи модели: \(s)"
        }
    }
}

/// Where the model lives and how it gets there.
public final class ModelStore: @unchecked Sendable {
    public static let shared = ModelStore()

    public let directory: URL
    private let fm = FileManager.default

    public init(directory: URL? = nil) {
        let base = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                               appropriateFor: nil, create: true))!
            .appendingPathComponent("Meteora", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        self.directory = base.appendingPathComponent(SpeechModel.id, isDirectory: true)
    }

    private var marker: URL { directory.appendingPathComponent(".verified") }

    public func path(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Installed = every file present with the expected size and the
    /// verification marker written after the full hash check.
    public var isInstalled: Bool {
        guard let m = try? String(contentsOf: marker, encoding: .utf8), m == Self.markerContents else { return false }
        for f in SpeechModel.files {
            let size = (try? fm.attributesOfItem(atPath: path(f.name).path)[.size] as? NSNumber)?.int64Value
            if size != f.size { return false }
        }
        return true
    }

    static var markerContents: String { SpeechModel.files.map(\.sha256).joined(separator: "\n") }

    public var installedBytes: Int64 { Self.directorySize(directory) }

    public func remove() throws {
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
    }

    /// Downloads missing files, verifies every hash, then marks the model
    /// as installed. Safe to call again after a failure or cancellation.
    public func install(progress: @escaping @Sendable (Double) -> Void,
                        isCancelled: @escaping @Sendable () -> Bool) async throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.removeItem(at: marker)
        let total = Double(SpeechModel.totalSize)
        var done: Int64 = 0
        for file in SpeechModel.files {
            let dest = path(file.name)
            if (try? Self.sha256(of: dest)) == file.sha256 {
                done += file.size
                progress(Double(done) / total)
                continue
            }
            try? fm.removeItem(at: dest)
            var lastError: Error = ModelError.network("нет доступа к серверам")
            var ok = false
            for url in SpeechModel.urls(for: file) {
                if isCancelled() { throw ModelError.cancelled }
                do {
                    let base = done
                    let tmp = try await Downloader.download(url, expectedSize: file.size, isCancelled: isCancelled) { got in
                        progress(Double(base + got) / total)
                    }
                    guard try Self.sha256(of: tmp) == file.sha256 else {
                        try? fm.removeItem(at: tmp)
                        lastError = ModelError.integrity(file.name)
                        continue // try the next host
                    }
                    try fm.moveItem(at: tmp, to: dest)
                    ok = true
                    break
                } catch ModelError.cancelled {
                    throw ModelError.cancelled
                } catch {
                    lastError = error
                }
            }
            guard ok else { throw lastError }
            done += file.size
            progress(Double(done) / total)
        }
        do {
            try Self.markerContents.write(to: marker, atomically: true, encoding: .utf8)
        } catch {
            throw ModelError.io(error.localizedDescription)
        }
    }

    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

/// HTTPS-only downloader with progress and cancellation. Public so the
/// summary model (MeteoraLLM) uses exactly the same hardened code path.
public enum Downloader {
    final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: (Int64) -> Void
        let isCancelled: () -> Bool
        let maxBytes: Int64
        var continuation: CheckedContinuation<URL, Error>?
        private let lock = NSLock()

        init(maxBytes: Int64, progress: @escaping (Int64) -> Void, isCancelled: @escaping () -> Bool) {
            self.maxBytes = maxBytes
            self.progress = progress
            self.isCancelled = isCancelled
        }

        private func finish(_ r: Result<URL, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: r)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if isCancelled() || totalBytesWritten > maxBytes { downloadTask.cancel(); return }
            progress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                finish(.failure(ModelError.network("сервер ответил \(http.statusCode)")))
                return
            }
            // The system deletes `location` when this method returns: move it now.
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent("meteora-model-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: keep)
                finish(.success(keep))
            } catch {
                finish(.failure(ModelError.io(error.localizedDescription)))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            if isCancelled() { finish(.failure(ModelError.cancelled)); return }
            finish(.failure(ModelError.network(error.localizedDescription)))
        }

        /// Follow redirects only to HTTPS (Hugging Face serves files from a CDN).
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
        }
    }

    public static func download(_ url: URL, expectedSize: Int64, isCancelled: @escaping () -> Bool,
                                progress: @escaping (Int64) -> Void) async throws -> URL {
        guard url.scheme == "https" else { throw ModelError.network("только HTTPS") }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        // At least an hour; large files get as long as ~200 KB/s needs.
        cfg.timeoutIntervalForResource = max(3600, Double(expectedSize) / 200_000)
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        let delegate = Delegate(maxBytes: expectedSize + 1024, progress: progress, isCancelled: isCancelled)
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.setValue("Meteora (macOS)", forHTTPHeaderField: "User-Agent")
        return try await withCheckedThrowingContinuation { cont in
            delegate.continuation = cont
            session.downloadTask(with: req).resume()
        }
    }
}
