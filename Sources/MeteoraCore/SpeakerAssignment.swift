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

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0 ..< min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    public static func normalized(_ v: [Float]) -> [Float] {
        var n: Float = 0
        for x in v where x.isFinite { n += x * x }
        n = n.squareRoot()
        guard n > 1e-12 else { return [Float](repeating: 0, count: v.count) }
        return v.map { $0.isFinite ? $0 / n : 0 }
    }
}

/// Final clean-up of the speakers found by diarization, so one voice is not
/// reported as two and noise does not become a "participant".
///
/// Works on whole speakers (each backed by up to 30 s of their speech),
/// whose embeddings are far more reliable than the 10-second-chunk
/// embeddings sherpa clusters with complete linkage — there one odd chunk
/// (a cough, overlap, a change of microphone distance) is enough to split a
/// speaker. Steps:
/// 1. exact count requested → merge the closest pair until it holds;
/// 2. merge while the closest pair of centroids is at least
///    `mergeSimilarity` apart (`shortRecordingMergeSimilarity` for
///    recordings shorter than `shortRecordingSeconds`: there a second
///    speaker needs stronger evidence);
/// 3. "tiny" speakers (less than `minSpeakerSeconds` of speech or less than
///    `minSpeakerShare` of all speech) join their most similar speaker
///    unless their voice is clearly different (similarity below
///    `tinyMergeSimilarity`); below `unreliableSeconds`, or without an
///    embedding, they always join;
/// 4. never more than `maxSpeakers`.
/// Pure logic, unit-tested; SpeakerDiarizer supplies the embeddings.
public enum SpeakerCleanup {
    public struct Speaker: Sendable {
        /// Voice embedding (any scale), nil if none could be computed.
        public var embedding: [Float]?
        /// Seconds of speech attributed to the speaker.
        public var seconds: Double

        public init(embedding: [Float]?, seconds: Double) {
            self.embedding = embedding
            self.seconds = seconds
        }
    }

    public struct Rules: Sendable, Equatable {
        /// Exact number of speakers wanted (nil = automatic).
        public var numSpeakers: Int?
        /// Upper bound on the number of speakers.
        public var maxSpeakers: Int
        /// Cosine similarity at which two speakers are the same voice.
        public var mergeSimilarity: Float
        /// Recordings shorter than this need stronger evidence for a split.
        public var shortRecordingSeconds: Double
        /// `mergeSimilarity` for short recordings (lower = merge sooner).
        public var shortRecordingMergeSimilarity: Float
        /// Speakers with less speech than this are "tiny".
        public var minSpeakerSeconds: Double
        /// …or with less than this share of all speech.
        public var minSpeakerShare: Double
        /// A tiny speaker stays separate only if its similarity to the
        /// nearest speaker is below this (clearly another voice).
        public var tinyMergeSimilarity: Float
        /// Below this much speech an embedding is not trusted at all.
        public var unreliableSeconds: Double

        public init(numSpeakers: Int? = nil, maxSpeakers: Int = 10,
                    mergeSimilarity: Float = 0.6,
                    shortRecordingSeconds: Double = 60,
                    shortRecordingMergeSimilarity: Float = 0.57,
                    minSpeakerSeconds: Double = 4,
                    minSpeakerShare: Double = 0.03,
                    tinyMergeSimilarity: Float = 0.4,
                    unreliableSeconds: Double = 1.5) {
            self.numSpeakers = numSpeakers
            self.maxSpeakers = maxSpeakers
            self.mergeSimilarity = mergeSimilarity
            self.shortRecordingSeconds = shortRecordingSeconds
            self.shortRecordingMergeSimilarity = shortRecordingMergeSimilarity
            self.minSpeakerSeconds = minSpeakerSeconds
            self.minSpeakerShare = minSpeakerShare
            self.tinyMergeSimilarity = tinyMergeSimilarity
            self.unreliableSeconds = unreliableSeconds
        }
    }

    private struct Group {
        var members: [Int]
        var sum: [Float]?
        var seconds: Double
        var centroid: [Float]? { sum.map(SpeakerLinking.normalized) }
    }

