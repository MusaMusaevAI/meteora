import XCTest
@testable import MeteoraCore

final class MeetingSummaryTests: XCTestCase {
    func testParsesPlainJSON() {
        let raw = """
        {"title": "Бюджет маркетинга", "summary": "Обсудили бюджет.", "key_points": ["Рост на 10%"],
         "decisions": ["Утвердить бюджет"], "action_items": ["Анна: подготовить смету"]}
        """
        let p = MeetingSummaryParser.parse(raw)
        XCTAssertTrue(p.fromJSON)
        XCTAssertEqual(p.title, "Бюджет маркетинга")
        XCTAssertEqual(p.summary, "Обсудили бюджет.")
        XCTAssertEqual(p.keyPoints, ["Рост на 10%"])
        XCTAssertEqual(p.decisions, ["Утвердить бюджет"])
        XCTAssertEqual(p.actionItems, ["Анна: подготовить смету"])
    }

    func testParsesFencedJSONWithThinkingAndTrailingCommas() {
        let raw = """
        <think>
        думаю
        </think>
        Вот протокол:
        ```json
        {"title": "Релиз", "summary": "Перенесли релиз.", "key_points": ["a", "b",], "decisions": [], }
        ```
        Готово.
        """
        let p = MeetingSummaryParser.parse(raw)
        XCTAssertTrue(p.fromJSON)
        XCTAssertEqual(p.title, "Релиз")
        XCTAssertEqual(p.keyPoints, ["a", "b"])
        XCTAssertEqual(p.decisions, [])
    }

    func testRepairsTruncatedJSON() {
        let raw = #"{"title": "Бюджет", "summary": "Обсудили.", "key_points": ["Первый", "Второй", "Тре"#
        let p = MeetingSummaryParser.parse(raw)
        XCTAssertTrue(p.fromJSON)
        XCTAssertEqual(p.title, "Бюджет")
        XCTAssertEqual(p.summary, "Обсудили.")
        XCTAssertTrue(p.keyPoints.starts(with: ["Первый", "Второй"]))
    }

    func testActionItemObjectsAndEmptyMarkers() {
        let raw = #"{"summary": "x", "decisions": ["нет"], "action_items": [{"owner": "Иван", "task": "отправить отчёт", "due": "пятница"}, {"task": "созвониться"}]}"#
        let p = MeetingSummaryParser.parse(raw)
        XCTAssertEqual(p.decisions, [])
        XCTAssertEqual(p.actionItems, ["Иван: отправить отчёт, срок — пятница", "созвониться"])
    }

    func testFallsBackToSections() {
        let raw = """
        Заголовок: Планирование спринта
        Резюме: Команда разобрала задачи.
        Решения:
        - Начать спринт в понедельник
        1. Начать спринт в понедельник
        Задачи:
        * Олег: обновить доску
        """
        let p = MeetingSummaryParser.parse(raw)
        XCTAssertFalse(p.fromJSON)
        XCTAssertEqual(p.title, "Планирование спринта")
        XCTAssertEqual(p.summary, "Команда разобрала задачи.")
        XCTAssertEqual(p.decisions, ["Начать спринт в понедельник"])
        XCTAssertEqual(p.actionItems, ["Олег: обновить доску"])
    }

