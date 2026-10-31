// MeteoraConverter.xpc — converts rare media formats with FFmpeg in isolation.
//
// Isolation chain:
//   Meteora.app (sandbox, user-selected files)
//     └─ this XPC service (sandbox only: no network, no file access)
//          └─ ffmpeg (sandbox + com.apple.security.inherit → same sandbox as this service)
// The app opens the source and the destination itself and passes them as
// file descriptors; FFmpeg reads fd 0 and writes fd 1 through its `fd:`
// protocol and never opens a path.
import Darwin
import Foundation
import MeteoraConverterProtocol

// MARK: - FFmpeg log parsing

/// Parses FFmpeg's stderr (`-loglevel info` + `-progress pipe:2`).
/// Everything in it may come from an untrusted file (metadata), so it is
/// only pattern-matched and length-limited, never interpreted.
final class FFmpegLog {
    private(set) var duration: Double?
    private(set) var outTime: Double = 0
    private(set) var outputHasVideo = false
    private(set) var tail: [String] = []
    private(set) var unsupported = false
    /// FFmpeg has no decoder for one of the selected streams (e.g. AV1 video).
    private(set) var missingDecoder = false
    private var inOutputSection = false
    private var partial = Data()

    private static let missingDecoderMarkers = [
        "no decoder found",
        "decoder not found",
        "unknown decoder",
        "codec not currently supported",
    ]
    private static let unsupportedMarkers = missingDecoderMarkers + [
        "invalid data found when processing input",
        "does not contain any stream",
        "matches no streams",
    ]

    /// Feeds raw bytes; returns true when the progress value changed.
    func feed(_ data: Data) -> Bool {
        partial.append(data)
        var changed = false
        while let nl = partial.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = partial[partial.startIndex..<nl]
            partial.removeSubrange(partial.startIndex...nl)
            if lineData.isEmpty { continue }
            if handle(String(decoding: lineData, as: UTF8.self)) { changed = true }
        }
        // A pathological endless line must not grow memory without bound.
        if partial.count > 64 * 1024 { partial.removeAll(keepingCapacity: false) }
        return changed
    }

    func finish() {
        if !partial.isEmpty { _ = handle(String(decoding: partial, as: UTF8.self)) }
        partial.removeAll()
    }

    var fraction: Double {
        guard let d = duration, d > 0 else { return -1 }
        return min(1, max(0, outTime / d))
    }

    var detail: String { tail.joined(separator: "\n") }

    private func handle(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("out_time_us=") {
            if let us = Double(line.dropFirst("out_time_us=".count)), us.isFinite, us > 0 {
                outTime = us / 1_000_000
                return true
            }
            return false
        }
        // Other -progress keys and the final stats line are noise.
        if let eq = line.firstIndex(of: "="), line[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            return false
        }
        if duration == nil, line.hasPrefix("Duration: ") {
            duration = Self.parseClock(line.dropFirst("Duration: ".count).prefix(while: { $0 != "," }))
        }
        if line.hasPrefix("Output #") {
            inOutputSection = true
        } else if line.hasPrefix("Input #") || line.hasPrefix("Stream mapping:") {
            inOutputSection = false
        } else if inOutputSection, line.hasPrefix("Stream #"), line.contains(": Video:") {
            outputHasVideo = true
        }
        let lower = line.lowercased()
        if Self.unsupportedMarkers.contains(where: { lower.contains($0) }) { unsupported = true }
        if Self.missingDecoderMarkers.contains(where: { lower.contains($0) }) { missingDecoder = true }
        appendTail(line)
        return false
    }

    private func appendTail(_ line: String) {
        var scalars = String.UnicodeScalarView()
        for u in line.unicodeScalars where !CharacterSet.controlCharacters.contains(u) {
            scalars.append(u)
            if scalars.count >= 300 { break }
        }
        let clean = String(scalars)
        guard !clean.isEmpty else { return }
        tail.append(clean)
        if tail.count > 30 { tail.removeFirst(tail.count - 30) }
    }

    /// "HH:MM:SS.ss" → seconds.
    static func parseClock<S: StringProtocol>(_ s: S) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
              let sec = Double(parts[2]) else { return nil }
        let total = h * 3600 + m * 60 + sec
        return total.isFinite && total > 0 ? total : nil
    }
}

// MARK: - Conversion job (one per connection)

/// State is guarded by `lock`; FFmpeg runs on `queue`.
final class ConversionJob: NSObject, ConverterServiceProtocol, @unchecked Sendable {
    enum VideoEncoder { case videoToolbox, mpeg4 }

    private weak var connection: NSXPCConnection?
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var busy = false
    private let queue = DispatchQueue(label: "com.musamusaev.meteora.converter.job", qos: .userInitiated)

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    private var ffmpegURL: URL? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    // MARK: ConverterServiceProtocol

