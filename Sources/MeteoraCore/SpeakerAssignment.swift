import Foundation

/// One stretch of speech by one speaker, as found by speaker separation.
/// `speaker` is a 0-based index local to one diarization result.
public struct SpeakerTurn: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: Int

    public init(start: Double, end: Double, speaker: Int) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }

    public var duration: Double { end - start }
}

/// Turns diarization output into labelled transcript phrases.
/// Pure logic: no models, no audio — fully unit-tested.
public enum SpeakerAssignment {
    /// Turns shorter than this are treated as noise and absorbed by neighbours.
    public static let defaultMinTurn = 0.7
    /// Same-speaker turns separated by at most this pause become one turn.
    public static let defaultMaxGap = 0.5
    /// A phrase that overlaps no turn takes the nearest turn within this distance.
    public static let defaultMaxDistance = 2.0

    /// "Спикер 1", "Спикер 2"… for a 0-based number.
    public static func label(_ number: Int) -> String { "Спикер \(number + 1)" }

    /// Sorts, joins same-speaker fragments separated by short pauses and
    /// removes micro-turns (< `minTurn`), letting the surrounding speaker
    /// continue across them. Never returns an empty list for non-empty input.
    public static func smooth(_ turns: [SpeakerTurn], minTurn: Double = defaultMinTurn,
                              maxGap: Double = defaultMaxGap) -> [SpeakerTurn] {
        let valid = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.speaker < $1.speaker }
        guard valid.count > 1 else { return valid }

        // 1. Join fragments of the same speaker first, so two 0.4 s pieces of
        //    one phrase are not mistaken for two micro-turns.
        func join(_ list: [SpeakerTurn]) -> [SpeakerTurn] {
            var out: [SpeakerTurn] = []
            for t in list {
                if let last = out.last, last.speaker == t.speaker, t.start - last.end <= maxGap {
                    out[out.count - 1].end = max(last.end, t.end)
                } else {
                    out.append(t)
                }
            }
            return out
        }
        let joined = join(valid)

        // 2. Drop micro-turns; a speaker interrupted only by micro-turns
        //    continues through them.
        var out: [SpeakerTurn] = []
        var bridged = false
        for t in joined {
            if t.duration < minTurn { bridged = true; continue }
            if let last = out.last, last.speaker == t.speaker, bridged || t.start - last.end <= maxGap {
                out[out.count - 1].end = max(last.end, t.end)
            } else {
                out.append(t)
            }
            bridged = false
        }
        return out.isEmpty ? joined : out
    }

    /// Labels every phrase with the speaker it overlaps most. Speakers are
    /// named «Спикер 1», «Спикер 2»… in order of their first phrase; a
    /// speaker without phrases does not take a number. `names` (label → name)
    /// is applied on top, see `rename`.
    public static func assign(_ turns: [SpeakerTurn], to segments: [TranscriptSegment],
                              names: [String: String] = [:],
                              minTurn: Double = defaultMinTurn,
                              maxGap: Double = defaultMaxGap,
                              maxDistance: Double = defaultMaxDistance) -> [TranscriptSegment] {
        let smoothed = smooth(turns, minTurn: minTurn, maxGap: maxGap)
        guard !smoothed.isEmpty else { return segments.map { var s = $0; s.speaker = nil; return s } }

        let raw = segments.map { rawSpeaker(for: $0, in: smoothed, maxDistance: maxDistance) }
        // Numbering in order of first appearance in the transcript.
        var number: [Int: Int] = [:]
        for case let r? in raw where number[r] == nil { number[r] = number.count }

        var out = segments
        for i in out.indices {
            out[i].speaker = raw[i].flatMap { number[$0] }.map(label)
        }
        return names.isEmpty ? out : rename(out, names)
    }

    /// Speaker index with the largest total overlap with the phrase; if none
    /// overlaps, the nearest turn not farther than `maxDistance`.
    static func rawSpeaker(for seg: TranscriptSegment, in turns: [SpeakerTurn], maxDistance: Double) -> Int? {
        var overlap: [Int: Double] = [:]
        var nearest: (speaker: Int, distance: Double)?
        let end = max(seg.end, seg.start)
        for t in turns {
            if t.start > end + maxDistance { break } // sorted by start
            let o = min(end, t.end) - max(seg.start, t.start)
            if o > 0 {
                overlap[t.speaker, default: 0] += o
            } else {
                let d = max(t.start - end, seg.start - t.end, 0)
                if d <= maxDistance, nearest == nil || d < nearest!.distance { nearest = (t.speaker, d) }
            }
        }
        if let best = overlap.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
            return best.key
        }
        return nearest?.speaker
    }

    /// Applies user names: every phrase whose speaker equals a key gets the
    /// value. Empty or whitespace-only names are ignored; one pass, so
    /// swapping two names works.
    public static func rename(_ segments: [TranscriptSegment], _ names: [String: String]) -> [TranscriptSegment] {
        let clean = names.compactMapValues { v -> String? in
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).joined(separator: " ")
            return t.isEmpty ? nil : String(t.prefix(80))
        }
        guard !clean.isEmpty else { return segments }
        return segments.map { s in
            var s = s
            if let sp = s.speaker, let n = clean[sp] { s.speaker = n }
            return s
        }
    }

    /// Distinct speaker labels in order of first appearance.
    public static func speakers(in segments: [TranscriptSegment]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for case let sp? in segments.map(\.speaker) where seen.insert(sp).inserted { out.append(sp) }
        return out
    }
}

