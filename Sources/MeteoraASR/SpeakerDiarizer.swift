import Foundation
import AVFoundation
import CSherpaOnnx
import MeteoraCore

public enum DiarizerError: Error, LocalizedError, Equatable {
    case notInstalled
    case modelLoad
    case cancelled
    case audio(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "Модель разделения по спикерам не загружена."
        case .modelLoad: return "Не удалось загрузить модель разделения по спикерам. Попробуйте скачать её заново в «Хранилище»."
        case .cancelled: return "Разделение по спикерам остановлено."
        case .audio(let s): return "Ошибка звука: \(s)"
        }
    }
}

/// Who spoke when, on the Mac: pyannote segmentation 3.0 + CAM++ voice
/// embeddings + clustering (sherpa-onnx offline speaker diarization, CPU).
/// Nothing leaves the computer.
///
/// Memory: sherpa's offline API needs the whole signal as one Float buffer
/// (2 h at 16 kHz = 460 MB). Instead the audio is streamed and diarized in
/// long windows (10 min by default, the last one up to 13 min so it is never
/// tiny): at most ~13 min of Float samples (~50 MB) are alive at once. Each
/// window's speakers get a voice embedding (CAM++, up to 30 s of their
/// longest turns) and are joined across windows by `SpeakerLinking`. Long
/// windows keep enough speech per person for reliable clustering inside the
/// window; recordings up to 13 min are diarized in one pass, exactly as
/// sherpa intends.
///
/// Cancellation is checked between windows and while decoding; sherpa
/// itself cannot be interrupted, so stopping takes up to one window's work.
public final class SpeakerDiarizer {
    public static let sampleRate = 16_000
    public static let engineName = "pyannote 3.0 + CAM++"

    public struct Options: Sendable {
        /// Known number of speakers; nil = find automatically.
        public var numSpeakers: Int?
        /// Clustering distance (1 − cos, complete linkage, sherpa default 0.5).
        /// Smaller → more speakers, larger → fewer.
        public var threshold: Float
        /// Cross-window linking distance between speaker centroids.
        public var linkThreshold: Float
        /// Speakers separated inside one window are joined only if this close.
        public var sameWindowLinkThreshold: Float
        /// Length of a processing window, seconds (at least 5).
        public var windowSeconds: Double
        /// A window may grow by this much so the final one is not tiny.
        public var carrySeconds: Double
        /// pyannote sliding-window shift as a fraction of its 10 s window
        /// (sherpa default 0.1). 0.25 is ~2.5× faster with little loss.
        public var windowShiftRatio: Float
        /// Turns shorter than this are dropped by sherpa, seconds.
        public var minDurationOn: Float
        /// Pauses shorter than this inside one speaker's turn are filled, seconds.
        public var minDurationOff: Float
        public var threads: Int

