import XCTest
@testable import MeteoraCore

final class TermDictionaryTests: XCTestCase {
    let c = TermCorrector(terms: StarterTerms.pensions + [Term(text: "Meteora", variants: ["метеора"])])

    func testAbbreviationsReadAloud() {
        XCTAssertEqual(c.correct("Подключаем пэдээс через госуслуги."), "Подключаем ПДС через Госуслуги.")
        XCTAssertEqual(c.correct("клиенты пэ дэ эс и о пэ эс"), "клиенты ПДС и ОПС")
        XCTAssertEqual(c.correct("зэ е вэ подписан"), "ЗЕВ подписан")
        XCTAssertEqual(c.correct("Пдс растёт."), "ПДС растёт.")
    }

    func testNamesAndJoinedWords() {
        XCTAssertEqual(c.correct("в газ фонд и газ-фонд"), "в Газфонд и Газфонд")
        XCTAssertEqual(c.correct("Это газфон."), "Это Газфонд.")
        XCTAssertEqual(c.correct("настроить авто платёж"), "настроить автоплатёж")
        XCTAssertEqual(c.correct("Авто платеж включён."), "Автоплатёж включён.")
    }

    func testDoesNotTouchOtherWords() {
        XCTAssertEqual(c.correct("автоплатежи уже работают"), "автоплатежи уже работают")
        XCTAssertEqual(c.correct("клиенты Газфонда"), "клиенты Газфонда")
        XCTAssertEqual(c.correct("о чём речь, пэ?"), "о чём речь, пэ?")
        // Words of a phrase separated by punctuation are not joined.
        XCTAssertEqual(c.correct("газ. Фонд"), "газ. Фонд")
    }

    func testTranscript() {
        let tr = Transcript(sourceName: "x", duration: 2, engine: "t",
                            segments: [TranscriptSegment(start: 0, end: 1, text: "метеора и пдс")])
        XCTAssertEqual(c.correct(tr).segments[0].text, "Meteora и ПДС")
    }

    func testCSVRoundTrip() {
        let terms = [Term(text: "ПДС"), Term(text: "Газфонд", variants: ["газ фонд", "газфон"]), Term(text: "a;b", variants: ["x\"y"])]
        let parsed = TermCSV.parse(TermCSV.export(terms))
        XCTAssertEqual(parsed.map(\.text), ["ПДС", "Газфонд", "a;b"])
        XCTAssertEqual(parsed[1].variants, ["газ фонд", "газфон"])
        XCTAssertEqual(parsed[2].variants, ["x\"y"])
        XCTAssertEqual(TermCSV.parse(Data("ОПС,о пэ эс\nНПФ".utf8)).map(\.text), ["ОПС", "НПФ"])
    }
}
