import Foundation
import CoreGraphics

// MARK: - Options

/// Where time codes appear in text exports.
public enum TimestampMode: String, CaseIterable, Codable, Sendable {
    case none
    case paragraph
    case phrase

    public var title: String {
        switch self {
        case .none: return "без времени"
        case .paragraph: return "у абзацев"
        case .phrase: return "у каждой фразы"
        }
    }
}

public struct TranscriptExportOptions: Codable, Equatable, Sendable {
    public var timestamps: TimestampMode
    /// Glue consecutive phrases into paragraphs (by pauses and length).
    public var paragraphs: Bool
    /// A pause of at least this many seconds starts a new paragraph.
    public var pauseForParagraph: Double
    /// A paragraph never spans more than this many seconds.
    public var maxParagraphSeconds: Double
    public var includeFrames: Bool
    public var includeFrameText: Bool

    public static let standard = TranscriptExportOptions()

    public init(timestamps: TimestampMode = .paragraph,
                paragraphs: Bool = true,
                pauseForParagraph: Double = 1.6,
                maxParagraphSeconds: Double = 75,
                includeFrames: Bool = true,
                includeFrameText: Bool = true) {
        self.timestamps = timestamps
        self.paragraphs = paragraphs
        self.pauseForParagraph = pauseForParagraph
        self.maxParagraphSeconds = maxParagraphSeconds
        self.includeFrames = includeFrames
        self.includeFrameText = includeFrameText
    }

    private enum CodingKeys: String, CodingKey {
        case timestamps, paragraphs, pauseForParagraph, maxParagraphSeconds, includeFrames, includeFrameText
    }

    /// Tolerant decoding: missing or unknown values fall back to defaults, so
    /// settings saved by another version never fail to load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TranscriptExportOptions()
        let ts: TimestampMode? = try? c.decode(TimestampMode.self, forKey: .timestamps)
        let par: Bool? = try? c.decode(Bool.self, forKey: .paragraphs)
        let pause: Double? = try? c.decode(Double.self, forKey: .pauseForParagraph)
        let maxLen: Double? = try? c.decode(Double.self, forKey: .maxParagraphSeconds)
        let frames: Bool? = try? c.decode(Bool.self, forKey: .includeFrames)
        let frameText: Bool? = try? c.decode(Bool.self, forKey: .includeFrameText)
        timestamps = ts ?? d.timestamps
        paragraphs = par ?? d.paragraphs
        pauseForParagraph = pause ?? d.pauseForParagraph
        maxParagraphSeconds = maxLen ?? d.maxParagraphSeconds
        includeFrames = frames ?? d.includeFrames
        includeFrameText = frameText ?? d.includeFrameText
    }
}

// MARK: - Formats

public enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case txt, md, docx, pdf, rtf, html, srt, vtt, csv, json

    public var title: String {
        switch self {
        case .txt: return "Текст (.txt)"
        case .md: return "Markdown (.md)"
        case .docx: return "Word (.docx)"
        case .pdf: return "PDF (.pdf)"
        case .rtf: return "RTF (.rtf)"
        case .html: return "Веб-страница (.html)"
        case .srt: return "Субтитры SRT (.srt)"
        case .vtt: return "Субтитры WebVTT (.vtt)"
        case .csv: return "Таблица CSV (.csv)"
        case .json: return "JSON (.json)"
        }
    }

    public var fileExtension: String { rawValue }

    /// The format can carry pictures of key frames.
    public var supportsFrames: Bool {
        switch self {
        case .docx, .pdf, .html, .md: return true
        default: return false
        }
    }

    /// The format lists key frames at all (as pictures or as captions + text).
    public var includesFrameEntries: Bool {
        switch self {
        case .txt, .srt, .vtt: return false
        default: return true
        }
    }

    /// The timestamp switch and paragraph settings change the output.
    public var usesTimestampMode: Bool {
        switch self {
        case .srt, .vtt, .json: return false
        default: return true
        }
    }
}

