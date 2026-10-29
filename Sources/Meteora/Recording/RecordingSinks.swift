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
/// 20 ms packets, ~32 kbit/s, about 14 MB per hour — and muxes into WebM.
final class OpusWebMSink: RecordingSink {
    let url: URL
    let formatName: String
    private let converter: AVAudioConverter
    private let pcm: AVAudioPCMBuffer
    private let packets: AVAudioCompressedBuffer
    private let writer: WebMOpusWriter

    /// Whether this Mac can encode Opus. Checked once.
    static let isEncoderAvailable: Bool = makeEncoder(bitRate: 32_000) != nil

    init(url: URL, bitRate: Int = 32_000) throws {
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

// MARK: - AAC in M4A (fallback)

/// Used only if the Opus encoder is missing. Unlike WebM, an .m4a is
/// readable only after `finish()` — a crash loses the file.
final class AACFileSink: RecordingSink {
    let url: URL
    let formatName = "M4A · AAC · 48 кГц · моно · 64 кбит/с"
    private var file: AVAudioFile?
    private let pcm: AVAudioPCMBuffer

    init(url: URL) throws {
        self.url = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: RecordingFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw RecorderError.folder(error.localizedDescription)
        }
        pcm = AVAudioPCMBuffer(pcmFormat: RecordingFormat.pcm, frameCapacity: AVAudioFrameCount(RecordingFormat.frameSize))!
    }

    func append(_ frame: UnsafeBufferPointer<Float>) throws {
        guard let file else { return }
        let n = min(frame.count, Int(pcm.frameCapacity))
        pcm.floatChannelData![0].update(from: frame.baseAddress!, count: n)
        pcm.frameLength = AVAudioFrameCount(n)
        do { try file.write(from: pcm) } catch { throw RecorderError.encoding(error.localizedDescription) }
    }

    func flush() {}

    func finish() throws {
        file = nil // closing writes the index
    }
}
