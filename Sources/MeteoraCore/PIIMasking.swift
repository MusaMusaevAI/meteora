import Foundation

// Personal-data masking for text that leaves the Mac (cloud summaries).
//
// A Swift port of the regex engine of Cloud.ru Guardrails
// (github.com/cloud-ru-tech/guardrails-llm-filter, Apache-2.0, ruleset
// configs/guardrails_regex_rules.yaml at v0.1.2 / commit bbd6f27): the same
// patterns, capture groups, minimum lengths, checksum validators (Luhn,
// СНИЛС, ИНН, ОГРН/ОГРНИП, IBAN mod-97, e-mail), overlap resolution and
// `<TYPE_N>` placeholders. Cloud.ru runs this engine as a proxy in front of an
// LLM; here it runs on the Mac, so the original values never leave it.
//
// Differences from upstream, all on the privacy-safe or precision side:
// — only PERSONAL_DATA, a few CREDENTIALS / ACCESS_TOKENS rules and IPv4 are
//   ported (vendor API-key catalogs derived from gitleaks are not);
// — address rule, branch C: «к 15» / «под 10» / «кв 2026» no longer count as
//   корпус / подъезд / квартира («Этап 2 к 15 ноября», «Отчёт 3 кв 2026»);
// — Meteora additions (`upstream == false`): 20-digit bank accounts, dates of
//   birth next to «дата рождения / г.р. / родился», and speaker names the
//   user typed in (exact words, with Russian case endings);
// — regexes run in ICU (NSRegularExpression) instead of Go RE2. All patterns
//   are RE2-compatible and ICU accepts them; ICU's \b also treats Cyrillic as
//   word characters, which only makes \b-anchored digit rules stricter.

public enum PIIValidator: String, Sendable {
    case luhn, snils, innPerson, innOrg, ogrn, ogrnip, ibanMod97, emailASCII, paymentCard, paymentCardShape, ipv4
}

/// One detection rule: a regex, the capture groups that hold the value (the
/// first one that matched is masked; none = the whole match) and validators
/// that must all pass.
public struct PIIRule: Sendable {
    public let id: String
    /// Placeholder type: `FIO` → `<FIO_1>`.
    public let placeholder: String
    public let pattern: String
    public let groups: [Int]
    /// In UTF-8 bytes, as upstream (Go `len`).
    public let minLength: Int
    public let validators: [PIIValidator]
    /// From the Cloud.ru ruleset (true) or a Meteora addition (false).
    public let upstream: Bool

    public init(_ id: String, _ placeholder: String, groups: [Int] = [], minLength: Int = 0,
                validators: [PIIValidator] = [], upstream: Bool = true, pattern: String) {
        self.id = id
        self.placeholder = placeholder
        self.pattern = pattern
        self.groups = groups
        self.minLength = minLength
        self.validators = validators
        self.upstream = upstream
    }
}

public struct PIIMatch: Sendable, Equatable {
    public var ruleID: String
    public var placeholder: String
    /// UTF-16 offsets in the scanned text (NSString units).
    public var location: Int
    public var length: Int
    public var value: String
}

public enum PIIMaskingError: Error, LocalizedError, Equatable {
    case badRule(String)

    public var errorDescription: String? {
        switch self {
        case .badRule(let id): return "Не удалось подготовить правило защиты данных «\(id)»."
        }
    }
}

/// Placeholders ↔ originals for one job. Lives only in memory on this Mac.
public struct PIIMap: Sendable, Equatable {
    public private(set) var placeholderToOriginal: [String: String] = [:]
    private var originalToPlaceholder: [String: String] = [:]
    private var counters: [String: Int] = [:]
    private var reserved: Set<String> = []

    public init() {}

    public var isEmpty: Bool { placeholderToOriginal.isEmpty }

    /// How many distinct values were hidden, by placeholder type.
    public var counts: [String: Int] {
        var out: [String: Int] = [:]
        for key in placeholderToOriginal.keys {
            out[PIIMap.kind(of: key), default: 0] += 1
        }
        return out
    }

    /// `<CREDIT_CARD_12>` → `CREDIT_CARD`.
    static func kind(of placeholder: String) -> String {
        var s = placeholder
        if s.hasPrefix("<") { s.removeFirst() }
        if s.hasSuffix(">") { s.removeLast() }
        if let i = s.lastIndex(of: "_") { return String(s[..<i]) }
        return s
    }

    /// The same value always gets the same placeholder.
    mutating func placeholder(for original: String, type: String) -> String {
        if let p = originalToPlaceholder[original] { return p }
        var p: String
        repeat {
            counters[type, default: 0] += 1
            p = "<\(type)_\(counters[type] ?? 1)>"
        } while reserved.contains(p) || placeholderToOriginal[p] != nil
        originalToPlaceholder[original] = p
        placeholderToOriginal[p] = original
        return p
    }

