import XCTest
@testable import MeteoraCore

final class SummaryGroundingTests: XCTestCase {
    let meeting = """
    [0:01] Анна: Давайте решим по релизу. Тестирование мобильного приложения не закончено, нашли ошибки в оплате.
    [0:20] Олег: Предлагаю перенести релиз на следующую неделю, а оплату проверить отдельно до пятницы.
    [0:41] Анна: Согласна, переносим релиз. Олег, подготовь список ошибок оплаты.
    """

    func testAssessment() {
        XCTAssertEqual(SummaryGrounding.assess("ну да привет"), .tooShort)
        let song = Array(repeating: "сенин гезлерин ай гюль ай гюль сенин гезлерин", count: 12).joined(separator: " ")
        XCTAssertEqual(SummaryGrounding.assess(song), .repetitive)
        XCTAssertEqual(SummaryGrounding.assess(meeting), .ok)
    }

    func testKeepsSupportedLinesAndDropsInventedOnes() {
        let index = SummaryGrounding.Index(meeting)
        let parsed = MeetingSummaryParser.Parsed(
            title: "Бюджет маркетинга на 2027 год",
            summary: "Команда обсудила перенос релиза мобильного приложения. Утвердили бюджет маркетинга на 2027 год.",
            keyPoints: ["Тестирование приложения не закончено, есть ошибки в оплате", "Рекламный бюджет вырос на 300 тысяч"],
            decisions: ["Перенести релиз на следующую неделю"],
            actionItems: ["Олег: подготовить список ошибок оплаты", "Мария: согласовать смету с подрядчиком"])
        let f = SummaryGrounding.filter(parsed, against: index)
        XCTAssertEqual(f.title, "")
        XCTAssertEqual(f.summary, "Команда обсудила перенос релиза мобильного приложения.")
        XCTAssertEqual(f.keyPoints, ["Тестирование приложения не закончено, есть ошибки в оплате"])
        XCTAssertEqual(f.decisions, ["Перенести релиз на следующую неделю"])
        XCTAssertEqual(f.actionItems, ["Олег: подготовить список ошибок оплаты"])
        XCTAssertFalse(SummaryGrounding.isVoid(f))
    }

    func testNoMeetingAnswerIsVoid() {
        let index = SummaryGrounding.Index("сенин гезлерин ай гюль")
        let p = MeetingSummaryParser.Parsed(summary: "Содержательного обсуждения в записи нет.")
        XCTAssertTrue(SummaryGrounding.isVoid(SummaryGrounding.filter(p, against: index)))
    }
}
