import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Opus packet helpers

public enum OpusPacket {
    /// Number of 48 kHz samples in an Opus packet (RFC 6716 §3.1), or nil
    /// for an invalid packet.
    public static func sampleCount(_ p: Data) -> Int? {
        guard let toc = p.first else { return nil }
        let config = Int(toc >> 3)
        let perFrame: Int
        switch config {
        case 0 ... 11: perFrame = [480, 960, 1920, 2880][config & 3]
        case 12 ... 15: perFrame = [480, 960][config & 1]
        default: perFrame = [120, 240, 480, 960][config & 3]
        }
        let frames: Int
        switch toc & 0x03 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard p.count >= 2 else { return nil }
            frames = Int(p[p.startIndex + 1] & 0x3F)
        }
        let total = perFrame * frames
        guard frames > 0, total <= 5760 else { return nil }
        return total
    }
}

// MARK: - Settings

public enum AudioQuality: String, CaseIterable, Identifiable, Sendable {
    case high
    case medium

    public var id: String { rawValue }
    public var title: String { self == .high ? "Высокое" : "Среднее" }
    public var detail: String {
        self == .high ? "M4A · 48 кГц · стерео · 192 кбит/с" : "M4A · 24 кГц · моно · 48 кбит/с"
    }
    public var sampleRate: Double { self == .high ? 48_000 : 24_000 }
    public var bitRate: Int { self == .high ? 192_000 : 48_000 }
    public func channels(source: Int) -> Int { self == .high ? min(2, max(1, source)) : 1 }
    /// Rough output size, bytes.
    public func estimatedSize(duration: Double) -> Int64 { Int64(duration * Double(bitRate) / 8 * 1.02) }
}

public struct AudioAnalysis: Sendable {
    /// Loudness envelope, one value per `envelopeStep` seconds, 0…1 (perceptual).
    public var envelope: [Float]
    public var envelopeStep: Double
    /// RMS of the "active" (non-silent) parts, linear.
    public var activeRMS: Float
    public var peak: Float
    public var decodedDuration: Double

    /// Gain that brings speech to a comfortable level for transcription.
    public var normalizationGain: Float {
        guard activeRMS > 1e-5 else { return 1 }
        let target: Float = 0.1 // ≈ −20 dBFS
        return min(8, max(0.5, target / activeRMS))
    }
}

// MARK: - Decoder

/// Decodes the Opus track of a WebM file to Float32 PCM using the system
/// Opus decoder (AudioToolbox). No third-party codec code is involved.
public final class OpusTrackDecoder {
    let demuxer: WebMDemuxer
    let channels: Int
    let sampleRate: Double = 48_000

    public init(demuxer: WebMDemuxer, info: AudioTrackInfo) throws {
        guard info.codecID == "A_OPUS" else { throw MediaError.unsupportedAudioCodec(info.codecName) }
        guard (1 ... 2).contains(info.channels) else { throw MediaError.unsupportedAudioCodec("Opus, \(info.channels) каналов") }
        self.demuxer = demuxer
        self.channels = info.channels
    }

    public var channelCount: Int { channels }

