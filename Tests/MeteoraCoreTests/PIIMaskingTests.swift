import XCTest
@testable import MeteoraCore

/// Local personal-data masking (Swift port of the Cloud.ru Guardrails
/// regex rules). All values are synthetic; checksums are valid where the
/// rule needs them.
final class PIIMaskingTests: XCTestCase {
    private var scanner: PIIScanner!

    override func setUpWithError() throws {
        scanner = try PIIScanner()
    }

    private func masked(_ text: String) -> (String, PIIMap) {
        var map = PIIMap()
        let out = scanner.mask(text, map: &map)
        return (out, map)
    }

    private func types(_ map: PIIMap) -> Set<String> { Set(map.counts.keys) }

    func testAllRulesCompile() throws {
        XCTAssertEqual(scanner.rules.count, PIIRules.standard.count)
        XCTAssertGreaterThanOrEqual(PIIRules.upstream.count, 20)
        XCTAssertEqual(Set(PIIRules.standard.map(\.id)).count, PIIRules.standard.count, "rule ids must be unique")
    }

    func testSampleCorpus() {
        for (text, type) in PIISamples.positives {
            let (out, map) = masked(text)
            XCTAssertTrue(types(map).contains(type), "\(type) not hidden in «\(text)» → «\(out)»")
            XCTAssertEqual(map.unmask(out), text, "round trip of «\(text)»")
        }
        for text in PIISamples.negatives {
            XCTAssertEqual(masked(text).0, text, "false positive in ordinary meeting text")
        }
    }

    func testPhones() {
        let (out, map) = masked("+7 916 123-45-67 и 8 (495) 123-45-67 и 89161234567")
        XCTAssertEqual(out, "<PHONE_RU_1> и <PHONE_RU_2> и <PHONE_RU_3>")
        XCTAssertEqual(map.counts["PHONE_RU"], 3)
    }

    func testEmailAndPlaceholderFormat() {
        let (out, map) = masked("Пишите: ivan.petrov@example.ru, копия — IVAN@EXAMPLE.RU")
        XCTAssertEqual(out, "Пишите: <EMAIL_1>, копия — <EMAIL_2>")
        XCTAssertEqual(map.placeholderToOriginal["<EMAIL_1>"], "ivan.petrov@example.ru")
    }

    func testPassportNeedsKeyword() {
        XCTAssertEqual(masked("паспорт 4509 123456 выдан").0, "паспорт <PASSPORT_RF_1> выдан")
        XCTAssertEqual(masked("паспорт серия 4509 № 123456").0, "паспорт серия <PASSPORT_RF_1>")
        // No keyword, no checksum: upstream leaves a bare 4+6 digit run alone.
        XCTAssertEqual(masked("встреча 45 09 123456 человек").0, "встреча 45 09 123456 человек")
    }

    func testSnilsChecksum() {
        XCTAssertEqual(masked("СНИЛС 112-233-445 95").0, "СНИЛС <SNILS_1>")
        XCTAssertEqual(masked("СНИЛС 112-233-445 96").0, "СНИЛС 112-233-445 96")
        XCTAssertTrue(PIIValidation.snils("11223344595"))
        XCTAssertFalse(PIIValidation.snils("11223344596"))
    }

    func testInnChecksums() {
        XCTAssertEqual(masked("ИНН 500100732259").0, "ИНН <INN_PERSON_1>")
        XCTAssertEqual(masked("ИНН 7707083893").0, "ИНН <INN_ORG_1>")
        XCTAssertEqual(masked("ИНН 500100732258").0, "ИНН 500100732258")
        XCTAssertEqual(masked("ИНН 7707083894").0, "ИНН 7707083894")
        XCTAssertTrue(PIIValidation.innPerson("500100732259"))
        XCTAssertTrue(PIIValidation.innOrg("7707083893"))
        XCTAssertTrue(PIIValidation.ogrn("1027700132195"))
        XCTAssertTrue(PIIValidation.ogrnip("304500116000157"))
    }

