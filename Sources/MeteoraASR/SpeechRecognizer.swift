import Foundation
import AVFoundation
import CSherpaOnnx
import MeteoraCore

/// Pinned at build time from the official model card (see scripts/fetch_vendor.sh).
let tokensSHA256 = "39abae20e692998290c574e606f11a9edef2902a1995463fcff63d1490cf22b7"

public enum RecognizerError: Error, LocalizedError, Equatable {
    case modelLoad
    case vadLoad
    case cancelled
    case audio(String)

    public var errorDescription: String? {
        switch self {
        case .modelLoad: return "Не удалось загрузить модель распознавания. Попробуйте скачать её заново в «Хранилище»."
        case .vadLoad: return "Не удалось загрузить детектор речи."
        case .cancelled: return "Расшифровка остановлена."
        case .audio(let s): return "Ошибка звука: \(s)"
        }
    }
}

/// Speech-to-text on the Mac: Silero VAD cuts the audio into phrases,
/// GigaAM-v3 (via sherpa-onnx / ONNX Runtime, CPU) turns each phrase into
/// punctuated text. Nothing leaves the computer.
public final class SpeechRecognizer {
    public static let sampleRate = 16_000
    public static let engineName = "GigaAM-v3 e2e RNN-T"

    private let recognizer: OpaquePointer
    private let vad: OpaquePointer

    /// - Parameters:
    ///   - store: where the GigaAM files are installed (must be verified).
    ///   - vadModel: bundled Silero VAD model.
    public init(store: ModelStore, vadModel: URL, threads: Int = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 1))) throws {
        guard store.isInstalled else { throw ModelError.notInstalled }
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }

        var cfg = SherpaOnnxOfflineRecognizerConfig()
        cfg.feat_config.sample_rate = Int32(Self.sampleRate)
        cfg.feat_config.feature_dim = 64
        cfg.model_config.transducer.encoder = c(store.path("encoder.int8.onnx").path)
        cfg.model_config.transducer.decoder = c(store.path("decoder.onnx").path)
        cfg.model_config.transducer.joiner = c(store.path("joiner.onnx").path)
        cfg.model_config.tokens = c(store.path("tokens.txt").path)
        cfg.model_config.num_threads = Int32(threads)
        cfg.model_config.provider = c("cpu")
        cfg.model_config.model_type = c("nemo_transducer")
        cfg.decoding_method = c("greedy_search")
        cfg.max_active_paths = 4
        guard let r = SherpaOnnxCreateOfflineRecognizer(&cfg) else { throw RecognizerError.modelLoad }

        var v = SherpaOnnxVadModelConfig()
        v.silero_vad.model = c(vadModel.path)
        v.silero_vad.threshold = 0.45
        v.silero_vad.min_silence_duration = 0.6
        v.silero_vad.min_speech_duration = 0.25
        v.silero_vad.window_size = 512
        v.silero_vad.max_speech_duration = 20
        v.sample_rate = Int32(Self.sampleRate)
        v.num_threads = 1
        v.provider = c("cpu")
        guard let d = SherpaOnnxCreateVoiceActivityDetector(&v, 60) else {
            SherpaOnnxDestroyOfflineRecognizer(r)
            throw RecognizerError.vadLoad
        }
        recognizer = r
        vad = d
    }

    deinit {
        SherpaOnnxDestroyVoiceActivityDetector(vad)
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    /// Recognizes one chunk of 16 kHz mono audio.
    func recognize(_ samples: UnsafePointer<Float>, count: Int) -> String {
        guard count > 0, let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        SherpaOnnxAcceptWaveformOffline(stream, Int32(Self.sampleRate), samples, Int32(count))
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let text = result.pointee.text else { return "" }
        return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Feeds 16 kHz samples to the VAD and recognizes every finished phrase.
    private func feed(_ samples: [Float], flush: Bool, into out: inout [TranscriptSegment],
                      onSegment: (TranscriptSegment) -> Void) {
        let v = vad
        if !samples.isEmpty {
            samples.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(v, $0.baseAddress, Int32($0.count)) }
        }
        if flush { SherpaOnnxVoiceActivityDetectorFlush(v) }
        while SherpaOnnxVoiceActivityDetectorEmpty(v) == 0 {
            guard let seg = SherpaOnnxVoiceActivityDetectorFront(v) else { break }
            let n = Int(seg.pointee.n)
            let start = Double(seg.pointee.start) / Double(Self.sampleRate)
            if n > 0, let p = seg.pointee.samples {
                let text = recognize(p, count: n)
                if !text.isEmpty {
                    let s = TranscriptSegment(start: max(0, start), end: start + Double(n) / Double(Self.sampleRate), text: text)
                    out.append(s)
                    onSegment(s)
                }
            }
            SherpaOnnxDestroySpeechSegment(seg)
            SherpaOnnxVoiceActivityDetectorPop(v)
        }
    }

    /// Transcribes a WebM recording's Opus track.
    public func transcribe(decoder: OpusTrackDecoder,
                           isCancelled: @escaping () -> Bool,
                           progress: @escaping (Double) -> Void,
                           onSegment: @escaping (TranscriptSegment) -> Void) throws -> [TranscriptSegment] {
        SherpaOnnxVoiceActivityDetectorReset(vad)
        let resampler = try MonoResampler(inputRate: 48_000, channels: decoder.channelCount, outputRate: Double(Self.sampleRate))
        var out: [TranscriptSegment] = []
        do {
            try decoder.decode(isCancelled: isCancelled, progress: progress) { buf in
                if isCancelled() { throw RecognizerError.cancelled }
                let mono16k = try resampler.process(buf)
                feed(mono16k, flush: false, into: &out, onSegment: onSegment)
            }
        } catch MediaError.cancelled {
            throw RecognizerError.cancelled
        }
        feed(try resampler.finish(), flush: true, into: &out, onSegment: onSegment)
        return out
    }

    /// Transcribes 16 kHz mono samples (used by tests).
    public func transcribe(samples16k: [Float]) -> [TranscriptSegment] {
        SherpaOnnxVoiceActivityDetectorReset(vad)
        var out: [TranscriptSegment] = []
        var i = 0
        while i < samples16k.count {
            let j = min(samples16k.count, i + 16_000)
            feed(Array(samples16k[i ..< j]), flush: false, into: &out) { _ in }
            i = j
        }
        feed([], flush: true, into: &out) { _ in }
        return out
    }

    public static var runtimeVersion: String { String(cString: SherpaOnnxGetVersionStr()) }
}

