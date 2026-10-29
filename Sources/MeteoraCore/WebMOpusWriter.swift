import Foundation

/// A minimal Matroska/WebM muxer for exactly one Opus audio track — what
/// Meteora's recorder writes.
///
/// Layout (the same as Chrome's MediaRecorder output, plus an index):
///
///     EBML header (DocType "webm")
///     Segment (size patched at finish)
///       Void → SeekHead (written into the reserved space at finish)
///       Info   (TimecodeScale 1 ms, Duration patched at finish)
///       Tracks (A_OPUS, OpusHead CodecPrivate, CodecDelay, SeekPreRoll)
///       Cluster, Cluster, …   (SimpleBlocks, ≤ `clusterDurationMs` each)
///       Cues   (one CuePoint per cluster)
///
/// The file is written incrementally: each finished cluster goes straight to
/// disk, the Segment starts with "unknown size". If the app crashes, the file
/// is still a valid live-stream style WebM up to the last full cluster
/// (WebMDemuxer and browsers read those). `finish()` writes the Cues and
/// seeks back to patch the Segment size, Duration and SeekHead.
///
/// Not thread-safe: use it from one serial queue.
public final class WebMOpusWriter {
    public enum WriterError: Error, LocalizedError, Equatable {
        case alreadyFinished
        case invalidParameters
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyFinished: return "Запись уже завершена."
            case .invalidParameters: return "Неверные параметры звука."
            case .io(let s): return "Не удалось записать файл: \(s)"
            }
        }
    }

    public let url: URL
    public let channels: Int
    /// Opus always decodes at 48 kHz; timestamps are counted in these samples.
    public let sampleRate: Int = 48_000
    /// Samples the decoder discards at the start (encoder look-ahead).
    public let preSkip: Int

    /// Longest cluster, ms. Short clusters bound what a crash can lose.
    public var clusterDurationMs: Int64 = 2_000

    public private(set) var packetCount = 0
    public private(set) var totalSamples: Int64 = 0
    public private(set) var bytesWritten: UInt64 = 0
    public var duration: Double { Double(totalSamples) / Double(sampleRate) }

    private let handle: FileHandle
    private var finished = false

    // Offsets for the patches at finish (absolute file positions).
    private var segmentSizeOffset: UInt64 = 0
    private var segmentDataOffset: UInt64 = 0
    private var seekHeadOffset: UInt64 = 0
    private var infoOffset: UInt64 = 0
    private var tracksOffset: UInt64 = 0
    private var durationOffset: UInt64 = 0

    // The cluster being filled, kept in memory until it is complete.
    private var cluster = Data()
    private var clusterOpen = false
    private var clusterStartMs: Int64 = 0
    private var cues: [(timeMs: Int64, position: UInt64)] = []

    static let seekHeadReserve = 96
    static let trackNumber: UInt8 = 1

    /// Creates (or truncates) the file and writes the headers.
    /// - Parameters:
    ///   - channels: 1 or 2.
    ///   - preSkip: encoder delay in 48 kHz samples (libopus: 312).
    public init(url: URL, channels: Int = 1, preSkip: Int = 312, writingApp: String = "Meteora") throws {
        guard (1 ... 2).contains(channels), (0 ... 65535).contains(preSkip) else { throw WriterError.invalidParameters }
        self.url = url
        self.channels = channels
        self.preSkip = preSkip
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw WriterError.io("нет доступа к «\(url.deletingLastPathComponent().lastPathComponent)»")
        }
        do { handle = try FileHandle(forWritingTo: url) } catch { throw WriterError.io(error.localizedDescription) }
        try writeHeaders(writingApp: writingApp)
    }

    deinit {
        if !finished { try? handle.close() }
    }

    // MARK: Writing

    /// Appends one Opus packet. `samples` is its duration in 48 kHz samples
    /// (960 for 20 ms). An empty packet only advances the clock (a gap the
    /// decoder fills with silence).
    public func append(_ packet: Data, samples: Int) throws {
        guard !finished else { throw WriterError.alreadyFinished }
        guard samples > 0, packet.count < 1 << 20 else { throw WriterError.invalidParameters }
        defer { totalSamples += Int64(samples) }
        guard !packet.isEmpty else { return }

        let t = totalSamples * 1000 / Int64(sampleRate)
        if !clusterOpen || t - clusterStartMs >= clusterDurationMs || t - clusterStartMs > Int64(Int16.max) {
            try flushCluster()
            clusterOpen = true
            clusterStartMs = t
            cluster = Self.uint(0xE7, UInt64(t)) // Cluster Timecode
        }
        let rel = Int16(t - clusterStartMs)
        var block = Data([0x80 | Self.trackNumber, UInt8(truncatingIfNeeded: UInt16(bitPattern: rel) >> 8),
                          UInt8(truncatingIfNeeded: UInt16(bitPattern: rel)), 0x80]) // keyframe
        block.append(packet)
        cluster.append(Self.element(0xA3, block)) // SimpleBlock
        packetCount += 1
    }

    /// Writes the pending cluster to disk (for example when recording pauses).
    public func flush() throws {
        guard !finished else { return }
        try flushCluster()
    }

    /// Writes the index and patches the sizes. The writer can't be used after.
    public func finish() throws {
        guard !finished else { throw WriterError.alreadyFinished }
        try flushCluster()
        finished = true
        defer { try? handle.close() }

        // Cues: one point per cluster.
        var cuesPosition: UInt64?
        if !cues.isEmpty {
            var points = Data()
            for c in cues {
                let positions = Self.uint(0xF7, UInt64(Self.trackNumber)) + Self.uint(0xF1, c.position)
                points.append(Self.element(0xBB, Self.uint(0xB3, UInt64(max(0, c.timeMs))) + Self.element(0xB7, positions)))
            }
            cuesPosition = bytesWritten - segmentDataOffset
            try write(Self.element(0x1C53BB6B, points))
        }

        // SeekHead into the reserved Void at the start of the segment.
        var seeks = Data()
        func seek(_ id: UInt32, _ position: UInt64) {
            seeks.append(Self.element(0x4DBB, Self.element(0x53AB, Self.idBytes(id)) + Self.uint(0x53AC, position)))
        }
        seek(0x1549A966, infoOffset - segmentDataOffset)
        seek(0x1654AE6B, tracksOffset - segmentDataOffset)
        if let cuesPosition { seek(0x1C53BB6B, cuesPosition) }
        let seekHead = Self.element(0x114D9B74, seeks)
        let rest = Self.seekHeadReserve - seekHead.count
        if rest == 0 || rest >= 2 {
            try patch(at: seekHeadOffset, seekHead + (rest > 0 ? Self.void(totalSize: rest) : Data()))
        } // else: keep the Void — the file is valid without a SeekHead.

        // Duration (ms, float64) and the Segment size.
        try patch(at: durationOffset, Self.float64Bytes(Double(totalSamples) * 1000 / Double(sampleRate)))
        try patch(at: segmentSizeOffset, Self.vint8(bytesWritten - segmentDataOffset))
        do { try handle.synchronize() } catch { /* data is written; fsync is best effort */ }
    }

    // MARK: Internals

    private func writeHeaders(writingApp: String) throws {
        var out = Data()
        // EBML header
        out.append(Self.element(0x1A45DFA3,
                                Self.uint(0x4286, 1) + Self.uint(0x42F7, 1) + Self.uint(0x42F2, 4) + Self.uint(0x42F3, 8)
                                    + Self.string(0x4282, "webm") + Self.uint(0x4287, 4) + Self.uint(0x4285, 2)))
        // Segment with "unknown" size: valid as is if we never get to finish().
        out.append(Self.idBytes(0x18538067))
        segmentSizeOffset = UInt64(out.count)
        out.append(contentsOf: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        segmentDataOffset = UInt64(out.count)

        // Space for the SeekHead.
        seekHeadOffset = UInt64(out.count)
        out.append(Self.void(totalSize: Self.seekHeadReserve))

        // Info
        var info = Self.uint(0x2AD7B1, 1_000_000) // TimecodeScale: 1 ms
        info.append(Self.string(0x4D80, "Meteora")) // MuxingApp
        info.append(Self.string(0x5741, writingApp)) // WritingApp
        // DateUTC: nanoseconds since 2001-01-01, which is Foundation's reference date.
        let ns = Int64(Date().timeIntervalSinceReferenceDate * 1e9)
        info.append(Self.idBytes(0x4461) + Self.sizeVint(8) + Self.bigEndian(UInt64(bitPattern: ns), bytes: 8))
        let durationInInfo = info.count + 3 // 2-byte ID + 1-byte size
        info.append(Self.element(0x4489, Self.float64Bytes(0)))
        infoOffset = UInt64(out.count)
        let infoHeader = Self.idBytes(0x1549A966) + Self.sizeVint(UInt64(info.count))
        durationOffset = infoOffset + UInt64(infoHeader.count + durationInInfo)
        out.append(infoHeader + info)

        // Tracks
        let uid = UInt64.random(in: 1 ... UInt64(Int64.max))
        var audio = Self.float(0xB5, Double(sampleRate))
        audio.append(Self.uint(0x9F, UInt64(channels)))
        var entry = Self.uint(0xD7, UInt64(Self.trackNumber))
        entry.append(Self.uint(0x73C5, uid))
        entry.append(Self.uint(0x83, 2)) // audio
        entry.append(Self.uint(0x9C, 0)) // no lacing
        entry.append(Self.string(0x86, "A_OPUS"))
        entry.append(Self.element(0x63A2, Self.opusHead(channels: channels, preSkip: preSkip, inputRate: sampleRate)))
        entry.append(Self.uint(0x56AA, UInt64(preSkip) * 1_000_000_000 / UInt64(sampleRate))) // CodecDelay, ns
        entry.append(Self.uint(0x56BB, 80_000_000)) // SeekPreRoll: 80 ms, as the spec recommends
        entry.append(Self.element(0xE1, audio))
        tracksOffset = UInt64(out.count)
        out.append(Self.element(0x1654AE6B, Self.element(0xAE, entry)))

        try write(out)
    }

    private func flushCluster() throws {
        guard clusterOpen else { return }
        clusterOpen = false
        cues.append((timeMs: clusterStartMs, position: bytesWritten - segmentDataOffset))
        let data = Self.element(0x1F43B675, cluster)
        cluster = Data()
        try write(data)
    }

    private func write(_ data: Data) throws {
        do { try handle.write(contentsOf: data) } catch { throw WriterError.io(error.localizedDescription) }
        bytesWritten += UInt64(data.count)
    }

    private func patch(at offset: UInt64, _ data: Data) throws {
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
            _ = try handle.seekToEnd()
        } catch {
            throw WriterError.io(error.localizedDescription)
        }
    }

    // MARK: EBML encoding

    /// Element ID bytes (IDs already carry their length marker).
    static func idBytes(_ id: UInt32) -> Data {
        let n = id > 0xFF_FFFF ? 4 : id > 0xFFFF ? 3 : id > 0xFF ? 2 : 1
        return bigEndian(UInt64(id), bytes: n)
    }

    /// Shortest EBML size. The all-ones pattern of each length is reserved
    /// for "unknown", so a length holds at most 2^(7·n) − 2.
    static func sizeVint(_ value: UInt64) -> Data {
        var n = 1
        while n < 8, value > (UInt64(1) << (7 * UInt64(n))) - 2 { n += 1 }
        let marked = value | (UInt64(1) << (7 * UInt64(n)))
        return bigEndian(marked, bytes: n)
    }

    /// An 8-byte EBML size (fixed width, for values patched later).
    static func vint8(_ value: UInt64) -> Data {
        bigEndian((value & 0x00FF_FFFF_FFFF_FFFF) | 0x0100_0000_0000_0000, bytes: 8)
    }

    static func element(_ id: UInt32, _ payload: Data) -> Data {
        idBytes(id) + sizeVint(UInt64(payload.count)) + payload
    }

    static func uint(_ id: UInt32, _ value: UInt64) -> Data {
        var n = 1
        while n < 8, value >> (8 * UInt64(n)) != 0 { n += 1 }
        return element(id, bigEndian(value, bytes: n))
    }

    static func float(_ id: UInt32, _ value: Double) -> Data {
        element(id, float64Bytes(value))
    }

    static func string(_ id: UInt32, _ value: String) -> Data {
        element(id, Data(value.utf8))
    }

    static func float64Bytes(_ value: Double) -> Data {
        bigEndian(value.bitPattern, bytes: 8)
    }

    /// A Void element of exactly `totalSize` bytes (≥ 2).
    static func void(totalSize: Int) -> Data {
        precondition(totalSize >= 2)
        if totalSize - 2 <= 126 {
            return Data([0xEC, 0x80 | UInt8(totalSize - 2)]) + Data(count: totalSize - 2)
        }
        return Data([0xEC]) + vint8(UInt64(totalSize - 9)) + Data(count: totalSize - 9)
    }

    static func bigEndian(_ value: UInt64, bytes n: Int) -> Data {
        var d = Data(count: n)
        for i in 0 ..< n { d[i] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(n - 1 - i))) }
        return d
    }

    /// RFC 7845 identification header, channel mapping family 0.
    static func opusHead(channels: Int, preSkip: Int, inputRate: Int) -> Data {
        var d = Data("OpusHead".utf8)
        d.append(1) // version
        d.append(UInt8(channels))
        d.append(UInt8(preSkip & 0xFF)); d.append(UInt8((preSkip >> 8) & 0xFF))
        for i in 0 ..< 4 { d.append(UInt8((inputRate >> (8 * i)) & 0xFF)) }
        d.append(contentsOf: [0, 0]) // output gain
        d.append(0) // mapping family
        return d
    }
}
