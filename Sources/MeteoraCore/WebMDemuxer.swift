import Foundation

// MARK: - Public model

public struct VideoTrackInfo: Equatable, Sendable {
    public var codecID: String
    public var width: Int
    public var height: Int

    public init(codecID: String, width: Int, height: Int) {
        self.codecID = codecID
        self.width = width
        self.height = height
    }

    /// Codec string for WebCodecs' VideoDecoder, if supported.
    public var webCodecsCodec: String? {
        switch codecID {
        case "V_VP8": return "vp8"
        case "V_VP9": return "vp09.00.10.08"
        case "V_AV1": return "av01.0.08M.08"
        default: return nil
        }
    }

    public var codecName: String {
        switch codecID {
        case "V_VP8": return "VP8"
        case "V_VP9": return "VP9"
        case "V_AV1": return "AV1"
        case "V_MPEG4/ISO/AVC", "avc1", "avc3": return "H.264"
        case "V_MPEGH/ISO/HEVC", "hvc1", "hev1": return "H.265"
        case "mp4v": return "MPEG-4"
        case "ap4h", "ap4x", "apch", "apcn", "apcs", "apco": return "ProRes"
        case "jpeg": return "Motion JPEG"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        default: return codecID.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }
}

public struct AudioTrackInfo: Equatable, Sendable {
    public var codecID: String
    public var sampleRate: Double
    public var channels: Int
    public var codecPrivate: Data
    public var codecDelayNs: UInt64

    public init(codecID: String, sampleRate: Double, channels: Int, codecPrivate: Data = Data(), codecDelayNs: UInt64 = 0) {
        self.codecID = codecID
        self.sampleRate = sampleRate
        self.channels = channels
        self.codecPrivate = codecPrivate
        self.codecDelayNs = codecDelayNs
    }

    public var codecName: String {
        switch codecID {
        case "A_OPUS": return "Opus"
        case "A_VORBIS": return "Vorbis"
        case "A_AAC": return "AAC"
        case "A_PCM/INT/LIT", "lpcm": return "PCM"
        case "mp4a", "aac ": return "AAC"
        case ".mp3", "mp3 ": return "MP3"
        case "alac": return "ALAC"
        case "flac", "fLaC": return "FLAC"
        case "ac-3": return "AC-3"
        case "ec-3": return "E-AC-3"
        case "opus": return "Opus"
        case "samr", "sawb": return "AMR"
        case "ima4": return "IMA ADPCM"
        case "ulaw", "alaw": return "G.711"
        default: return codecID.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }
}

/// One video frame in the stream index (payload stays in the file).
public struct VideoPacket: Equatable, Sendable {
    public var time: Double      // seconds from start of the recording
    public var size: Int         // compressed size in bytes
    public var isKey: Bool
    public var offset: UInt64    // payload position in the file

    public init(time: Double, size: Int, isKey: Bool, offset: UInt64 = 0) {
        self.time = time
        self.size = size
        self.isKey = isKey
        self.offset = offset
    }
}

struct BlockRef {
    var timeNs: Int64
    var payloadOffset: UInt64
    var payloadSize: Int
    var lacing: UInt8
}

public struct MediaInfo: Sendable {
    public var url: URL
    public var fileSize: UInt64
    public var duration: Double
    public var video: VideoTrackInfo?
    public var audio: AudioTrackInfo?
    public var writingApp: String?
    public var hasCues: Bool
    public var videoPackets: [VideoPacket]
    public var audioPacketCount: Int
    public var isAudioOnly: Bool { video == nil && audio != nil }

