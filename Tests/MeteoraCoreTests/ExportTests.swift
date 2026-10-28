import XCTest
import AppKit
import CoreGraphics
import PDFKit
@testable import MeteoraCore

final class ExportTests: XCTestCase {
    // MARK: Fixtures

    func image(_ w: Int = 64, _ h: Int = 40) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.31, blue: 0.42, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1))
        ctx.fill(CGRect(x: 8, y: 8, width: w / 2, height: h / 3))
        return ctx.makeImage()!
    }

    let meta = ReportExporter.Meta(title: "Планёрка", sourceName: "Планёрка.webm", duration: 100)

    var transcript: Transcript {
        Transcript(sourceName: "Планёрка.webm", duration: 100, engine: "test", segments: [
            TranscriptSegment(start: 1.5, end: 4.25, text: "Добрый день, коллеги."),
            TranscriptSegment(start: 4.5, end: 6, text: "Начнём."),
            TranscriptSegment(start: 10, end: 12, text: "Итоги квартала."),
        ])
    }

    func string(_ result: ExportResult) -> String {
        String(decoding: result.primary, as: UTF8.self)
    }

    // MARK: Paragraphs

    func testParagraphsSplitOnPauses() {
        let segs = [
            TranscriptSegment(start: 0, end: 1, text: "Привет."),
            TranscriptSegment(start: 1.2, end: 2, text: "Как дела?"),
            TranscriptSegment(start: 5, end: 6, text: "Новая мысль."),
        ]
        let p = TranscriptExporter.paragraphs(segs, options: .standard)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].segments.count, 2)
        XCTAssertEqual(p[0].text, "Привет. Как дела?")
        XCTAssertEqual(p[0].start, 0)
        XCTAssertEqual(p[0].end, 2)
        XCTAssertEqual(p[1].text, "Новая мысль.")

        var off = TranscriptExportOptions.standard
        off.paragraphs = false
        XCTAssertEqual(TranscriptExporter.paragraphs(segs, options: off).count, 3)
    }

    func testParagraphsRespectMaxLength() {
        let segs = (0 ..< 20).map { i in
            TranscriptSegment(start: Double(i) * 5, end: Double(i) * 5 + 4.5, text: "Фраза \(i)")
        }
        var o = TranscriptExportOptions.standard
        o.maxParagraphSeconds = 30
        let p = TranscriptExporter.paragraphs(segs, options: o)
        XCTAssertEqual(p.count, 4)
        XCTAssertEqual(p.map { $0.segments.count }, [6, 6, 6, 2])
        for para in p { XCTAssertLessThanOrEqual(para.end - para.start, 30) }
    }

    func testParagraphsSoftCharacterLimit() {
        let long = String(repeating: "слово ", count: 66) + "конец." // ~400 characters
        let segs = (0 ..< 3).map { i in TranscriptSegment(start: Double(i), end: Double(i) + 0.9, text: long) }
        let p = TranscriptExporter.paragraphs(segs, options: .standard)
        XCTAssertEqual(p.map { $0.segments.count }, [2, 1])
    }

    func testParagraphsSplitOnSpeakerAndDecodeOldJSON() throws {
        let segs = [
            TranscriptSegment(start: 0, end: 1, text: "Да.", speaker: "Анна"),
            TranscriptSegment(start: 1.1, end: 2, text: "Нет.", speaker: "Борис"),
        ]
        XCTAssertEqual(TranscriptExporter.paragraphs(segs, options: .standard).count, 2)

        let old = Data(#"{"start":1,"end":2,"text":"Старый кэш"}"#.utf8)
        let seg = try JSONDecoder().decode(TranscriptSegment.self, from: old)
        XCTAssertNil(seg.speaker)
        XCTAssertEqual(seg.text, "Старый кэш")
        let roundTrip = try JSONDecoder().decode(TranscriptSegment.self, from: JSONEncoder().encode(seg))
        XCTAssertEqual(roundTrip, seg)
    }

    func testOptionsDecodeTolerantly() throws {
        let empty = try JSONDecoder().decode(TranscriptExportOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, .standard)
        let custom = TranscriptExportOptions(timestamps: .phrase, paragraphs: false, pauseForParagraph: 3,
                                             maxParagraphSeconds: 20, includeFrames: false, includeFrameText: false)
        let decoded = try JSONDecoder().decode(TranscriptExportOptions.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(decoded, custom)
        let unknown = try JSONDecoder().decode(TranscriptExportOptions.self, from: Data(#"{"timestamps":"word"}"#.utf8))
        XCTAssertEqual(unknown.timestamps, .paragraph)
        XCTAssertEqual(TimestampMode.allCases.map(\.title), ["без времени", "у абзацев", "у каждой фразы"])
    }

    // MARK: TXT

    func testPlainTextTimestampModes() throws {
        var o = TranscriptExportOptions.standard

        o.timestamps = .none
        let none = string(try TranscriptExporter.export(transcript, frames: [], meta: meta, format: .txt, options: o))
        XCTAssertTrue(none.contains("Добрый день, коллеги. Начнём.\n\nИтоги квартала.\n"), none)
        XCTAssertFalse(none.contains("["), none)

        o.timestamps = .paragraph
        let para = string(try TranscriptExporter.export(transcript, frames: [], meta: meta, format: .txt, options: o))
        XCTAssertTrue(para.contains("[0:01] Добрый день, коллеги. Начнём.\n\n[0:10] Итоги квартала.\n"), para)

        o.timestamps = .phrase
        let phrase = string(try TranscriptExporter.export(transcript, frames: [], meta: meta, format: .txt, options: o))
        XCTAssertTrue(phrase.contains("[0:01] Добрый день, коллеги. [0:04] Начнём.\n\n[0:10] Итоги квартала.\n"), phrase)

        XCTAssertTrue(phrase.hasPrefix("Планёрка\n"))
        XCTAssertTrue(phrase.contains("3 фразы"), phrase)
    }

    func testNothingToExportThrows() {
        XCTAssertThrowsError(try TranscriptExporter.export(nil, frames: [], meta: meta, format: .docx)) { error in
            XCTAssertEqual(error as? ExportError, .nothingToExport)
        }
    }

    // MARK: Subtitles

    func testSRTAndVTTCues() throws {
        var o = TranscriptExportOptions.standard
        o.timestamps = .none // subtitles always carry real times
        let srt = string(try TranscriptExporter.export(transcript, frames: [], meta: meta, format: .srt, options: o))
        XCTAssertTrue(srt.hasPrefix("1\n00:00:01,500 --> 00:00:04,250\nДобрый день, коллеги.\n\n2\n00:00:04,500 --> 00:00:06,000\nНачнём.\n\n3\n"), srt)

        let vtt = string(try TranscriptExporter.export(transcript, frames: [], meta: meta, format: .vtt, options: o))
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n00:00:01.500 --> 00:00:04.250\nДобрый день, коллеги.\n\n00:00:04.500 --> 00:00:06.000\nНачнём.\n\n"), vtt)

        let evil = Transcript(sourceName: "x", duration: 10, engine: "t", segments: [
            TranscriptSegment(start: 0, end: 1, text: "<b>жирный</b> & --> стрелка"),
        ])
        let v = string(try TranscriptExporter.export(evil, frames: [], meta: meta, format: .vtt, options: o))
        XCTAssertTrue(v.contains("&lt;b&gt;жирный&lt;/b&gt; &amp; --&gt; стрелка"), v)
        let s = string(try TranscriptExporter.export(evil, frames: [], meta: meta, format: .srt, options: o))
        XCTAssertFalse(s.contains("<b>"))
        XCTAssertEqual(s.components(separatedBy: "-->").count, 2, "only the timing line has an arrow")
    }

    // MARK: CSV

    func testCSVQuotingInjectionAndBOM() throws {
        let tr = Transcript(sourceName: "x", duration: 100, engine: "t", segments: [
            TranscriptSegment(start: 0.5, end: 1, text: #"=HYPERLINK("http://x","y")"#),
            TranscriptSegment(start: 1.2, end: 2, text: #"Привет, "мир""#),
            TranscriptSegment(start: 2.1, end: 2.9, text: "-2+3"),
        ])
        let frames = [SceneFrame(id: 1, time: 3, image: image(), text: "Строка 1\nСтрока 2")]
        var o = TranscriptExportOptions.standard
        o.timestamps = .phrase
        let data = try TranscriptExporter.export(tr, frames: frames, meta: meta, format: .csv, options: o).primary
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let csv = String(decoding: data.dropFirst(3), as: UTF8.self)
        XCTAssertTrue(csv.hasPrefix("начало;конец;тип;текст\r\n"), csv)
        XCTAssertTrue(csv.contains("0:00:00;0:00:01;речь;\"'=HYPERLINK(\"\"http://x\"\",\"\"y\"\")\"\r\n"), csv)
        XCTAssertTrue(csv.contains(";речь;\"Привет, \"\"мир\"\"\"\r\n"), csv)
        XCTAssertTrue(csv.contains(";речь;'-2+3\r\n"), csv)
        XCTAssertTrue(csv.contains("0:00:03;0:00:03;кадр;\"Кадр 1\nСтрока 1\nСтрока 2\"\r\n"), csv)

        XCTAssertEqual(TranscriptExporter.csvCell("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(TranscriptExporter.csvCell("+1"), "'+1")
        XCTAssertEqual(TranscriptExporter.csvCell("\tx"), "'\tx")
        XCTAssertEqual(TranscriptExporter.csvCell("обычный текст"), "обычный текст")
    }

    // MARK: JSON

    func testJSONIsStableAndParsable() throws {
        let frames = [SceneFrame(id: 7, time: 8, image: image(), text: "Слайд")]
        let tr = transcript
        let result = try TranscriptExporter.export(tr, frames: frames, meta: meta, format: .json)
        let text = string(result)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.primary) as? [String: Any])
        let metaJSON = try XCTUnwrap(root["meta"] as? [String: Any])
        XCTAssertEqual(metaJSON["title"] as? String, "Планёрка")
        XCTAssertEqual(metaJSON["engine"] as? String, "test")
        XCTAssertNotNil(metaJSON["created"] as? String)
        XCTAssertNotNil(root["options"] as? [String: Any])
        let paragraphs = try XCTUnwrap(root["paragraphs"] as? [[String: Any]])
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual((paragraphs[0]["phrases"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(paragraphs[0]["text"] as? String, "Добрый день, коллеги. Начнём.")
        let framesJSON = try XCTUnwrap(root["frames"] as? [[String: Any]])
        XCTAssertEqual(framesJSON.first?["id"] as? Int, 7)
        XCTAssertEqual(framesJSON.first?["text"] as? String, "Слайд")
        XCTAssertNil(framesJSON.first?["image"])
        // Sorted keys: stable output.
        let order = ["\"frames\"", "\"meta\"", "\"options\"", "\"paragraphs\""].compactMap { text.range(of: $0)?.lowerBound }
        XCTAssertEqual(order.count, 4)
        XCTAssertEqual(order, order.sorted())
        let again = try TranscriptExporter.export(tr, frames: frames, meta: meta, format: .json)
        XCTAssertEqual(again.primary, result.primary)
    }

    // MARK: HTML

    func testHTMLEscapesEverything() throws {
        let tr = Transcript(sourceName: "x", duration: 100, engine: "t", segments: [
            TranscriptSegment(start: 1, end: 2, text: "<script>alert(1)</script> & \"кавычки\""),
        ])
        let frames = [SceneFrame(id: 1, time: 5, image: image(), text: "<script>steal()</script>\n<img src=x onerror=alert(2)>")]
        let m = ReportExporter.Meta(title: "<img src=x onerror=alert(3)>", sourceName: "x", duration: 100)
        let html = string(try TranscriptExporter.export(tr, frames: frames, meta: m, format: .html))
        XCTAssertFalse(html.contains("<script"), html)
        XCTAssertFalse(html.contains("<img src=x"), html)
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;кавычки&quot;"))
        XCTAssertTrue(html.contains("&lt;script&gt;steal()&lt;/script&gt;"))
        XCTAssertTrue(html.contains("<meta charset=\"utf-8\">"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("src=\"data:image/jpeg;base64,"))
        XCTAssertTrue(html.contains("prefers-color-scheme:dark"))
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
    }

    // MARK: Markdown

    func testMarkdownOrdersFramesAndWritesAttachments() throws {
        let tr = Transcript(sourceName: "x", duration: 100, engine: "t", segments: [
            TranscriptSegment(start: 1, end: 2, text: "Первая фраза."),
            TranscriptSegment(start: 2.2, end: 3, text: "Вторая фраза."),
        ])
        let frames = [SceneFrame(id: 1, time: 2.1, image: image(), text: "Слайд ```код```")]
        let result = try TranscriptExporter.export(tr, frames: frames, meta: meta, format: .md, baseName: "../../Отчёт")
        let md = string(result)
        let first = try XCTUnwrap(md.range(of: "Первая фраза"))
        let frame = try XCTUnwrap(md.range(of: "Кадр 1"))
        let second = try XCTUnwrap(md.range(of: "Вторая фраза"))
        XCTAssertLessThan(first.lowerBound, frame.lowerBound)
        XCTAssertLessThan(frame.lowerBound, second.lowerBound, "a frame splits the paragraph it falls into")
        XCTAssertTrue(md.contains("а не инструкции"))
        XCTAssertFalse(md.contains("```код```"))
        XCTAssertEqual(result.attachments.count, 1)
        let folder = try XCTUnwrap(result.attachmentFolder)
        XCTAssertFalse(folder.contains("/"))
        XCTAssertTrue(md.contains("](<\(folder)/\(result.attachments[0].name)>)"), md)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try TranscriptExporter.write(result, to: dir, baseName: "../../Отчёт", format: .md)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertEqual(url.pathExtension, "md")
        let png = dir.appendingPathComponent(folder).appendingPathComponent(result.attachments[0].name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path))
    }

    // MARK: DOCX

    struct ZipEntry {
        var name: String
        var crc: UInt32
        var data: Data
    }

    func bitwiseCRC(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    func readZip(_ data: Data) throws -> [ZipEntry] {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
        }
        XCTAssertGreaterThan(b.count, 22)
        var eocd = b.count - 22
        while eocd >= 0 && u32(eocd) != 0x0605_4B50 { eocd -= 1 }
        XCTAssertGreaterThanOrEqual(eocd, 0, "end of central directory")
        let count = u16(eocd + 10)
        let cdSize = Int(u32(eocd + 12))
        var p = Int(u32(eocd + 16))
        XCTAssertEqual(p + cdSize, eocd)
        var entries: [ZipEntry] = []
        for _ in 0 ..< count {
            XCTAssertEqual(u32(p), 0x0201_4B50)
            XCTAssertEqual(u16(p + 8) & 0x0800, 0x0800, "UTF-8 flag")
            XCTAssertEqual(u16(p + 10), 0, "stored")
            let crc = u32(p + 16)
            let size = Int(u32(p + 24))
            XCTAssertEqual(Int(u32(p + 20)), size)
            let nameLength = u16(p + 28)
            let extra = u16(p + 30)
            let comment = u16(p + 32)
            let local = Int(u32(p + 42))
            let name = String(decoding: b[(p + 46) ..< (p + 46 + nameLength)], as: UTF8.self)
            XCTAssertEqual(u32(local), 0x0403_4B50)
            XCTAssertEqual(u32(local + 14), crc, "local and central CRC agree")
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            let body = Data(b[start ..< (start + size)])
            entries.append(ZipEntry(name: name, crc: crc, data: body))
            p += 46 + nameLength + extra + comment
        }
        return entries
    }

    func testDocxPackageIsValid() throws {
        let tr = Transcript(sourceName: "x", duration: 100, engine: "t", segments: [
            TranscriptSegment(start: 1, end: 2, text: "Текст & <теги> \u{0001} \u{FFFE} «кавычки»"),
            TranscriptSegment(start: 9, end: 10, text: "Ещё абзац."),
        ])
        let frames = [SceneFrame(id: 1, time: 5, image: image(), text: "Слайд\nвторая строка & <x>"),
                      SceneFrame(id: 2, time: 20, image: image(40, 64), text: "")]
        let m = ReportExporter.Meta(title: "Встреча & <план>\u{0007}", sourceName: "x", duration: 100)
        var o = TranscriptExportOptions.standard
        o.timestamps = .phrase
        let data = try TranscriptExporter.export(tr, frames: frames, meta: m, format: .docx, options: o).primary
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])

        let entries = try readZip(data)
        let names = Set(entries.map(\.name))
        for required in ["[Content_Types].xml", "_rels/.rels", "docProps/core.xml", "word/document.xml",
                         "word/styles.xml", "word/_rels/document.xml.rels", "word/media/frame1.jpeg", "word/media/frame2.jpeg"] {
            XCTAssertTrue(names.contains(required), "missing \(required)")
        }
        for entry in entries {
            XCTAssertEqual(entry.crc, bitwiseCRC(entry.data), "CRC of \(entry.name)")
            XCTAssertEqual(entry.crc, CRC32.checksum(entry.data))
            if entry.name.hasSuffix(".xml") || entry.name.hasSuffix(".rels") {
                let parser = XMLParser(data: entry.data)
                XCTAssertTrue(parser.parse(), "\(entry.name) is not well-formed: \(String(describing: parser.parserError))")
            }
            if entry.name.hasSuffix(".jpeg") {
                XCTAssertEqual(Array(entry.data.prefix(2)), [0xFF, 0xD8])
            }
        }
        let document = String(decoding: try XCTUnwrap(entries.first { $0.name == "word/document.xml" }).data, as: UTF8.self)
        XCTAssertTrue(document.contains("<wp:inline"))
        XCTAssertTrue(document.contains("<wp:docPr id=\"1\""))
        XCTAssertTrue(document.contains("<wp:docPr id=\"2\""))
        XCTAssertTrue(document.contains("r:embed=\"rId2\""))
        XCTAssertTrue(document.contains("Текст &amp; &lt;теги&gt;"))
        XCTAssertTrue(document.contains("w:val=\"Timecode\""))
        XCTAssertTrue(document.contains("<w:br/>"), "OCR lines are kept")
        let rels = String(decoding: try XCTUnwrap(entries.first { $0.name == "word/_rels/document.xml.rels" }).data, as: UTF8.self)
        XCTAssertTrue(rels.contains("Target=\"media/frame2.jpeg\""))
    }

    func testZipCRCKnownValue() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    // MARK: PDF / RTF

    func testPDFIsProducedAndPaged() throws {
        let segs = (0 ..< 200).map { i in
            TranscriptSegment(start: Double(i) * 3, end: Double(i) * 3 + 1,
                              text: "Фраза номер \(i): обсуждаем план работ, сроки и ответственных по каждому пункту.")
        }
        let tr = Transcript(sourceName: "x", duration: 700, engine: "t", segments: segs)
        let frames = [SceneFrame(id: 1, time: 30, image: image(), text: "Итоги квартала")]
        let data = try TranscriptExporter.export(tr, frames: frames, meta: meta, format: .pdf).primary
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("Фраза номер 0") ?? false)
        XCTAssertTrue(pdf.string?.contains("Итоги квартала") ?? false)
    }

    func testRTF() throws {
        let frames = [SceneFrame(id: 1, time: 5, image: image(), text: "Слайд")]
        let data = try TranscriptExporter.export(transcript, frames: frames, meta: meta, format: .rtf).primary
        XCTAssertTrue(String(decoding: data.prefix(5), as: UTF8.self).hasPrefix("{\\rtf"))
        let back = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: nil)
        XCTAssertTrue(back.string.contains("Итоги квартала"))
        XCTAssertTrue(back.string.contains("Кадр 1"))
    }

    // MARK: Formats & plurals

    func testFormatsMetadata() {
        XCTAssertEqual(ExportFormat.allCases.count, 10)
        XCTAssertEqual(ExportFormat.docx.title, "Word (.docx)")
        XCTAssertEqual(ExportFormat.vtt.fileExtension, "vtt")
        XCTAssertEqual(Set(ExportFormat.allCases.filter(\.supportsFrames)), [.docx, .pdf, .html, .md])
        for f in ExportFormat.allCases { XCTAssertTrue(f.title.contains(".\(f.fileExtension)")) }
    }

    func testRussianPlural() {
        func p(_ n: Int) -> String { RussianPlural.format(n, "фраза", "фразы", "фраз") }
        XCTAssertEqual(p(1), "1 фраза")
        XCTAssertEqual(p(2), "2 фразы")
        XCTAssertEqual(p(5), "5 фраз")
        XCTAssertEqual(p(11), "11 фраз")
        XCTAssertEqual(p(12), "12 фраз")
        XCTAssertEqual(p(21), "21 фраза")
        XCTAssertEqual(p(22), "22 фразы")
        XCTAssertEqual(p(25), "25 фраз")
        XCTAssertEqual(p(111), "111 фраз")
        XCTAssertEqual(p(0), "0 фраз")
    }
}
