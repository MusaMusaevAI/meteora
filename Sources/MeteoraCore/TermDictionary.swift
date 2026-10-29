import Foundation

/// A word the recogniser should write in a particular way: an abbreviation
/// («ПДС»), a company or product name («Газфонд»), jargon.
public struct Term: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The correct spelling.
    public var text: String
    /// How it may come out of speech recognition («пэдээс», «газ фонд»).
    /// Letter-by-letter readings of abbreviations are added automatically.
    public var variants: [String]

    public init(id: UUID = UUID(), text: String, variants: [String] = []) {
        self.id = id
        self.text = text
        self.variants = variants
    }
}

/// Corrects transcripts with the user's terms. Pure and deterministic.
public struct TermCorrector: Sendable {
    /// One replacement rule: a sequence of normalised words → the term.
    struct Rule: Sendable {
        var words: [String]
        var replacement: String
    }

    private let rules: [Rule]
    /// Long single-word terms that may be matched with one typo.
    private let fuzzy: [(key: String, replacement: String)]
    private let maxWords: Int

    public init(terms: [Term]) {
        var rules: [Rule] = []
        var fuzzy: [(String, String)] = []
        for t in terms {
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var forms = Set<String>()
            forms.insert(text)
            for v in t.variants { forms.insert(v) }
            for v in Self.spokenForms(of: text) { forms.insert(v) }
            for f in forms {
                let words = Self.words(f)
                if words.isEmpty { continue }
                rules.append(Rule(words: words, replacement: text))
                // «газ фонд» also matches «газфонд» and «газ-фонд».
                if words.count > 1 { rules.append(Rule(words: [words.joined()], replacement: text)) }
            }
            let key = Self.normalize(text)
            if key.count >= 7, !key.contains(" ") { fuzzy.append((key, text)) }
        }
        // Longest rules first: «пенсионный фонд газфонд» before «газфонд».
        self.rules = rules.sorted { $0.words.count > $1.words.count }
        self.fuzzy = fuzzy
        self.maxWords = rules.map(\.words.count).max() ?? 1
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// Corrects one line of text.
    public func correct(_ line: String) -> String {
        guard !rules.isEmpty else { return line }
        let tokens = Self.tokenize(line)
        var out = ""
        var i = 0
        let wordIdx = tokens.indices.filter { tokens[$0].isWord }
        var w = 0 // position in wordIdx
        while i < tokens.count {
            let tok = tokens[i]
            guard tok.isWord, w < wordIdx.count, wordIdx[w] == i else {
                out += tok.text
                i += 1
                continue
            }
            var matched = false
            for rule in rules where rule.words.count <= wordIdx.count - w {
                var ok = true
                for (k, word) in rule.words.enumerated() {
                    let t = tokens[wordIdx[w + k]]
                    if Self.normalize(t.text) != word { ok = false; break }
                    // Words of a phrase must be separated only by spaces or hyphens.
                    if k > 0 {
                        let between = tokens[(wordIdx[w + k - 1] + 1)..<wordIdx[w + k]].map(\.text).joined()
                        if between.contains(where: { !$0.isWhitespace && $0 != "-" }) { ok = false; break }
                    }
                }
                guard ok else { continue }
                let first = tokens[wordIdx[w]].text
                out += Self.matchCase(rule.replacement, like: first, sentenceStart: Self.isSentenceStart(out))
                i = wordIdx[w + rule.words.count - 1] + 1
                w += rule.words.count
                matched = true
                break
            }
            if !matched {
                let norm = Self.normalize(tok.text)
                if norm.count >= 6, let hit = fuzzy.first(where: { Self.closeEnough(norm, $0.key) }) {
                    out += hit.replacement
                } else {
                    out += tok.text
                }
                i += 1
                w += 1
            }
        }
        return out
    }

    public func correct(_ transcript: Transcript) -> Transcript {
        guard !rules.isEmpty else { return transcript }
        var t = transcript
        t.segments = t.segments.map { s in
            var s = s
            s.text = correct(s.text)
            return s
        }
        return t
    }

    // MARK: Text helpers

    struct Token {
        var text: String
        var isWord: Bool
    }

    static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord = false
        for ch in s {
            let isWord = ch.isLetter || ch.isNumber
            if current.isEmpty {
                current = String(ch); currentIsWord = isWord
            } else if isWord == currentIsWord {
                current.append(ch)
            } else {
                tokens.append(Token(text: current, isWord: currentIsWord))
                current = String(ch); currentIsWord = isWord
            }
        }
        if !current.isEmpty { tokens.append(Token(text: current, isWord: currentIsWord)) }
        return tokens
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    static func words(_ s: String) -> [String] {
        tokenize(s).filter(\.isWord).map { normalize($0.text) }
    }

    static func isSentenceStart(_ written: String) -> Bool {
        let trimmed = written.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return true }
        return ".!?…".contains(last)
    }

    /// Keeps the term's own capitalisation (ПДС, Газфонд); a lower-case term
    /// gets a capital letter at the start of a sentence.
    static func matchCase(_ term: String, like original: String, sentenceStart: Bool) -> String {
        guard let f = term.first, f.isLowercase, sentenceStart, original.first?.isUppercase == true else { return term }
        return f.uppercased() + term.dropFirst()
    }

