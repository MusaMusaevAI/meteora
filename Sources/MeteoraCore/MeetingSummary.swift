import Foundation

/// A meeting summary produced on the Mac by the local language model.
/// Pure data: generation lives in MeteoraLLM, UI in the app.
public struct MeetingSummary: Codable, Equatable, Sendable {
    /// Short topic (≤ 60 characters), followed by " — <date, time>" when the
    /// meeting date was known.
    public var title: String
    /// 2–5 sentences.
    public var summary: String
    public var keyPoints: [String]
    public var decisions: [String]
    /// "Owner: task, deadline" when an owner was named, otherwise just the task.
    public var actionItems: [String]

    public init(title: String, summary: String, keyPoints: [String] = [], decisions: [String] = [],
                actionItems: [String] = []) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
    }

    private enum CodingKeys: String, CodingKey { case title, summary, keyPoints, decisions, actionItems }

    /// Tolerant decoding: missing fields become empty, so summaries saved by
    /// another version always load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        keyPoints = (try? c.decode([String].self, forKey: .keyPoints)) ?? []
        decisions = (try? c.decode([String].self, forKey: .decisions)) ?? []
        actionItems = (try? c.decode([String].self, forKey: .actionItems)) ?? []
    }

    public var isEmpty: Bool {
        summary.isEmpty && keyPoints.isEmpty && decisions.isEmpty && actionItems.isEmpty
    }

    // MARK: Title

    public static let maxTopicLength = 60

    /// "Тема встречи — 29 октября 2026, 14:30". The topic is cut to 60
    /// characters at a word boundary; the date is added only when known.
    public static func composeTitle(topic: String, date: Date?, timeZone: TimeZone = .current) -> String {
        var t = MeetingSummaryParser.cleanItem(topic)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"«»“”'.:;— -"))
        if t.count > maxTopicLength {
            let cut = String(t.prefix(maxTopicLength - 1))
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > maxTopicLength / 2 {
                t = String(cut[..<space])
            } else {
                t = cut
            }
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: ",;:— -")) + "…"
        }
        if t.isEmpty { t = "Встреча" }
        guard let date else { return t }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = timeZone
        f.dateFormat = "d MMMM yyyy, HH:mm"
        return "\(t) — \(f.string(from: date))"
    }

    // MARK: Rendering

    /// Markdown for export or pasting. Model output is derived from an
    /// untrusted recording, so every line is escaped (no links, images, HTML).
    public func markdown() -> String {
        func esc(_ s: String) -> String { ReportExporter.escapeMarkdown(s) }
        var out = "# \(esc(title))\n\n"
        if !summary.isEmpty { out += esc(summary) + "\n\n" }
        for (heading, items) in sections where !items.isEmpty {
            out += "## \(heading)\n\n"
            for i in items { out += "- \(esc(i))\n" }
            out += "\n"
        }
        out += "> Резюме составлено автоматически локальной моделью по расшифровке встречи. Проверьте важное по записи.\n"
        return out
    }

    /// Plain text (clipboard, .txt).
    public func plainText() -> String {
        var out = title + "\n\n"
        if !summary.isEmpty { out += summary + "\n\n" }
        for (heading, items) in sections where !items.isEmpty {
            out += heading + ":\n"
            for i in items { out += "• \(i)\n" }
            out += "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    public var sections: [(String, [String])] {
        [("Ключевые моменты", keyPoints), ("Решения", decisions), ("Задачи", actionItems)]
    }
}

// MARK: - Parsing model output

/// Turns whatever the model wrote into a `MeetingSummary`: JSON first (code
/// fences, "thinking" blocks, prose around it, trailing commas and a cut-off
/// end are tolerated), then a plain "Заголовок: / Решения: / - пункт" layout.
public enum MeetingSummaryParser {
    public struct Parsed: Equatable, Sendable {
        public var title: String
        public var summary: String
        public var keyPoints: [String]
        public var decisions: [String]
        public var actionItems: [String]
        /// true when the text was valid (possibly repaired) JSON.
        public var fromJSON: Bool

