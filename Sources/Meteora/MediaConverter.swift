import AVFoundation
import Darwin
import Foundation
import MeteoraConverterProtocol

/// Errors of the rare-format converter. Messages are shown to the user.
enum MediaConverterError: LocalizedError {
    case cannotOpenInput
    case notARegularFile
    case cannotCreateOutput
    case serviceUnavailable
    case serviceCrashed
    case unsupportedFormat(detail: String?)
    case conversionFailed(detail: String?)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .cannotOpenInput: return "Не удалось открыть файл. Проверьте, что он на месте и доступен."
        case .notARegularFile: return "Это не обычный файл с записью."
        case .cannotCreateOutput: return "Не удалось создать временный файл для преобразования. Проверьте свободное место на диске."
        case .serviceUnavailable: return "Модуль преобразования форматов недоступен. Переустановите Meteora."
        case .serviceCrashed: return "Модуль преобразования форматов неожиданно завершился. Возможно, файл повреждён."
        case .unsupportedFormat: return "Формат или кодек этой записи не поддерживается."
        case .conversionFailed: return "Не удалось преобразовать запись. Возможно, файл повреждён."
        case .emptyOutput: return "Преобразование не дало звука или видео. Возможно, файл повреждён."
        }
    }

    /// Technical FFmpeg log tail for diagnostics (never shown in UI).
    var debugDetail: String? {
        switch self {
        case .unsupportedFormat(let d), .conversionFailed(let d): return d
        default: return nil
        }
    }
}

/// Converts formats AVFoundation can't open (MKV, AVI, WMV, OGG, …) into
/// MP4/M4A using FFmpeg in the isolated XPC service
/// `com.musamusaev.meteora.converter`. The service and FFmpeg run in their
/// own sandbox without network or file access: this class opens the source
/// and creates the destination, and passes only the two file descriptors.
final class MediaConverter: @unchecked Sendable {
    init() {}

    /// Formats AVFoundation opens itself (WebM has its own parser).
    static let nativeExtensions: [String] = [
        "mp4", "mov", "m4v", "m4a", "m4b", "mp3", "wav", "wave", "aif", "aiff", "aifc",
        "caf", "aac", "adts", "flac", "ac3", "eac3", "ec3", "3gp", "3g2", "au", "snd", "webm",
    ]
    /// Formats converted through the isolated FFmpeg service.
    static let convertedExtensions: [String] = [
        "mkv", "mka", "avi", "wmv", "wma", "asf", "flv", "mpeg", "mpg", "mpe", "m1v", "m2v",
        "vob", "ts", "mts", "m2ts", "m2t", "ogv", "ogg", "oga", "opus", "amr", "3ga", "w64",
    ]
    /// Everything Meteora accepts (open panels, drag & drop): lowercase, no dots.
    static let supportedExtensions: [String] = nativeExtensions + convertedExtensions

