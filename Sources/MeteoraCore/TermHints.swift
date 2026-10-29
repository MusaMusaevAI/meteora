import Foundation

/// Turns the user's terms into recognizer hints (hotwords): the phrases the
/// speech model should prefer while decoding. Pure and deterministic.
///
/// GigaAM-v3 e2e writes cased, punctuated text, so a hint must look like
/// the model's own output: the term as written («ПДС», «Газфонд»), plus a
/// capitalised form for a lower-case term at the start of a sentence, plus
/// the «е» spelling of a word with «ё». Variants («пэдээс», «газ фонд») are
/// the *wrong* outputs that `TermCorrector` fixes afterwards — boosting them
/// would make them more likely, so they are never hints.
public enum TermHints {
    /// Upper bound on phrases: every phrase is re-encoded for every phrase
    /// of speech, and a huge list mostly adds false boosts.
    public static let maxPhrases = 300

    public static func phrases(from terms: [Term]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            let p = clean(s)
            guard p.filter(\.isLetter).count >= 2, seen.insert(p).inserted else { return }
            out.append(p)
        }
        for t in terms {
            let text = t.text.precomposedStringWithCanonicalMapping
            var forms = [text]
            if text.contains("ё") || text.contains("Ё") {
                forms.append(text.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е"))
            }
            for f in forms {
                add(f)
                let c = clean(f)
                if let first = c.first, first.isLowercase {
                    add(first.uppercased() + c.dropFirst())
                }
            }
            if out.count >= maxPhrases { break }
        }
        return Array(out.prefix(maxPhrases))
    }

    /// Words of letters, digits and inner hyphens separated by single
    /// spaces; everything else («/», «:», quotes, punctuation) is a word
    /// break. Keeps the hint syntax of the decoder unambiguous.
    public static func clean(_ s: String) -> String {
        var words: [String] = []
        var current = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "-" {
                current.append(ch)
            } else {
                words.append(current)
                current = ""
            }
        }
        words.append(current)
        return words
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