        public init(title: String = "", summary: String = "", keyPoints: [String] = [], decisions: [String] = [],
                    actionItems: [String] = [], fromJSON: Bool = false) {
            self.title = title
            self.summary = summary
            self.keyPoints = keyPoints
            self.decisions = decisions
            self.actionItems = actionItems
            self.fromJSON = fromJSON
        }

        public var isEmpty: Bool {
            title.isEmpty && summary.isEmpty && keyPoints.isEmpty && decisions.isEmpty && actionItems.isEmpty
        }
    }

    public static func parse(_ raw: String) -> Parsed {
        let text = stripThinking(raw)
        if let obj = jsonObject(in: text) {
            let p = fromJSON(obj)
            if !p.isEmpty { return p }
        }
        return fromSections(stripFences(text))
    }

    // MARK: Cleanup

    /// Removes <think>…</think> (also an unterminated one at the end).
    static func stripThinking(_ s: String) -> String {
        var t = s
        while let open = t.range(of: "<think>") {
            if let close = t.range(of: "</think>", range: open.upperBound ..< t.endIndex) {
                t.removeSubrange(open.lowerBound ..< close.upperBound)
            } else {
                t.removeSubrange(open.lowerBound ..< t.endIndex)
            }
        }
        // A stray closing tag (the opening one was in the prompt).
        if let close = t.range(of: "</think>") { t.removeSubrange(t.startIndex ..< close.upperBound) }
        return t
    }

    static func stripFences(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
    }

    // MARK: JSON

    /// First JSON object in the text, repairing what small models get wrong.
    static func jsonObject(in text: String) -> [String: Any]? {
        let t = stripFences(text)
        guard let start = t.firstIndex(of: "{") else { return nil }
        let candidate = balancedObject(String(t[start...]))
        func decode(_ s: String) -> [String: Any]? {
            guard let data = s.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
        }
        for attempt in [candidate, removeTrailingCommas(candidate), removeTrailingCommas(closeTruncated(candidate))] {
            if let obj = decode(attempt) { return obj }
        }
        // Cut off mid-value: drop back to the last complete value and close.
        for comma in commaPositions(candidate).reversed().prefix(64) {
            if let obj = decode(removeTrailingCommas(closeTruncated(String(candidate[..<comma]))))  { return obj }
        }
        return nil
    }

    /// Positions of commas outside strings.
    static func commaPositions(_ s: String) -> [String.Index] {
        var out: [String.Index] = []
        var inString = false, escaped = false
        for i in s.indices {
            let ch = s[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true } else if ch == "," { out.append(i) }
        }
        return out
    }

    /// True once the text holds a complete top-level JSON object (used to
    /// stop generation as soon as the answer is finished).
    public static func isCompleteObject(_ s: String) -> Bool {
        guard let start = s.firstIndex(of: "{") else { return false }
        let obj = balancedObject(String(s[start...]))
        return obj.last == "}" && balancedDepthIsZero(obj)
    }