    func testCardsLuhnAndContext() {
        XCTAssertTrue(PIIValidation.luhn("2200123456789019"))
        XCTAssertFalse(PIIValidation.luhn("2200123456789010"))
        XCTAssertEqual(masked("номер 4276380012345679 списали").0, "номер <CREDIT_CARD_1> списали")
        // Luhn fails and no card keyword: not a card.
        XCTAssertEqual(masked("номер 4276380012345678 списали").0, "номер 4276380012345678 списали")
        // Luhn fails but right after «карта»: hidden (upstream context rule).
        XCTAssertEqual(masked("на карту 2200 1234 5678 9010").0, "на карту <CREDIT_CARD_1>")
    }

    func testBankAccount20Digits() {
        XCTAssertEqual(masked("счёт 40817810099910004312 в банке").0, "счёт <BANK_ACCOUNT_1> в банке")
        XCTAssertEqual(masked("счёт 40817 810 0 9991 0004312").0, "счёт <BANK_ACCOUNT_1>")
        // Overlapping card-shaped prefix merges into the longer account.
        XCTAssertEqual(masked("счёт 4081 7810 0999 1000 4312 открыт").0, "счёт <BANK_ACCOUNT_1> открыт")
    }

    func testBirthDatesOnlyWithContext() {
        XCTAssertEqual(masked("дата рождения 12.03.1985").0, "дата рождения <BIRTH_DATE_1>")
        XCTAssertEqual(masked("родилась 5 мая 1990 года").0, "родилась <BIRTH_DATE_1>")
        XCTAssertEqual(masked("клиент 1985 г.р. обратился").0, "клиент <BIRTH_DATE_1> г.р. обратился")
        XCTAssertEqual(masked("сдать до 12.03.2027").0, "сдать до 12.03.2027")
        XCTAssertEqual(masked("дата рождения проекта — 2019 год").0, "дата рождения проекта — 2019 год")
    }

    func testNames() {
        XCTAssertEqual(masked("Иванов Иван Иванович подписал").0, "<FIO_1> подписал")
        XCTAssertEqual(masked("передайте Смирновой Анне Сергеевне").0, "передайте <FIO_1>")
        XCTAssertEqual(masked("подпись: Смирнова А.С.").0, "подпись: <FIO_1>")
        XCTAssertEqual(masked("Звоните Ивану Петрову завтра").0, "Звоните <FIO_1> завтра")
        XCTAssertEqual(masked("Петрова-Водкина Анна Сергеевна пришла").0, "<FIO_1> пришла")
        // A lone first name is not a ФИО for the rules.
        XCTAssertEqual(masked("Иван предложил перенести").0, "Иван предложил перенести")
    }

    func testAddressAndPatchedBranch() {
        XCTAssertEqual(masked("адрес: г. Москва, ул. Тверская, д. 15, кв. 4").0, "адрес: <ADDRESS_1>")
        XCTAssertEqual(masked("Чехова 44 кв 78").0, "<ADDRESS_1>")
        XCTAssertEqual(masked("Этап 2 к 15 ноября").0, "Этап 2 к 15 ноября")
        XCTAssertEqual(masked("Отчёт 3 кв 2026 сдаём").0, "Отчёт 3 кв 2026 сдаём")
    }

    func testOrdinaryMeetingNumbers() {
        let text = "Бюджет 1 500 000 рублей, рост 12,5 %, срок до 15.11.2026, в 14:30, 3 кв. 2026, ставка 7,5% годовых, NPS 72, версия 2.4.1."
        XCTAssertEqual(masked(text).0, text)
    }

    func testSameValueSamePlaceholder() {
        let (out, map) = masked("карта 4276 3800 1234 5679, ещё раз 4276 3800 1234 5679; тел. +7 916 123-45-67")
        XCTAssertEqual(out, "карта <CREDIT_CARD_1>, ещё раз <CREDIT_CARD_1>; тел. <PHONE_RU_1>")
        XCTAssertEqual(map.counts, ["CREDIT_CARD": 1, "PHONE_RU": 1])
    }