    public var pcmFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                      channels: AVAudioChannelCount(channels), interleaved: false)!
    }

    private func makeConverter(framesPerPacket: UInt32) throws -> AVAudioConverter {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let inFormat = AVAudioFormat(streamDescription: &asbd),
              let conv = AVAudioConverter(from: inFormat, to: pcmFormat) else {
            throw MediaError.audioDecoderUnavailable
        }
        return conv
    }

    /// Streams decoded PCM in file order. Gaps in the packet timeline (for
    /// example while a participant was muted) are filled with silence so the
    /// output stays in sync with the video.
    public func decode(isCancelled: (() -> Bool)? = nil,
                       progress: ((Double) -> Void)? = nil,
                       _ sink: (AVAudioPCMBuffer) throws -> Void) throws {
        var converter: AVAudioConverter?
        var converterFPP: UInt32 = 0
        let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 5760)!
        let silence = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 48_000)!
        var producedSamples: Int64 = 0
        var startTime: Double?
        var index = 0
        let total = max(1, demuxer.audioPacketCount)
        var decodedAny = false
        var failures = 0
        // Never produce more audio than the recording spans (+5 s), whatever
        // the timestamps say — protects against "silence bombs".
        let maxSamples = Int64((demuxer.packetSpan + 5) * sampleRate)
        // Silence may never dominate: at most 30 min or 3× the real audio.
        var silenceSamples: Int64 = 0
        var realSamples: Int64 = 0

        try demuxer.forEachAudioPacket(isCancelled: isCancelled) { time, packet in
            index += 1
            if producedSamples >= maxSamples { return }
            if index % 2000 == 0 { progress?(Double(index) / Double(total)) }
            guard let n = OpusPacket.sampleCount(packet), packet.count <= 4000 else { failures += 1; return }

            // Fill gaps with silence (cap a single gap at 10 minutes).
            if startTime == nil { startTime = time }
            let expected = Int64(((time - startTime!) * sampleRate).rounded())
            let silenceBudget = max(Int64(sampleRate * 1800), 3 * realSamples) - silenceSamples
            var gap = min(expected - producedSamples, Int64(sampleRate * 600), maxSamples - producedSamples, silenceBudget)
            if gap > Int64(n) {
                while gap > 0 {
                    let chunk = AVAudioFrameCount(min(gap, Int64(silence.frameCapacity)))
                    silence.frameLength = chunk
                    for c in 0 ..< channels { memset(silence.floatChannelData![c], 0, Int(chunk) * 4) }
                    try sink(silence)
                    producedSamples += Int64(chunk)
                    silenceSamples += Int64(chunk)
                    gap -= Int64(chunk)
                }
            }

            if converter == nil || converterFPP != UInt32(n) {
                // Opus packet duration changed: re-create the decoder. In
                // practice Telemost uses a constant 10 ms.
                converter = try makeConverter(framesPerPacket: UInt32(n))
                converterFPP = UInt32(n)
            }
            let conv = converter!
            let compressed = AVAudioCompressedBuffer(format: conv.inputFormat, packetCapacity: 1,
                                                     maximumPacketSize: max(packet.count, 1))
            packet.withUnsafeBytes { raw in
                compressed.data.copyMemory(from: raw.baseAddress!, byteCount: packet.count)
            }
            compressed.byteLength = UInt32(packet.count)
            compressed.packetCount = 1
            compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))

            var supplied = false
            out.frameLength = 0
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, outStatus in
                if supplied { outStatus.pointee = .noDataNow; return nil }
                supplied = true
                outStatus.pointee = .haveData
                return compressed
            }
            if status == .error || out.frameLength == 0 {
                failures += 1
                // Keep timing: substitute silence for a broken packet.
                silence.frameLength = AVAudioFrameCount(n)
                for c in 0 ..< channels { memset(silence.floatChannelData![c], 0, n * 4) }
                try sink(silence)
                producedSamples += Int64(n)
                if !decodedAny, failures > 50 { throw MediaError.audioDecoderUnavailable }
                return
            }
            decodedAny = true
            try sink(out)
            producedSamples += Int64(out.frameLength)
            realSamples += Int64(out.frameLength)
        }
        progress?(1)
        if !decodedAny { throw MediaError.audioDecoderUnavailable }
    }

    // MARK: Analysis

    /// One fast pass over the track: loudness envelope for the waveform and
    /// statistics for volume normalization.
    public func analyze(envelopeStep: Double = 0.1,
                        isCancelled: (() -> Bool)? = nil,
                        progress: ((Double) -> Void)? = nil) throws -> AudioAnalysis {
        let window = Int(sampleRate * envelopeStep)
        var envelope: [Float] = []
        var acc: Double = 0
        var accN = 0
        var peak: Float = 0
        var activeSum: Double = 0
        var activeN = 0
        var total: Int64 = 0

        try decode(isCancelled: isCancelled, progress: progress) { buf in
            let n = Int(buf.frameLength)
            guard let data = buf.floatChannelData else { return }
            for i in 0 ..< n {
                var s: Float = 0
                for c in 0 ..< channels { s += data[c][i] }
                s /= Float(channels)
                let a = abs(s)
                if a > peak { peak = a }
                acc += Double(s * s)
                accN += 1
                if accN == window {
                    let rms = Float((acc / Double(accN)).squareRoot())
                    envelope.append(rms)
                    if rms > 0.003 { activeSum += acc; activeN += accN } // > −50 dBFS
                    acc = 0; accN = 0
                }
            }
            total += Int64(n)
        }
        if accN > 0 { envelope.append(Float((acc / Double(accN)).squareRoot())) }
        // Perceptual scale for drawing: map −60…0 dBFS to 0…1.
        let shaped = envelope.map { rms -> Float in
            let db = 20 * log10(max(rms, 1e-6))
            return min(1, max(0, (db + 60) / 60))
        }
        let activeRMS = activeN > 0 ? Float((activeSum / Double(activeN)).squareRoot()) : 0
        return AudioAnalysis(envelope: shaped, envelopeStep: envelopeStep, activeRMS: activeRMS,
                             peak: peak, decodedDuration: Double(total) / sampleRate)
    }
}

