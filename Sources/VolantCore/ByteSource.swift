import Foundation

/// Read-only, bounds-checked random access to a file.
///
/// Security notes:
/// - The file is never mapped into memory (a file on a removable/network
///   volume that disappears would otherwise crash the app with SIGBUS).
/// - Every read is bounds-checked against the file size; a single read is
///   capped at `maxReadSize` so a malformed length field can never make us
///   allocate gigabytes.
public final class ByteSource {
    public static let maxReadSize = 64 * 1024 * 1024
    private static let chunkSize = 1 << 20

    public let url: URL
    public let size: UInt64
    private let handle: FileHandle
    private var buffer = Data()
    private var bufferStart: UInt64 = 0
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        // Open first, then check what we actually opened (fstat) — so a file
        // swapped for a FIFO/device between check and open can't block us.
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { throw MediaError.io(String(cString: strerror(errno))) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw MediaError.notARegularFile
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.size = UInt64(max(0, st.st_size))
    }


    /// Returns exactly `count` bytes starting at `offset` (as a fresh,
    /// zero-indexed `Data`), or throws `.truncated`.
    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, count <= ByteSource.maxReadSize else { throw MediaError.malformed("слишком большой блок данных") }
        if count == 0 { return Data() }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(count))
        guard !overflow, end <= size else { throw MediaError.truncated }

        lock.lock(); defer { lock.unlock() }
        let bufferEnd = bufferStart + UInt64(buffer.count)
        if offset >= bufferStart, end <= bufferEnd {
            let lo = Int(offset - bufferStart)
            return buffer.subdata(in: lo ..< lo + count)
        }
        if count >= ByteSource.chunkSize {
            return try rawRead(at: offset, count: count)
        }
        let want = Int(min(UInt64(ByteSource.chunkSize), size - offset))
        buffer = try rawRead(at: offset, count: want)
        bufferStart = offset
        return buffer.subdata(in: 0 ..< count)
    }

    /// Reads up to `count` bytes (fewer at end of file). Used by the media
    /// scheme handler that streams byte ranges to the player.
    public func readUpTo(at offset: UInt64, count: Int) throws -> Data {
        guard offset < size else { return Data() }
        let n = Int(min(UInt64(max(0, min(count, ByteSource.maxReadSize))), size - offset))
        return try read(at: offset, count: n)
    }

    private func rawRead(at offset: UInt64, count: Int) throws -> Data {
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw MediaError.truncated
            }
            return data
        } catch let error as MediaError {
            throw error
        } catch {
            throw MediaError.io(error.localizedDescription)
        }
    }
}

public enum MediaError: Error, LocalizedError, Equatable {
    case notARegularFile
    case notWebM
    case truncated
    case malformed(String)
    case io(String)
    case noAudio
    case noVideo
    case unsupportedAudioCodec(String)
    case audioDecoderUnavailable
    case cancelled
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notARegularFile: return "Это не файл записи."
        case .notWebM: return "Файл не похож на запись WebM."
        case .truncated: return "Файл обрезан или повреждён — часть данных отсутствует."
        case .malformed(let s): return "Файл повреждён: \(s)."
        case .io(let s): return "Не удалось прочитать файл: \(s)"
        case .noAudio: return "В записи нет звуковой дорожки."
        case .noVideo: return "В записи нет видео."
        case .unsupportedAudioCodec(let c): return "Звук в формате \(c) пока не поддерживается."
        case .audioDecoderUnavailable: return "На этом Mac недоступен декодер Opus."
        case .cancelled: return "Отменено."
        case .exportFailed(let s): return "Не удалось сохранить: \(s)"
        }
    }
}

/// Minimal, strict parser for a single HTTP byte range, used by the
/// in-app media server.
public enum HTTPRange {
    /// - Returns: `nil` if the header is invalid/unsatisfiable (→ 416),
    ///   `.some(nil)` if there is no header (→ whole file),
    ///   `.some(range)` otherwise.
    public static func parse(_ header: String?, size: UInt64) -> ClosedRange<UInt64>?? {
        guard let header else { return .some(nil) }
        let h = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard h.hasPrefix("bytes="), size > 0, h.count <= 64 else { return nil }
        let spec = h.dropFirst(6)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let a = spec[..<dash], b = spec[spec.index(after: dash)...]
        if a.isEmpty {
            guard let n = UInt64(b), n > 0 else { return nil }
            return .some(size - min(n, size) ... size - 1)
        }
        guard let start = UInt64(a), start < size else { return nil }
        if b.isEmpty { return .some(start ... size - 1) }
        guard let end = UInt64(b), end >= start else { return nil }
        return .some(start ... min(end, size - 1))
    }
}