/// 48 kHz (mono/stereo) Float32 → 16 kHz mono Float32, streaming.
final class MonoResampler {
    private let mixFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let mixBuffer: AVAudioPCMBuffer
    private let outBuffer: AVAudioPCMBuffer
    private let channels: Int

    init(inputRate: Double, channels: Int, outputRate: Double) throws {
        guard let mix = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: mix, to: out),
              let mb = AVAudioPCMBuffer(pcmFormat: mix, frameCapacity: 48_000),
              let ob = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: AVAudioFrameCount(outputRate) + 1024) else {
            throw RecognizerError.audio("формат")
        }
        conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        mixFormat = mix; outFormat = out; converter = conv; mixBuffer = mb; outBuffer = ob
        self.channels = max(1, channels)
    }

    func process(_ input: AVAudioPCMBuffer) throws -> [Float] {
        var result: [Float] = []
        let n = Int(input.frameLength)
        var offset = 0
        guard let src = input.floatChannelData, let dst = mixBuffer.floatChannelData else { return [] }
        let ch = min(channels, Int(input.format.channelCount))
        while offset < n {
            let chunk = min(n - offset, Int(mixBuffer.frameCapacity))
            for i in 0 ..< chunk {
                var v: Float = 0
                for c in 0 ..< ch { v += src[c][offset + i] }
                dst[0][i] = v / Float(ch)
            }
            mixBuffer.frameLength = AVAudioFrameCount(chunk)
            result += try convert(mixBuffer, final: false)
            offset += chunk
        }
        return result
    }

    func finish() throws -> [Float] { try convert(nil, final: true) }

    private func convert(_ input: AVAudioPCMBuffer?, final: Bool) throws -> [Float] {
        var out: [Float] = []
        var given = false
        while true {
            outBuffer.frameLength = 0
            var err: NSError?
            let status = converter.convert(to: outBuffer, error: &err) { _, s in
                if let input, !given { given = true; s.pointee = .haveData; return input }
                s.pointee = final ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error { throw RecognizerError.audio(err?.localizedDescription ?? "ресемплинг") }
            if let d = outBuffer.floatChannelData, outBuffer.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: d[0], count: Int(outBuffer.frameLength)))
            }
            if status != .haveData { break }
        }
        return out
    }
}