// MARK: - Export

public struct AudioExportOptions: Sendable {
    public var quality: AudioQuality
    public var normalize: Bool
    public init(quality: AudioQuality, normalize: Bool) {
        self.quality = quality
        self.normalize = normalize
    }
}

public enum AudioExporter {
    /// Decodes the Opus track and writes an AAC (.m4a) file.
    /// The file is first written to a temporary sibling and moved into place
    /// only on success, so a cancelled export never leaves a broken file.
    public static func export(decoder: OpusTrackDecoder,
                              analysis: AudioAnalysis?,
                              options: AudioExportOptions,
                              to destination: URL,
                              isCancelled: (() -> Bool)? = nil,
                              progress: ((Double) -> Void)? = nil) throws {
        let outChannels = options.quality.channels(source: decoder.channels)
        let outRate = options.quality.sampleRate
        let gain: Float = options.normalize ? (analysis?.normalizationGain ?? 1) : 1

        guard let mixFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: decoder.sampleRate,
                                            channels: AVAudioChannelCount(outChannels), interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outRate,
                                            channels: AVAudioChannelCount(outChannels), interleaved: false)
        else { throw MediaError.exportFailed("формат") }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outRate,
            AVNumberOfChannelsKey: outChannels,
            AVEncoderBitRateKey: options.quality.bitRate,
        ]
        // Work in our own temporary directory: inside the App Sandbox we may
        // only write to the exact file the user picked, not next to it.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("volant-\(UUID().uuidString).m4a")
        var file: AVAudioFile? = try AVAudioFile(forWriting: tmp, settings: settings,
                                                 commonFormat: .pcmFormatFloat32, interleaved: false)
        var success = false
        defer {
            file = nil
            if !success { try? FileManager.default.removeItem(at: tmp) }
        }

        let resampler: AVAudioConverter? = outRate == decoder.sampleRate ? nil : AVAudioConverter(from: mixFormat, to: outFormat)
        resampler?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let mixBuf = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: 48_000)!
        let rsBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(outRate) + 1024)!

        func write(_ b: AVAudioPCMBuffer) throws {
            guard b.frameLength > 0 else { return }
            do { try file!.write(from: b) } catch { throw MediaError.exportFailed(error.localizedDescription) }
        }

        func resampleAndWrite(_ input: AVAudioPCMBuffer?, final: Bool) throws {
            guard let rs = resampler else { if let input { try write(input) }; return }
            var given = false
            while true {
                rsBuf.frameLength = 0
                var err: NSError?
                let st = rs.convert(to: rsBuf, error: &err) { _, s in
                    if let input, !given { given = true; s.pointee = .haveData; return input }
                    s.pointee = final ? .endOfStream : .noDataNow
                    return nil
                }
                if st == .error { throw MediaError.exportFailed(err?.localizedDescription ?? "ресемплинг") }
                try write(rsBuf)
                if st != .haveData { break }
            }
        }

        try decoder.decode(isCancelled: isCancelled, progress: progress) { src in
            let n = Int(src.frameLength)
            var offset = 0
            while offset < n {
                let chunk = min(n - offset, Int(mixBuf.frameCapacity))
                let s = src.floatChannelData!
                let d = mixBuf.floatChannelData!
                for i in 0 ..< chunk {
                    if outChannels == 1 {
                        var v: Float = 0
                        for c in 0 ..< decoder.channels { v += s[c][offset + i] }
                        d[0][i] = limit(v / Float(decoder.channels) * gain)
                    } else {
                        for c in 0 ..< outChannels {
                            d[c][i] = limit(s[min(c, decoder.channels - 1)][offset + i] * gain)
                        }
                    }
                }
                mixBuf.frameLength = AVAudioFrameCount(chunk)
                try resampleAndWrite(mixBuf, final: false)
                offset += chunk
            }
        }
        try resampleAndWrite(nil, final: true)
        if isCancelled?() == true { throw MediaError.cancelled }
        file = nil // closes and finalizes the container

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tmp, to: destination)
            success = true
        } catch {
            throw MediaError.exportFailed(error.localizedDescription)
        }
    }

    /// Soft limiter: transparent below −1 dBFS, smooth saturation above.
    @inline(__always)
    static func limit(_ x: Float) -> Float {
        let t: Float = 0.89
        let a = abs(x)
        if a <= t { return x }
        let y = t + (1 - t) * tanh((a - t) / (1 - t))
        return x < 0 ? -y : y
    }
}