        public init(numSpeakers: Int? = nil,
                    threshold: Float = 0.5,
                    linkThreshold: Float = 0.5,
                    sameWindowLinkThreshold: Float = 0.3,
                    windowSeconds: Double = 600,
                    carrySeconds: Double = 180,
                    windowShiftRatio: Float = 0.25,
                    minDurationOn: Float = 0.3,
                    minDurationOff: Float = 0.5,
                    threads: Int = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 1))) {
            self.numSpeakers = numSpeakers
            self.threshold = threshold
            self.linkThreshold = linkThreshold
            self.sameWindowLinkThreshold = sameWindowLinkThreshold
            self.windowSeconds = windowSeconds
            self.carrySeconds = carrySeconds
            self.windowShiftRatio = windowShiftRatio
            self.minDurationOn = minDurationOn
            self.minDurationOff = minDurationOff
            self.threads = threads
        }
    }

    public let options: Options
    private let diarizer: OpaquePointer
    private let extractor: OpaquePointer

    public init(store: ModelStore = .speakers, options: Options = Options()) throws {
        guard store.isInstalled else { throw DiarizerError.notInstalled }
        self.options = options
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }
        let segmentation = store.path(SpeakerModel.segmentationFile).path
        let embedding = store.path(SpeakerModel.embeddingFile).path

        var cfg = SherpaOnnxOfflineSpeakerDiarizationConfig()
        cfg.segmentation.pyannote.model = c(segmentation)
        cfg.segmentation.pyannote.window_shift_ratio = min(1, max(0.05, options.windowShiftRatio))
        cfg.segmentation.num_threads = Int32(options.threads)
        cfg.segmentation.provider = c("cpu")
        cfg.embedding.model = c(embedding)
        cfg.embedding.num_threads = Int32(options.threads)
        cfg.embedding.provider = c("cpu")
        cfg.clustering = Self.clustering(numSpeakers: options.numSpeakers, threshold: options.threshold)
        cfg.min_duration_on = options.minDurationOn
        cfg.min_duration_off = options.minDurationOff
        guard let sd = SherpaOnnxCreateOfflineSpeakerDiarization(&cfg) else { throw DiarizerError.modelLoad }
        guard SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(sd) == Int32(Self.sampleRate) else {
            SherpaOnnxDestroyOfflineSpeakerDiarization(sd)
            throw DiarizerError.modelLoad
        }

        var e = SherpaOnnxSpeakerEmbeddingExtractorConfig()
        e.model = c(embedding)
        e.num_threads = Int32(options.threads)
        e.provider = c("cpu")
        guard let ex = SherpaOnnxCreateSpeakerEmbeddingExtractor(&e) else {
            SherpaOnnxDestroyOfflineSpeakerDiarization(sd)
            throw DiarizerError.modelLoad
        }
        diarizer = sd
        extractor = ex
    }

    deinit {
        SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor)
        SherpaOnnxDestroyOfflineSpeakerDiarization(diarizer)
    }

    private static func clustering(numSpeakers: Int?, threshold: Float) -> SherpaOnnxFastClusteringConfig {
        var c = SherpaOnnxFastClusteringConfig()
        c.num_clusters = Int32(numSpeakers.map { max(1, $0) } ?? -1)
        c.threshold = threshold
        c.compute_confidence = 0
        return c
    }

    // MARK: Public entry points

    /// Diarizes any decoded audio source (WebM Opus or AVFoundation).
    /// - Parameter expectedDuration: recording length if known (better progress).
    /// - Returns: turns sorted by start; speakers numbered 0, 1, 2… in order of
    ///   first appearance.
    public func diarize(decoder: PCMSource,
                        expectedDuration: Double? = nil,
                        isCancelled: @escaping () -> Bool,
                        progress: @escaping (Double) -> Void) throws -> [SpeakerTurn] {
        let resampler: MonoResampler
        do {
            resampler = try MonoResampler(inputRate: decoder.sampleRate, channels: decoder.channelCount,
                                          outputRate: Double(Self.sampleRate))
        } catch {
            throw DiarizerError.audio("формат")
        }
        let run = Run(owner: self, expectedDuration: expectedDuration, isCancelled: isCancelled, progress: progress)
        do {
            try decoder.decode(isCancelled: isCancelled, progress: { run.decodeFraction = $0 }) { buf in
                if isCancelled() { throw DiarizerError.cancelled }
                try run.append(try resampler.process(buf))
            }
            try run.append(try resampler.finish())
        } catch MediaError.cancelled {
            throw DiarizerError.cancelled
        } catch let e as RecognizerError {
            if case .audio(let s) = e { throw DiarizerError.audio(s) }
            throw e
        }
        return try run.finish()
    }

    /// Diarizes 16 kHz mono samples (self-test, tests).
    public func diarize(samples16k: [Float],
                        isCancelled: @escaping () -> Bool = { false },
                        progress: @escaping (Double) -> Void = { _ in }) throws -> [SpeakerTurn] {
        let run = Run(owner: self, expectedDuration: Double(samples16k.count) / Double(Self.sampleRate),
                      isCancelled: isCancelled, progress: progress)
        var i = 0
        let step = Self.sampleRate * 30
        while i < samples16k.count {
            let j = min(samples16k.count, i + step)
            try run.append(Array(samples16k[i ..< j]))
            i = j
        }
        return try run.finish()
    }

    public static var runtimeVersion: String { String(cString: SherpaOnnxGetVersionStr()) }

    // MARK: One diarization run (streaming into windows)

    private struct Window {
        var index: Int
        var offset: Double
        var turns: [SpeakerTurn]           // global time, local speaker ids
        var embeddings: [Int: [Float]]      // local speaker → voice embedding
        var speech: [Int: Double]           // local speaker → seconds of speech
    }

    private final class Run {
        let owner: SpeakerDiarizer
        let isCancelled: () -> Bool
        let report: (Double) -> Void
        let expectedDuration: Double?
        var decodeFraction: Double = 0

        let windowSamples: Int
        let maxSamples: Int
        var buffer: [Float] = []
        var consumed = 0              // samples handed to windows so far
        var windows: [Window] = []
        var lastProgress: Double = 0

        init(owner: SpeakerDiarizer, expectedDuration: Double?, isCancelled: @escaping () -> Bool,
             progress: @escaping (Double) -> Void) {
            self.owner = owner
            self.expectedDuration = expectedDuration
            self.isCancelled = isCancelled
            self.report = progress
            let rate = Double(SpeakerDiarizer.sampleRate)
            windowSamples = max(SpeakerDiarizer.sampleRate * 5, Int(owner.options.windowSeconds * rate))
            maxSamples = windowSamples + max(0, Int(owner.options.carrySeconds * rate))
            buffer.reserveCapacity(min(maxSamples, SpeakerDiarizer.sampleRate * 60) + 48_000)
        }

        func append(_ samples: [Float]) throws {
            guard !samples.isEmpty else { return }
            buffer.append(contentsOf: samples)
            while buffer.count >= maxSamples {
                try processWindow(count: windowSamples, last: false)
                buffer.removeFirst(windowSamples)
            }
        }

        func finish() throws -> [SpeakerTurn] {
            if !buffer.isEmpty {
                try processWindow(count: buffer.count, last: true)
                buffer = []
            }
            report(1)
            return link()
        }

        /// Total duration estimate for progress, in samples.
        private func estimatedTotal(pending: Int) -> Double {
            let rate = Double(SpeakerDiarizer.sampleRate)
            let known = Double(consumed + pending)
            if let d = expectedDuration, d > 0 { return max(known, d * rate) }
            if decodeFraction > 0.01 { return max(known, Double(consumed + buffer.count) / decodeFraction) }
            return known
        }

        private func progress(windowCount: Int, fraction: Double) {
            let total = estimatedTotal(pending: windowCount)
            guard total > 0 else { return }
            let p = min(0.99, (Double(consumed) + fraction * Double(windowCount)) / total)
            if p > lastProgress + 0.002 {
                lastProgress = p
                report(p)
            }
        }

        private func processWindow(count: Int, last: Bool) throws {
            if isCancelled() { throw DiarizerError.cancelled }
            let single = last && windows.isEmpty
            let offset = Double(consumed) / Double(SpeakerDiarizer.sampleRate)
            let window = try buffer.withUnsafeBufferPointer { all -> Window in
                let slice = UnsafeBufferPointer(rebasing: all[0 ..< count])
                return try owner.diarizeWindow(slice, index: windows.count, offset: offset,
                                               numSpeakers: single ? owner.options.numSpeakers : nil,
                                               withEmbeddings: !single) { [unowned self] f in
                    self.progress(windowCount: count, fraction: f)
                }
            }
            if isCancelled() { throw DiarizerError.cancelled }
            windows.append(window)
            consumed += count
            progress(windowCount: 0, fraction: 0)
        }

        /// Joins window-local speakers into recording-wide ones.
        private func link() -> [SpeakerTurn] {
            var global: [[Int: Int]] = windows.map { _ in [:] }
            if windows.count == 1 {
                for t in windows[0].turns { global[0][t.speaker] = t.speaker }
            } else {
                var items: [SpeakerLinking.Item] = []
                var keys: [(w: Int, s: Int)] = []
                for (wi, w) in windows.enumerated() {
                    for (s, e) in w.embeddings.sorted(by: { $0.key < $1.key }) {
                        items.append(SpeakerLinking.Item(window: wi, embedding: e, weight: w.speech[s] ?? 1))
                        keys.append((wi, s))
                    }
                }
                let labels = SpeakerLinking.cluster(items, numSpeakers: owner.options.numSpeakers,
                                                    threshold: owner.options.linkThreshold,
                                                    sameWindowThreshold: owner.options.sameWindowLinkThreshold)
                for (k, l) in zip(keys, labels) { global[k.w][k.s] = l }
            }
            // Turns of speakers without an embedding (too little speech) are dropped.
            var turns: [SpeakerTurn] = []
            for (wi, w) in windows.enumerated() {
                for t in w.turns {
                    if let g = global[wi][t.speaker] { turns.append(SpeakerTurn(start: t.start, end: t.end, speaker: g)) }
                }
            }
            turns.sort { $0.start != $1.start ? $0.start < $1.start : $0.speaker < $1.speaker }
            // Renumber by first appearance.
            var number: [Int: Int] = [:]
            for t in turns where number[t.speaker] == nil { number[t.speaker] = number.count }
            return turns.map { SpeakerTurn(start: $0.start, end: $0.end, speaker: number[$0.speaker] ?? 0) }
        }
    }

    // MARK: sherpa-onnx calls

    private final class ProgressBox {
        let f: (Double) -> Void
        init(_ f: @escaping (Double) -> Void) { self.f = f }
    }

    /// Runs sherpa's offline diarization on one window and, for multi-window
    /// recordings, computes one voice embedding per local speaker.
    private func diarizeWindow(_ samples: UnsafeBufferPointer<Float>, index: Int, offset: Double,
                               numSpeakers: Int?, withEmbeddings: Bool,
                               progress: @escaping (Double) -> Void) throws -> Window {
        var window = Window(index: index, offset: offset, turns: [], embeddings: [:], speech: [:])
        guard let base = samples.baseAddress, samples.count > Self.sampleRate / 2 else { return window }

        var cfg = SherpaOnnxOfflineSpeakerDiarizationConfig()
        cfg.clustering = Self.clustering(numSpeakers: numSpeakers, threshold: options.threshold)
        SherpaOnnxOfflineSpeakerDiarizationSetConfig(diarizer, &cfg)

        let box = ProgressBox(progress)
        let arg = Unmanaged.passUnretained(box).toOpaque()
        let result: OpaquePointer? = withExtendedLifetime(box) {
            SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(diarizer, base, Int32(samples.count), { done, total, arg in
                if let arg, total > 0 {
                    Unmanaged<ProgressBox>.fromOpaque(arg).takeUnretainedValue().f(Double(done) / Double(total))
                }
                return 0
            }, arg)
        }
        guard let result else { throw DiarizerError.modelLoad }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }

        let n = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        var local: [(start: Double, end: Double, speaker: Int)] = []
        if n > 0, let segs = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) {
            defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segs) }
            for i in 0 ..< n {
                let s = segs[i]
                let a = Double(s.start), b = Double(s.end)
                guard a.isFinite, b.isFinite, b > a, s.speaker >= 0 else { continue }
                local.append((a, b, Int(s.speaker)))
            }
        }
        window.turns = local.map { SpeakerTurn(start: offset + $0.start, end: offset + $0.end, speaker: $0.speaker) }
        for t in local { window.speech[t.speaker, default: 0] += t.end - t.start }

        if withEmbeddings {
            for sp in Set(local.map { $0.speaker }) {
                let mine = local.filter { $0.speaker == sp }
                if let e = embedding(of: mine.map { ($0.start, $0.end) }, in: samples) {
                    window.embeddings[sp] = e
                }
            }
        }
        return window
    }

    /// Voice embedding of one speaker from their longest turns (up to 30 s).
    private func embedding(of turns: [(Double, Double)], in samples: UnsafeBufferPointer<Float>) -> [Float]? {
        guard let base = samples.baseAddress else { return nil }
        let rate = Double(Self.sampleRate)
        var picked = turns.filter { $0.1 - $0.0 >= 0.5 }.sorted { ($0.1 - $0.0) > ($1.1 - $1.0) }
        if picked.isEmpty { picked = turns }
        guard let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else { return nil }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        var total = 0.0
        for (a, b) in picked {
            let from = max(0, min(samples.count, Int(a * rate)))
            let to = max(from, min(samples.count, Int(b * rate), from + Int((30 - total) * rate)))
            guard to > from else { continue }
            SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(Self.sampleRate), base + from, Int32(to - from))
            total += Double(to - from) / rate
            if total >= 30 { break }
        }
        guard total > 0 else { return nil }
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) != 0,
              let v = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(v) }
        let dim = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))
        guard dim > 0 else { return nil }
        let e = Array(UnsafeBufferPointer(start: v, count: dim))
        return e.allSatisfy(\.isFinite) ? e : nil
    }
}

