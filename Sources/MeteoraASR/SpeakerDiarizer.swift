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

/// Who spoke when, on the Mac: pyannote segmentation 3.0 + TitaNet voice
/// embeddings + clustering (sherpa-onnx offline speaker diarization, CPU),
/// then a clean-up pass over whole speakers (`SpeakerCleanup`). Nothing
/// leaves the computer.
///
/// Memory: sherpa's offline API needs the whole signal as one Float buffer
/// (2 h at 16 kHz = 460 MB). Instead the audio is streamed and diarized in
/// long windows (10 min by default, the last one up to 13 min so it is never
/// tiny): at most ~13 min of Float samples (~50 MB) are alive at once. Each
/// window's speakers get a voice embedding (up to 30 s of their longest
/// turns) and are joined across windows by `SpeakerLinking`; recordings up
/// to 13 min are diarized in one pass, exactly as sherpa intends.
///
/// Why the clean-up pass: sherpa clusters embeddings of short pieces inside
/// 10 s chunks with complete linkage, so a single odd piece (overlap, a
/// laugh, a change of distance to the microphone) is enough to split one
/// person into two. Embeddings of a speaker's whole speech are far more
/// stable; similar ones are merged, and "speakers" with a few seconds of
/// speech join their nearest voice unless it is clearly someone else.
///
/// Cancellation is checked between windows and while decoding; sherpa
/// itself cannot be interrupted, so stopping takes up to one window's work.
public final class SpeakerDiarizer {
    public static let sampleRate = 16_000
    public static var engineName: String { SpeakerModel.defaultTier.displayName }

    public struct Options: Sendable {
        /// Exact number of speakers (the user knows it); nil = automatic.
        public var numSpeakers: Int?
        /// Never report more speakers than this (meetings up to 10 people).
        public var maxSpeakers: Int
        /// sherpa's clustering distance (1 − cos, complete linkage over
        /// chunk embeddings): pieces join a cluster only if they are within
        /// this distance of every member, so larger → fewer speakers.
        public var threshold: Float
        /// Clean-up: two speakers whose whole-speech embeddings have at least
        /// this cosine similarity are one voice.
        public var mergeSimilarity: Float
        /// Clean-up: recordings shorter than this need stronger evidence for
        /// a second speaker…
        public var shortRecordingSeconds: Double
        /// …i.e. they merge already at this similarity.
        public var shortRecordingMergeSimilarity: Float
        /// Clean-up: a speaker with less speech than this…
        public var minSpeakerSeconds: Double
        /// …or less than this share of all speech is "tiny"…
        public var minSpeakerShare: Double
        /// …and joins the most similar voice unless the similarity is below
        /// this (clearly another person)…
        public var tinyMergeSimilarity: Float
        /// …always, if it has less speech than this (embedding unreliable).
        public var unreliableSeconds: Double
        /// Cross-window linking distance between speaker centroids.
        public var linkThreshold: Float
        /// Speakers separated inside one window are linked only if this close.
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