    /// Placeholder-looking text already present in the input is never
    /// reused, so unmasking can't turn someone's literal "<EMAIL_1>" into a
    /// real address.
    mutating func reserve(in text: String) {
        guard text.contains("<"), let re = PIIMap.literalRegex else { return }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            reserved.insert(ns.substring(with: m.range))
        }
    }

    private static let literalRegex = try? NSRegularExpression(pattern: #"<[A-Za-z0-9_]+_[0-9]+>"#)
    /// Also accepts what models do to placeholders: dropped or HTML-escaped
    /// brackets, markdown-escaped underscores, a space inside the brackets.
    private static let answerRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])(?:&lt;\s?|\\?<\s?)?([A-Z][A-Z0-9]*(?:\\?_[A-Z0-9]+)*?)\\?_([0-9]{1,5})(?:\s?&gt;|\s?\\?>)?(?![A-Za-z0-9])"#)

    /// Puts the originals back into a model's answer. Only placeholders made
    /// by this map are replaced; anything else is left as written.
    public func unmask(_ text: String) -> String {
        guard !placeholderToOriginal.isEmpty, let re = PIIMap.answerRegex else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var pos = 0
        for m in matches {
            let type = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "\\_", with: "_")
            let key = "<\(type)_\(ns.substring(with: m.range(at: 2)))>"
            guard let original = placeholderToOriginal[key] else { continue }
            out += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            out += original
            pos = m.range.location + m.range.length
        }
        out += ns.substring(from: pos)
        return out
    }
}

/// Finds personal data with the compiled rules. Immutable and thread-safe
/// (NSRegularExpression is safe to share).
public final class PIIScanner: @unchecked Sendable {
    public let rules: [PIIRule]
    private let compiled: [NSRegularExpression]
    private let terms: [NSRegularExpression]

    /// `terms` are extra exact words to hide — speaker names the user typed
    /// in — matched as whole words, with Russian case endings.
    public init(rules: [PIIRule] = PIIRules.standard, terms: [String] = []) throws {
        self.rules = rules
        var out: [NSRegularExpression] = []
        for r in rules {
            guard let re = try? NSRegularExpression(pattern: r.pattern) else { throw PIIMaskingError.badRule(r.id) }
            out.append(re)
        }
        compiled = out
        self.terms = Self.termRegexes(terms)
    }

