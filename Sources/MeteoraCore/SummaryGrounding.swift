import Foundation

/// Keeps meeting summaries honest. A small model handed a song, noise or a
/// few stray words will still write a confident "protocol"; these checks run
/// before and after the model:
///  — `assess` says whether there is a conversation worth summarising at all;
///  — `filter` drops every line of the answer that the transcript doesn't
///    support (its content words never occur in the transcript, or it cites
///    a number nobody said).
public enum SummaryGrounding {
    public enum Assessment: Equatable, Sendable {
        case ok
        /// Too little speech to summarise.
        case tooShort
        /// The same few words over and over: a song, a chant, looped audio.
        case repetitive
    }

    /// Words that a summary uses to frame content rather than carry it.
    /// They prove nothing about the transcript, so they don't count.
    static let framing: Set<String> = [
        "встреч", "совещ", "обсуд", "обсуж", "участ", "коман", "догов", "решил", "решен", "подго",
        "необх", "вопро", "тема", "темы", "темой", "говор", "сказа", "отмет", "предл", "рассм",
        "также", "котор", "этого", "этому", "этот", "этой", "было", "были", "будет", "есть",
        "нужно", "можно", "очень", "более", "менее", "после", "перед", "между", "через", "когда",
        "чтобы", "потом", "сейчас", "часть", "запис", "разго", "речь", "речи", "проток",
        "итоги", "итог", "резюм", "пункт", "задач", "поруч", "срок", "сроки", "прозв", "упомя",
        "связи", "связа", "плани", "работ", "свой", "своих", "своей", "всех", "всего", "весь",
    ]

    /// Lower-cased word tokens (letters and digits).
    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// Crude stem good enough for Russian inflection: the first five letters
    /// of a word of four letters or more. Shorter words don't carry content.
    static func stem(_ w: String) -> String? {
        guard w.count >= 4, w.first?.isLetter == true else { return nil }
        return String(w.prefix(5))
    }

    /// Numbers of three digits or more (years, sums, counts): those a model
    /// likes to invent. Small numbers are often spoken as words; not checked.
    static func bigNumbers(_ s: String) -> [String] {
        words(s).filter { $0.count >= 3 && $0.allSatisfy(\.isNumber) }
    }

    /// The spoken text without timestamps and speaker labels.
    public static func spokenText(_ tr: Transcript) -> String {
        tr.segments.map(\.text).joined(separator: " ")
    }

    public static func assess(_ spoken: String) -> Assessment {
        let ws = words(spoken).filter { $0.count >= 2 }
        if ws.count < 15 { return .tooShort }
        let stems = ws.compactMap(stem)
        if stems.count >= 40 {
            let unique = Set(stems).count
            if Double(unique) / Double(stems.count) < 0.22 { return .repetitive }
        }
        return .ok
    }

    /// Support index of a transcript.
    public struct Index: Sendable {
        let stems: Set<String>
        let numbers: Set<String>
        public init(_ text: String) {
            let ws = words(text)
            stems = Set(ws.compactMap(stem))
            numbers = Set(ws.filter { $0.allSatisfy(\.isNumber) })
        }
    }

    /// Share of the line's content words found in the transcript, or nil if
    /// the line has no content words at all.
    static func support(_ line: String, in index: Index) -> Double? {
        let content = Set(words(line).compactMap(stem).filter { !framing.contains($0) })
        guard !content.isEmpty else { return nil }
        return Double(content.filter(index.stems.contains).count) / Double(content.count)
    }

    public static func isGrounded(_ line: String, in index: Index, threshold: Double = 0.4) -> Bool {
        if bigNumbers(line).contains(where: { !index.numbers.contains($0) }) { return false }
        guard let s = support(line, in: index) else { return true }
        return s >= threshold
    }

    /// The parsed answer with unsupported lines removed. Summary sentences
    /// are judged one by one, a little more leniently (they paraphrase).
    public static func filter(_ p: MeetingSummaryParser.Parsed, against index: Index) -> MeetingSummaryParser.Parsed {
        var out = p
        out.title = isGrounded(p.title, in: index, threshold: 0.5) ? p.title : ""
        out.summary = sentences(p.summary).filter { isGrounded($0, in: index, threshold: 0.3) }.joined(separator: " ")
        out.keyPoints = p.keyPoints.filter { isGrounded($0, in: index) }
        out.decisions = p.decisions.filter { isGrounded($0, in: index) }
        out.actionItems = p.actionItems.filter { isGrounded($0, in: index) }
        return out
    }

    /// Nothing usable survived.
    public static func isVoid(_ p: MeetingSummaryParser.Parsed) -> Bool {
        p.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && p.keyPoints.isEmpty && p.decisions.isEmpty && p.actionItems.isEmpty
    }

    static func sentences(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s {
            cur.append(ch)
            if ".!?…".contains(ch) {
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                cur = ""
            }
        }
        let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { out.append(t) }
        return out
    }
}
