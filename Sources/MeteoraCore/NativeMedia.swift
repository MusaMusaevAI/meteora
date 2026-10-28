import Foundation
import AVFoundation
import CoreMedia

/// Anything that can stream decoded Float32 PCM (non-interleaved): the Opus
/// track of a WebM file, or any audio macOS can decode itself.
public protocol PCMSource: AnyObject {
    var channelCount: Int { get }
    var sampleRate: Double { get }
    func decode(isCancelled: (() -> Bool)?,
                progress: ((Double) -> Void)?,
                _ sink: (AVAudioPCMBuffer) throws -> Void) throws
}

extension OpusTrackDecoder: PCMSource {}

extension PCMSource {
    /// One fast pass over the track: loudness envelope for the waveform and
    /// statistics for volume normalization.
    public func analyze(envelopeStep: Double = 0.1,
                        isCancelled: (() -> Bool)? = nil,
                        progress: ((Double) -> Void)? = nil) throws -> AudioAnalysis {
        let rate = sampleRate
        let channels = channelCount
        let window = max(1, Int(rate * envelopeStep))
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
            let ch = min(channels, Int(buf.format.channelCount))
            guard ch > 0 else { return }
            for i in 0 ..< n {
                var s: Float = 0
                for c in 0 ..< ch { s += data[c][i] }
                s /= Float(ch)
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
                             peak: peak, decodedDuration: Double(total) / rate)
    }
}

/// Decodes the audio of any file AVFoundation can read (MP4, MOV, M4A, MP3,
/// WAV, AIFF, CAF, FLAC, …) to 48 kHz Float32, mono or stereo.
public final class AssetAudioDecoder: PCMSource {
    public let sampleRate: Double = 48_000
    public let channelCount: Int
    private let asset: AVURLAsset
    private let tracks: [AVAssetTrack]
    private let duration: Double

    private init(asset: AVURLAsset, tracks: [AVAssetTrack], channels: Int, duration: Double) {
        self.asset = asset
        self.tracks = tracks
        self.channelCount = channels
        self.duration = duration
    }

    public static func make(url: URL) async throws -> AssetAudioDecoder {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let first = tracks.first else { throw MediaError.noAudio }
        var channels = 2
        if let desc = try await first.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            channels = Int(asbd.mChannelsPerFrame)
        }
        let duration = try await asset.load(.duration).seconds
        return AssetAudioDecoder(asset: asset, tracks: [first], channels: max(1, min(2, channels)),
                                 duration: duration.isFinite ? duration : 0)
    }

    public func decode(isCancelled: (() -> Bool)? = nil,
                       progress: ((Double) -> Void)? = nil,
                       _ sink: (AVAudioPCMBuffer) throws -> Void) throws {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw MediaError.io(error.localizedDescription) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
        ]
        // The mix output downmixes multichannel audio and resamples for us.
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaError.audioDecoderUnavailable }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaError.io(reader.error?.localizedDescription ?? "чтение звука")
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channelCount), interleaved: false) else {
            throw MediaError.audioDecoderUnavailable
        }
        var produced: Int64 = 0
        var lastReport = Date.distantPast
        // Never produce absurd amounts of audio, whatever the file claims.
        let maxSamples = Int64((max(duration, 1) + 60) * sampleRate)
        while let sample = output.copyNextSampleBuffer() {
            if isCancelled?() == true {
                reader.cancelReading()
                throw MediaError.cancelled
            }
            let n = CMSampleBufferGetNumSamples(sample)
            guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { continue }
            buf.frameLength = AVAudioFrameCount(n)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(n),
                                                                      into: buf.mutableAudioBufferList)
            guard status == noErr else { continue }
            try sink(buf)
            produced += Int64(n)
            if produced > maxSamples { reader.cancelReading(); break }
            if duration > 0, Date().timeIntervalSince(lastReport) > 0.1 {
                lastReport = Date()
                progress?(min(1, Double(produced) / sampleRate / duration))
            }
        }
        if reader.status == .failed {
            throw MediaError.io(reader.error?.localizedDescription ?? "чтение звука")
        }
        if produced == 0 { throw MediaError.audioDecoderUnavailable }
        progress?(1)
    }
}

/// Reads the structure of a file AVFoundation can open.
public enum AssetProbe {
    public static func analyze(url: URL) async throws -> MediaInfo {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw MediaError.notARegularFile }
        let asset = AVURLAsset(url: url)
        let playable: Bool
        do { playable = try await asset.load(.isPlayable) } catch { throw MediaError.unplayable }
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard playable || !audioTracks.isEmpty, !(audioTracks.isEmpty && videoTracks.isEmpty) else {
            throw MediaError.unplayable
        }
        let duration = (try? await asset.load(.duration).seconds) ?? 0

        var video: VideoTrackInfo?
        if let v = videoTracks.first {
            let size = (try? await v.load(.naturalSize)) ?? .zero
            let transform = (try? await v.load(.preferredTransform)) ?? .identity
            let shown = size.applying(transform)
            let codec = (try? await v.load(.formatDescriptions).first).map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "video"
            video = VideoTrackInfo(codecID: codec, width: Int(abs(shown.width).rounded()), height: Int(abs(shown.height).rounded()))
        }
        var audio: AudioTrackInfo?
        if let a = audioTracks.first {
            var rate = 48_000.0, channels = 2, codec = "audio"
            if let desc = try? await a.load(.formatDescriptions).first {
                codec = fourCC(CMFormatDescriptionGetMediaSubType(desc))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                    rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : rate
                    channels = Int(asbd.mChannelsPerFrame)
                }
            }
            audio = AudioTrackInfo(codecID: codec, sampleRate: rate, channels: max(1, channels))
        }
        return MediaInfo(url: url, fileSize: UInt64(max(0, values?.fileSize ?? 0)),
                         duration: duration.isFinite ? duration : 0, video: video, audio: audio)
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        return printable ? String(decoding: bytes, as: UTF8.self) : String(format: "0x%08x", code)
    }

    /// Times to sample for key frames in a file without a keyframe index:
    /// an even grid, denser in thorough mode.
    public static func sampleTimes(duration: Double, thorough: Bool) -> [Double] {
        guard duration > 0 else { return [] }
        let step = max(thorough ? 1.5 : 3.0, duration / Double(ScenePlanner.maxSamples))
        return Array(stride(from: 0.0, to: duration, by: step))
    }
}
