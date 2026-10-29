import Foundation
import AVFoundation
import AudioToolbox
import MeteoraCore

/// Where mixed audio goes: 20 ms frames of 48 kHz mono Float32.
/// All calls arrive on the recorder's processing queue.
protocol RecordingSink: AnyObject {
    var url: URL { get }
    /// Human-readable format for logs and the self-test.
    var formatName: String { get }
    func append(_ frame: UnsafeBufferPointer<Float>) throws
    /// Puts everything buffered so far on disk (on pause).
    func flush()
    func finish() throws
}

enum RecordingFormat {
    static let sampleRate: Double = 48_000
    static let frameSize = 960 // 20 ms
    /// The pipeline's internal format: 48 kHz mono Float32.
    static let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
}

// MARK: - Opus in WebM (the normal path)

/// Encodes with the system Opus encoder (AudioToolbox) — 48 kHz mono,
/// 20 ms packets, ~48 kbit/s, about 22 MB per hour — and muxes into WebM.
final class OpusWebMSink: RecordingSink {
    let url: URL
    let formatName: String
    private let converter: AVAudioConverter
    private let pcm: AVAudioPCMBuffer
    private let packets: AVAudioCompressedBuffer
    private let writer: WebMOpusWriter

    /// Whether this Mac can encode Opus. Checked once.
    static let isEncoderAvailable: Bool = makeEncoder(bitRate: 48_000) != nil

    init(url: URL, bitRate: Int = 48_000) throws {
        guard let converter = Self.makeEncoder(bitRate: bitRate) else { throw RecorderError.encoderUnavailable }
        self.url = url
        self.converter = converter
        self.formatName = "WebM · Opus · 48 кГц · моно · \(converter.bitRate / 1000) кбит/с"
        pcm = AVAudioPCMBuffer(pcmFormat: RecordingFormat.pcm, frameCapacity: AVAudioFrameCount(RecordingFormat.frameSize))!
        packets = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 4,
                                          maximumPacketSize: max(converter.maximumOutputPacketSize, 4_000))
        writer = try WebMOpusWriter(url: url, channels: 1, preSkip: 312)
    }

    static func makeEncoder(bitRate: Int) -> AVAudioConverter? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: RecordingFormat.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(RecordingFormat.frameSize), mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: RecordingFormat.pcm, to: opus) else { return nil }
        // Pick the supported rate closest to the one asked for.
        if let rates = converter.applicableEncodeBitRates?.map(\.intValue), !rates.isEmpty {
            converter.bitRate = rates.min { abs($0 - bitRate) < abs($1 - bitRate) } ?? rates[0]
        }
        return converter
    }

    func append(_ frame: UnsafeBufferPointer<Float>) throws {
        let n = min(frame.count, Int(pcm.frameCapacity))
        pcm.floatChannelData![0].update(from: frame.baseAddress!, count: n)
        pcm.frameLength = AVAudioFrameCount(n)
        try encode(pcm, final: false)
    }

    func flush() {
        try? writer.flush()
    }

    func finish() throws {
        try encode(nil, final: true)
        try writer.finish()
    }

    private func encode(_ input: AVAudioPCMBuffer?, final: Bool) throws {
        var given = false
        while true {
            packets.packetCount = 0
            packets.byteLength = 0
            var err: NSError?
            let status = converter.convert(to: packets, error: &err) { _, outStatus in
                if let input, !given {
                    given = true
                    outStatus.pointee = .haveData
                    return input
                }
                outStatus.pointee = final ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error { throw RecorderError.encoding(err?.localizedDescription ?? "Opus") }
            try drainPackets()
            if status != .haveData { break }
        }
    }

    private func drainPackets() throws {
        guard packets.packetCount > 0, let descriptions = packets.packetDescriptions else { return }
        for i in 0 ..< Int(packets.packetCount) {
            let d = descriptions[i]
            let size = Int(d.mDataByteSize)
            guard size > 0 else { continue }
            let packet = Data(bytes: packets.data.advanced(by: Int(d.mStartOffset)), count: size)
            let samples = OpusPacket.sampleCount(packet) ?? RecordingFormat.frameSize
            try writer.append(packet, samples: samples)
        }
    }
}

// MARK: - AAC in M4A

/// AAC in a fragmented .m4a via AVAssetWriter: plays everywhere (QuickTime,
/// Finder preview, phones), and thanks to 10-second fragments a crash loses
/// at most the last few seconds — the file stays readable.
final class AACFileSink: RecordingSink {
    let url: URL
    let formatName: String
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: CMAudioFormatDescription
    private var sampleTime: Int64 = 0

    init(url: URL, bitRate: Int = 64_000) throws {
        self.url = url
        formatName = "M4A · AAC · 48 кГц · моно · \(bitRate / 1000) кбит/с"
        try? FileManager.default.removeItem(at: url)
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            throw RecorderError.folder(error.localizedDescription)
        }
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: RecordingFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.encoding("AAC") }
        writer.add(input)
        var fd: CMAudioFormatDescription?
        let st = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: RecordingFormat.pcm.streamDescription,
                                                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                                extensions: nil, formatDescriptionOut: &fd)
        guard st == noErr, let fd else { throw RecorderError.encoding("AAC \(st)") }
        format = fd
        guard writer.startWriting() else {
            throw RecorderError.folder(writer.error?.localizedDescription ?? "AAC")
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ frame: UnsafeBufferPointer<Float>) throws {
        guard let base = frame.baseAddress, frame.count > 0 else { return }
        let bytes = frame.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                    offsetToData: 0, dataLength: bytes,
                                                    flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard st == noErr, let block else { throw RecorderError.encoding("AAC \(st)") }
        st = CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        guard st == noErr else { throw RecorderError.encoding("AAC \(st)") }
        var sample: CMSampleBuffer?
        st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frame.count,
            presentationTimeStamp: CMTime(value: sampleTime, timescale: CMTimeScale(RecordingFormat.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard st == noErr, let sample else { throw RecorderError.encoding("AAC \(st)") }
        sampleTime += Int64(frame.count)
        // Real-time input is almost always ready; wait a moment if not.
        var waited = 0
        while !input.isReadyForMoreMediaData && waited < 400 {
            usleep(500)
            waited += 1
        }
        guard input.append(sample) else {
            throw RecorderError.encoding(writer.error?.localizedDescription ?? "AAC")
        }
    }

    func flush() {}

    func finish() throws {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw RecorderError.encoding(writer.error?.localizedDescription ?? "AAC")
        }
    }
}

/// What the recorder writes.
enum RecordingFileFormat: String, CaseIterable, Identifiable {
    /// AAC in .m4a — opens anywhere. The default.
    case m4a
    /// Opus in .webm — half the size, the format Telemost uses.
    case webm

    var id: String { rawValue }
    var title: String {
        switch self {
        case .m4a: return "M4A (AAC)"
        case .webm: return "WebM (Opus)"
        }
    }
    var subtitle: String {
        switch self {
        case .m4a: return "Открывается везде: QuickTime, телефон, мессенджеры. ~29 МБ в час."
        case .webm: return "Вдвое компактнее, как записи Телемоста. Открывается в Meteora и браузерах. ~22 МБ в час."
        }
    }
    static let key = "recorder.format"
    static var current: RecordingFileFormat {
        UserDefaults.standard.string(forKey: key).flatMap(RecordingFileFormat.init(rawValue:)) ?? .m4a
    }
}