    public init(url: URL, fileSize: UInt64, duration: Double, video: VideoTrackInfo?, audio: AudioTrackInfo?,
                writingApp: String? = nil, hasCues: Bool = false, videoPackets: [VideoPacket] = [], audioPacketCount: Int = 0) {
        self.url = url
        self.fileSize = fileSize
        self.duration = duration
        self.video = video
        self.audio = audio
        self.writingApp = writingApp
        self.hasCues = hasCues
        self.videoPackets = videoPackets
        self.audioPacketCount = audioPacketCount
    }
}

// MARK: - Demuxer

/// A strict, defensive WebM (Matroska subset) parser.
///
/// The parser treats the file as hostile input:
/// - all lengths are validated against the parent element and the file size;
/// - nesting depth and the number of indexed packets are capped;
/// - string fields are length-limited and decoded leniently;
/// - nothing in the file can make the parser allocate more than
///   `ByteSource.maxReadSize` at once.
public final class WebMDemuxer {
    // Element IDs (with length marker bits, as in the spec)
    enum ID {
        static let ebml: UInt32 = 0x1A45DFA3
        static let docType: UInt32 = 0x4282
        static let segment: UInt32 = 0x18538067
        static let seekHead: UInt32 = 0x114D9B74
        static let info: UInt32 = 0x1549A966
        static let timecodeScale: UInt32 = 0x2AD7B1
        static let duration: UInt32 = 0x4489
        static let writingApp: UInt32 = 0x5741
        static let tracks: UInt32 = 0x1654AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86
        static let codecPrivate: UInt32 = 0x63A2
        static let codecDelay: UInt32 = 0x56AA
        static let video: UInt32 = 0xE0
        static let pixelWidth: UInt32 = 0xB0
        static let pixelHeight: UInt32 = 0xBA
        static let audio: UInt32 = 0xE1
        static let samplingFrequency: UInt32 = 0xB5
        static let channels: UInt32 = 0x9F
        static let cluster: UInt32 = 0x1F43B675
        static let timecode: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let referenceBlock: UInt32 = 0xFB
        static let cues: UInt32 = 0x1C53BB6B
        static let tags: UInt32 = 0x1254C367
        static let chapters: UInt32 = 0x1043A770
        static let attachments: UInt32 = 0x1941A469
        static let void: UInt32 = 0xEC

        static let topLevel: Set<UInt32> = [seekHead, info, tracks, cluster, cues, tags, chapters, attachments]
    }

    static let maxPackets = 8_000_000
    static let maxTracks = 64
    static let maxDuration: Double = 48 * 3600
    /// Accepted block timestamps: from −1 hour to +48 hours.
    static let timeWindowNs: ClosedRange<Int64> = (-3_600_000_000_000) ... 172_800_000_000_000
    static let maxStringLength = 4096
    static let maxCodecPrivate = 64 * 1024

    struct Header {
        var id: UInt32
        var headerSize: Int
        var dataOffset: UInt64
        var size: UInt64?          // nil = unknown size
    }

    struct Track {
        var number: UInt64 = 0
        var type: UInt64 = 0
        var codecID = ""
        var codecPrivate = Data()
        var codecDelay: UInt64 = 0
        var width = 0
        var height = 0
        var sampleRate = 8000.0
        var channels = 1
    }

    let src: ByteSource
    private(set) var timecodeScale: UInt64 = 1_000_000
    private(set) var declaredDurationTicks: Double?
    private(set) var writingApp: String?
    private(set) var tracks: [Track] = []
    private(set) var hasCues = false
    private(set) var videoBlocks: [VideoPacket] = []
    private(set) var audioBlocks: [BlockRef] = []
    private var videoTrack: Track?
    private var audioTrack: Track?
    private var firstTimeNs: Int64?
    private var lastTimeNs: Int64 = 0

    public init(url: URL) throws {
        self.src = try ByteSource(url: url)
    }

    // MARK: Public entry points

    /// Parses headers and builds a packet index of the whole file.
    public static func analyze(url: URL,
                               progress: ((Double) -> Void)? = nil,
                               isCancelled: (() -> Bool)? = nil) throws -> (MediaInfo, WebMDemuxer) {
        let d = try WebMDemuxer(url: url)
        let info = try d.parse(progress: progress, isCancelled: isCancelled)
        return (info, d)
    }