    /// True when the file must go through `convert` before AVFoundation can
    /// play it. Decided by AVFoundation itself; the extension list is only a
    /// fallback when the asset can't be inspected at all.
    static func needsConversion(_ url: URL) async -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "webm" { return false } // own WebM path
        // Formats only FFmpeg reads go straight to the isolated service, and so
        // does anything that is really Matroska/WebM under another extension:
        // the system parser never sees them.
        if convertedExtensions.contains(ext) || isEBML(url) { return true }
        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isPlayable)
            guard playable else { return true }
            let tracks = try await asset.load(.tracks)
            var hasPlayableAudio = false, hasVideo = false, hasPlayableVideo = false
            for track in tracks {
                let isPlayable = (try? await track.load(.isPlayable)) ?? false
                switch track.mediaType {
                case .audio: if isPlayable { hasPlayableAudio = true }
                case .video:
                    hasVideo = true
                    if isPlayable { hasPlayableVideo = true }
                default: break
                }
            }
            if hasVideo && !hasPlayableVideo { return true }
            return !(hasPlayableAudio || hasPlayableVideo)
        } catch {
            return !nativeExtensions.contains(ext)
        }
    }

    /// Matroska/WebM signature (1A 45 DF A3) at the start of the file.
    static func isEBML(_ url: URL) -> Bool {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        var b = [UInt8](repeating: 0, count: 4)
        return Darwin.read(fd, &b, 4) == 4 && b == [0x1A, 0x45, 0xDF, 0xA3]
    }

    /// Converts `url` into a new file in the app's temporary directory
    /// (`meteora-converted-<UUID>.mp4`, or `.m4a` when the result has no
    /// video). The caller owns (and should eventually delete) that file.
    /// `progress` gets 0…1 (from a background queue). Throws
    /// `CancellationError` when `isCancelled` returns true or the task is
    /// cancelled; otherwise `MediaConverterError`.
    func convert(_ url: URL, keepVideo: Bool,
                 progress: @escaping @Sendable (Double) -> Void,
                 isCancelled: @escaping @Sendable () -> Bool) async throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Open without following FIFOs/devices into a hang, then check the type
        // on the descriptor itself.
        let inFD = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard inFD >= 0 else { throw MediaConverterError.cannotOpenInput }
        var st = stat()
        guard fstat(inFD, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(inFD)
            throw MediaConverterError.notARegularFile
        }
        _ = fcntl(inFD, F_SETFL, fcntl(inFD, F_GETFL) & ~O_NONBLOCK)
        let input = FileHandle(fileDescriptor: inFD, closeOnDealloc: true)

        let tmp = FileManager.default.temporaryDirectory
        let base = "meteora-converted-\(UUID().uuidString)"
        let mp4URL = tmp.appendingPathComponent(base + ".mp4")
        let outFD = open(mp4URL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard outFD >= 0 else {
            try? input.close()
            throw MediaConverterError.cannotCreateOutput
        }
        let output = FileHandle(fileDescriptor: outFD, closeOnDealloc: true)

        var succeeded = false
        defer {
            try? input.close()
            try? output.close()
            if !succeeded { try? FileManager.default.removeItem(at: mp4URL) }
        }

        let hasVideo = try await runService(input: input, output: output, keepVideo: keepVideo,
                                            progress: progress, isCancelled: isCancelled)
        try? output.close()

        let size = (try? FileManager.default.attributesOfItem(atPath: mp4URL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw MediaConverterError.emptyOutput }
        var result = mp4URL
        if !hasVideo {
            let m4aURL = tmp.appendingPathComponent(base + ".m4a")
            do {
                try FileManager.default.moveItem(at: mp4URL, to: m4aURL)
                result = m4aURL
            } catch {
                result = mp4URL // still a valid MPEG-4 audio file
            }
        }
        succeeded = true
        return result
    }

    // MARK: - XPC

    /// Receives progress from the service (on an XPC queue).
    private final class ProgressReceiver: NSObject, ConverterClientProtocol {
        let handler: @Sendable (Double) -> Void
        init(_ handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }
        func converterDidProgress(_ fraction: Double) {
            if fraction.isFinite, fraction >= 0 { handler(min(1, fraction)) }
        }
    }

    /// Resumes a continuation exactly once, whichever event comes first
    /// (reply, connection error, cancellation).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Error>?
        init(_ c: CheckedContinuation<Bool, Error>) { continuation = c }
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return continuation == nil }
        func resume(_ result: Result<Bool, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
        }
    }

    /// Returns whether the output has video.
    private func runService(input: FileHandle, output: FileHandle, keepVideo: Bool,
                            progress: @escaping @Sendable (Double) -> Void,
                            isCancelled: @escaping @Sendable () -> Bool) async throws -> Bool {
        if isCancelled() || Task.isCancelled { throw CancellationError() }
        let connection = NSXPCConnection(serviceName: meteoraConverterServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ConverterServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: ConverterClientProtocol.self)
        connection.exportedObject = ProgressReceiver(progress)
        connection.resume()
        defer { connection.invalidate() }

        let cancelRequested = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                let once = Once(continuation)
                connection.interruptionHandler = {
                    once.resume(.failure(cancelRequested.isSet ? CancellationError() as Error : MediaConverterError.serviceCrashed))
                }
                connection.invalidationHandler = {
                    once.resume(.failure(cancelRequested.isSet ? CancellationError() as Error : MediaConverterError.serviceUnavailable))
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    let nsError = error as NSError
                    let failure: Error
                    if cancelRequested.isSet {
                        failure = CancellationError()
                    } else if nsError.domain == NSCocoaErrorDomain,
                              nsError.code == NSXPCConnectionInterrupted {
                        failure = MediaConverterError.serviceCrashed
                    } else {
                        failure = MediaConverterError.serviceUnavailable
                    }
                    once.resume(.failure(failure))
                } as? ConverterServiceProtocol
                guard let proxy else {
                    once.resume(.failure(MediaConverterError.serviceUnavailable))
                    return
                }
                proxy.convert(input, output: output, keepVideo: keepVideo) { hasVideo, code, detail in
                    switch ConverterResultCode(rawValue: code) {
                    case .ok?: once.resume(.success(hasVideo))
                    case .cancelled?: once.resume(.failure(CancellationError()))
                    case .unsupported?: once.resume(.failure(MediaConverterError.unsupportedFormat(detail: detail)))
                    case .badHandles?: once.resume(.failure(MediaConverterError.notARegularFile))
                    case .internalError?: once.resume(.failure(MediaConverterError.serviceUnavailable))
                    default: once.resume(.failure(MediaConverterError.conversionFailed(detail: detail)))
                    }
                }
                // Poll the caller's cancellation flag while FFmpeg runs.
                func poll() {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        if once.isDone { return }
                        if isCancelled() || cancelRequested.isSet {
                            cancelRequested.set()
                            proxy.cancel()
                            // If the service doesn't answer, give up after 5 s.
                            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                                once.resume(.failure(CancellationError()))
                            }
                            return
                        }
                        poll()
                    }
                }
                poll()
            }
        } onCancel: {
            cancelRequested.set()
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    // ===================================================================
    // MARK: - Self-test (CI only)
    // Called from SelfTest.swift when the app is started with
    // `--convert-fixtures <dir>`. Converts every fixture in `fixtures`
    // through the XPC service, verifies the results with AVFoundation, checks
    // cancellation and the sandbox isolation, copies outputs to `output`.
    // ===================================================================

    static func runSelfTest(fixtures: URL, output: URL) async -> [String: Any] {
        var report: [String: Any] = [:]
        var errors: [String] = []
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? [])
            .filter { convertedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if files.isEmpty { errors.append("no fixtures in \(fixtures.path)") }
        let audioOnlyExtensions: Set<String> = ["ogg", "oga", "opus", "mka", "wma", "amr", "3ga", "w64"]
        let converter = MediaConverter()
        var results: [String: Any] = [:]

        for file in files {
            let name = file.lastPathComponent
            var entry: [String: Any] = [:]
            let needs = await needsConversion(file)
            // Recorded, not asserted: a future macOS may open some of these natively.
            entry["needsConversion"] = needs
            let progressBox = ProgressBox()
            let t0 = Date()
            do {
                let out = try await converter.convert(file, keepVideo: true,
                                                      progress: { progressBox.set($0) },
                                                      isCancelled: { false })
                entry["seconds"] = Date().timeIntervalSince(t0)
                entry["output"] = out.lastPathComponent
                entry["lastProgress"] = progressBox.value
                entry["bytes"] = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.intValue ?? 0
                let asset = AVURLAsset(url: out)
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.load(.tracks)
                let audio = tracks.filter { $0.mediaType == .audio }
                let video = tracks.filter { $0.mediaType == .video }
                entry["duration"] = duration.isFinite ? duration : -1 // report.json can't hold NaN
                entry["audioTracks"] = audio.count
                entry["videoTracks"] = video.count
                if let v = video.first {
                    let size = try await v.load(.naturalSize)
                    entry["videoSize"] = "\(Int(size.width))x\(Int(size.height))"
                    let formats = try await v.load(.formatDescriptions)
                    entry["videoCodec"] = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
                }
                entry["playable"] = try await asset.load(.isPlayable)
                let expectVideo = !audioOnlyExtensions.contains(file.pathExtension.lowercased())
                var ok = true
                if !(abs(duration - 3) < 0.5) { ok = false; errors.append("\(name): duration \(duration)") }
                if audio.count != 1 { ok = false; errors.append("\(name): audio tracks \(audio.count)") }
                if expectVideo != !video.isEmpty { ok = false; errors.append("\(name): video tracks \(video.count)") }
                if out.pathExtension != (expectVideo ? "mp4" : "m4a") {
                    ok = false; errors.append("\(name): extension \(out.pathExtension)")
                }
                if !out.lastPathComponent.hasPrefix("meteora-converted-") {
                    ok = false; errors.append("\(name): name \(out.lastPathComponent)")
                }
                entry["ok"] = ok
                let dest = output.appendingPathComponent("\(name).\(out.pathExtension)")
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: out, to: dest)
                try? FileManager.default.removeItem(at: out)
            } catch {
                entry["ok"] = false
                entry["error"] = error.localizedDescription
                if let e = error as? MediaConverterError, let d = e.debugDetail { entry["detail"] = d }
                errors.append("\(name): \(error.localizedDescription)")
            }
            results[name] = entry
        }
        report["files"] = results

        // Cancellation: before start, and while FFmpeg runs (cancel at the
        // first progress report). Must throw CancellationError and leave no
        // temporary file. A tiny fixture may finish before the cancel lands;
        // that is recorded, not treated as an error.
        if let first = files.first {
            let before = tempOutputs()
            var cancel: [String: Any] = [:]
            do {
                _ = try await converter.convert(first, keepVideo: true, progress: { _ in }, isCancelled: { true })
                errors.append("cancel: not cancelled before start")
                cancel["beforeStart"] = "not cancelled"
            } catch is CancellationError {
                cancel["beforeStart"] = "ok"
            } catch {
                cancel["beforeStart"] = "error: \(error.localizedDescription)"
                errors.append("cancel before start: \(error.localizedDescription)")
            }
            let seen = ProgressBox()
            do {
                let out = try await converter.convert(first, keepVideo: true, progress: { seen.set($0) },
                                                      isCancelled: { seen.value > 0 })
                try? FileManager.default.removeItem(at: out)
                cancel["running"] = "finished before the cancel arrived"
            } catch is CancellationError {
                cancel["running"] = "ok"
            } catch {
                cancel["running"] = "error: \(error.localizedDescription)"
                errors.append("cancel while running: \(error.localizedDescription)")
            }
            let leftovers = tempOutputs().subtracting(before)
            cancel["leftovers"] = leftovers.sorted()
            if !leftovers.isEmpty { errors.append("cancel: temporary files left") }
            report["cancel"] = cancel
        }

        // Isolation: neither the service nor FFmpeg may open a user file or the network.
        if let first = files.first {
            let isolation = await probeIsolation(path: first.path)
            report["isolation"] = isolation
            if isolation["serviceFileBlocked"] as? Bool != true { errors.append("isolation: service can open user files") }
            if isolation["ffmpegFileBlocked"] as? Bool != true { errors.append("isolation: ffmpeg can open user files") }
            if isolation["networkBlocked"] as? Bool != true { errors.append("isolation: network is reachable") }
        }

        report["errors"] = errors
        report["ok"] = errors.isEmpty
        return report
    }

    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var v = 0.0
        var value: Double { lock.lock(); defer { lock.unlock() }; return v }
        func set(_ x: Double) { lock.lock(); v = x; lock.unlock() }
    }

    /// `fire()` returns true exactly once.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    private static func tempOutputs() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("meteora-converted-") })
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func probeIsolation(path: String) async -> [String: Any] {
        let connection = NSXPCConnection(serviceName: meteoraConverterServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ConverterServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any], Never>) in
            let latch = Latch()
            func finish(_ value: [String: Any]) {
                if latch.fire() { continuation.resume(returning: value) }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                finish(["error": error.localizedDescription])
            } as? ConverterServiceProtocol
            guard let proxy else { return finish(["error": "no proxy"]) }
            proxy.probeIsolation(path) { serviceBlocked, ffmpegBlocked, networkBlocked, detail in
                finish(["serviceFileBlocked": serviceBlocked, "ffmpegFileBlocked": ffmpegBlocked,
                        "networkBlocked": networkBlocked, "detail": detail])
            }
        }
    }
    // ===================================================================
    // MARK: - End of self-test
    // ===================================================================
}