    static func balancedDepthIsZero(_ s: String) -> Bool {
        var depth = 0, inString = false, escaped = false
        for ch in s {
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            default: break
            }
        }
        return depth == 0 && !inString
    }

    /// Text up to the brace that closes the first one (string-aware), or all
    /// of it when the object never closes (output cut by the token limit).
    static func balancedObject(_ s: String) -> String {
        var depth = 0, inString = false, escaped = false
        var end = s.endIndex
        loop: for i in s.indices {
            let ch = s[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { end = s.index(after: i); break loop }
            default: break
            }
        }
        return String(s[..<end])
    }

    static func removeTrailingCommas(_ s: String) -> String {
        var out = ""
        var inString = false, escaped = false
        var pendingComma = false, pendingSpace = ""
        for ch in s {
            if inString {
                out.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            if pendingComma {
                if ch.isWhitespace { pendingSpace.append(ch); continue }
                if ch != "}" && ch != "]" { out.append(",") }
                out += pendingSpace
                pendingComma = false
                pendingSpace = ""
            }
            if ch == "," { pendingComma = true; continue }
            if ch == "\"" { inString = true }
            out.append(ch)
        }
        return out
    }

    /// Closes an unterminated string, drops a dangling key or comma, then
    /// closes open arrays/objects in order.
    static func closeTruncated(_ s: String) -> String {
        var stack: [Character] = []
        var inString = false, escaped = false
        for ch in s {
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{": stack.append("}")
            case "[": stack.append("]")
            case "}", "]": if !stack.isEmpty { stack.removeLast() }
            default: break
            }
        }
        var t = s
        if escaped { t.removeLast() }
        if inString { t += "\"" }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // `"key":` or `"key"` with no value, or a trailing comma.
        while let last = t.last, last == "," || last == ":" {
            t.removeLast()
            if last == ":", let q = t.lastIndex(of: "\"") {
                // Remove the dangling key string.
                let head = t[..<q]
                if let q2 = head.lastIndex(of: "\"") { t = String(t[..<q2]) }
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t + String(stack.reversed())
    }

    static let titleKeys = ["title", "заголовок", "тема", "topic", "name"]
    static let summaryKeys = ["summary", "резюме", "краткое_содержание", "кратко", "overview", "описание"]
    static let keyPointKeys = ["key_points", "keypoints", "key points", "основные_моменты", "ключевые_моменты",
                               "тезисы", "points", "highlights", "главное"]
    static let decisionKeys = ["decisions", "решения", "договоренности", "договорённости", "agreements"]
    static let actionKeys = ["action_items", "actionitems", "action items", "tasks", "todo", "задачи",
                             "поручения", "действия", "next_steps"]

    static func value(_ obj: [String: Any], _ keys: [String]) -> Any? {
        let normalized = Dictionary(obj.map { ($0.key.lowercased().replacingOccurrences(of: "-", with: "_"), $0.value) },
                                    uniquingKeysWith: { a, _ in a })
        for k in keys {
            if let v = normalized[k] { return v }
            if let v = normalized[k.replacingOccurrences(of: " ", with: "_")] { return v }
            if let v = normalized[k.replacingOccurrences(of: "_", with: "")] { return v }
        }
        return nil
    }

    static func fromJSON(_ obj: [String: Any]) -> Parsed {
        var p = Parsed(fromJSON: true)
        p.title = text(value(obj, titleKeys))
        p.summary = text(value(obj, summaryKeys))
        p.keyPoints = list(value(obj, keyPointKeys))
        p.decisions = list(value(obj, decisionKeys))
        p.actionItems = list(value(obj, actionKeys), actions: true)
        return p
    }

    static func text(_ v: Any?) -> String {
        switch v {
        case let s as String: return cleanItem(s)
        case let a as [Any]: return a.map { text($0) }.filter { !$0.isEmpty }.joined(separator: " ")
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }

    static func list(_ v: Any?, actions: Bool = false) -> [String] {
        var raw: [String] = []
        switch v {
        case let s as String:
            raw = s.split(whereSeparator: \.isNewline).map(String.init)
        case let a as [Any]:
            for item in a {
                if let d = item as? [String: Any] {
                    raw.append(actions ? actionText(d) : d.values.map { text($0) }.filter { !$0.isEmpty }.joined(separator: " — "))
                } else {
                    raw.append(text(item))
                }
            }
        default: break
        }
        return dedupe(raw.map(cleanItem).filter(isMeaningful))
    }

    /// {"owner": "Иван", "task": "…", "due": "пятница"} → "Иван: …, срок — пятница".
    static func actionText(_ d: [String: Any]) -> String {
        let owner = text(value(d, ["owner", "ответственный", "assignee", "кто", "who", "responsible"]))
        let task = text(value(d, ["task", "задача", "action", "что", "what", "description", "item"]))
        let due = text(value(d, ["due", "deadline", "срок", "when", "когда"]))
        var s = task.isEmpty ? d.values.map { text($0) }.filter { !$0.isEmpty }.joined(separator: " — ") : task
        if !owner.isEmpty, isMeaningful(owner) { s = "\(owner): \(s)" }
        if !due.isEmpty, isMeaningful(due) { s += ", срок — \(due)" }
        return s
    }

    // MARK: Section fallback

    enum Section { case title, summary, keyPoints, decisions, actions }

    static func heading(_ line: String) -> (Section, String)? {
        var l = line.trimmingCharacters(in: .whitespaces)
        while l.hasPrefix("#") || l.hasPrefix("*") { l.removeFirst() }
        l = l.trimmingCharacters(in: .whitespaces)
        let lower = l.lowercased()
        let table: [(Section, [String])] = [
            (.title, ["заголовок", "тема", "title"]),
            (.summary, ["резюме", "краткое содержание", "кратко", "summary", "итог"]),
            (.keyPoints, ["ключевые моменты", "основные моменты", "главное", "тезисы", "key points"]),
            (.decisions, ["решения", "принятые решения", "договорённости", "договоренности", "decisions"]),
            (.actions, ["задачи", "поручения", "следующие шаги", "action items", "действия"]),
        ]
        for (section, names) in table {
            for n in names where lower.hasPrefix(n) {
                var rest = String(l.dropFirst(n.count))
                rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "*: \t"))
                // "Решения" as the first word of a normal sentence is not a heading.
                if !rest.isEmpty && !(l.dropFirst(n.count).trimmingCharacters(in: CharacterSet(charactersIn: "* ")).hasPrefix(":")) {
                    continue
                }
                return (section, rest)
            }
        }
        return nil
    }

    static func fromSections(_ text: String) -> Parsed {
        var p = Parsed()
        var current: Section? = nil
        var summaryLines: [String] = []
        var loose: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let h = heading(line) {
                current = h.0
                if !h.1.isEmpty { append(h.1, to: h.0, &p, &summaryLines) }
                continue
            }
            if let section = current {
                append(line, to: section, &p, &summaryLines)
            } else {
                loose.append(line)
            }
        }
        p.summary = cleanItem(summaryLines.joined(separator: " "))
        if p.summary.isEmpty && p.keyPoints.isEmpty && p.decisions.isEmpty && p.actionItems.isEmpty {
            // No structure at all: keep the prose as the summary.
            p.summary = cleanItem(loose.joined(separator: " "))
        }
        p.keyPoints = dedupe(p.keyPoints.filter(isMeaningful))
        p.decisions = dedupe(p.decisions.filter(isMeaningful))
        p.actionItems = dedupe(p.actionItems.filter(isMeaningful))
        return p
    }

    static func append(_ line: String, to section: Section, _ p: inout Parsed, _ summaryLines: inout [String]) {
        let item = cleanItem(line)
        guard !item.isEmpty else { return }
        switch section {
        case .title: if p.title.isEmpty { p.title = item }
        case .summary: summaryLines.append(item)
        case .keyPoints: p.keyPoints.append(item)
        case .decisions: p.decisions.append(item)
        case .actions: p.actionItems.append(item)
        }
    }

    // MARK: Items

    /// One line, no list markers or wrapping quotes, single spaces.
    public static func cleanItem(_ s: String) -> String {
        var t = TranscriptExporter.cleanLine(s)
        var changed = true
        while changed {
            changed = false
            for prefix in ["- ", "– ", "— ", "• ", "* ", "· ", "▪ ", "□ ", "[ ] ", "[x] "] where t.hasPrefix(prefix) {
                t.removeFirst(prefix.count); changed = true
            }
            // "1. ", "2) "
            if let dot = t.firstIndex(where: { $0 == "." || $0 == ")" }), t.distance(from: t.startIndex, to: dot) <= 3,
               t[..<dot].allSatisfy(\.isNumber), !t[..<dot].isEmpty {
                let after = t.index(after: dot)
                if after < t.endIndex, t[after] == " " { t = String(t[t.index(after: after)...]); changed = true }
            }
            t = t.trimmingCharacters(in: .whitespaces)
        }
        t = t.replacingOccurrences(of: "**", with: "")
        if t.count >= 2, let f = t.first, let l = t.last, (f == "\"" && l == "\"") || (f == "«" && l == "»") {
            t = String(t.dropFirst().dropLast())
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func isMeaningful(_ s: String) -> Bool {
        let l = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .—-–()"))
        if l.isEmpty { return false }
        let empty: Set<String> = ["нет", "не указано", "не указаны", "не названо", "отсутствуют", "отсутствует",
                                  "нет данных", "n/a", "none", "null", "—", "не определено", "не обсуждалось",
                                  "не было", "решений нет", "задач нет", "не назначены", "не принято", "не приняты"]
        return !empty.contains(l)
    }

    static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for i in items {
            let key = i.lowercased().filter { $0.isLetter || $0.isNumber }
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            out.append(i)
        }
        return out
    }
}

