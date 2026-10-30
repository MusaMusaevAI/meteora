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

/// Streaming cubic (Catmull-Rom) resampler for small clock corrections.
/// `step` is the number of input samples consumed per output sample: 1 keeps
/// the rate, 1.001 makes the stream 0.1 % shorter. Latency: two samples.
public struct DriftResampler {
    /// Unconsumed input; `buffer[0]` is the left context of the cubic.
    private var buffer: [Float] = [0]
    /// Read position in `buffer`, always in [1, 2) between calls.
    private var position: Double = 1

    public init() {}

    public mutating func reset() {
        buffer = [0]
        position = 1
    }

    public mutating func process(_ input: UnsafeBufferPointer<Float>, step: Double) -> [Float] {
        buffer.append(contentsOf: input)
        var out: [Float] = []
        out.reserveCapacity(Int(Double(input.count) / max(step, 0.5)) + 4)
        let n = buffer.count
        var p = position
        buffer.withUnsafeBufferPointer { b in
            while true {
                let k = Int(p)
                if k + 2 >= n { break }
                let f = Float(p - Double(k))
                let xm1 = b[k - 1], x0 = b[k], x1 = b[k + 1], x2 = b[k + 2]
                let c = 2 * xm1 - 5 * x0 + 4 * x1 - x2 + f * (3 * (x0 - x1) + x2 - xm1)
                out.append(x0 + 0.5 * f * (x1 - xm1 + f * c))
                p += step
            }
        }
        let consumed = min(Int(p) - 1, buffer.count - 1)
        if consumed > 0 {
            buffer.removeFirst(consumed)
            p -= Double(consumed)
        }
        position = p
        return out
    }
}

/// Mixes one or two mono 48 kHz inputs into fixed-size frames.
///
/// The microphone and the system-audio tap run on different clocks (a
/// Bluetooth headset, a USB microphone, the Mac's own output), so one input
/// slowly gets ahead of the other, and either may stall for a while.
/// - A frame is emitted when every input has a full frame; inputs are summed.
/// - Clock drift is absorbed smoothly: the system input (1) goes through a
///   resampler whose rate follows the difference between the two backlogs, up
///   to ±`maxCorrection` (1 % — inaudible). An input is never cut into pieces
///   with silence in between: the earlier rule did exactly that to the slower
///   input and made the other side of a call unintelligible.
/// - An input that has delivered nothing while the other delivered
///   `stallLimit` samples is stalled: it is silent until it comes back.
/// - An input that piles up more than `maxBacklog` samples loses its oldest
///   samples (counted in `droppedSamples`).
public struct FrameMixer {
    public let frameSize: Int
    public let enabled: [Bool]
    public var gains: [Float]
    public var stallLimit: Int
    public var maxBacklog: Int
    /// Largest clock correction applied to the system input (fraction).
    public var maxCorrection: Double = 0.01
    /// Correction per sample of backlog difference: 1 % at 100 ms.
    public var correctionGain: Double = 0.01 / 4_800
    /// Beyond this difference (500 ms) the sources are realigned at once.
    public var resyncLimit = 24_000
    public private(set) var droppedSamples = 0
    public private(set) var paddedSamples = 0
    /// Current correction of the system input: positive = it is consumed
    /// faster (its clock runs fast against the microphone's).
    public private(set) var driftCorrection: Double = 0

    private var fifos: [SampleFIFO]
    private var sinceLastPush = [0, 0]
    private var smoothedOffset: Double = 0
    private var resampler = DriftResampler()

    /// - Parameters:
    ///   - inputs: which of the two inputs (0 = microphone, 1 = system) take part.
    ///   - frameSize: samples per output frame (960 = 20 ms at 48 kHz).
    ///   - stallLimit: 12 000 = 250 ms of the other input without a word.
    public init(inputs: Set<Int>, frameSize: Int = 960, stallLimit: Int = 12_000, maxBacklog: Int = 480_000) {
        self.frameSize = frameSize
        self.enabled = [inputs.contains(0), inputs.contains(1)]
        self.gains = [1, 1]
        self.stallLimit = stallLimit
        self.maxBacklog = maxBacklog
        self.fifos = [SampleFIFO(), SampleFIFO()]
    }

    private var mixing: Bool { enabled[0] && enabled[1] }

    public func backlog(_ input: Int) -> Int { fifos[input].count }

    /// True while `input` is silent because it stopped delivering.
    public func isStalled(_ input: Int) -> Bool { mixing && sinceLastPush[input] > stallLimit }

    public mutating func push(_ input: Int, _ samples: UnsafeBufferPointer<Float>) {
        guard (0 ... 1).contains(input), enabled[input] else { return }
        if input == 1, mixing {
            let corrected = resampler.process(samples, step: 1 + driftCorrection)
            corrected.withUnsafeBufferPointer { append(1, $0) }
        } else {
            append(input, samples)
        }
        guard mixing else { return }
        sinceLastPush[input] = 0
        sinceLastPush[1 - input] += samples.count
        // The backlog difference only moves with drift: frames take the same
        // amount from both inputs. Smoothed over about a second of pushes.
        if !isStalled(0), !isStalled(1) {
            let difference = Double(fifos[1].count - fifos[0].count)
            smoothedOffset += 0.01 * (difference - smoothedOffset)
            driftCorrection = min(maxCorrection, max(-maxCorrection, correctionGain * smoothedOffset))
            // Far out of step (a source delivered at the wrong rate for a
            // few seconds before it was corrected): line them up at once by
            // giving the late source a moment of silence. Nothing is lost.
            let gap = fifos[1].count - fifos[0].count
            if abs(gap) > resyncLimit {
                fifos[gap < 0 ? 1 : 0].append([Float](repeating: 0, count: abs(gap)))
                paddedSamples += abs(gap)
                smoothedOffset = 0
            }
        }
    }

    public mutating func push(_ input: Int, _ samples: [Float]) {
        samples.withUnsafeBufferPointer { push(input, $0) }
    }

    private mutating func append(_ input: Int, _ samples: UnsafeBufferPointer<Float>) {
        fifos[input].append(samples)
        let excess = fifos[input].count - maxBacklog
        if excess > 0 {
            fifos[input].drop(excess)
            droppedSamples += excess
        }
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
        resampler.reset()
        sinceLastPush = [0, 0]
        smoothedOffset = 0
        driftCorrection = 0
    }

    private mutating func produce(into out: UnsafeMutableBufferPointer<Float>, final: Bool) -> Bool {
        precondition(out.count >= frameSize)
        let active = (0 ... 1).filter { enabled[$0] }
        guard !active.isEmpty else { return false }
        if final {
            guard active.contains(where: { fifos[$0].count > 0 }) else { return false }
        } else {
            var anyFull = false
            for i in active {
                if fifos[i].count >= frameSize {
                    anyFull = true
                } else if !isStalled(i) {
                    return false // it is only a little late: wait for it
                }
            }
            guard anyFull else { return false }
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