    func parse(progress: ((Double) -> Void)?, isCancelled: (() -> Bool)?) throws -> MediaInfo {
        // EBML header
        let h0 = try readHeader(at: 0, limit: src.size)
        guard h0.id == ID.ebml, let h0size = h0.size, h0size < 4096 else { throw MediaError.notWebM }
        var docType = ""
        try forEachChild(of: h0, depth: 1) { h in
            if h.id == ID.docType { docType = try readString(h) }
        }
        guard docType == "webm" || docType == "matroska" else { throw MediaError.notWebM }

        // Segment
        let segOffset = h0.dataOffset + h0size
        let seg = try readHeader(at: segOffset, limit: src.size)
        guard seg.id == ID.segment else { throw MediaError.notWebM }
        let segEnd = seg.size.map { min(src.size, seg.dataOffset &+ $0) } ?? src.size

        var pos = seg.dataOffset
        var lastReport = Date.distantPast
        while pos < segEnd {
            if isCancelled?() == true { throw MediaError.cancelled }
            let h: Header
            do { h = try readHeader(at: pos, limit: segEnd) } catch MediaError.truncated { break }
            switch h.id {
            case ID.info:
                try parseInfo(h)
            case ID.tracks:
                try parseTracks(h)
            case ID.cues:
                hasCues = true
            case ID.cluster:
                pos = try parseCluster(h, segmentEnd: segEnd)
                if let progress, Date().timeIntervalSince(lastReport) > 0.1 {
                    lastReport = Date()
                    progress(Double(pos) / Double(max(1, segEnd)))
                }
                continue
            default:
                break
            }
            guard let size = h.size else {
                // Unknown size is only legal for Segment/Cluster.
                throw MediaError.malformed("элемент неизвестной длины")
            }
            let (next, overflow) = h.dataOffset.addingReportingOverflow(size)
            if overflow || next <= pos { throw MediaError.malformed("неверная длина элемента") }
            pos = next
        }
        progress?(1)

        guard videoTrack != nil || audioTrack != nil else { throw MediaError.malformed("нет дорожек") }

        // Differences in Double: Int64 subtraction could overflow on hostile input.
        let span = (Double(lastTimeNs) - Double(firstTimeNs ?? 0)) / 1e9
        let durationFromPackets = min(max(0, span), Self.maxDuration)
        var duration = durationFromPackets
        if let ticks = declaredDurationTicks, ticks.isFinite, ticks > 0 {
            let d = ticks * Double(timecodeScale) / 1e9
            if d.isFinite, d > 0, d < Self.maxDuration { duration = max(d, durationFromPackets) }
        }

        let v = videoTrack.map { VideoTrackInfo(codecID: $0.codecID, width: $0.width, height: $0.height) }
        let a = audioTrack.map {
            AudioTrackInfo(codecID: $0.codecID, sampleRate: $0.sampleRate, channels: $0.channels,
                           codecPrivate: $0.codecPrivate, codecDelayNs: $0.codecDelay)
        }
        return MediaInfo(url: src.url, fileSize: src.size, duration: duration, video: v, audio: a,
                         writingApp: writingApp, hasCues: hasCues, videoPackets: videoBlocks,
                         audioPacketCount: audioBlocks.count)
    }

    // MARK: Audio access

    /// Iterates the audio packets in file order, splitting laced blocks.
    /// `time` is seconds relative to the first packet of the file.
    public func forEachAudioPacket(isCancelled: (() -> Bool)? = nil,
                                   _ body: (_ time: Double, _ packet: Data) throws -> Void) throws {
        let origin = firstTimeNs ?? 0
        var n = 0
        for b in audioBlocks {
            n += 1
            if n & 1023 == 0, isCancelled?() == true { throw MediaError.cancelled }
            let payload = try src.read(at: b.payloadOffset, count: b.payloadSize)
            let t = (Double(b.timeNs) - Double(origin)) / 1e9
            if b.lacing == 0 {
                try body(t, payload)
            } else {
                for frame in try Self.splitLacing(payload, lacing: b.lacing) {
                    try body(t, frame)
                }
            }
        }
    }

    public var audioPacketCount: Int { audioBlocks.count }

    /// Compressed bytes of one video frame (≤ 16 MB).
    public func videoPayload(_ p: VideoPacket) throws -> Data {
        guard p.size >= 0, p.size <= 16 * 1024 * 1024 else { throw MediaError.malformed("слишком большой кадр") }
        return try src.read(at: p.offset, count: p.size)
    }