// MARK: - Transcript → model input

/// Prepares a transcript for the model: paragraphs with a time stamp and the
/// speaker (when known), split into chunks that fit the context window.
public enum MeetingTranscriptText {
    /// "[0:12] Иван: текст абзаца" per paragraph.
    public static func lines(_ tr: Transcript) -> [String] {
        let hours = tr.duration >= 3600
        return TranscriptExporter.paragraphs(tr.segments, options: .standard).compactMap { p in
            let text = p.text
            guard !text.isEmpty else { return nil }
            let stamp = Timecode.string(p.start, alwaysHours: hours)
            if let sp = p.speaker { return "[\(stamp)] \(sp): \(text)" }
            return "[\(stamp)] \(text)"
        }
    }

    /// Speakers named in the transcript, in order of first appearance.
    public static func speakers(_ tr: Transcript) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in tr.segments {
            guard let raw = s.speaker else { continue }
            let name = TranscriptExporter.cleanLine(raw)
            if !name.isEmpty, seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    /// Greedy packing of lines into chunks of at most `budget` tokens (as
    /// counted by `count`). A line longer than the budget is split at
    /// sentence ends, then at spaces, then hard.
    public static func chunks(_ lines: [String], budget: Int, count: (String) -> Int) -> [String] {
        let budget = max(8, budget)
        var pieces: [(String, Int)] = []
        for line in lines {
            let n = count(line)
            if n <= budget { pieces.append((line, n)); continue }
            for part in split(line, budget: budget, count: count) { pieces.append((part, count(part))) }
        }
        var out: [String] = []
        var current: [String] = []
        var used = 0
        for (text, n) in pieces {
            if !current.isEmpty && used + n + 1 > budget {
                out.append(current.joined(separator: "\n"))
                current = []
                used = 0
            }
            current.append(text)
            used += n + 1
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n")) }
        return out
    }

    static func split(_ line: String, budget: Int, count: (String) -> Int) -> [String] {
        // Sentences first.
        var sentences: [String] = []
        var cur = ""
        for ch in line {
            cur.append(ch)
            if ".!?…".contains(ch) { sentences.append(cur); cur = "" }
        }
        if !cur.isEmpty { sentences.append(cur) }
        var out: [String] = []
        var acc = ""
        func flush() { let t = acc.trimmingCharacters(in: .whitespaces); if !t.isEmpty { out.append(t) }; acc = "" }
        for s in sentences {
            if count(acc + s) <= budget { acc += s; continue }
            flush()
            if count(s) <= budget { acc = s; continue }
            // Words.
            for w in s.split(separator: " ", omittingEmptySubsequences: true) {
                let candidate = acc.isEmpty ? String(w) : acc + " " + w
                if count(candidate) <= budget { acc = candidate; continue }
                flush()
                if count(String(w)) <= budget { acc = String(w); continue }
                // A single absurdly long "word": hard cut by characters.
                var rest = Substring(w)
                let step = max(16, budget)
                while !rest.isEmpty { out.append(String(rest.prefix(step))); rest = rest.dropFirst(step) }
            }
        }
        flush()
        return out
    }
}