// MARK: - Self-test (CI)

extension SpeakerDiarizer {
    /// Downloads the speaker models if needed (network), then diarizes:
    /// 1. the Russian sample as is (one speaker → expect 1);
    /// 2. the sample, 0.5 s of silence, the sample again (same voice → expect 1);
    /// 3. case 2 with 8 s windows, so the cross-window linking path runs
    ///    (expect 1).
    /// Writes `diarization.json` into the `output` folder and returns the
    /// same dictionary. `ok` is true when all expectations hold.
    public static func runSelfTest(wav: URL, output: URL) async -> [String: Any] {
        var report: [String: Any] = ["engine": engineName, "runtime": runtimeVersion]
        var errors: [String] = []
        let store = ModelStore.speakers

        let t0 = Date()
        if !store.isInstalled {
            do {
                try await store.install(progress: { _ in }, isCancelled: { false })
                report["downloadOK"] = true
            } catch {
                report["downloadOK"] = false
                errors.append("download: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
            report["downloadSeconds"] = Date().timeIntervalSince(t0)
        }
        report["installed"] = store.isInstalled
        report["modelBytes"] = store.installedBytes

        if store.isInstalled {
            do {
                let samples = try readMono16k(wav)
                let seconds = Double(samples.count) / Double(sampleRate)
                report["wavSeconds"] = seconds
                let doubled = samples + [Float](repeating: 0, count: sampleRate / 2) + samples

                let t1 = Date()
                let diarizer = try SpeakerDiarizer()
                report["loadSeconds"] = Date().timeIntervalSince(t1)

                func run(_ name: String, _ d: SpeakerDiarizer, _ audio: [Float]) throws {
                    let t = Date()
                    let turns = try d.diarize(samples16k: audio)
                    let elapsed = Date().timeIntervalSince(t)
                    let speakers = Set(turns.map(\.speaker)).count
                    let audioSeconds = Double(audio.count) / Double(sampleRate)
                    report[name] = [
                        "audioSeconds": audioSeconds,
                        "seconds": elapsed,
                        "rtf": audioSeconds > 0 ? elapsed / audioSeconds : 0,
                        "speakers": speakers,
                        "turns": turns.map { String(format: "%.2f–%.2f S%ld", $0.start, $0.end, $0.speaker + 1) },
                    ] as [String: Any]
                    if speakers != 1 { errors.append("\(name): expected 1 speaker, got \(speakers)") }
                }
                try run("single", diarizer, samples)
                try run("doubled", diarizer, doubled)
                var small = SpeakerDiarizer.Options()
                small.windowSeconds = 8
                small.carrySeconds = 0
                let windowed = try SpeakerDiarizer(options: small)
                try run("doubledWindowed", windowed, doubled)
            } catch {
                errors.append("diarize: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }
        report["errors"] = errors
        report["ok"] = errors.isEmpty
        report["totalSeconds"] = Date().timeIntervalSince(t0)

        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("diarization.json"), options: .atomic)
        }
        return report
    }

    /// Any audio file AVFoundation reads → 16 kHz mono Float.
    static func readMono16k(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw DiarizerError.audio(error.localizedDescription) }
        let fmt = file.processingFormat
        let resampler = try MonoResampler(inputRate: fmt.sampleRate, channels: Int(fmt.channelCount),
                                          outputRate: Double(sampleRate))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48_000) else { throw DiarizerError.audio("буфер") }
        var out: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: 48_000)
            if buf.frameLength == 0 { break }
            out += try resampler.process(buf)
        }
        out += try resampler.finish()
        return out
    }
}