    /// Non-overlapping matches, sorted by position.
    public func matches(in text: String) -> [PIIMatch] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return [] }
        var all: [PIIMatch] = []
        for (rule, re) in zip(rules, compiled) {
            for m in re.matches(in: text, range: full) {
                guard let r = Self.span(m, rule.groups) else { continue }
                let value = ns.substring(with: r)
                if rule.minLength > 0 && value.utf8.count < rule.minLength { continue }
                guard PIIValidation.validate(value, rule.validators) else { continue }
                all.append(PIIMatch(ruleID: rule.id, placeholder: rule.placeholder,
                                    location: r.location, length: r.length, value: value))
            }
        }
        for re in terms {
            for m in re.matches(in: text, range: full) where m.range.length > 0 {
                all.append(PIIMatch(ruleID: "meteora.speaker-name", placeholder: "FIO",
                                    location: m.range.location, length: m.range.length,
                                    value: ns.substring(with: m.range)))
            }
        }
        return Self.resolveConflicts(all, in: ns)
    }

    /// Replaces found values with placeholders, recording them in `map`.
    public func mask(_ text: String, map: inout PIIMap) -> String {
        map.reserve(in: text)
        let found = matches(in: text)
        guard !found.isEmpty else { return text }
        let ns = text as NSString
        var out = ""
        var pos = 0
        for m in found where m.location >= pos {
            out += ns.substring(with: NSRange(location: pos, length: m.location - pos))
            out += map.placeholder(for: m.value, type: m.placeholder)
            pos = m.location + m.length
        }
        out += ns.substring(from: pos)
        return out
    }

    static func span(_ m: NSTextCheckingResult, _ groups: [Int]) -> NSRange? {
        if groups.isEmpty { return m.range.length > 0 ? m.range : nil }
        for g in groups where g < m.numberOfRanges {
            let r = m.range(at: g)
            if r.location != NSNotFound && r.length > 0 { return r }
        }
        return nil
    }

    /// Upstream `resolveConflicts`: overlapping matches merge into one span
    /// covering all of them, typed by the longest (then earliest, then by
    /// rule id).
    static func resolveConflicts(_ matches: [PIIMatch], in ns: NSString) -> [PIIMatch] {
        guard matches.count > 1 else { return matches }
        let sorted = matches.sorted { a, b in
            if a.location != b.location { return a.location < b.location }
            if a.length != b.length { return a.length > b.length }
            return a.ruleID < b.ruleID
        }
        var out: [PIIMatch] = []
        var run: [PIIMatch] = [sorted[0]]
        var runEnd = sorted[0].location + sorted[0].length
        func flush() {
            var primary = run[0]
            for m in run.dropFirst() {
                if m.length != primary.length {
                    if m.length > primary.length { primary = m }
                } else if m.location != primary.location {
                    if m.location < primary.location { primary = m }
                } else if m.ruleID < primary.ruleID {
                    primary = m
                }
            }
            let start = run[0].location
            let r = NSRange(location: start, length: runEnd - start)
            out.append(PIIMatch(ruleID: primary.ruleID, placeholder: primary.placeholder,
                                location: r.location, length: r.length, value: ns.substring(with: r)))
        }
        for m in sorted.dropFirst() {
            if m.location < runEnd {
                run.append(m)
                runEnd = max(runEnd, m.location + m.length)
                continue
            }
            flush()
            run = [m]
            runEnd = m.location + m.length
        }
        flush()
        return out
    }

    /// Generic labels («Спикер 1») are not names and stay as they are.
    static func isGenericSpeaker(_ s: String) -> Bool {
        s.range(of: #"^(?:спикер|speaker|говорящий|участник|собеседник|голос)\s*\d*$"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Speaker names → whole-word patterns: the full name and each word of a
    /// longer one, with the final а/я/й/ь dropped so declined forms match too
    /// («Мария Иванова» → «Марии», «Ивановой»; «Пётр» → «Петру»).
    static func termRegexes(_ terms: [String]) -> [NSRegularExpression] {
        var words: [String] = []
        for raw in terms {
            let t = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard t.count >= 2, t.count <= 80, !isGenericSpeaker(t) else { continue }
            words.append(t)
            let parts = t.split(separator: " ").map(String.init)
            if parts.count > 1 { words += parts.filter { $0.count >= 3 && ($0.first?.isUppercase ?? false) } }
        }
        var seen = Set<String>()
        var out: [NSRegularExpression] = []
        for w in words.sorted(by: { $0.count > $1.count }) where seen.insert(w).inserted {
            var stem = w
            if stem.count >= 4, let last = stem.last, "аяйьАЯЙЬ".contains(last) { stem.removeLast() }
            var body = ""
            for ch in stem {
                switch ch {
                case "е", "ё": body += "[её]"
                case "Е", "Ё": body += "[ЕЁ]"
                case " ": body += #"\s+"#
                default: body += NSRegularExpression.escapedPattern(for: String(ch))
                }
            }
            let pattern = #"(?<![\p{L}\p{N}_])"# + body + #"(?:[ая]|[уюиыйье]|ом|ем|ым|им|ой|ей|ою|ею|ём)?(?![\p{L}\p{N}_])"#
            if let re = try? NSRegularExpression(pattern: pattern) { out.append(re) }
        }
        return out
    }
}

/// Checksums and formats, ported from upstream `pkg/guardrails/regex/validation`.
public enum PIIValidation {
    static func validate(_ candidate: String, _ validators: [PIIValidator]) -> Bool {
        guard !validators.isEmpty else { return true }
        let digits = candidate.filter { $0.isASCII && $0.isNumber }
        for v in validators {
            let ok: Bool
            switch v {
            case .luhn: ok = luhn(digits)
            case .snils: ok = snils(digits)
            case .innPerson: ok = innPerson(digits)
            case .innOrg: ok = innOrg(digits)
            case .ogrn: ok = ogrn(digits)
            case .ogrnip: ok = ogrnip(digits)
            case .ibanMod97: ok = iban(candidate)
            case .emailASCII: ok = emailASCII(candidate)
            case .paymentCard: ok = paymentCardShape(digits) && luhn(digits)
            case .paymentCardShape: ok = paymentCardShape(digits)
            case .ipv4: ok = ipv4(candidate)
            }
            if !ok { return false }
        }
        return true
    }

    static func values(_ digits: String) -> [Int]? {
        let v = digits.unicodeScalars.map { Int($0.value) - 48 }
        guard !v.isEmpty, v.allSatisfy({ (0...9).contains($0) }) else { return nil }
        return v
    }

    public static func luhn(_ digits: String) -> Bool {
        guard let d = values(digits) else { return false }
        let parity = d.count % 2
        var sum = 0
        for (i, x) in d.enumerated() {
            var y = x
            if i % 2 == parity {
                y *= 2
                if y > 9 { y -= 9 }
            }
            sum += y
        }
        return sum % 10 == 0
    }

    public static func snils(_ digits: String) -> Bool {
        guard digits.count == 11, let d = values(digits) else { return false }
        var sum = 0
        for i in 0..<9 { sum += d[i] * (9 - i) }
        var check = sum % 101
        if check > 99 { check = 0 }
        return d[9] * 10 + d[10] == check
    }

    static func weighted(_ d: [Int], _ w: [Int]) -> Int {
        var sum = 0
        for (i, x) in w.enumerated() { sum += d[i] * x }
        return (sum % 11) % 10
    }

    public static func innPerson(_ digits: String) -> Bool {
        guard digits.count == 12, let d = values(digits) else { return false }
        let c1 = weighted(d, [7, 2, 4, 10, 3, 5, 9, 4, 6, 8])
        let c2 = weighted(Array(d[0..<10]) + [c1], [3, 7, 2, 4, 10, 3, 5, 9, 4, 6, 8])
        return d[10] == c1 && d[11] == c2
    }

    public static func innOrg(_ digits: String) -> Bool {
        guard digits.count == 10, let d = values(digits) else { return false }
        return d[9] == weighted(d, [2, 4, 10, 3, 5, 9, 4, 6, 8])
    }

    public static func ogrn(_ digits: String) -> Bool {
        guard digits.count == 13, let d = values(digits) else { return false }
        var n: Int64 = 0
        for x in d[0..<12] { n = n * 10 + Int64(x) }
        return Int64(d[12]) == (n % 11) % 10
    }

    public static func ogrnip(_ digits: String) -> Bool {
        guard digits.count == 15, let d = values(digits) else { return false }
        var r = 0
        for x in d[0..<14] { r = (r * 10 + x) % 13 }
        return d[14] == r % 10
    }

    public static func iban(_ candidate: String) -> Bool {
        let s = candidate.replacingOccurrences(of: " ", with: "").uppercased()
        guard s.count >= 4, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        let rearranged = String(s.dropFirst(4) + s.prefix(4))
        var r = 0
        for ch in rearranged.unicodeScalars {
            let v = Int(ch.value)
            if v >= 65 && v <= 90 {
                for c in String(v - 55).unicodeScalars { r = (r * 10 + Int(c.value) - 48) % 97 }
            } else {
                r = (r * 10 + v - 48) % 97
            }
        }
        return r == 1
    }

    public static func emailASCII(_ candidate: String) -> Bool {
        let s = candidate.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.utf8.count <= 254, s.utf8.allSatisfy({ $0 < 128 }),
              let at = s.firstIndex(of: "@") else { return false }
        let local = String(s[..<at])
        let domain = String(s[s.index(after: at)...])
        guard !local.isEmpty, !domain.isEmpty, local.count <= 64, domain.count <= 253,
              !local.contains(".."), !local.hasPrefix("."), !local.hasSuffix(".") else { return false }
        let localChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-/=?^_`{|}~")
        for part in local.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.allSatisfy({ localChars.contains($0) }) else { return false }
        }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for (i, label) in labels.enumerated() {
            guard !label.isEmpty, label.count <= 63, label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
            if i == labels.count - 1 && !label.allSatisfy({ $0.isASCII && $0.isLetter }) { return false }
        }
        return true
    }

    public static func paymentCardShape(_ digits: String) -> Bool {
        let n = digits.count
        guard n >= 13, n <= 19, values(digits) != nil else { return false }
        func head(_ len: Int) -> Int { Int(digits.prefix(len)) ?? -1 }
        if digits.hasPrefix("4") { return n == 13 || n == 16 || n == 19 }
        if digits.hasPrefix("34") || digits.hasPrefix("37") { return n == 15 }
        if (51...55).contains(head(2)) || (2221...2720).contains(head(4)) { return n == 16 }
        if digits.hasPrefix("6011") || (644...649).contains(head(3)) || digits.hasPrefix("65") { return n >= 16 }
        if digits.hasPrefix("62") { return n >= 16 }
        if (2200...2204).contains(head(4)) { return n >= 16 }
        return false
    }

    public static func ipv4(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for p in parts {
            // netip.ParseAddr rejects leading zeros ("01").
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }),
                  p.count == 1 || p.first != "0", let v = Int(p), v <= 255 else { return false }
        }
        return true
    }
}

/// The rule set used for cloud summaries.
public enum PIIRules {
    public static let standard: [PIIRule] = upstream + meteora

    /// Ported verbatim from Cloud.ru guardrails_regex_rules.yaml (see the
    /// header for the one patched branch in `pii.docs.address`).
    public static let upstream: [PIIRule] = [
        PIIRule("pii.fio-ru", "FIO", groups: [1], pattern: ##"(?:^|[^ЁА-Яёа-я])((?:[ЁА-Я][ёа-я]+(?:-[ЁА-Я][ёа-я]+)?\s+[ЁА-Я][ёа-я]+\s+[ЁА-Я][ёа-я]+(?:ич(?:а|у|ем|е)?|вн(?:а|ы|е|у|ой)|ичн(?:а|ы|е|у|ой)))|(?:[ЁА-Я][ёа-я]+\s+[ЁА-Я][ёа-я]+(?:ич(?:а|у|ем|е)?|вн(?:а|ы|е|у|ой)|ичн(?:а|ы|е|у|ой))\s+[ЁА-Я][ёа-я]+(?:-[ЁА-Я][ёа-я]+)?)|(?:[ЁА-Я]{2,}(?:-[ЁА-Я]{2,})?\s+[ЁА-Я]{2,}\s+[ЁА-Я]+(?:ИЧ(?:А|У|ЕМ|Е)?|ВН(?:А|Ы|Е|У|ОЙ)|ИЧН(?:А|Ы|Е|У|ОЙ)))|(?:[ЁА-Я]{2,}\s+[ЁА-Я]+(?:ИЧ(?:А|У|ЕМ|Е)?|ВН(?:А|Ы|Е|У|ОЙ)|ИЧН(?:А|Ы|Е|У|ОЙ))\s+[ЁА-Я]{2,}(?:-[ЁА-Я]{2,})?))(?:[^ЁА-Яёа-я]|$)"##),
        PIIRule("pii.fio-ru.initials", "FIO", groups: [1], pattern: ##"(?:^|[^ЁА-Яёа-я])((?:[ЁА-Я][ёа-я]+(?:-[ЁА-Я][ёа-я]+)?\s+[ЁА-Я]\.\s?[ЁА-Я]\.)|(?:[ЁА-Я]\.\s?[ЁА-Я]\.\s*[ЁА-Я][ёа-я]+(?:-[ЁА-Я][ёа-я]+)?)|(?:[ЁА-Я]{2,}(?:-[ЁА-Я]{2,})?\s+[ЁА-Я]\.\s?[ЁА-Я]\.)|(?:[ЁА-Я]\.\s?[ЁА-Я]\.\s*[ЁА-Я]{2,}(?:-[ЁА-Я]{2,})?))(?:[^ЁА-Яёа-я.]|$)"##),
        PIIRule("pii.fio-ru.short", "FIO", groups: [1], pattern: ##"(?:^|[^ЁА-Яёа-я])((?:(?:(?:(?:Александр|Анастаси|Валентин|Екатерин|Елизавет|Маргарит|Алевтин|Ангелин|Антонин|Вероник|Виктори|Кристин|Светлан|Валери|Варвар|Евгени|Зинаид|Клавди|Людмил|Надежд|Натали|Наталь|Татьян|Анжел|Галин|Карин|Ксени|Ларис|Марин|Милан|Оксан|Полин|Регин|Таиси|Тамар|Ульян|Ален|Алин|Алис|Алён|Дарь|Диан|Елен|Жанн|Ирин|Лиди|Лили|Мари|Марь|Олес|Ольг|Раис|Софи|Софь|Алл|Анн|Вер|Дин|Инн|Кир|Нин|Юли|Ев|Зо|Ян)(?:а|я|ы|е|у|ю|ой|ей))|(?:(?:Константин|Александр|Владислав|Станислав|Анатолий|Валентин|Владимир|Всеволод|Вячеслав|Геннадий|Григорий|Алексей|Аркадий|Арсений|Валерий|Василий|Виталий|Георгий|Дмитрий|Евгений|Николай|Савелий|Тимофей|Ярослав|Андрей|Богдан|Виктор|Герман|Даниил|Данила|Кирилл|Леонид|Максим|Матвей|Михаил|Никита|Руслан|Сергей|Степан|Эдуард|Антон|Артем|Артём|Борис|Вадим|Данил|Денис|Игорь|Макар|Марат|Мирон|Павел|Роман|Семен|Семён|Тимур|Федор|Фёдор|Глеб|Егор|Иван|Илья|Марк|Олег|Петр|Пётр|Юрий|Лев)(?:а|у|ом|ем|е|ой|я|ю|й)?)|(?:Любовь))\s+[ЁА-Я][ёа-я]+(?:-[ЁА-Я][ёа-я]+)?)|(?:[ЁА-Я][ёа-я]+(?:ов|ев|ёв|ин|ын|ск|цк|енк|ук|юк|ич|шин|нко|ая|яя|ой|ый|ий|ых|их)[ёа-я]{0,3}\s+(?:(?:(?:Александр|Анастаси|Валентин|Екатерин|Елизавет|Маргарит|Алевтин|Ангелин|Антонин|Вероник|Виктори|Кристин|Светлан|Валери|Варвар|Евгени|Зинаид|Клавди|Людмил|Надежд|Натали|Наталь|Татьян|Анжел|Галин|Карин|Ксени|Ларис|Марин|Милан|Оксан|Полин|Регин|Таиси|Тамар|Ульян|Ален|Алин|Алис|Алён|Дарь|Диан|Елен|Жанн|Ирин|Лиди|Лили|Мари|Марь|Олес|Ольг|Раис|Софи|Софь|Алл|Анн|Вер|Дин|Инн|Кир|Нин|Юли|Ев|Зо|Ян)(?:а|я|ы|е|у|ю|ой|ей))|(?:(?:Константин|Александр|Владислав|Станислав|Анатолий|Валентин|Владимир|Всеволод|Вячеслав|Геннадий|Григорий|Алексей|Аркадий|Арсений|Валерий|Василий|Виталий|Георгий|Дмитрий|Евгений|Николай|Савелий|Тимофей|Ярослав|Андрей|Богдан|Виктор|Герман|Даниил|Данила|Кирилл|Леонид|Максим|Матвей|Михаил|Никита|Руслан|Сергей|Степан|Эдуард|Антон|Артем|Артём|Борис|Вадим|Данил|Денис|Игорь|Макар|Марат|Мирон|Павел|Роман|Семен|Семён|Тимур|Федор|Фёдор|Глеб|Егор|Иван|Илья|Марк|Олег|Петр|Пётр|Юрий|Лев)(?:а|у|ом|ем|е|ой|я|ю|й)?)|(?:Любовь))))(?:[^ЁА-Яёа-я]|$)"##),
        PIIRule("pii.phone-ru", "PHONE_RU", groups: [1], minLength: 10, pattern: ##"(?:^|[^\d])((?:\+7|8)[\s\-]?\(?\d{3}\)?[\s\-]?\d{3}[\s\-]?\d{2}[\s\-]?\d{2})\b"##),
        PIIRule("pii.email", "EMAIL", groups: [1], minLength: 6, validators: [.emailASCII], pattern: ##"(?:^|[^\w\\])([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,63})\b"##),
        PIIRule("pii.docs.snils", "SNILS", validators: [.snils], pattern: ##"\b\d{3}[\s-]?\d{3}[\s-]?\d{3}[\s-]?\d{2}\b"##),
        PIIRule("pii.docs.passport", "PASSPORT_RF", groups: [1], pattern: ##"(?i)(?:паспорт[а-яё]*|пасп\.?|серия)(?:[\s,.:;!?()«»"\x27-]+[а-яё]+){0,3}[\s,.:;!?()«»"\x27№-]*(\d{2}[\s-]?\d{2}[\s-]*(?:(?:№|номер)[\s№:.-]*)?\d{6})(?:\D|$)"##),
        PIIRule("pii.docs.kpp", "KPP", groups: [1], pattern: ##"(?i)кпп(?:[\s,.:;!?()«»"\x27-]+[а-яёa-z]+){0,3}[\s,.:;!?()«»"\x27-]*(\d{4}[\dА-ЯA-Z]{2}\d{3})\b"##),
        PIIRule("pii.docs.address", "ADDRESS", groups: [1], pattern: ##"(?i)(?:^|[\s.,:;!?(])((?:[Гг]\.?\s?(?-i:[ЁА-Я])[ёа-я\-]+,?\s+)?(?:ул(?:иц[аеу])?|пр-т|пр\.|просп(?:ект)?|пер(?:еул(?:ок)?)?\.?|пл(?:ощадь)?|б-р|бул(?:ьвар)?|шоссе|ш\.|наб(?:ережная)?|проезд|алл(?:ея)?)\.?\s+(?:(?-i:[ЁА-Я])[ёа-яЁА-Я0-9.\-]*[,\s]+){1,3}(?:д(?:ом)?\.?\s?)?\d+[а-я]?(?:\s?(?:к(?:орп(?:ус)?)?|стр(?:оение)?)\.?\s?\d+)?(?:[,\s]+(?:кв(?:артира)?|подъезд|под|офис)\.?\s?\d+[а-я]?)?|(?:(?-i:[ЁА-Я])[ёа-яЁА-Я0-9.\-]*\s+){1,2}(?:проспект|улиц[аеу]|переулок|площадь|шоссе|бульвар|набережная|проезд)[,\s]+(?:д(?:ом)?\.?\s?)?\d+[а-я]?(?:[,\s]+(?:кв(?:артира)?|подъезд|под|офис|корпус|к)\.?\s?\d+[а-я]?)?|(?-i:[ЁА-Я])[ёа-яЁА-Я0-9.\-]*\s+\d+[а-я]?\s?(?:(?:корп(?:ус)?\.?|к\.)\s?\d+|(?:,?\s?(?:кв(?:артира)?|подъезд)\.?\s?(?!(?:19|20)\d\d(?!\d))\d{1,4}(?!\d))))"##),
        PIIRule("pii.docs.inn-person", "INN_PERSON", minLength: 12, validators: [.innPerson], pattern: ##"\b\d{12}\b"##),
        PIIRule("pii.docs.inn-org", "INN_ORG", minLength: 10, validators: [.innOrg], pattern: ##"\b\d{10}\b"##),
        PIIRule("pii.docs.ogrn", "OGRN", minLength: 13, validators: [.ogrn], pattern: ##"\b\d{13}\b"##),
        PIIRule("pii.docs.ogrnip", "OGRNIP", minLength: 15, validators: [.ogrnip], pattern: ##"\b3\d{14}\b"##),
        PIIRule("pii.fin.credit-card", "CREDIT_CARD", minLength: 13, validators: [.luhn, .paymentCard], pattern: ##"\b(?:4|5[1-5]|2(?:2(?:2[1-9]|[3-9]\d)|[3-6]\d{2}|7(?:0\d|20))|3[47]|6011|64[4-9]|65|62|220[0-4])(?:[ -]?\d){11,17}\b"##),
        PIIRule("pii.fin.credit-card.context", "CREDIT_CARD", groups: [1], minLength: 13, validators: [.paymentCardShape], pattern: ##"(?i)(?:карт[аеуы]|карточк[аеиуой]|card|visa|mastercard|maestro|маэстро)[\s:.,;№#()\-/]{1,4}((?:4|5[1-5]|2(?:2(?:2[1-9]|[3-9]\d)|[3-6]\d{2}|7(?:0\d|20))|3[47]|6011|64[4-9]|65|62|220[0-4])(?:[ -]?\d){11,17})"##),
        PIIRule("pii.fin.iban", "IBAN", minLength: 15, validators: [.ibanMod97], pattern: ##"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}\b"##),
        PIIRule("pii.fin.cvc", "CVC", groups: [1, 2], pattern: ##"(?i)(?:(?:cvc|cvv|цвс|cvv2|cvc2|код\s+безопасности)(?:[\s,.:;!?()«»"\x27-]+[а-яё]+){0,3}[\s,.:;!?()«»"\x27-]*(\d{3})|(?:обороте?\s+карт[а-яё]*|сзади\s+карт[а-яё]*|на\s+обороте|код\s+подтвержден[а-яё]+\s+карт[а-яё]*|цифры\s+(?:на\s+)?обороте|карт[а-яё]*\s+для\s+бронировани[а-яё]*)(?:[^\d]{0,20})(\d{3}))\b"##),
        PIIRule("credentials.url_with_creds", "URL_WITH_CREDS", groups: [1], pattern: ##"(?i)((?:https?|ftp)://[^:\s@/\\]+:[^@\s/'"`,\\]{3,}@[^\s'"`\\,;!?()\[\]{}]*[^\s'"`\\,;.!?()\[\]{}])(?:[\x60'"\s,;.!?()\[\]{}]|\\[nr]|$)"##),
        PIIRule("credentials.db_connection", "DB_DSN", groups: [1], pattern: ##"(?i)((?:postgres(?:ql)?|mysql|mssql|mongodb(?:\+srv)?)://[^:@\s\\]+:[^@\s'"`\,\\]{3,}@[^\s'"`\,;!?()\[\]{}\\]*[^\s'"`\,;.!?()\[\]{}\\])(?:[\x60'"\s,;.!?()\[\]{}]|\\[nr]|$)"##),
        PIIRule("credentials.http_auth_bearer", "BEARER_TOKEN", groups: [1], pattern: ##"(?i)Authorization:\s*(?:Bearer|Token)\s+([A-Za-z0-9\-_.~+/]{12,512})(?:[\x60'"\s,;:!?()\[\]{}]|\\[nr]|$)"##),
        PIIRule("credentials.password", "PASSWORD", groups: [1, 2, 3, 4, 5], pattern: ##"(?i)(?:password|passwd|pwd)\s*[:=>{]+\s*(?:"([^"\\\r\n]{6,256})"|'([^'\\\r\n]{6,256})'|"([^\\\s'"`\,;:)\]\}]{6,256})|'([^\\\s'"`\,;:)\]\}]{6,256})|([^\\\s'"`\,;:)\]\}]{6,256}))(?:[\x60'"\s,;:()\[\]{}]|\\[nr]|$)"##),
        PIIRule("access_tokens.generic-token", "TOKEN", groups: [1, 2, 3], pattern: ##"(?i)(?:(?:api[\s-]?(?:ключ|key)|access[\s-]?token|reset[\s-]?токен|токен|token)(?:[\s,.:;!?()«»"\x27-]+[а-яё]+){0,5}[\s,.:;!?()«»"\x27-]*([A-Za-z0-9]{16,})|\b((?:api|key|token|tok|sk|pk|secret|access)_[A-Za-z0-9]{16,})|(?:смс\s+с\s+код[а-яё]*|код\s+(?:восстановлени[а-яё]+|подтвержден[а-яё]+|активаци[а-яё]+|из\s+смс|для\s+(?:подтвержден[а-яё]+|активаци[а-яё]+|верификац[а-яё]+))|otp|one-time|(?:пришел|пришёл|получил)\s+код)(?:[^\d]{0,15})(\d{4,8}))\b"##),
        PIIRule("access_tokens.private-key-pem", "PEM_KEY", pattern: ##"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]+?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"##),
        PIIRule("ip-addrs.ipv4", "IPV4", validators: [.ipv4], pattern: ##"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"##),
    ]

    /// Meteora additions: things meetings at a pension fund do contain and the
    /// upstream ruleset doesn't cover.
    public static let meteora: [PIIRule] = [
        // Russian bank account: 20 digits, contiguous or in the usual groups
        // (40817 810 0 9999 1234567, 40817-81009-99912-34567, 4081 7810 …).
        PIIRule("meteora.account-ru", "BANK_ACCOUNT", groups: [1], upstream: false,
                pattern: ##"(?<![\d.,])(\d{20}|\d{5}[ .\-]\d{3}[ .\-]\d[ .\-]?\d{4}[ .\-]?\d{7}|\d{5}(?:[ .\-]\d{5}){3}|\d{4}(?:[ .\-]\d{4}){4})(?![\d]|[.,]\d)"##),
        // Date of birth: only next to «дата рождения», «д.р.», «родился»,
        // «г.р.», «года рождения» — deadlines and other dates stay.
        PIIRule("meteora.birth-date", "BIRTH_DATE", groups: [1, 2], upstream: false,
                pattern: ##"(?i)(?:(?:дат[аеуы]\s+рождения|д\.\s?р\.|д/р|родил(?:ся|ась|ись)|рожд[её]н(?:а|ный|ная)?)[\s:,\-—–]*(?:в\s+)?(\d{1,2}[./\-]\d{1,2}[./\-](?:19|20)?\d{2}(?!\d)|\d{1,2}\s+(?:января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря)(?:\s+(?:19|20)\d{2}(?!\d)(?:\s*(?:г\.|год[ау]?))?)?|(?:19|20)\d{2}(?!\d)(?:\s*(?:г\.|год[ау]?))?)|(?<![\d.])((?:\d{1,2}[./]\d{1,2}[./])?(?:19|20)\d{2})\s*(?:г\.\s?р\.|года\s+рождения))"##),
    ]
}

/// Synthetic examples for tests and the self-test: values that must be
/// hidden (with the expected placeholder type) and ordinary meeting phrases
/// that must stay untouched. All numbers are made up; checksums are valid.
public enum PIISamples {
    public static let positives: [(text: String, type: String)] = [
        ("Позвоните мне: +7 916 123-45-67", "PHONE_RU"),
        ("мой номер 8 (495) 123-45-67, звоните", "PHONE_RU"),
        ("номер 89161234567", "PHONE_RU"),
        ("пишите на ivan.petrov@example.ru до пятницы", "EMAIL"),
        ("паспорт 4509 123456 выдан", "PASSPORT_RF"),
        ("паспортные данные: серия 45 09 номер 123456", "PASSPORT_RF"),
        ("СНИЛС 112-233-445 95", "SNILS"),
        ("СНИЛС клиента 11223344595", "SNILS"),
        ("ИНН 500100732259", "INN_PERSON"),
        ("ИНН организации 7707083893", "INN_ORG"),
        ("ОГРН 1027700132195", "OGRN"),
        ("карта 2200 1234 5678 9019", "CREDIT_CARD"),
        ("номер 4276380012345679 списали", "CREDIT_CARD"),
        ("на карту 2200 1234 5678 9010", "CREDIT_CARD"),
        ("счёт 40817810099910004312 в банке", "BANK_ACCOUNT"),
        ("счёт 40817 810 0 9991 0004312", "BANK_ACCOUNT"),
        ("дата рождения 12.03.1985", "BIRTH_DATE"),
        ("родилась 5 мая 1990 года", "BIRTH_DATE"),
        ("клиент 1985 г.р. обратился", "BIRTH_DATE"),
        ("Иванов Иван Иванович подписал", "FIO"),
        ("передайте Смирновой Анне Сергеевне", "FIO"),
        ("подпись: Смирнова А.С.", "FIO"),
        ("звонила Анна Смирнова", "FIO"),
        ("адрес: г. Москва, ул. Тверская, д. 15, кв. 4", "ADDRESS"),
        ("живёт на Ленинградский проспект, дом 45", "ADDRESS"),
        ("IBAN DE89370400440532013000", "IBAN"),
        ("код безопасности 123", "CVC"),
        ("password: Qw3rty!2026x", "PASSWORD"),
    ]

    public static let negatives: [String] = [
        "Сдать отчёт до 15.11.2026, бюджет 1 500 000 рублей, рост 12,5 %.",
        "Встречаемся в 14:30, срок — 3 недели, конверсия выросла на 2,3 п.п.",
        "План на 3 кв. 2026 года: 250 тыс. клиентов и 40% автоплатежей.",
        "Отчёт 3 кв 2026 сдаём до 20 января.",
        "Этап 2 к 15 ноября, Задача 1 к 20 числу.",
        "Вариант 2 под 10 человек, Глава 5 под 3 пункта.",
        "Сумма взносов 8 500 000 руб., ставка 7,5% годовых, номер задачи 4512.",
        "Версия 2.4.1 выйдет 01.12.2026, пункт 3.1 договора, приложение № 5.",
        "Звонок в 10:00, 25 человек, NPS 72, выручка 1,2 млрд.",
        "Иван предложил перенести на пятницу, Мария согласна.",
        "Москва, Санкт-Петербург и Казань дали 45% продаж.",
        "Газфонд пенсионные накопления запускает акцию с 1 декабря по 31 января.",
        "С 2027 года взнос 36 000 рублей в год, софинансирование до 36 тыс.",
        "Дедлайн 2026-12-31, бюджет 3 млн, ROI 140%.",
        "Новый Год, Добрый день всем, Спасибо большое.",
        "ПДС и ОПС: доходность 9,8% за 2025 год, 1 200 000 клиентов.",
        "Обсудили KPI: 15 000 договоров, конверсия 3,5%, срок до 30.06.2027.",
        "Рождённые в 1990-х чаще выбирают автоплатёж.",
    ]
}