        /// Calibrated with sherpa-onnx 2.0.1 (the version the app links) on
        /// sherpa's speaker test clips (csukuangfj/sr-data, 3D-Speaker demo
        /// clips) and four real 2- and 4-person recordings from the
        /// sherpa-onnx release `speaker-segmentation-models`: 24 synthetic
        /// meetings with 1–5 people, turns of 2–15 s. TitaNet-S and
        /// TitaNet-L landed on the same values, so both tiers share them.
        /// - sherpa `threshold` 0.7: at 0.5–0.6 single speakers still split
        ///   inside sherpa; at 0.8 two people start sharing one sherpa
        ///   cluster, which no later step can undo.
        /// - whole-speaker cosine: same voice split by sherpa ≥ 0.60 (0.69+
        ///   unless one part is tiny), different people ≤ 0.54 (worst case a
        ///   cluster with 20 % of another voice; real conversations ≤ 0.46)
        ///   → merge at 0.60; 0.57 for recordings under a minute.
        /// - tiny speakers (< 4 s or < 3 % of speech) join the nearest voice
        ///   unless it is below 0.40 (different people with that little
        ///   speech scored 0.13–0.39); under 1.5 s they always join.
        /// Result: 23/24 synthetic meetings (S), 24/24 (L), 4/4 real ones
        /// counted right. The old setup (CAM++, threshold 0.5, no clean-up)
        /// got 7/18 and 1/4 and split 4 of 9 one-person clips, among them
        /// a 30 s one into three speakers.
        public init(tier: SpeakerModelTier = SpeakerModel.defaultTier, numSpeakers: Int? = nil, maxSpeakers: Int = 10) {
            self.numSpeakers = numSpeakers.map { max(1, $0) }
            self.maxSpeakers = max(1, maxSpeakers)
            let merge: Float
            switch tier {
            case .standard, .accurate:
                threshold = 0.7
                merge = 0.6
                shortRecordingMergeSimilarity = 0.57
                tinyMergeSimilarity = 0.4
            }
            mergeSimilarity = merge
            shortRecordingSeconds = 60
            minSpeakerSeconds = 4
            minSpeakerShare = 0.03
            unreliableSeconds = 1.5
            linkThreshold = 1 - merge
            sameWindowLinkThreshold = 1 - merge
            windowSeconds = 600
            carrySeconds = 180
            windowShiftRatio = 0.25
            minDurationOn = 0.3
            minDurationOff = 0.5
            threads = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 1))
        }

        /// The clean-up rules for a recording.
        public var cleanupRules: SpeakerCleanup.Rules {
            SpeakerCleanup.Rules(numSpeakers: numSpeakers, maxSpeakers: maxSpeakers,
                                 mergeSimilarity: mergeSimilarity,
                                 shortRecordingSeconds: shortRecordingSeconds,
                                 shortRecordingMergeSimilarity: shortRecordingMergeSimilarity,
                                 minSpeakerSeconds: minSpeakerSeconds, minSpeakerShare: minSpeakerShare,
                                 tinyMergeSimilarity: tinyMergeSimilarity, unreliableSeconds: unreliableSeconds)
        }
    }

    public let tier: SpeakerModelTier
    public let options: Options
    private let diarizer: OpaquePointer
    private let extractor: OpaquePointer

    /// - Parameters:
    ///   - tier: which voice model to use (must be installed).
    ///   - options: nil = the values calibrated for `tier`.
    public init(tier: SpeakerModelTier = SpeakerModel.defaultTier, options: Options? = nil) throws {
        guard tier.isInstalled else { throw DiarizerError.notInstalled }
        let options = options ?? Options(tier: tier)
        self.tier = tier
        self.options = options
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }
        let segmentation = ModelStore.speakerSegmentation.path(SpeakerModel.segmentationFile).path
        let embedding = tier.store.path(tier.embeddingFile.name).path

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
                                               numSpeakers: single ? owner.options.numSpeakers : nil) { [unowned self] f in
                    self.progress(windowCount: count, fraction: f)
                }
            }
            if isCancelled() { throw DiarizerError.cancelled }
            windows.append(window)
            consumed += count
            progress(windowCount: 0, fraction: 0)
        }

        /// Joins window-local speakers into recording-wide ones, then cleans
        /// them up (`SpeakerCleanup`).
        private func link() -> [SpeakerTurn] {
            let opts = owner.options
            // 1. Window-local speaker → linked speaker.
            var linked: [[Int: Int]] = windows.map { _ in [:] }
            var count = 0
            if windows.count == 1 {
                for s in Set(windows[0].turns.map(\.speaker)).sorted() {
                    linked[0][s] = count
                    count += 1
                }
            } else {
                var items: [SpeakerLinking.Item] = []
                var keys: [(w: Int, s: Int)] = []
                for (wi, w) in windows.enumerated() {
                    for (s, e) in w.embeddings.sorted(by: { $0.key < $1.key }) {
                        items.append(SpeakerLinking.Item(window: wi, embedding: e, weight: w.speech[s] ?? 1))
                        keys.append((wi, s))
                    }
                }
                let labels = SpeakerLinking.cluster(items, numSpeakers: opts.numSpeakers,
                                                    threshold: opts.linkThreshold,
                                                    sameWindowThreshold: opts.sameWindowLinkThreshold)
                for (k, l) in zip(keys, labels) { linked[k.w][k.s] = l }
                count = (labels.max() ?? -1) + 1
                // Speakers without an embedding (very little speech) become
                // their own entries; the clean-up joins them to someone.
                for (wi, w) in windows.enumerated() {
                    for s in Set(w.turns.map(\.speaker)).sorted() where linked[wi][s] == nil {
                        linked[wi][s] = count
                        count += 1
                    }
                }
            }
            guard count > 0 else { return [] }

            // 2. Whole-speaker embeddings (speech-weighted) and speech time.
            var sums: [[Float]?] = Array(repeating: nil, count: count)
            var seconds = [Double](repeating: 0, count: count)
            for (wi, w) in windows.enumerated() {
                for (s, g) in linked[wi] {
                    let speech = w.speech[s] ?? 0
                    seconds[g] += speech
                    guard let e = w.embeddings[s] else { continue }
                    let weight = Float(max(speech, 0.01))
                    let v = SpeakerLinking.normalized(e).map { $0 * weight }
                    if var acc = sums[g] {
                        for k in acc.indices where k < v.count { acc[k] += v[k] }
                        sums[g] = acc
                    } else {
                        sums[g] = v
                    }
                }
            }
            let speakers = (0 ..< count).map { SpeakerCleanup.Speaker(embedding: sums[$0], seconds: seconds[$0]) }
            let duration = Double(consumed) / Double(SpeakerDiarizer.sampleRate)
            let plan = SpeakerCleanup.plan(speakers, recordingSeconds: duration, rules: opts.cleanupRules)

            // 3. Turns with final speakers, numbered by first appearance.
            var turns: [SpeakerTurn] = []
            for (wi, w) in windows.enumerated() {
                for t in w.turns {
                    if let g = linked[wi][t.speaker], g < plan.count {
                        turns.append(SpeakerTurn(start: t.start, end: t.end, speaker: plan[g]))
                    }
                }
            }
            turns.sort { $0.start != $1.start ? $0.start < $1.start : $0.speaker < $1.speaker }
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

    /// Runs sherpa's offline diarization on one window and computes one
    /// voice embedding per local speaker (for linking and clean-up).
    private func diarizeWindow(_ samples: UnsafeBufferPointer<Float>, index: Int, offset: Double,
                               numSpeakers: Int?,
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

        for sp in Set(local.map { $0.speaker }) {
            let mine = local.filter { $0.speaker == sp }
            if let e = embedding(of: mine.map { ($0.start, $0.end) }, in: samples) {
                window.embeddings[sp] = e
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

/// Real voices of three different people for the multi-speaker self-test:
/// sherpa-onnx's speaker-identification test set (github.com/csukuangfj/sr-data,
/// Apache-2.0), 2–8 s clips at 16 kHz. Fetched from raw.githubusercontent.com
/// at a fixed commit, so the content cannot change; every file's size and
/// SHA-256 is pinned below (computed from that commit's checkout and
/// matching its git blob ids) and checked before use.
enum SpeakerTestClips {
    struct Clip {
        let path: String
        let size: Int64
        let sha256: String
    }

    static let commit = "92b4978ba6b4358e95be385e51e86ece86524d33"
    static let base = "https://raw.githubusercontent.com/csukuangfj/sr-data/\(commit)/"

    /// "A", "B", "C" = three different men, Mandarin; 18 s, 28 s, 14 s.
    static let speakers: [String: [Clip]] = [
        "A": [
            Clip(path: "enroll/fangjun-sr-1.wav", size: 73_606, sha256: "33c24061180224d2350143ee19e3af031446995c676bd25996325d34bb20a4d5"),
            Clip(path: "enroll/fangjun-sr-2.wav", size: 165_370, sha256: "c9209ff0cc83cb3c30b3efb376cec6df93f33ceb0f3c1a8eb28fced7a8d08409"),
            Clip(path: "enroll/fangjun-sr-3.wav", size: 90_324, sha256: "5a5f2fc98cb95cde4e457c31349dcbd5cf7ec2567528aac11487aa3884795bd8"),
            Clip(path: "test/fangjun-test-sr-1.wav", size: 178_374, sha256: "9175e523081bf6a630ce72a55b05f92148eaafaf58cbbbe743686cd81c50848e"),
            Clip(path: "test/fangjun-test-sr-2.wav", size: 69_890, sha256: "c55912144a28817a67d5eac806e5952ffcd29b82db3925f46d33df4c5f038907"),
        ],
        "B": [
            Clip(path: "enroll/leijun-sr-1.wav", size: 134_474, sha256: "160a3d9bf5dd5038da8191b4430e1f3f751461613ae9489401b6b35a61b488ad"),
            Clip(path: "enroll/leijun-sr-2.wav", size: 152_368, sha256: "37a759c036f2520d143708dfe46d45901b38a0a6e621b52d6f1aef2c000d7fe0"),
            Clip(path: "test/leijun-test-sr-1.wav", size: 263_878, sha256: "36cda04ee4d10e38095de73b77c99e8e7c54347232967a9cde4cf54f7d496bab"),
            Clip(path: "test/leijun-test-sr-2.wav", size: 217_872, sha256: "84b85e7413b5348303a95bd78813e4d669b4dc70fa5a99990b9860ca6fda91e8"),
            Clip(path: "test/leijun-test-sr-3.wav", size: 138_064, sha256: "ef026f55e457780fc066b0f5d22d944e102690b2d77c7c0536e8d84f55a034a8"),
        ],
        "C": [
            Clip(path: "enroll/liudehua-sr-1.wav", size: 95_390, sha256: "f39ebb7357d537009a9b7e59a6c9c0199f2204fcffb3c2d9d829a6961813eca1"),
            Clip(path: "enroll/liudehua-sr-2.wav", size: 126_406, sha256: "0f0afddb99d381a23c899f464864f692dc21190cebbd4edf4ff695e10a107c9c"),
            Clip(path: "test/liudehua-test-sr-1.wav", size: 119_442, sha256: "a855706ad8e8253e341e3f65892c66d7dfb4bdc83675bcf38b863f2f8d167553"),
            Clip(path: "test/liudehua-test-sr-2.wav", size: 97_552, sha256: "2c9ba09e7fe9deca8bea0b67776c39665cad3a1036e7a8d3407d1e45e2ede23a"),
        ],
    ]

    /// Downloads (or reuses) every clip and returns 16 kHz samples by speaker.
    static func load(cache: URL) async throws -> [String: [[Float]]] {
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        var out: [String: [[Float]]] = [:]
        for (name, clips) in speakers {
            var list: [[Float]] = []
            for clip in clips {
                let dest = cache.appendingPathComponent(clip.path.replacingOccurrences(of: "/", with: "_"))
                if (try? ModelStore.sha256(of: dest)) != clip.sha256 {
                    try? fm.removeItem(at: dest)
                    guard let url = URL(string: base + clip.path) else { throw ModelError.network(clip.path) }
                    let tmp = try await Downloader.download(url, expectedSize: clip.size, isCancelled: { false }, progress: { _ in })
                    guard try ModelStore.sha256(of: tmp) == clip.sha256 else {
                        try? fm.removeItem(at: tmp)
                        throw ModelError.integrity(clip.path)
                    }
                    try fm.moveItem(at: tmp, to: dest)
                }
                list.append(try SpeakerDiarizer.readMono16k(dest))
            }
            out[name] = list
        }
        return out
    }

    /// Clips in order with 0.4 s of silence after each; returns the audio
    /// and the true turns (one per clip).
    static func compose(_ seq: [(String, Int)], from clips: [String: [[Float]]]) -> (audio: [Float], truth: [(start: Double, end: Double, speaker: String)]) {
        let rate = Double(SpeakerDiarizer.sampleRate)
        let gap = [Float](repeating: 0, count: Int(0.4 * rate))
        var audio: [Float] = []
        var truth: [(start: Double, end: Double, speaker: String)] = []
        for (speaker, index) in seq {
            guard let list = clips[speaker], index < list.count else { continue }
            let start = Double(audio.count) / rate
            audio += list[index]
            truth.append((start: start, end: Double(audio.count) / rate, speaker: speaker))
            audio += gap
        }
        return (audio, truth)
    }

    /// How well `turns` match `truth` (10 ms frames, best one-to-one
    /// mapping of speakers by overlap):
    /// - confusion: share of true speech that hypothesis covers but gives
    ///   to the wrong speaker;
    /// - missed: share of true speech no turn covers (clip edges are
    ///   partly silence, so 0.1–0.2 is normal);
    /// - boundaryError: mean distance, seconds, from each true change of
    ///   speaker to the nearest found change (nil without true changes).
    static func score(_ turns: [SpeakerTurn], truth: [(start: Double, end: Double, speaker: String)]) -> [String: Any] {
        let step = 0.01
        let end = max(truth.map { $0.end }.max() ?? 0, turns.map { $0.end }.max() ?? 0)
        guard end.isFinite, end > 0 else { return [:] }
        let n = Int(end / step) + 1
        func frames(_ a: Double, _ b: Double) -> StrideTo<Int> {
            stride(from: max(0, Int(a / step)), to: min(n, Int(max(0, b) / step)), by: 1)
        }
        var ref = [String?](repeating: nil, count: n)
        var hyp = [Set<Int>](repeating: [], count: n)
        for t in truth { for i in frames(t.start, t.end) { ref[i] = t.speaker } }
        for t in turns where t.start.isFinite && t.end.isFinite { for i in frames(t.start, t.end) { hyp[i].insert(t.speaker) } }

        var overlap: [String: [Int: Int]] = [:]
        for i in 0 ..< n { if let r = ref[i] { for h in hyp[i] { overlap[r, default: [:]][h, default: 0] += 1 } } }
        var mapping: [String: Int] = [:]
        var usedHyp = Set<Int>()
        var pairs: [(r: String, h: Int, c: Int)] = []
        for (r, row) in overlap { for (h, c) in row { pairs.append((r, h, c)) } }
        pairs.sort { $0.c != $1.c ? $0.c > $1.c : ($0.r != $1.r ? $0.r < $1.r : $0.h < $1.h) }
        for p in pairs where mapping[p.r] == nil && !usedHyp.contains(p.h) {
            mapping[p.r] = p.h
            usedHyp.insert(p.h)
        }

        var speech = 0, missed = 0, wrong = 0
        for i in 0 ..< n {
            guard let r = ref[i] else { continue }
            speech += 1
            if hyp[i].isEmpty {
                missed += 1
            } else if let m = mapping[r], hyp[i].contains(m) {
                continue
            } else {
                wrong += 1
            }
        }
        var trueChanges: [Double] = []
        for k in 1 ..< max(1, truth.count) where truth[k].speaker != truth[k - 1].speaker {
            trueChanges.append((truth[k - 1].end + truth[k].start) / 2)
        }
        let sorted = turns.sorted { $0.start < $1.start }
        var found: [Double] = []
        for k in 1 ..< max(1, sorted.count) where sorted[k].speaker != sorted[k - 1].speaker {
            found.append(sorted[k].start)
        }
        var out: [String: Any] = [
            "confusion": speech > 0 ? Double(wrong) / Double(speech) : 0,
            "missed": speech > 0 ? Double(missed) / Double(speech) : 0,
            "trueChanges": trueChanges.count,
            "foundChanges": found.count,
        ]
        if !trueChanges.isEmpty {
            let distances = trueChanges.map { c in found.map { abs($0 - c) }.min() ?? end }
            out["boundaryError"] = distances.reduce(0, +) / Double(distances.count)
        }
        return out
    }
}

extension SpeakerDiarizer {
    /// Downloads the speaker models if needed (network) and checks, for each
    /// tier in `tiers` (the accurate one only if its download succeeds):
    /// 1. the Russian sample `wav` as is, twice in a row, and twice with 8 s
    ///    windows (cross-window linking) → 1 speaker each;
    /// 2. one person's five clips, 30 s (the case that used to split) → 1;
    ///    another person's clips played forwards then backwards, 36 s → 1;
    /// 3. two people taking turns (A A A B B A A B B B, 50 s) → 2, also
    ///    with the count given explicitly;
    /// 4. three people (66 s) → 3;
    /// 5. case 4 with 30 s windows → 3 (reported only: `warnings`).
    /// Every case reports turns, real-time factor and, where the truth is
    /// known, confusion / missed speech / boundary error (`score`).
    /// Writes `diarization.json` into `output` and returns the same
    /// dictionary; `ok` is true when every required expectation holds.
    public static func runSelfTest(wav: URL, output: URL,
                                   tiers: [SpeakerModelTier] = SpeakerModelTier.allCases) async -> [String: Any] {
        var report: [String: Any] = ["engine": engineName, "runtime": runtimeVersion]
        var errors: [String] = []
        var warnings: [String] = []
        let t0 = Date()

        // Test voices (small, from GitHub at a pinned commit).
        var clips: [String: [[Float]]] = [:]
        do {
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent("meteora-speaker-clips", isDirectory: true)
            clips = try await SpeakerTestClips.load(cache: cache)
            report["clipsOK"] = true
        } catch {
            report["clipsOK"] = false
            errors.append("test clips: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        var russian: [Float] = []
        do {
            russian = try readMono16k(wav)
            report["wavSeconds"] = Double(russian.count) / Double(sampleRate)
        } catch {
            errors.append("wav: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }

        for tier in tiers {
            var r: [String: Any] = ["model": tier.displayName, "bytes": tier.totalSize]
            let required = tier == SpeakerModel.defaultTier
            if !tier.isInstalled {
                let t = Date()
                do {
                    try await tier.install(progress: { _ in }, isCancelled: { false })
                    r["downloadOK"] = true
                } catch {
                    r["downloadOK"] = false
                    let msg = "\(tier.rawValue) download: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                    if required { errors.append(msg) } else { warnings.append(msg) }
                }
                r["downloadSeconds"] = Date().timeIntervalSince(t)
            }
            r["installed"] = tier.isInstalled
            guard tier.isInstalled else { report[tier.rawValue] = r; continue }

            do {
                let t1 = Date()
                let diarizer = try SpeakerDiarizer(tier: tier)
                r["loadSeconds"] = Date().timeIntervalSince(t1)

                func run(_ name: String, _ d: SpeakerDiarizer, _ audio: [Float], expect: Int,
                         truth: [(start: Double, end: Double, speaker: String)]? = nil, soft: Bool = false) throws {
                    guard !audio.isEmpty else { return }
                    let t = Date()
                    let turns = try d.diarize(samples16k: audio)
                    let elapsed = Date().timeIntervalSince(t)
                    let speakers = Set(turns.map(\.speaker)).count
                    let audioSeconds = Double(audio.count) / Double(sampleRate)
                    var c: [String: Any] = [
                        "audioSeconds": audioSeconds,
                        "seconds": elapsed,
                        "rtf": audioSeconds > 0 ? elapsed / audioSeconds : 0,
                        "speakers": speakers,
                        "expected": expect,
                        "countOK": speakers == expect,
                        "turns": turns.map { String(format: "%.2f–%.2f S%ld", $0.start, $0.end, $0.speaker + 1) },
                    ]
                    if let truth { c["score"] = SpeakerTestClips.score(turns, truth: truth) }
                    r[name] = c
                    if speakers != expect {
                        let msg = "\(tier.rawValue) \(name): expected \(expect) speaker(s), got \(speakers)"
                        if soft { warnings.append(msg) } else { errors.append(msg) }
                    }
                }

                // 1. Russian sample.
                if !russian.isEmpty {
                    let doubled = russian + [Float](repeating: 0, count: sampleRate / 2) + russian
                    try run("single", diarizer, russian, expect: 1)
                    try run("doubled", diarizer, doubled, expect: 1)
                    var small = Options(tier: tier)
                    small.windowSeconds = 8
                    small.carrySeconds = 0
                    try run("doubledWindowed", try SpeakerDiarizer(tier: tier, options: small), doubled, expect: 1)
                }

                // 2–5. Different real voices.
                if !clips.isEmpty {
                    let allB: [(String, Int)] = (0 ..< 5).map { ("B", $0) }
                    let one = SpeakerTestClips.compose(allB, from: clips)
                    try run("oneSpeaker30s", diarizer, one.audio, expect: 1, truth: one.truth)
                    let allA: [(String, Int)] = (0 ..< 5).map { ("A", $0) }
                    let twice = SpeakerTestClips.compose(allA + Array(allA.reversed()), from: clips)
                    try run("oneSpeakerTwice", diarizer, twice.audio, expect: 1, truth: twice.truth)

                    let two = SpeakerTestClips.compose([("A", 0), ("A", 1), ("A", 2), ("B", 0), ("B", 1),
                                                        ("A", 3), ("A", 4), ("B", 2), ("B", 3), ("B", 4)], from: clips)
                    try run("twoSpeakers", diarizer, two.audio, expect: 2, truth: two.truth)
                    let exact = try SpeakerDiarizer(tier: tier, options: Options(tier: tier, numSpeakers: 2))
                    try run("twoSpeakersExact", exact, two.audio, expect: 2, truth: two.truth)

                    let three = SpeakerTestClips.compose([("A", 0), ("A", 1), ("B", 0), ("B", 1), ("C", 0), ("C", 1),
                                                          ("A", 2), ("A", 3), ("A", 4), ("B", 2), ("B", 3), ("B", 4),
                                                          ("C", 2), ("C", 3)], from: clips)
                    try run("threeSpeakers", diarizer, three.audio, expect: 3, truth: three.truth)
                    var windows = Options(tier: tier)
                    windows.windowSeconds = 30
                    windows.carrySeconds = 0
                    try run("threeSpeakersWindowed", try SpeakerDiarizer(tier: tier, options: windows), three.audio,
                            expect: 3, truth: three.truth, soft: true)
                }
            } catch {
                errors.append("\(tier.rawValue) diarize: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
            report[tier.rawValue] = r
        }
        report["errors"] = errors
        report["warnings"] = warnings
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