    /// Returns, for every input speaker, the index of its final speaker
    /// (dense, 0-based, numbered in the order of the first member).
    public static func plan(_ speakers: [Speaker], recordingSeconds: Double, rules: Rules) -> [Int] {
        guard !speakers.isEmpty else { return [] }
        var groups: [Group] = speakers.enumerated().map { pair -> Group in
            let i = pair.offset, s = pair.element
            let seconds = s.seconds.isFinite ? max(0, s.seconds) : 0
            var sum: [Float]?
            if let e = s.embedding, !e.isEmpty {
                let n = SpeakerLinking.normalized(e)
                if n.contains(where: { $0 != 0 }) {
                    let w = Float(max(seconds, 0.01))
                    sum = n.map { $0 * w }
                }
            }
            return Group(members: [i], sum: sum, seconds: seconds)
        }

        func similarity(_ a: Int, _ b: Int) -> Float? {
            guard let x = groups[a].centroid, let y = groups[b].centroid else { return nil }
            return SpeakerLinking.dot(x, y)
        }
        /// Moves group `from` into group `into`.
        func merge(_ into: Int, _ from: Int) {
            let src = groups[from]
            if let s = src.sum {
                if var d = groups[into].sum {
                    for k in d.indices where k < s.count { d[k] += s[k] }
                    groups[into].sum = d
                } else {
                    groups[into].sum = s
                }
            }
            groups[into].seconds += src.seconds
            groups[into].members += src.members
            groups.remove(at: from)
        }
        func closestPair() -> (i: Int, j: Int, sim: Float)? {
            var best: (i: Int, j: Int, sim: Float)?
            for i in 0 ..< groups.count {
                for j in (i + 1) ..< groups.count {
                    guard let s = similarity(i, j) else { continue }
                    if best == nil || s > best!.sim { best = (i, j, s) }
                }
            }
            return best
        }
        /// One merge towards a target count: a speaker without an embedding
        /// joins the largest one; otherwise the closest pair merges.
        func forceMerge() {
            let blind = groups.indices.filter { groups[$0].sum == nil }
            if let small = blind.min(by: { groups[$0].seconds < groups[$1].seconds }),
               let big = groups.indices.filter({ $0 != small }).max(by: { groups[$0].seconds < groups[$1].seconds }) {
                merge(big, small)
            } else if let p = closestPair() {
                merge(p.i, p.j)
            } else if groups.count > 1 {
                merge(0, groups.count - 1)
            }
        }

        let cap = max(1, rules.maxSpeakers)
        if let n = rules.numSpeakers {
            let target = min(max(1, n), cap)
            while groups.count > target { forceMerge() }
        } else {
            // 2. Same voice.
            let limit = recordingSeconds < rules.shortRecordingSeconds
                ? rules.shortRecordingMergeSimilarity : rules.mergeSimilarity
            while groups.count > 1, let p = closestPair(), p.sim >= limit { merge(p.i, p.j) }

            // 3. Tiny speakers, smallest first.
            while groups.count > 1 {
                let total = groups.reduce(0) { $0 + $1.seconds }
                var pick: (seconds: Double, from: Int, into: Int)?
                for k in groups.indices {
                    let g = groups[k]
                    let tiny = g.seconds < rules.minSpeakerSeconds || g.seconds < rules.minSpeakerShare * total
                    guard tiny || g.sum == nil else { continue }
                    var target: Int?
                    var targetSim: Float?
                    for o in groups.indices where o != k {
                        let s = similarity(k, o)
                        let better: Bool
                        if let t = target {
                            let a = s ?? -2, b = targetSim ?? -2
                            better = a > b || (a == b && groups[o].seconds > groups[t].seconds)
                        } else {
                            better = true
                        }
                        if better { target = o; targetSim = s }
                    }
                    guard let into = target else { continue }
                    let joins = g.sum == nil || targetSim == nil || g.seconds < rules.unreliableSeconds
                        || targetSim! >= rules.tinyMergeSimilarity
                    guard joins else { continue }
                    if pick == nil || g.seconds < pick!.seconds { pick = (g.seconds, k, into) }
                }
                guard let p = pick else { break }
                merge(p.into, p.from)
            }
        }
        // 4. Upper bound.
        while groups.count > cap { forceMerge() }

        var out = [Int](repeating: 0, count: speakers.count)
        let ordered = groups.sorted { ($0.members.min() ?? 0) < ($1.members.min() ?? 0) }
        for (c, g) in ordered.enumerated() { for i in g.members { out[i] = c } }
        return out
    }
}