extension Transcript {
    /// Distinct speaker labels in order of first appearance.
    public var speakers: [String] { SpeakerAssignment.speakers(in: segments) }

    /// Copy with speakers assigned from diarization turns.
    public func assigningSpeakers(_ turns: [SpeakerTurn], names: [String: String] = [:]) -> Transcript {
        var t = self
        t.segments = SpeakerAssignment.assign(turns, to: segments, names: names)
        return t
    }

    /// Copy with speakers renamed (label → new name).
    public func renamingSpeakers(_ names: [String: String]) -> Transcript {
        var t = self
        t.segments = SpeakerAssignment.rename(segments, names)
        return t
    }
}

/// Joins speakers found in separate long windows of a recording into
/// recording-wide speakers by comparing voice embeddings (agglomerative
/// clustering on cosine distance between weighted centroids).
/// Pure logic, used by SpeakerDiarizer for long meetings.
public enum SpeakerLinking {
    public struct Item: Sendable {
        /// Which window the local speaker came from.
        public var window: Int
        /// Voice embedding of that speaker in that window (any scale).
        public var embedding: [Float]
        /// How much speech backs the embedding (seconds); weights centroids.
        public var weight: Double

        public init(window: Int, embedding: [Float], weight: Double) {
            self.window = window
            self.embedding = embedding
            self.weight = weight
        }
    }

    /// Returns a cluster id (0-based, dense) for every item.
    /// - Parameters:
    ///   - numSpeakers: if known, merge until exactly that many remain
    ///     (cross-window merges are preferred over same-window ones).
    ///   - threshold: without `numSpeakers`, merge while the cosine distance
    ///     (1 − cos) between cluster centroids is at most this.
    ///   - sameWindowThreshold: two speakers already separated inside one
    ///     window are merged only if they are at least this close.
    public static func cluster(_ items: [Item], numSpeakers: Int? = nil,
                               threshold: Float = 0.5, sameWindowThreshold: Float = 0.3) -> [Int] {
        guard !items.isEmpty else { return [] }
        var members: [[Int]] = items.indices.map { [$0] }
        var sums: [[Float]] = items.map { item in
            let w = Float(max(item.weight, 0.01))
            return normalized(item.embedding).map { $0 * w }
        }
        var centroids: [[Float]] = sums.map(normalized)
        var windows: [Set<Int>] = items.map { [$0.window] }
        let target = numSpeakers.map { max(1, $0) }

        while members.count > 1 {
            if let target, members.count <= target { break }
            var best: (i: Int, j: Int, cost: Float)?
            for i in 0 ..< members.count {
                for j in (i + 1) ..< members.count {
                    let d = 1 - dot(centroids[i], centroids[j])
                    let sameWindow = !windows[i].isDisjoint(with: windows[j])
                    let limit = sameWindow ? min(threshold, sameWindowThreshold) : threshold
                    let cost: Float
                    if target != nil {
                        cost = d + (sameWindow && d > limit ? 2 : 0) // last resort only
                    } else {
                        guard d <= limit else { continue }
                        cost = d
                    }
                    if best == nil || cost < best!.cost { best = (i, j, cost) }
                }
            }
            guard let b = best else { break }
            members[b.i] += members[b.j]
            for k in sums[b.i].indices where k < sums[b.j].count { sums[b.i][k] += sums[b.j][k] }
            centroids[b.i] = normalized(sums[b.i])
            windows[b.i].formUnion(windows[b.j])
            members.remove(at: b.j)
            sums.remove(at: b.j)
            centroids.remove(at: b.j)
            windows.remove(at: b.j)
        }

        var out = [Int](repeating: 0, count: items.count)
        for (c, m) in members.enumerated() { for i in m { out[i] = c } }
        return out
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0 ..< min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var n: Float = 0
        for x in v where x.isFinite { n += x * x }
        n = n.squareRoot()
        guard n > 1e-12 else { return [Float](repeating: 0, count: v.count) }
        return v.map { $0.isFinite ? $0 / n : 0 }
    }
}