    /// `a` (heard) is `b` (term) with one letter wrong or missing, same
    /// first letter. A longer `a` is never matched: in Russian an extra
    /// letter is usually a case ending («Газфонда»), not a mistake.
    static func closeEnough(_ a: String, _ b: String) -> Bool {
        guard a != b, a.first == b.first, a.count == b.count || a.count == b.count - 1 else { return false }
        let x = Array(a), y = Array(b)
        var i = 0, j = 0, edits = 0
        while i < x.count && j < y.count {
            if x[i] == y[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if x.count > y.count { i += 1 } else if y.count > x.count { j += 1 } else { i += 1; j += 1 }
        }
        edits += (x.count - i) + (y.count - j)
        return edits <= 1
    }

    // MARK: Abbreviations read aloud

    private static let letterNames: [Character: [String]] = [
        "А": ["а"], "Б": ["бэ", "бе"], "В": ["вэ", "ве"], "Г": ["гэ", "ге"], "Д": ["дэ", "де"],
        "Е": ["е", "йе"], "Ж": ["жэ", "же"], "З": ["зэ", "зе"], "И": ["и"], "К": ["ка"],
        "Л": ["эль", "эл"], "М": ["эм"], "Н": ["эн"], "О": ["о"], "П": ["пэ", "пе"],
        "Р": ["эр"], "С": ["эс"], "Т": ["тэ", "те"], "У": ["у"], "Ф": ["эф"], "Х": ["ха"],
        "Ц": ["цэ", "це"], "Ч": ["че"], "Ш": ["ша"], "Щ": ["ща"], "Э": ["э"], "Ю": ["ю"], "Я": ["я"],
    ]

    /// «ПДС» → «пэдээс», «пэ дэ эс», «пдс». Only for all-caps Cyrillic
    /// abbreviations of 2–5 letters.
    public static func spokenForms(of text: String) -> [String] {
        let letters = Array(text)
        guard (2...5).contains(letters.count), letters.allSatisfy({ $0.isUppercase && letterNames[$0] != nil }) else { return [] }
        var combos: [[String]] = [[]]
        for l in letters {
            let names = letterNames[l]!
            combos = combos.flatMap { prefix in names.map { prefix + [$0] } }
            if combos.count > 64 { break }
        }
        var forms: [String] = [text.lowercased()]
        for c in combos {
            forms.append(c.joined())
            forms.append(c.joined(separator: " "))
        }
        return forms
    }
}

// MARK: - CSV

public enum TermCSV {
    /// «термин;варианты» with variants separated by «|». First row is a header.
    public static func export(_ terms: [Term]) -> Data {
        var lines = ["термин;как ещё может прозвучать"]
        for t in terms {
            lines.append(cell(t.text) + ";" + cell(t.variants.joined(separator: " | ")))
        }
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data((lines.joined(separator: "\r\n") + "\r\n").utf8))
        return data
    }

    /// Accepts «;», «,» or tab as separator; the header row is optional.
    public static func parse(_ data: Data) -> [Term] {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var terms: [Term] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let sep: Character = line.contains(";") ? ";" : line.contains("\t") ? "\t" : ","
            let cells = split(line, by: sep)
            guard let first = cells.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty else { continue }
            if terms.isEmpty, first.lowercased() == "термин" || first.lowercased() == "term" { continue }
            let variants = cells.count > 1
                ? cells[1].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            terms.append(Term(text: first, variants: variants))
        }
        return terms
    }

    private static func cell(_ s: String) -> String {
        s.contains(where: { $0 == ";" || $0 == "\"" || $0.isNewline }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    private static func split(_ line: String, by sep: Character) -> [String] {
        var cells: [String] = [], cur = "", quoted = false
        let it = Array(line)
        var i = 0
        while i < it.count {
            let c = it[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < it.count, it[i + 1] == "\"" { cur.append("\""); i += 1 } else { quoted = false }
                } else { cur.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == sep {
                cells.append(cur); cur = ""
            } else {
                cur.append(c)
            }
            i += 1
        }
        cells.append(cur)
        return cells
    }
}

// MARK: - Starter set

public enum StarterTerms {
    /// Terms of a Russian pension fund's everyday work.
    public static let pensions: [Term] = [
        Term(text: "ПДС"),
        Term(text: "ОПС"),
        Term(text: "НПО"),
        Term(text: "НПФ"),
        Term(text: "ЗЕВ"),
        Term(text: "ИИС"),
        Term(text: "НДП"),
        Term(text: "ПДн"),
        Term(text: "КПЭ"),
        Term(text: "CRM", variants: ["црм", "си ар эм", "сиарэм"]),
        Term(text: "Газфонд", variants: ["газ фонд", "газфон"]),
        Term(text: "Газпром", variants: ["газ пром"]),
        Term(text: "Норникель", variants: ["нор никель", "норильский никель"]),
        Term(text: "Госуслуги", variants: ["гос услуги"]),
        Term(text: "Телемост", variants: ["теле мост"]),
        Term(text: "Яндекс Трекер", variants: ["яндекс трекер", "трекер яндекса"]),
        Term(text: "софинансирование", variants: ["со финансирование"]),
        Term(text: "автоплатёж", variants: ["авто платёж", "авто платеж", "автоплатеж"]),
        Term(text: "лендинг", variants: ["лэндинг"]),
        Term(text: "воронка"),
    ]
}
