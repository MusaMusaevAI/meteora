import Foundation

/// A tiny grayscale thumbnail of a video frame used to compare frames.
public struct FrameThumb: Equatable, Sendable {
    public static let width = 64
    public static let height = 40
    public var luma: [UInt8]

    public init?(luma: [UInt8]) {
        guard luma.count == FrameThumb.width * FrameThumb.height else { return nil }
        self.luma = luma
    }

    /// Fraction (0…1) of pixels whose brightness changed noticeably.
    public func changedFraction(to other: FrameThumb) -> Double {
        var changed = 0
        for i in 0 ..< luma.count where abs(Int(luma[i]) - Int(other.luma[i])) > 24 { changed += 1 }
        return Double(changed) / Double(luma.count)
    }

    /// True for black/flat frames (connecting screen, fade, etc.).
    public var isBlank: Bool {
        let n = Double(luma.count)
        let mean = luma.reduce(0.0) { $0 + Double($1) } / n
        let variance = luma.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / n
        return variance < 9
    }
}

/// Chooses the moments of a recording worth looking at, using only the
/// structure of the compressed stream (no decoding):
/// - keyframes: the encoder emits them periodically and the decoder can jump
///   to them instantly, so sampling them is cheap;
/// - very large inter-frames ("spikes"): a big chunk of the picture changed
///   (new slide, switched window) — used to date a change precisely and, in
///   thorough mode, to catch slides shown only briefly between keyframes.
public enum ScenePlanner {
    public static let minSpacing = 4.0
    public static let maxGap = 20.0
    public static let maxSamples = 5_000

    public static func primaryTimes(packets: [VideoPacket], duration: Double) -> [Double] {
        var times: [Double] = []
        var last = -Double.infinity
        for p in packets where p.isKey && p.time >= 0 {
            if p.time - last >= minSpacing {
                times.append(p.time)
                last = p.time
            }
        }
        if times.isEmpty { times = [0] }
        // Fill long stretches without keyframes with evenly spaced points.
        var filled: [Double] = []
        let ends = times + [max(min(duration, 48 * 3600) - 0.5, times.last!)]
        for (a, b) in zip(ends, ends.dropFirst()) {
            filled.append(a)
            let gap = b - a
            if gap > maxGap {
                let steps = min(Int((gap / maxGap).rounded(.up)), maxSamples)
                for k in 1 ..< steps { filled.append(a + gap * Double(k) / Double(steps)) }
            }
        }
        if let lastEnd = ends.last, lastEnd - (filled.last ?? 0) >= minSpacing { filled.append(lastEnd) }
        if filled.count > maxSamples {
            // Thin out evenly rather than run for hours.
            let step = Double(filled.count) / Double(maxSamples)
            filled = (0 ..< maxSamples).map { filled[min(filled.count - 1, Int(Double($0) * step))] }
        }
        return filled
    }

    /// Times of unusually large inter-frames. Spikes within 0.3 s after a
    /// keyframe are ignored (encoders often refresh reference frames there).
    public static func spikes(packets: [VideoPacket], width: Int, height: Int) -> [Double] {
        let floor = max(6_000, Int(Double(width * height) * 0.006))
        var window: [Int] = []
        window.reserveCapacity(64)
        var lastKey = -Double.infinity
        var result: [Double] = []
        for p in packets {
            if p.isKey { lastKey = p.time; continue }
            if window.count >= 20 {
                let median = window.sorted()[window.count / 2]
                if p.size > max(10 * median, floor), p.time - lastKey > 0.3 {
                    if let last = result.last, p.time - last < 2 { /* same burst */ } else { result.append(p.time) }
                }
            }
            window.append(p.size)
            if window.count > 60 { window.removeFirst() }
        }
        return result
    }

    /// The most likely moment of a change between two samples.
    public static func changeTime(between a: Double, and b: Double, spikes: [Double]) -> Double {
        spikes.last { $0 > a && $0 <= b } ?? b
    }

    /// Extra sample points for thorough mode: one per interval that
    /// contains a spike, shortly after it (when the picture has settled).
    public static func secondaryTimes(primary: [Double], spikes: [Double]) -> [Double] {
        var out: [Double] = []
        for (a, b) in zip(primary, primary.dropFirst()) {
            for s in spikes where s > a && s < b {
                let t = s + 1.2
                if t < b - 0.5, (out.last ?? -1) < s { out.append(t) }
            }
        }
        return out
    }
}

/// Decides which sampled frames become "key frames" of the meeting.
public final class SceneCollector {
    public struct Kept: Sendable {
        public var sampleTime: Double
        public var changeTime: Double
        public var thumb: FrameThumb
    }

    /// Fraction of the picture that must change to count as a new scene.
    public var threshold: Double
    public private(set) var kept: [Kept] = []
    private var previousSampleTime: Double?

    public init(threshold: Double = 0.06) {
        self.threshold = threshold
    }

    /// Returns the change time if the frame should be kept.
    public func consider(time: Double, thumb: FrameThumb, spikes: [Double]) -> Double? {
        defer { previousSampleTime = time }
        if thumb.isBlank { return nil }
        guard let last = kept.last else {
            kept.append(Kept(sampleTime: time, changeTime: time, thumb: thumb))
            return time
        }
        guard thumb.changedFraction(to: last.thumb) > threshold else { return nil }
        // Don't repeat a slide that was already captured recently.
        for k in kept.suffix(30) where thumb.changedFraction(to: k.thumb) < threshold / 2 { return nil }
        let change = ScenePlanner.changeTime(between: previousSampleTime ?? last.sampleTime, and: time, spikes: spikes)
        kept.append(Kept(sampleTime: time, changeTime: change, thumb: thumb))
        return change
    }

    /// Forget a kept frame (e.g. it turned out to contain no text).
    public func dropLast() { _ = kept.popLast() }
}

// MARK: - Formatting helpers

public enum Timecode {
    public static func string(_ seconds: Double, alwaysHours: Bool = false) -> String {
        guard seconds.isFinite else { return "--:--" }
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 || alwaysHours { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    public static func fileSafe(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d-%02d-%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

public enum FileSizeText {
    public static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }
}

/// Word-level similarity of two OCR texts (0…1).
public func textSimilarity(_ a: String, _ b: String) -> Double {
    func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }
    let wa = words(a), wb = words(b)
    if wa.isEmpty && wb.isEmpty { return 1 }
    let inter = wa.intersection(wb).count
    let union = wa.union(wb).count
    return union == 0 ? 0 : Double(inter) / Double(union)
}

/// Strips file names down to something safe to show and to reuse as a base
/// name for exported files.
public func sanitizedBaseName(_ url: URL) -> String {
    var name = url.deletingPathExtension().lastPathComponent
    let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\0").union(.controlCharacters).union(.newlines)
    name = name.components(separatedBy: bad).joined(separator: " ")
    name = name.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
    // Remove bidi overrides and other invisible format characters.
    name = String(name.unicodeScalars.filter { $0.properties.generalCategory != .format }.map(Character.init))
    if name.isEmpty { name = "Запись" }
    // Keep room for suffixes: file names are limited to 255 bytes.
    while name.utf8.count > 150 { name.removeLast() }
    return name
}