    func convert(_ input: FileHandle, output: FileHandle, keepVideo: Bool,
                 withReply reply: @escaping (Bool, Int, String?) -> Void) {
        lock.lock()
        if busy {
            lock.unlock()
            reply(false, ConverterResultCode.busy.rawValue, "busy")
            return
        }
        busy = true
        lock.unlock()
        // XPC delivers messages on a serial queue: return immediately so that
        // cancel() can arrive while FFmpeg runs.
        queue.async { [self] in
            let (hasVideo, code, detail) = run(input: input, output: output, keepVideo: keepVideo)
            try? input.close()
            try? output.close()
            lock.lock(); busy = false; process = nil; lock.unlock()
            reply(hasVideo, code.rawValue, detail)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate() // SIGTERM: FFmpeg stops cleanly
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    func probeIsolation(_ path: String,
                        withReply reply: @escaping (Bool, Bool, Bool, String) -> Void) {
        queue.async { [self] in
            var notes: [String] = []
            // 1. The service itself opening a user file.
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            let openErr = errno
            let serviceBlocked: Bool
            if fd >= 0 {
                close(fd); serviceBlocked = false; notes.append("service open: allowed")
            } else {
                serviceBlocked = openErr == EPERM || openErr == EACCES
                notes.append("service open: errno \(openErr) \(String(cString: strerror(openErr)))")
            }
            // 2. Network.
            let (networkBlocked, netNote) = Self.probeNetwork()
            notes.append(netNote)
            // 3. FFmpeg opening the same file by path.
            var ffmpegBlocked = false
            if let ff = ffmpegURL {
                let p = Process()
                p.executableURL = ff
                p.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", "file:" + path]
                p.environment = ["LC_ALL": "C"]
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                let err = Pipe()
                p.standardError = err
                do {
                    try p.run()
                    try? err.fileHandleForWriting.close()
                    let deadline = DispatchTime.now() + 10
                    DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
                    let out = err.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    let text = String(decoding: out.prefix(4096), as: UTF8.self)
                    ffmpegBlocked = text.contains("Operation not permitted") || text.contains("Permission denied")
                    let summary = String(text.replacingOccurrences(of: "\n", with: " | ").prefix(400))
                    notes.append("ffmpeg exit \(p.terminationStatus) reason \(p.terminationReason.rawValue): \(summary)")
                } catch {
                    notes.append("ffmpeg launch failed: \(error.localizedDescription)")
                }
            } else {
                notes.append("ffmpeg missing in service bundle")
            }
            reply(serviceBlocked, ffmpegBlocked, networkBlocked, notes.joined(separator: "\n"))
        }
    }

    private static func probeNetwork() -> (Bool, String) {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        if s < 0 {
            let e = errno
            return (e == EPERM || e == EACCES, "socket: errno \(e)")
        }
        defer { close(s) }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(443).bigEndian
        addr.sin_addr.s_addr = inet_addr("1.1.1.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r == 0 { return (false, "connect: succeeded") }
        let e = errno
        return (e == EPERM || e == EACCES, "connect: errno \(e) \(String(cString: strerror(e)))")
    }

    // MARK: Conversion

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func run(input: FileHandle, output: FileHandle, keepVideo: Bool)
        -> (Bool, ConverterResultCode, String?) {
        let inFD = input.fileDescriptor, outFD = output.fileDescriptor
        var st = stat()
        // Input: a readable regular file (seekable, so every demuxer works).
        guard fstat(inFD, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              (fcntl(inFD, F_GETFL) & O_ACCMODE) != O_WRONLY else {
            return (false, .badHandles, "input is not a readable regular file")
        }
        // Output: a regular file (plain MP4, moov written at the end by
        // seeking on the descriptor) or a pipe (fragmented MP4, no seeking).
        guard fstat(outFD, &st) == 0 else { return (false, .badHandles, "output fstat failed") }
        let kind = st.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFIFO || kind == S_IFSOCK,
              (fcntl(outFD, F_GETFL) & O_ACCMODE) != O_RDONLY else {
            return (false, .badHandles, "output is not writable")
        }
        let fragmented = kind != S_IFREG
        guard let ffmpeg = ffmpegURL else { return (false, .internalError, "ffmpeg missing in service bundle") }

        // Attempts, from best to most compatible: H.264 via VideoToolbox →
        // software MPEG-4 (VideoToolbox unavailable) → audio only (no
        // decoder for the video, e.g. AV1). A retry only happens when FFmpeg
        // failed before producing anything, and never for pipes (they can't
        // be rewound).
        var encoder = VideoEncoder.videoToolbox
        var keep = keepVideo
        while true {
            if isCancelled { return (false, .cancelled, nil) }
            lseek(inFD, 0, SEEK_SET)
            if !fragmented { ftruncate(outFD, 0); lseek(outFD, 0, SEEK_SET) }
            let args = Self.arguments(keepVideo: keep, encoder: encoder, fragmented: fragmented)
            let result = launch(ffmpeg, args: args, input: input, output: output)
            switch result {
            case .launchFailed(let message):
                return (false, .internalError, message)
            case .finished(let status, let reason, let log):
                if isCancelled { return (false, .cancelled, nil) }
                if status == 0 && reason == .exit {
                    return (keep && log.outputHasVideo, .ok, nil)
                }
                var detail = log.detail
                if reason == .uncaughtSignal { detail += "\nffmpeg terminated by signal \(status)" }
                let canRetry = keep && !fragmented && log.outTime == 0 && reason == .exit
                if canRetry && log.missingDecoder {
                    keep = false
                    continue
                }
                if canRetry && encoder == .videoToolbox && !log.unsupported {
                    encoder = .mpeg4
                    continue
                }
                return (false, log.unsupported ? .unsupported : .failed, detail)
            }
        }
    }

    private enum LaunchResult {
        case launchFailed(String)
        case finished(Int32, Process.TerminationReason, FFmpegLog)
    }

    private func launch(_ ffmpeg: URL, args: [String], input: FileHandle, output: FileHandle) -> LaunchResult {
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = args
        p.environment = ["LC_ALL": "C"]
        p.standardInput = input
        p.standardOutput = output
        let err = Pipe()
        p.standardError = err
        p.qualityOfService = .userInitiated

        lock.lock()
        if cancelled { lock.unlock(); return .launchFailed("cancelled") }
        do {
            try p.run()
        } catch {
            lock.unlock()
            return .launchFailed("ffmpeg launch failed: \(error.localizedDescription)")
        }
        process = p
        lock.unlock()
        // Our copy of the write end must be closed, or EOF never arrives.
        try? err.fileHandleForWriting.close()

        let log = FFmpegLog()
        let reader = err.fileHandleForReading
        var lastSent = -2.0
        var lastTime = Date.distantPast
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            if log.feed(chunk) {
                let f = log.fraction
                let now = Date()
                if f >= 0, f - lastSent >= 0.005 || now.timeIntervalSince(lastTime) > 0.5 {
                    lastSent = f; lastTime = now
                    report(f)
                }
            }
        }
        log.finish()
        p.waitUntilExit()
        try? reader.close()
        if p.terminationStatus == 0 { report(1) }
        return .finished(p.terminationStatus, p.terminationReason, log)
    }

    private func report(_ fraction: Double) {
        guard let c = connection else { return }
        (c.remoteObjectProxy as? ConverterClientProtocol)?.converterDidProgress(fraction)
    }

    static func arguments(keepVideo: Bool, encoder: VideoEncoder, fragmented: Bool) -> [String] {
        var a = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "info",
                 "-progress", "pipe:2",
                 // Input = the inherited descriptor 0; nothing else may be opened.
                 "-protocol_whitelist", "fd", "-i", "fd:",
                 "-map_metadata", "-1", "-map_chapters", "-1", "-sn", "-dn"]
        if keepVideo {
            // 0:V excludes cover art / attached pictures.
            a += ["-map", "0:V:0?", "-map", "0:a:0?",
                  "-vf", "bwdif=mode=send_frame:deint=interlaced,"
                      + "scale=w='min(1920,trunc(iw/2)*2)':h=-2,format=yuv420p",
                  "-fps_mode", "vfr"]
            switch encoder {
            case .videoToolbox:
                // Average 3 Mb/s. No -maxrate/-profile: VideoToolbox fails the
                // whole session if a property is unsupported (e.g. software
                // encoder in a VM), and its own defaults are fine.
                a += ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "3000k", "-g", "250"]
            case .mpeg4:
                a += ["-c:v", "mpeg4", "-q:v", "4", "-g", "250"]
            }
        } else {
            a += ["-vn", "-map", "0:a:0"]
        }
        a += ["-c:a", "aac", "-b:a", "160k",
              "-af", "aformat=sample_rates=48000|44100|32000|24000|22050|16000|12000|11025|8000"
                  + ":channel_layouts=mono|stereo",
              "-f", "mp4"]
        if fragmented { a += ["-movflags", "+frag_keyframe+empty_moov+default_base_moof"] }
        // Hard limits against "bomb" files: at most 48 h of media, 20 GB of output.
        a += ["-t", "172800", "-fs", "21474836480"]
        a += ["fd:"]
        return a
    }
}

// MARK: - Listener

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let job = ConversionJob(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: ConverterServiceProtocol.self)
        connection.exportedObject = job
        connection.remoteObjectInterface = NSXPCInterface(with: ConverterClientProtocol.self)
        // The app went away (quit, crash, invalidated): stop FFmpeg.
        // Only Meteora itself may talk to the converter (the service is
        // private to the app bundle anyway; this is a second lock).
        connection.setCodeSigningRequirement("identifier \"com.musamusaev.meteora\"")
        connection.invalidationHandler = { job.cancel() }
        connection.interruptionHandler = { job.cancel() }
        connection.resume()
        return true
    }
}

signal(SIGPIPE, SIG_IGN)
let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume() // never returns