    /// Time span covered by the indexed packets, seconds (bounded).
    public var packetSpan: Double {
        min(Self.maxDuration, max(0, (Double(lastTimeNs) - Double(firstTimeNs ?? 0)) / 1e9))
    }

    // MARK: Element parsing

    private func parseInfo(_ h: Header) throws {
        try forEachChild(of: h, depth: 2) { c in
            switch c.id {
            case ID.timecodeScale:
                let v = try readUInt(c)
                guard v > 0, v <= 1_000_000_000 else { throw MediaError.malformed("неверный масштаб времени") }
                timecodeScale = v
            case ID.duration:
                declaredDurationTicks = try readFloat(c)
            case ID.writingApp:
                writingApp = try readString(c)
            default: break
            }
        }
    }

    private func parseTracks(_ h: Header) throws {
        try forEachChild(of: h, depth: 2) { c in
            guard c.id == ID.trackEntry else { return }
            var t = Track()
            try forEachChild(of: c, depth: 3) { e in
                switch e.id {
                case ID.trackNumber: t.number = try readUInt(e)
                case ID.trackType: t.type = try readUInt(e)
                case ID.codecID: t.codecID = try readString(e)
                case ID.codecPrivate:
                    guard let s = e.size, s <= UInt64(Self.maxCodecPrivate) else { throw MediaError.malformed("слишком большие параметры кодека") }
                    t.codecPrivate = try src.read(at: e.dataOffset, count: Int(s))
                case ID.codecDelay: t.codecDelay = try readUInt(e)
                case ID.video:
                    try forEachChild(of: e, depth: 4) { v in
                        if v.id == ID.pixelWidth { t.width = try Int(clamping: readUInt(v)) }
                        if v.id == ID.pixelHeight { t.height = try Int(clamping: readUInt(v)) }
                    }
                case ID.audio:
                    try forEachChild(of: e, depth: 4) { a in
                        if a.id == ID.samplingFrequency { t.sampleRate = try readFloat(a) }
                        if a.id == ID.channels { t.channels = try Int(clamping: readUInt(a)) }
                    }
                default: break
                }
            }
            guard t.number > 0 else { return }
            guard tracks.count < Self.maxTracks else { throw MediaError.malformed("слишком много дорожек") }
            tracks.append(t)
            if t.type == 1, videoTrack == nil {
                guard (1...16384).contains(t.width), (1...16384).contains(t.height) else {
                    throw MediaError.malformed("неверный размер кадра")
                }
                videoTrack = t
            }
            if t.type == 2, audioTrack == nil {
                guard t.sampleRate.isFinite, (1000...384_000).contains(t.sampleRate), (1...8).contains(t.channels) else {
                    throw MediaError.malformed("неверные параметры звука")
                }
                audioTrack = t
            }
        }
    }

    /// Parses one cluster and returns the offset right after it.
    private func parseCluster(_ h: Header, segmentEnd: UInt64) throws -> UInt64 {
        let end = h.size.map { min(segmentEnd, h.dataOffset &+ $0) } ?? segmentEnd
        var clusterTime: Int64 = 0
        var pos = h.dataOffset
        while pos < end {
            let c: Header
            do { c = try readHeader(at: pos, limit: end) } catch MediaError.truncated { return end }
            // A level-1 element terminates an unknown-size cluster.
            if h.size == nil, ID.topLevel.contains(c.id) || c.id == ID.segment { return pos }
            guard let size = c.size else { throw MediaError.malformed("блок неизвестной длины") }
            let (next, overflow) = c.dataOffset.addingReportingOverflow(size)
            guard !overflow else { throw MediaError.malformed("неверная длина блока") }
            if next > src.size { return src.size } // truncated tail: keep what we have
            guard next <= end || h.size == nil else { throw MediaError.malformed("блок выходит за границы кластера") }

            switch c.id {
            case ID.timecode:
                clusterTime = try Int64(clamping: readUInt(c))
            case ID.simpleBlock:
                try indexBlock(offset: c.dataOffset, size: size, clusterTime: clusterTime, simple: true, hasReference: false)
            case ID.blockGroup:
                var blockOffset: UInt64?
                var blockSize: UInt64 = 0
                var hasRef = false
                try forEachChild(of: c, depth: 4) { g in
                    if g.id == ID.block, let s = g.size { blockOffset = g.dataOffset; blockSize = s }
                    if g.id == ID.referenceBlock { hasRef = true }
                }
                if let bo = blockOffset {
                    try indexBlock(offset: bo, size: blockSize, clusterTime: clusterTime, simple: false, hasReference: hasRef)
                }
            default:
                break
            }
            pos = next
        }
        return end
    }