public struct ExportAttachment: Equatable, Sendable {
    public var name: String
    public var data: Data
    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public struct ExportResult: Equatable, Sendable {
    public var primary: Data
    /// Extra files referenced by the primary file (Markdown images).
    public var attachments: [ExportAttachment]
    /// Folder (next to the primary file) the attachments belong in; the
    /// primary file links to `<attachmentFolder>/<name>`.
    public var attachmentFolder: String?

    public init(primary: Data, attachments: [ExportAttachment] = [], attachmentFolder: String? = nil) {
        self.primary = primary
        self.attachments = attachments
        self.attachmentFolder = attachmentFolder
    }
}

public enum ExportError: Error, LocalizedError, Equatable {
    case nothingToExport
    case unsafeFileName
    case tooLarge
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .nothingToExport: return "Нечего сохранять: нет ни расшифровки, ни кадров."
        case .unsafeFileName: return "Недопустимое имя файла."
        case .tooLarge: return "Документ слишком большой для этого формата."
        case .encodingFailed: return "Не удалось собрать документ."
        }
    }
}

// MARK: - Russian plurals

public enum RussianPlural {
    /// "1 фраза", "3 фразы", "16 фраз", "21 фраза", "11 фраз".
    public static func format(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(n) \(form(n, one, few, many))"
    }

    public static func form(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m100 = n.magnitude % 100
        let m10 = m100 % 10
        if m100 >= 11 && m100 <= 14 { return many }
        if m10 == 1 { return one }
        if m10 >= 2 && m10 <= 4 { return few }
        return many
    }
}

// MARK: - Paragraphs