    func testMapIsSharedAcrossTexts() {
        var map = PIIMap()
        let a = scanner.mask("Позвоните на +7 916 123-45-67", map: &map)
        let b = scanner.mask("Повторю: +7 916 123-45-67, а лучше 8 (495) 123-45-67", map: &map)
        XCTAssertEqual(a, "Позвоните на <PHONE_RU_1>")
        XCTAssertEqual(b, "Повторю: <PHONE_RU_1>, а лучше <PHONE_RU_2>")
    }

    func testLiteralPlaceholdersAreReservedAndNotRestored() {
        let (out, map) = masked("В шаблоне есть <EMAIL_1>, а настоящий адрес a@example.ru")
        XCTAssertEqual(out, "В шаблоне есть <EMAIL_1>, а настоящий адрес <EMAIL_2>")
        XCTAssertNil(map.placeholderToOriginal["<EMAIL_1>"])
        XCTAssertEqual(map.unmask(out), "В шаблоне есть <EMAIL_1>, а настоящий адрес a@example.ru")
    }

    func testUnmaskToleratesModelFormatting() {
        let (_, map) = masked("звонила Анна Смирнова, телефон +7 916 123-45-67")
        let answer = "FIO\\_1 позвонит на &lt;PHONE_RU_1&gt;; < FIO_1 > и FIO_1: готово. <FIO_7> и TOKEN_1 остаются."
        XCTAssertEqual(map.unmask(answer),
                       "Анна Смирнова позвонит на +7 916 123-45-67; Анна Смирнова и Анна Смирнова: готово. <FIO_7> и TOKEN_1 остаются.")
    }

    func testRoundTripLongText() {
        let line = "[0:12] Спикер 1: Анна Смирнова, ИНН 500100732259, карта 2200 1234 5678 9019, e-mail a@example.ru; бюджет 1 500 000 ₽.\n"
        let text = String(repeating: line, count: 300)
        let (out, map) = masked(text)
        XCTAssertFalse(out.contains("Смирнова"))
        XCTAssertFalse(out.contains("500100732259"))
        XCTAssertTrue(out.contains("1 500 000 ₽"))
        XCTAssertEqual(map.unmask(out), text)
    }

    func testSpeakerNames() throws {
        let s = try PIIScanner(terms: ["Мария Иванова", "Пётр", "Спикер 3", "  "])
        var map = PIIMap()
        let lines = ["[0:01] Мария Иванова: Пётр, позвоните.",
                     "[0:09] Пётр: Хорошо, Петру и Марии Ивановой напомню.",
                     "[0:15] Спикер 3: Мария Иванова в копии."]
        let out = lines.map { s.mask($0, map: &map) }
        for word in ["Мария", "Иванов", "Пётр", "Петру", "Марии"] {
            XCTAssertFalse(out.contains { $0.contains(word) }, "\(word) leaked: \(out)")
        }
        XCTAssertTrue(out[2].hasPrefix("[0:15] Спикер 3: "), "generic label must stay")
        XCTAssertEqual(out[0], "[0:01] <FIO_1>: <FIO_2>, позвоните.")
        XCTAssertEqual(out[2], "[0:15] Спикер 3: <FIO_1> в копии.")
        for (o, l) in zip(out, lines) { XCTAssertEqual(map.unmask(o), l) }
    }

    func testGenericSpeakerLabels() {
        XCTAssertTrue(PIIScanner.isGenericSpeaker("Спикер 1"))
        XCTAssertTrue(PIIScanner.isGenericSpeaker("speaker 12"))
        XCTAssertFalse(PIIScanner.isGenericSpeaker("Анна"))
    }

    func testEmptyAndPlainText() {
        XCTAssertEqual(masked("").0, "")
        let (out, map) = masked("Просто текст без данных.")
        XCTAssertEqual(out, "Просто текст без данных.")
        XCTAssertTrue(map.isEmpty)
        XCTAssertEqual(map.unmask("<FIO_1>"), "<FIO_1>")
    }
}