    private func indexBlock(offset: UInt64, size: UInt64, clusterTime: Int64, simple: Bool, hasReference: Bool) throws {
        guard size >= 4, size <= UInt64(ByteSource.maxReadSize) else { throw MediaError.malformed("неверный размер блока") }
        let head = try src.read(at: offset, count: Int(min(size, 12)))
        let (track, tlen) = try Self.readVint(head, at: 0)
        guard let track, tlen + 3 <= head.count else { throw MediaError.malformed("неверный заголовок блока") }
        let rel = Int16(bitPattern: UInt16(head[tlen]) << 8 | UInt16(head[tlen + 1]))
        let flags = head[tlen + 2]
        let headerLen = tlen + 3
        let payloadSize = Int(size) - headerLen
        guard payloadSize >= 0 else { throw MediaError.malformed("пустой блок") }

        let (ticks, o1) = clusterTime.addingReportingOverflow(Int64(rel))
        let (ns, o2) = ticks.multipliedReportingOverflow(by: Int64(timecodeScale))
        // Blocks with absurd timestamps are skipped, not trusted.
        guard !o1, !o2, Self.timeWindowNs.contains(ns) else { return }

        let isVideo = videoTrack.map { track == $0.number } ?? false
        let isAudio = audioTrack.map { track == $0.number } ?? false
        guard isVideo || isAudio else { return }
        if firstTimeNs == nil || ns < firstTimeNs! { firstTimeNs = ns }
        if ns > lastTimeNs { lastTimeNs = ns }

        guard videoBlocks.count + audioBlocks.count < Self.maxPackets else { throw MediaError.malformed("слишком много пакетов") }

        if isVideo {
            let key = simple ? (flags & 0x80) != 0 : !hasReference
            guard (flags >> 1) & 0x03 == 0 else { return } // laced video is not used by real encoders
            videoBlocks.append(VideoPacket(time: Double(ns) / 1e9, size: payloadSize, isKey: key,
                                           offset: offset + UInt64(headerLen)))
        } else {
            audioBlocks.append(BlockRef(timeNs: ns, payloadOffset: offset + UInt64(headerLen),
                                        payloadSize: payloadSize, lacing: (flags >> 1) & 0x03))
        }
    }

    // MARK: Low-level EBML

    /// Reads an element header at `offset`. `limit` bounds the header itself.
    func readHeader(at offset: UInt64, limit: UInt64) throws -> Header {
        guard offset < limit else { throw MediaError.truncated }
        let avail = Int(min(12, limit - offset))
        let bytes = try src.read(at: offset, count: avail)
        guard let first = bytes.first, first != 0 else { throw MediaError.malformed("неверный идентификатор элемента") }
        let idLen = first.leadingZeroBitCount + 1
        guard idLen <= 4, idLen < bytes.count else { throw MediaError.malformed("неверный идентификатор элемента") }
        var id: UInt32 = 0
        for i in 0 ..< idLen { id = id << 8 | UInt32(bytes[i]) }
        let (size, sizeLen) = try Self.readVint(bytes, at: idLen)
        let headerSize = idLen + sizeLen
        return Header(id: id, headerSize: headerSize, dataOffset: offset + UInt64(headerSize), size: size)
    }

    /// Reads a variable-length integer. Returns nil value for the
    /// reserved "unknown" pattern (all value bits set).
    static func readVint(_ d: Data, at i: Int) throws -> (UInt64?, Int) {
        guard i < d.count else { throw MediaError.truncated }
        let first = d[i]
        guard first != 0 else { throw MediaError.malformed("неверное число переменной длины") }
        let len = first.leadingZeroBitCount + 1
        guard i + len <= d.count else { throw MediaError.truncated }
        var value = UInt64(first & (0xFF >> len))
        var allOnes = value == UInt64(0xFF >> len)
        for k in 1 ..< len {
            let b = d[i + k]
            value = value << 8 | UInt64(b)
            if b != 0xFF { allOnes = false }
        }
        return (allOnes ? nil : value, len)
    }