/// Consecutive phrases glued together for reading.
public struct TranscriptParagraph: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var segments: [TranscriptSegment]

    public init(start: Double, end: Double, segments: [TranscriptSegment]) {
        self.start = start
        self.end = end
        self.segments = segments
    }

    public var speaker: String? {
        guard let s = segments.first?.speaker else { return nil }
        let clean = TranscriptExporter.cleanLine(s)
        return clean.isEmpty ? nil : clean
    }

    /// Text of all phrases joined with spaces.
    public var text: String {
        segments.map { TranscriptExporter.cleanLine($0.text) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension TranscriptExporter {
    /// A paragraph that grew past this many characters ends at the next
    /// sentence boundary.
    static let softParagraphCharacters = 700

    /// Groups phrases into paragraphs: a new paragraph starts after a pause of
    /// `pauseForParagraph`, when the paragraph would last longer than
    /// `maxParagraphSeconds`, or after ~700 characters at a sentence end.
    /// With `paragraphs == false` every phrase is its own block.
    public static func paragraphs(_ segments: [TranscriptSegment], options: TranscriptExportOptions) -> [TranscriptParagraph] {
        paragraphs(segments, options: options, breaks: [])
    }

    /// `breaks`: moments (key frames) a paragraph must not run across.
    static func paragraphs(_ segments: [TranscriptSegment], options: TranscriptExportOptions,
                           breaks: [Double]) -> [TranscriptParagraph] {
        let ordered: [TranscriptSegment] = segments.enumerated()
            .filter { $0.element.start.isFinite && !cleanLine($0.element.text).isEmpty }
            .sorted { a, b in
                if a.element.start != b.element.start { return a.element.start < b.element.start }
                return a.offset < b.offset
            }
            .map { $0.element }
        let cuts = breaks.filter { $0.isFinite }.sorted()
        let pause = options.pauseForParagraph.isFinite ? max(0, options.pauseForParagraph) : 1.6
        let maxLength = (options.maxParagraphSeconds.isFinite && options.maxParagraphSeconds > 0)
            ? options.maxParagraphSeconds : Double.greatestFiniteMagnitude

        var result: [TranscriptParagraph] = []
        var current: [TranscriptSegment] = []
        var currentStart = 0.0
        var currentEnd = 0.0
        var currentChars = 0
        var cutIndex = 0

        for seg in ordered {
            let segEnd = segmentEnd(seg)
            var forced = false
            while cutIndex < cuts.count && cuts[cutIndex] <= seg.start {
                if let last = current.last, cuts[cutIndex] > last.start { forced = true }
                cutIndex += 1
            }
            if let last = current.last {
                var split = forced || !options.paragraphs
                if !split && seg.start - currentEnd >= pause { split = true }
                if !split && max(currentEnd, segEnd) - currentStart > maxLength { split = true }
                if !split && currentChars >= softParagraphCharacters && endsSentence(last.text) { split = true }
                if !split && seg.speaker != last.speaker { split = true }
                if split {
                    result.append(TranscriptParagraph(start: currentStart, end: currentEnd, segments: current))
                    current = []
                }
            }
            if current.isEmpty {
                currentStart = seg.start
                currentEnd = segEnd
                currentChars = 0
            }
            current.append(seg)
            currentEnd = max(currentEnd, segEnd)
            currentChars += seg.text.count + 1
        }
        if !current.isEmpty {
            result.append(TranscriptParagraph(start: currentStart, end: currentEnd, segments: current))
        }
        return result
    }

    static func segmentEnd(_ seg: TranscriptSegment) -> Double {
        seg.end.isFinite ? max(seg.end, seg.start) : seg.start
    }

    static func endsSentence(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let closers: Set<Character> = ["»", "\"", "'", ")", "”", "’"]
        while let last = t.last, closers.contains(last) { t.removeLast() }
        guard let last = t.last else { return false }
        let enders: Set<Character> = [".", "!", "?", "…"]
        return enders.contains(last)
    }

    // MARK: Text hygiene

    static func isBidiControl(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069: return true
        default: return false
        }
    }

    /// One line of text: no control characters, no bidi overrides, single spaces.
    static func cleanLine(_ text: String) -> String {
        let space: Unicode.Scalar = " "
        var scalars = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if isBidiControl(u) { continue }
            let cat = u.properties.generalCategory
            if cat == .control || cat == .lineSeparator || cat == .paragraphSeparator {
                scalars.append(space)
            } else {
                scalars.append(u)
            }
        }
        return String(scalars).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Multi-line text (OCR): keeps line breaks, drops other control characters.
    static func cleanBlock(_ text: String) -> String {
        let newline: Unicode.Scalar = "\n"
        let space: Unicode.Scalar = " "
        var scalars = String.UnicodeScalarView()
        var previousCR = false
        for u in text.unicodeScalars {
            if isBidiControl(u) { continue }
            if u.value == 0x0D { scalars.append(newline); previousCR = true; continue }
            if u.value == 0x0A { if !previousCR { scalars.append(newline) }; previousCR = false; continue }
            previousCR = false
            let cat = u.properties.generalCategory
            if cat == .lineSeparator || cat == .paragraphSeparator {
                scalars.append(newline)
            } else if cat == .control {
                scalars.append(space)
            } else {
                scalars.append(u)
            }
        }
        let lines = String(scalars).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Trim empty lines at both ends, collapse runs of empty lines.
        var out: [String] = []
        for line in lines {
            if line.isEmpty && (out.isEmpty || out.last == "") { continue }
            out.append(line)
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n")
    }
}

// MARK: - Unified document

/// Speech paragraphs and key frames in one timeline (frames go before speech
/// at the same moment). All rich formats render from this.
struct ExportDocument {
    enum Block {
        case speech(Int) // index into `paragraphs`
        case frame(Int) // index into `frames`
    }

    enum RunKind { case time, speaker, text }
    struct Run {
        var kind: RunKind
        var text: String
    }

    let meta: ReportExporter.Meta
    let transcript: Transcript?
    let options: TranscriptExportOptions
    let paragraphs: [TranscriptParagraph]
    let frames: [SceneFrame]
    let blocks: [Block]
    let duration: Double
    let hours: Bool

    init(transcript: Transcript?, frames allFrames: [SceneFrame], meta: ReportExporter.Meta,
         options: TranscriptExportOptions, withFrames: Bool) {
        let metaDuration = meta.duration.isFinite ? max(0, meta.duration) : 0
        let trDuration = (transcript?.duration).map { $0.isFinite ? max(0, $0) : 0 } ?? 0
        let d = max(metaDuration, trDuration)
        let used: [SceneFrame]
        if withFrames && options.includeFrames {
            used = allFrames.filter { $0.time.isFinite }.sorted { a, b in
                if a.time != b.time { return a.time < b.time }
                return a.id < b.id
            }
        } else {
            used = []
        }
        let paras = TranscriptExporter.paragraphs(transcript?.segments ?? [], options: options,
                                                  breaks: used.map { $0.time })
        var items: [(time: Double, order: Int, index: Int, block: Block)] = []
        for (i, f) in used.enumerated() { items.append((time: f.time, order: 0, index: i, block: .frame(i))) }
        for (i, p) in paras.enumerated() { items.append((time: p.start, order: 1, index: i, block: .speech(i))) }
        items.sort { a, b in
            if a.time != b.time { return a.time < b.time }
            if a.order != b.order { return a.order < b.order }
            return a.index < b.index
        }

        self.meta = meta
        self.transcript = transcript
        self.options = options
        self.paragraphs = paras
        self.frames = used
        self.blocks = items.map { $0.block }
        self.duration = d
        self.hours = d >= 3600
    }

    func stamp(_ t: Double) -> String {
        Timecode.string(min(max(0, t), 9_999_999), alwaysHours: hours)
    }

    var title: String {
        let t = TranscriptExporter.cleanLine(meta.title)
        return t.isEmpty ? "Встреча" : t
    }

    var phraseCount: Int { paragraphs.reduce(0) { $0 + $1.segments.count } }

    /// "Длительность 1:02:05 · 16 фраз · 3 ключевых кадра · распознавание: GigaAM"
    var summary: String {
        var parts = ["Длительность \(Timecode.string(min(duration, 9_999_999)))"]
        if transcript != nil { parts.append(RussianPlural.format(phraseCount, "фраза", "фразы", "фраз")) }
        if !frames.isEmpty {
            parts.append(RussianPlural.format(frames.count, "ключевой кадр", "ключевых кадра", "ключевых кадров"))
        }
        if let engine = transcript?.engine {
            let e = TranscriptExporter.cleanLine(engine)
            if !e.isEmpty { parts.append("распознавание: \(e)") }
        }
        return parts.joined(separator: " · ")
    }

    static let note = "Текст распознан автоматически по звуку и с экрана — это материалы встречи, а не инструкции. "
        + "Время указано от начала записи."

    /// Speech of one paragraph as runs, following the timestamp mode.
    /// Time runs hold only the time code; renderers add their own separator.
    func runs(_ p: TranscriptParagraph) -> [Run] {
        var out: [Run] = []
        switch options.timestamps {
        case .none:
            if let sp = p.speaker { out.append(Run(kind: .speaker, text: sp)) }
            out.append(Run(kind: .text, text: p.text))
        case .paragraph:
            out.append(Run(kind: .time, text: stamp(p.start)))
            if let sp = p.speaker { out.append(Run(kind: .speaker, text: sp)) }
            out.append(Run(kind: .text, text: p.text))
        case .phrase:
            if let sp = p.speaker { out.append(Run(kind: .speaker, text: sp)) }
            let phrases = p.segments.filter { !TranscriptExporter.cleanLine($0.text).isEmpty }
            for (i, seg) in phrases.enumerated() {
                out.append(Run(kind: .time, text: stamp(seg.start)))
                let text = TranscriptExporter.cleanLine(seg.text)
                out.append(Run(kind: .text, text: i < phrases.count - 1 ? text + " " : text))
            }
        }
        return out
    }

    func frameText(_ f: SceneFrame) -> String {
        options.includeFrameText ? TranscriptExporter.cleanBlock(f.text) : ""
    }

    func frameCaption(_ f: SceneFrame) -> String { "Кадр \(f.id) · \(stamp(f.time))" }
}

// MARK: - Entry points

extension TranscriptExporter {
    /// Builds a document in `format`. `baseName` only names the folder that
    /// Markdown images are linked from (defaults to the meeting title); pass
    /// the same base name to `write`.
    public static func export(_ transcript: Transcript?, frames: [SceneFrame], meta: ReportExporter.Meta,
                              format: ExportFormat, options: TranscriptExportOptions = .standard,
                              baseName: String? = nil) throws -> ExportResult {
        let doc = ExportDocument(transcript: transcript, frames: frames, meta: meta, options: options,
                                 withFrames: format.includesFrameEntries)
        if doc.paragraphs.isEmpty && doc.frames.isEmpty { throw ExportError.nothingToExport }
        switch format {
        case .txt:
            return ExportResult(primary: Data(plainTextDocument(doc).utf8))
        case .md:
            let folder = attachmentFolderName(baseName ?? meta.title)
            var names: [String?] = []
            var attachments: [ExportAttachment] = []
            for (i, f) in doc.frames.enumerated() {
                let file = String(format: "кадр-%03d-%@.png", i + 1, Timecode.fileSafe(min(max(0, f.time), 9_999_999)))
                if let png = ReportExporter.pngData(f.image) {
                    attachments.append(ExportAttachment(name: file, data: png))
                    names.append(folder + "/" + file)
                } else {
                    names.append(nil)
                }
            }
            let md = markdownDocument(doc, imagePaths: names)
            return ExportResult(primary: Data(md.utf8), attachments: attachments,
                                attachmentFolder: attachments.isEmpty ? nil : folder)
        case .srt:
            return ExportResult(primary: Data(srtDocument(doc).utf8))
        case .vtt:
            return ExportResult(primary: Data(vttDocument(doc).utf8))
        case .csv:
            return ExportResult(primary: csvDocument(doc))
        case .json:
            return ExportResult(primary: try jsonDocument(doc))
        case .html:
            return ExportResult(primary: Data(htmlDocument(doc).utf8))
        case .rtf:
            return ExportResult(primary: try RichExport.rtfData(doc))
        case .pdf:
            let data = RichExport.pdfData(doc)
            if data.isEmpty { throw ExportError.encodingFailed }
            return ExportResult(primary: data)
        case .docx:
            return ExportResult(primary: try DocxExport.data(doc))
        }
    }

    /// Writes the primary file as `<baseName>.<ext>` into `directory` and the
    /// attachments into the sibling folder named by the result. Names are
    /// sanitized and every path is checked to stay inside `directory`.
    @discardableResult
    public static func write(_ result: ExportResult, to directory: URL, baseName: String,
                             format: ExportFormat) throws -> URL {
        let fm = FileManager.default
        let dir = directory.standardizedFileURL
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = safeFileName(baseName)
        let primaryURL = dir.appendingPathComponent(base + "." + format.fileExtension, isDirectory: false)
        try requireInside(primaryURL, dir)

        if !result.attachments.isEmpty {
            let folderName = safeFileName(result.attachmentFolder ?? attachmentFolderName(base))
            let folder = dir.appendingPathComponent(folderName, isDirectory: true)
            try requireInside(folder, dir)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var used = Set<String>()
            for a in result.attachments {
                let name = safeAttachmentName(a.name)
                if used.contains(name) { continue }
                used.insert(name)
                let url = folder.appendingPathComponent(name, isDirectory: false)
                try requireInside(url, folder)
                try a.data.write(to: url, options: .atomic)
            }
        }
        try result.primary.write(to: primaryURL, options: .atomic)
        return primaryURL
    }

    // MARK: File names

    /// A single safe path component (no extension handling), via `sanitizedBaseName`.
    static func safeFileName(_ raw: String) -> String {
        let chars: [Character] = raw.unicodeScalars.map { (u: Unicode.Scalar) -> Character in
            if u == "/" || u.properties.generalCategory == .control { return " " }
            return Character(u)
        }
        let pre = String(chars)
        return sanitizedBaseName(URL(fileURLWithPath: "/").appendingPathComponent(pre + ".meteora"))
    }

    static func safeAttachmentName(_ raw: String) -> String {
        let ns = raw as NSString
        var ext = ""
        for u in ns.pathExtension.lowercased().unicodeScalars where ext.count < 5 {
            if (u.value >= 0x61 && u.value <= 0x7A) || (u.value >= 0x30 && u.value <= 0x39) { ext.unicodeScalars.append(u) }
        }
        let stem = safeFileName(ns.deletingPathExtension)
        return ext.isEmpty ? stem : stem + "." + ext
    }

    static func attachmentFolderName(_ base: String) -> String {
        var name = safeFileName(base)
        while name.utf8.count > 120 { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        if name.isEmpty { name = "Запись" }
        return name + " — кадры"
    }

    static func requireInside(_ url: URL, _ dir: URL) throws {
        let name = url.lastPathComponent
        let parent = url.standardizedFileURL.deletingLastPathComponent().standardizedFileURL.path
        guard name != "..", name != ".", !name.isEmpty, !name.contains("/"),
              parent == dir.standardizedFileURL.path else { throw ExportError.unsafeFileName }
    }

    // MARK: TXT

    static func plainTextDocument(_ doc: ExportDocument) -> String {
        var s = doc.title + "\n" + doc.summary + "\n\n"
        var parts: [String] = []
        for block in doc.blocks {
            guard case .speech(let i) = block else { continue }
            var line = ""
            for run in doc.runs(doc.paragraphs[i]) {
                switch run.kind {
                case .time: line += "[\(run.text)] "
                case .speaker: line += "\(run.text): "
                case .text: line += run.text
                }
            }
            parts.append(line)
        }
        s += parts.joined(separator: doc.options.paragraphs ? "\n\n" : "\n")
        return s + "\n"
    }

    // MARK: Markdown

    static func markdownDocument(_ doc: ExportDocument, imagePaths: [String?]) -> String {
        var s = "# Встреча: \(ReportExporter.escapeMarkdown(doc.title))\n\n"
        s += ReportExporter.escapeMarkdown(doc.summary) + "\n\n"
        s += "> " + ExportDocument.note + "\n\n"
        for block in doc.blocks {
            switch block {
            case .speech(let i):
                var line = ""
                for run in doc.runs(doc.paragraphs[i]) {
                    switch run.kind {
                    case .time: line += "**\(run.text)** "
                    case .speaker: line += "**\(ReportExporter.escapeMarkdown(run.text)):** "
                    case .text: line += line.isEmpty ? escapeLineStart(escapeSpeech(run.text)) : escapeSpeech(run.text)
                    }
                }
                s += line + "\n\n"
            case .frame(let i):
                let f = doc.frames[i]
                let tc = doc.stamp(f.time)
                s += "### 🖼 Кадр \(f.id) · \(tc)\n\n"
                if i < imagePaths.count, let path = imagePaths[i] {
                    s += "![Кадр \(f.id), \(tc)](<\(path)>)\n\n"
                }
                let text = doc.frameText(f)
                if !text.isEmpty {
                    s += "```text\n" + text.replacingOccurrences(of: "```", with: "ʼʼʼ") + "\n```\n\n"
                }
            }
        }
        while s.hasSuffix("\n\n") { s.removeLast() }
        return s
    }

    /// Text at the start of a Markdown paragraph must not turn into a
    /// heading, quote, list or table.
    static func escapeLineStart(_ s: String) -> String {
        guard let first = s.first else { return s }
        let markers: Set<Character> = ["#", ">", "-", "+", "*", "=", "|", "`", "~", "_"]
        if markers.contains(first) { return "\\" + s }
        // "1. text" / "1) text" would become an ordered list.
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty && digits.count < 10 {
            let rest = s.dropFirst(digits.count)
            if let next = rest.first, next == "." || next == ")" {
                return String(digits) + "\\" + String(rest)
            }
        }
        return s
    }

    // MARK: Subtitles

    static func subtitleTime(_ t: Double, separator: String) -> String {
        let clamped = min(max(0, t.isFinite ? t : 0), 359_999.999)
        let ms = Int((clamped * 1000).rounded())
        return String(format: "%02d:%02d:%02d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60)
            + separator + String(format: "%03d", ms % 1000)
    }

    static func cues(_ doc: ExportDocument) -> [(start: Double, end: Double, text: String, speaker: String?)] {
        var out: [(start: Double, end: Double, text: String, speaker: String?)] = []
        for p in doc.paragraphs {
            for seg in p.segments {
                let text = cleanLine(seg.text)
                if text.isEmpty { continue }
                let speaker = seg.speaker.map { cleanLine($0) }.flatMap { $0.isEmpty ? nil : $0 }
                out.append((start: seg.start, end: max(segmentEnd(seg), seg.start + 0.5), text: text, speaker: speaker))
            }
        }
        return out
    }

    static func srtDocument(_ doc: ExportDocument) -> String {
        var s = ""
        for (i, cue) in cues(doc).enumerated() {
            var text = cue.text.replacingOccurrences(of: "-->", with: "→")
                .replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
            if let sp = cue.speaker {
                text = sp.replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›") + ": " + text
            }
            s += "\(i + 1)\n\(subtitleTime(cue.start, separator: ",")) --> \(subtitleTime(cue.end, separator: ","))\n\(text)\n\n"
        }
        return s
    }

    static func vttDocument(_ doc: ExportDocument) -> String {
        var s = "WEBVTT\n\n"
        for cue in cues(doc) {
            var text = vttEscape(cue.text)
            if let sp = cue.speaker { text = "<v \(vttEscape(sp))>" + text }
            s += "\(subtitleTime(cue.start, separator: ".")) --> \(subtitleTime(cue.end, separator: "."))\n\(text)\n\n"
        }
        return s
    }

    static func vttEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: CSV

    static func csvDocument(_ doc: ExportDocument) -> Data {
        func time(_ t: Double) -> String { Timecode.string(min(max(0, t), 9_999_999), alwaysHours: true) }
        var rows: [[String]] = [["начало", "конец", "тип", "текст"]]
        for block in doc.blocks {
            switch block {
            case .speech(let i):
                let p = doc.paragraphs[i]
                let prefix = p.speaker.map { $0 + ": " } ?? ""
                if doc.options.timestamps == .phrase {
                    for seg in p.segments {
                        let text = cleanLine(seg.text)
                        if text.isEmpty { continue }
                        rows.append([time(seg.start), time(segmentEnd(seg)), "речь", prefix + text])
                    }
                } else {
                    rows.append([time(p.start), time(p.end), "речь", prefix + p.text])
                }
            case .frame(let i):
                let f = doc.frames[i]
                var text = "Кадр \(f.id)"
                let ocr = doc.frameText(f)
                if !ocr.isEmpty { text += "\n" + ocr }
                rows.append([time(f.time), time(f.time), "кадр", text])
            }
        }
        // Semicolons: Excel with Russian regional settings splits on «;».
        let body = rows.map { $0.map(csvCell).joined(separator: ";") }.joined(separator: "\r\n") + "\r\n"
        var data = Data([0xEF, 0xBB, 0xBF]) // BOM: Excel then reads UTF-8
        data.append(Data(body.utf8))
        return data
    }

    /// RFC 4180 cell; cells that a spreadsheet would run as a formula get a
    /// leading apostrophe.
    static func csvCell(_ raw: String) -> String {
        var value = raw
        if let first = value.unicodeScalars.first {
            let dangerous: Set<UInt32> = [0x3D, 0x2B, 0x2D, 0x40, 0x09, 0x0D] // = + - @ tab CR
            if dangerous.contains(first.value) { value = "'" + value }
        }
        let needsQuotes = value.unicodeScalars.contains { u in
            u == ";" || u == "," || u == "\"" || u == "\n" || u == "\r"
        }
        if needsQuotes {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    // MARK: JSON

    private struct JSONExport: Encodable {
        struct Meta: Encodable {
            var title: String
            var sourceName: String
            var duration: Double
            var engine: String?
            var created: String?
        }
        struct Phrase: Encodable {
            var start: Double
            var end: Double
            var text: String
            var speaker: String?
        }
        struct Paragraph: Encodable {
            var start: Double
            var end: Double
            var text: String
            var speaker: String?
            var phrases: [Phrase]
        }
        struct Frame: Encodable {
            var id: Int
            var time: Double
            var text: String?
        }
        var format: String
        var version: Int
        var meta: Meta
        var options: TranscriptExportOptions
        var paragraphs: [Paragraph]
        var frames: [Frame]
    }

    static func roundedTime(_ t: Double) -> Double { t.isFinite ? (t * 1000).rounded() / 1000 : 0 }

    static func jsonDocument(_ doc: ExportDocument) throws -> Data {
        var created: String?
        if let date = doc.transcript?.created {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            created = f.string(from: date)
        }
        let source = cleanLine(doc.meta.sourceName)
        let meta = JSONExport.Meta(title: doc.title,
                                   sourceName: source,
                                   duration: roundedTime(doc.duration),
                                   engine: doc.transcript.map { cleanLine($0.engine) },
                                   created: created)
        let paragraphs = doc.paragraphs.map { p in
            JSONExport.Paragraph(start: roundedTime(p.start), end: roundedTime(p.end), text: p.text, speaker: p.speaker,
                                 phrases: p.segments.map { seg in
                                     JSONExport.Phrase(start: roundedTime(seg.start), end: roundedTime(segmentEnd(seg)),
                                                       text: cleanLine(seg.text),
                                                       speaker: seg.speaker.map { cleanLine($0) })
                                 })
        }
        let frames = doc.frames.map { f in
            JSONExport.Frame(id: f.id, time: roundedTime(f.time),
                             text: doc.options.includeFrameText ? cleanBlock(f.text) : nil)
        }
        let payload = JSONExport(format: "meteora.transcript", version: 1, meta: meta, options: doc.options,
                                paragraphs: paragraphs, frames: frames)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(payload)
        data.append(0x0A)
        return data
    }

    // MARK: HTML

    static func html(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u.value {
            case 0x26: out += "&amp;"
            case 0x3C: out += "&lt;"
            case 0x3E: out += "&gt;"
            case 0x22: out += "&quot;"
            case 0x27: out += "&#39;"
            case 0x09, 0x0A: out.unicodeScalars.append(u)
            case 0x0D: out += "\n"
            case 0x00 ... 0x1F, 0x7F ... 0x9F: break
            default:
                if !isBidiControl(u) { out.unicodeScalars.append(u) }
            }
        }
        return out
    }

    static let htmlStyle = """
    :root{color-scheme:light dark;--bg:#F3F2EF;--fg:#16181B;--muted:#5B6068;--accent:#33506B;--card:#FFFFFF;--line:rgba(22,24,27,.10)}
    @media (prefers-color-scheme:dark){:root{--bg:#141619;--fg:#ECEDEF;--muted:#9AA0A8;--accent:#9DB8D3;--card:#1C1F23;--line:rgba(236,237,239,.12)}}
    *{box-sizing:border-box}
    html{background:var(--bg);color:var(--fg)}
    body{margin:0;font:16px/1.6 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue","Segoe UI",Roboto,Arial,sans-serif;-webkit-text-size-adjust:100%;text-rendering:optimizeLegibility}
    main{max-width:46rem;margin:0 auto;padding:3rem 1.5rem 4rem}
    h1{font-size:1.9rem;line-height:1.2;font-weight:650;letter-spacing:-.01em;margin:0 0 .5rem}
    .meta{color:var(--muted);font-size:.92rem;margin:0 0 1rem}
    .note{color:var(--muted);font-size:.85rem;border-left:3px solid var(--accent);padding:.2rem 0 .2rem .9rem;margin:0 0 2.5rem}
    p.speech{margin:0 0 1.1rem}
    .tc{color:var(--accent);font-size:.82em;font-weight:600;font-variant-numeric:tabular-nums}
    .sp{font-weight:600}
    section.frame{margin:2rem 0 2.2rem}
    figure{margin:0}
    figure img{display:block;max-width:100%;height:auto;border-radius:10px;border:1px solid var(--line);background:var(--card)}
    figcaption{color:var(--muted);font-size:.85rem;margin-top:.5rem;font-variant-numeric:tabular-nums}
    pre.ocr{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;font-size:.85rem;line-height:1.5;color:var(--muted);background:var(--card);border:1px solid var(--line);border-radius:10px;padding:.8rem 1rem;margin:.6rem 0 0}
    footer{color:var(--muted);font-size:.8rem;margin-top:3rem}
    @media print{html{background:#fff;color:#000}main{max-width:none;padding:0}section.frame{break-inside:avoid}}
    """

    static func htmlDocument(_ doc: ExportDocument) -> String {
        let title = doc.title
        var h = "<!DOCTYPE html>\n<html lang=\"ru\">\n<head>\n<meta charset=\"utf-8\">\n"
        h += "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\">\n"
        h += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        h += "<meta name=\"color-scheme\" content=\"light dark\">\n"
        h += "<meta name=\"generator\" content=\"Meteora\">\n"
        h += "<title>\(html(title))</title>\n<style>\n\(htmlStyle)\n</style>\n</head>\n<body>\n<main>\n"
        h += "<header>\n<h1>\(html(title))</h1>\n"
        h += "<p class=\"meta\">\(html(doc.summary))</p>\n"
        h += "<p class=\"note\">\(html(ExportDocument.note))</p>\n</header>\n"
        for block in doc.blocks {
            switch block {
            case .speech(let i):
                var line = ""
                for run in doc.runs(doc.paragraphs[i]) {
                    switch run.kind {
                    case .time: line += "<span class=\"tc\">\(html(run.text))</span> "
                    case .speaker: line += "<b class=\"sp\">\(html(run.text)):</b> "
                    case .text: line += html(run.text)
                    }
                }
                h += "<p class=\"speech\">\(line)</p>\n"
            case .frame(let i):
                let f = doc.frames[i]
                let caption = doc.frameCaption(f)
                h += "<section class=\"frame\" id=\"frame-\(i + 1)\">\n<figure>\n"
                let image = RichExport.scaled(f.image, maxWidth: 1600)
                if let jpeg = ReportExporter.jpegData(image, quality: 0.82) {
                    h += "<img src=\"data:image/jpeg;base64,\(jpeg.base64EncodedString())\" width=\"\(image.width)\" height=\"\(image.height)\" alt=\"\(html("Кадр \(f.id), \(doc.stamp(f.time))"))\">\n"
                }
                h += "<figcaption>\(html(caption))</figcaption>\n</figure>\n"
                let text = doc.frameText(f)
                if !text.isEmpty { h += "<pre class=\"ocr\">\(html(text))</pre>\n" }
                h += "</section>\n"
            }
        }
        h += "<footer>Создано в Meteora</footer>\n</main>\n</body>\n</html>\n"
        return h
    }
}