    func testCompleteObjectDetection() {
        XCTAssertFalse(MeetingSummaryParser.isCompleteObject(#"{"a": "}"#))
        XCTAssertFalse(MeetingSummaryParser.isCompleteObject(#"{"a": [1, 2"#))
        XCTAssertTrue(MeetingSummaryParser.isCompleteObject(#"{"a": "}{"} и дальше"#))
    }

    func testTitleLengthAndDate() {
        let long = String(repeating: "очень длинная тема ", count: 10)
        let t = MeetingSummary.composeTitle(topic: long, date: nil)
        XCTAssertLessThanOrEqual(t.count, MeetingSummary.maxTopicLength)
        XCTAssertTrue(t.hasSuffix("…"))
        let date = ISO8601DateFormatter().date(from: "2026-10-29T11:30:00Z")!
        let dated = MeetingSummary.composeTitle(topic: "«Бюджет 2027.»", date: date, timeZone: TimeZone(identifier: "Europe/Moscow")!)
        XCTAssertEqual(dated, "Бюджет 2027 — 29 октября 2026, 14:30")
        XCTAssertEqual(MeetingSummary.composeTitle(topic: "  ", date: nil), "Встреча")
    }

    func testMarkdownEscapesModelOutput() {
        let s = MeetingSummary(title: "Тема", summary: "См. [ссылку](http://x)", keyPoints: ["<img src=x>"])
        let md = s.markdown()
        XCTAssertFalse(md.contains("](http"))
        XCTAssertTrue(md.contains("\\<img"))
        XCTAssertTrue(md.contains("## Ключевые моменты"))
        XCTAssertFalse(md.contains("## Решения"))
    }

    func testDecodesOldOrPartialJSON() throws {
        let s = try JSONDecoder().decode(MeetingSummary.self, from: Data(#"{"title": "T"}"#.utf8))
        XCTAssertEqual(s.title, "T")
        XCTAssertEqual(s.actionItems, [])
    }

    func testChunksRespectBudget() {
        let lines = (0 ..< 50).map { "[0:\(String(format: "%02d", $0))] " + String(repeating: "слово ", count: 20) }
        let count: (String) -> Int = { $0.split(separator: " ").count }
        let chunks = MeetingTranscriptText.chunks(lines, budget: 100, count: count)
        XCTAssertGreaterThan(chunks.count, 5)
        for c in chunks { XCTAssertLessThanOrEqual(count(c), 100) }
        XCTAssertEqual(chunks.joined(separator: "\n").split(separator: "\n").count, 50)
        // A single line longer than the budget is split.
        let huge = MeetingTranscriptText.chunks([String(repeating: "Фраза из слов. ", count: 100)], budget: 40, count: count)
        XCTAssertGreaterThan(huge.count, 1)
        for c in huge { XCTAssertLessThanOrEqual(count(c), 40) }
    }

    func testTranscriptLinesWithSpeakers() {
        let tr = Transcript(sourceName: "x", duration: 30, engine: "t", segments: [
            TranscriptSegment(start: 0, end: 2, text: "Привет.", speaker: "Анна"),
            TranscriptSegment(start: 2.2, end: 4, text: "Начнём.", speaker: "Анна"),
            TranscriptSegment(start: 5, end: 7, text: "Да.", speaker: "Олег"),
        ])
        let lines = MeetingTranscriptText.lines(tr)
        XCTAssertEqual(lines.first, "[0:00] Анна: Привет. Начнём.")
        XCTAssertEqual(lines.last, "[0:05] Олег: Да.")
        XCTAssertEqual(MeetingTranscriptText.speakers(tr), ["Анна", "Олег"])
    }
}

final class MeetingMailTests: XCTestCase {
    let summary = MeetingSummary(title: "Рассылка по ПДС", summary: "Обсудили старт <рассылки>.",
                                 keyPoints: ["Старт 10 ноября"], decisions: ["Стартуем 10 ноября"],
                                 actionItems: ["Олег: тексты писем до пятницы"])

    func testMailtoCarriesSubjectAndBody() {
        let mail = MeetingMail(summary: summary, recipients: ["team@example.com"])
        let url = mail.mailtoURL.absoluteString
        XCTAssertTrue(url.hasPrefix("mailto:team@example.com?subject="))
        XCTAssertTrue(url.contains("&body="))
        let comps = URLComponents(string: url)
        XCTAssertEqual(comps?.queryItems?.first { $0.name == "subject" }?.value, "Итоги: Рассылка по ПДС")
        XCTAssertTrue(comps?.queryItems?.first { $0.name == "body" }?.value?.contains("Олег: тексты писем") == true)
    }

    func testLongMailtoIsShortened() {
        var long = summary
        long.keyPoints = Array(repeating: "Очень длинный пункт про рассылку, сроки и ответственных", count: 80)
        let url = MeetingMail(summary: long).mailtoURL
        XCTAssertLessThanOrEqual(url.absoluteString.count, MeetingMail.mailtoLimit)
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:?subject="))
    }

    func testEmlIsAnUnsentMimeMessageWithAttachment() {
        let att = MeetingMail.Attachment(fileName: "Встреча — расшифровка.docx",
                                         mimeType: MeetingMail.mimeType(forExtension: "docx"), data: Data([1, 2, 3]))
        let mail = MeetingMail(summary: summary, attachments: [att], footer: "Подпись")
        let text = String(decoding: mail.eml(date: Date(timeIntervalSince1970: 0), boundary: "B"), as: UTF8.self)
        XCTAssertTrue(text.contains("X-Unsent: 1\r\n"))
        XCTAssertTrue(text.contains("Subject: =?UTF-8?B?"))
        XCTAssertTrue(text.contains("Content-Type: multipart/mixed; boundary=\"mixed-B\""))
        XCTAssertTrue(text.contains("Content-Type: text/html; charset=utf-8"))
        XCTAssertTrue(text.contains("filename*=UTF-8''"))
        XCTAssertTrue(text.contains("AQID")) // base64 of 1,2,3
        XCTAssertTrue(text.hasSuffix("--mixed-B--\r\n"))
    }

    func testHtmlEscapesModelText() {
        let html = MeetingMail(summary: summary).html
        XCTAssertTrue(html.contains("&lt;рассылки&gt;"))
        XCTAssertFalse(html.contains("<рассылки>"))
    }
}