    private func forEachChild(of parent: Header, depth: Int, _ body: (Header) throws -> Void) throws {
        guard depth <= 8 else { throw MediaError.malformed("слишком глубокая вложенность") }
        guard let psize = parent.size else { throw MediaError.malformed("элемент неизвестной длины") }
        let (end, overflow) = parent.dataOffset.addingReportingOverflow(psize)
        guard !overflow, end <= src.size else { throw MediaError.truncated }
        var pos = parent.dataOffset
        while pos < end {
            let h = try readHeader(at: pos, limit: end)
            guard let size = h.size else { throw MediaError.malformed("элемент неизвестной длины") }
            let (next, o2) = h.dataOffset.addingReportingOverflow(size)
            guard !o2, next <= end else { throw MediaError.malformed("элемент выходит за границы родителя") }
            try body(h)
            pos = next
        }
    }

    private func readUInt(_ h: Header) throws -> UInt64 {
        guard let s = h.size, s <= 8 else { throw MediaError.malformed("неверное целое") }
        let d = try src.read(at: h.dataOffset, count: Int(s))
        return d.reduce(0) { $0 << 8 | UInt64($1) }
    }

    private func readFloat(_ h: Header) throws -> Double {
        guard let s = h.size else { throw MediaError.malformed("неверное число") }
        let d = try src.read(at: h.dataOffset, count: Int(min(s, 8)))
        let bits = d.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        switch s {
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case 8: return Double(bitPattern: bits)
        case 0: return 0
        default: throw MediaError.malformed("неверное число")
        }
    }

    private func readString(_ h: Header) throws -> String {
        guard let s = h.size else { throw MediaError.malformed("неверная строка") }
        let d = try src.read(at: h.dataOffset, count: Int(min(s, UInt64(Self.maxStringLength))))
        let trimmed = d.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    // MARK: Lacing

    static func splitLacing(_ d: Data, lacing: UInt8) throws -> [Data] {
        guard !d.isEmpty else { throw MediaError.malformed("пустой блок") }
        let count = Int(d[0]) + 1
        var pos = 1
        var sizes: [Int] = []
        sizes.reserveCapacity(count)
        switch lacing {
        case 1: // Xiph
            for _ in 0 ..< count - 1 {
                var s = 0
                while true {
                    guard pos < d.count else { throw MediaError.truncated }
                    let b = Int(d[pos]); pos += 1
                    s += b
                    if b != 255 { break }
                }
                sizes.append(s)
            }
        case 3: // EBML
            if count > 1 {
                let (first, l1) = try readVint(d, at: pos)
                guard let first else { throw MediaError.malformed("неверная укладка") }
                pos += l1
                var prev = Int64(clamping: first)
                sizes.append(Int(clamping: prev))
                for _ in 0 ..< (count - 2) {
                    let (raw, l) = try readVint(d, at: pos)
                    guard let raw else { throw MediaError.malformed("неверная укладка") }
                    pos += l
                    let bias = (Int64(1) << (7 * Int64(l) - 1)) - 1
                    prev += Int64(clamping: raw) - bias
                    guard prev >= 0, prev <= Int64(d.count) else { throw MediaError.malformed("неверная укладка") }
                    sizes.append(Int(prev))
                }
            }
        case 2: // fixed
            let remaining = d.count - pos
            guard remaining % count == 0 else { throw MediaError.malformed("неверная укладка") }
            sizes = Array(repeating: remaining / count, count: count - 1)
        default:
            return [d]
        }
        let used = sizes.reduce(0, +)
        let last = d.count - pos - used
        guard last >= 0 else { throw MediaError.malformed("неверная укладка") }
        sizes.append(last)
        var frames: [Data] = []
        for s in sizes {
            guard pos + s <= d.count else { throw MediaError.truncated }
            frames.append(d.subdata(in: pos ..< pos + s))
            pos += s
        }
        return frames
    }
}
