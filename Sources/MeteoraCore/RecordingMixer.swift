import Foundation

// Pure DSP for the meeting recorder: no audio APIs, so it can be unit-tested.
// Everything here is single-threaded — the recorder calls it from one serial
// processing queue, never from a real-time audio thread.

/// A growable first-in first-out buffer of mono Float samples.
public struct SampleFIFO {
    private var storage: [Float] = []
    private var head = 0

    public init() {}

    public var count: Int { storage.count - head }

    public mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        storage.append(contentsOf: samples)
    }

    public mutating func append(_ samples: [Float]) {
        storage.append(contentsOf: samples)
    }

    /// Copies up to `count` samples into `out` and removes them. Returns how
    /// many were copied.
    @discardableResult
    public mutating func read(into out: UnsafeMutablePointer<Float>, count wanted: Int) -> Int {
        let n = min(wanted, count)
        guard n > 0 else { return 0 }
        storage.withUnsafeBufferPointer { src in
            out.update(from: src.baseAddress! + head, count: n)
        }
        drop(n)
        return n
    }

    /// Removes the oldest `n` samples.
    public mutating func drop(_ n: Int) {
        head += min(n, count)
        // Compact now and then so the array doesn't grow forever.
        if head >= 48_000, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

/// Mixes one or two mono 48 kHz inputs into fixed-size frames.
///
/// The microphone and the system-audio tap run on different clocks, so one
/// input slowly gets ahead of the other and either may stall (a Bluetooth
/// hiccup, a device switch). The rule is simple and never blocks:
/// - when both inputs have a full frame, they are summed;
/// - when the leading input is more than `lagTolerance` samples ahead and the
///   other has run dry, the frame is emitted anyway and the missing part of the
///   lagging input is silence;
/// - an input that piles up more than `maxBacklog` samples loses its oldest
///   samples (counted in `droppedSamples`).
public struct FrameMixer {
    public let frameSize: Int
    public let enabled: [Bool]
    public var gains: [Float]
    public var lagTolerance: Int
    public var maxBacklog: Int
    public private(set) var droppedSamples = 0
    public private(set) var paddedSamples = 0

    private var fifos: [SampleFIFO]

    /// - Parameters:
    ///   - inputs: which of the two inputs (0, 1) take part.
    ///   - frameSize: samples per output frame (960 = 20 ms at 48 kHz).
    public init(inputs: Set<Int>, frameSize: Int = 960, lagTolerance: Int = 14_400, maxBacklog: Int = 480_000) {
        self.frameSize = frameSize
        self.enabled = [inputs.contains(0), inputs.contains(1)]
        self.gains = [1, 1]
        self.lagTolerance = lagTolerance
        self.maxBacklog = maxBacklog
        self.fifos = [SampleFIFO(), SampleFIFO()]
    }

    public func backlog(_ input: Int) -> Int { fifos[input].count }

    public mutating func push(_ input: Int, _ samples: UnsafeBufferPointer<Float>) {
        guard (0 ... 1).contains(input), enabled[input] else { return }
        fifos[input].append(samples)
        let excess = fifos[input].count - maxBacklog
        if excess > 0 {
            fifos[input].drop(excess)
            droppedSamples += excess
        }
    }

    public mutating func push(_ input: Int, _ samples: [Float]) {
        samples.withUnsafeBufferPointer { push(input, $0) }
    }

    /// Produces the next frame into `out` (at least `frameSize` long) if
    /// enough input is buffered.
    public mutating func nextFrame(into out: UnsafeMutableBufferPointer<Float>) -> Bool {
        produce(into: out, final: false)
    }

    /// At the end of a recording: emits what is left, padded with silence.
    public mutating func nextFinalFrame(into out: UnsafeMutableBufferPointer<Float>) -> Bool {
        produce(into: out, final: true)
    }

    public mutating func reset() {
        fifos[0].removeAll()
        fifos[1].removeAll()
    }

    private mutating func produce(into out: UnsafeMutableBufferPointer<Float>, final: Bool) -> Bool {
        precondition(out.count >= frameSize)
        let active = (0 ... 1).filter { enabled[$0] }
        guard !active.isEmpty else { return false }
        let counts = active.map { fifos[$0].count }
        let most = counts.max() ?? 0
        if final {
            guard most > 0 else { return false }
        } else {
            let allFull = counts.allSatisfy { $0 >= frameSize }
            let leaderFarAhead = most >= frameSize + lagTolerance
            guard allFull || (most >= frameSize && (active.count == 1 || leaderFarAhead)) else { return false }
        }

        let base = out.baseAddress!
        base.update(repeating: 0, count: frameSize)
        var input = [Float](repeating: 0, count: frameSize)
        for i in active {
            let got = input.withUnsafeMutableBufferPointer { buf in fifos[i].read(into: buf.baseAddress!, count: frameSize) }
            if got < frameSize { paddedSamples += frameSize - got }
            let g = gains[i]
            for k in 0 ..< got { base[k] += input[k] * g }
        }
        for k in 0 ..< frameSize { base[k] = Self.softLimit(base[k]) }
        return true
    }

    // MARK: Helpers

    /// Soft limiter: transparent below −1 dBFS, smooth saturation above.
    @inline(__always)
    public static func softLimit(_ x: Float) -> Float {
        let t: Float = 0.89
        let a = abs(x)
        if a <= t { return x }
        let y = t + (1 - t) * tanh((a - t) / (1 - t))
        return x < 0 ? -y : y
    }

    public static func peak(_ samples: UnsafeBufferPointer<Float>) -> Float {
        var p: Float = 0
        for s in samples { p = max(p, abs(s)) }
        return p
    }

    /// Maps a linear peak to a 0…1 meter value on a −60…0 dBFS scale.
    public static func meterLevel(peak: Float) -> Float {
        guard peak > 0.001 else { return 0 }
        let db = 20 * log10(min(1, peak))
        return max(0, min(1, (db + 60) / 60))
    }
}
