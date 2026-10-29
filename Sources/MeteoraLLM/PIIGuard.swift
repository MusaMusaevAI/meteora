import Foundation
import MeteoraCore

/// «Защита персональных данных» for cloud summaries: before a transcript
/// leaves the Mac, ФИО, phones, e-mail, passport, СНИЛС, ИНН, cards,
/// accounts, addresses and dates of birth are replaced with placeholders
/// (`<FIO_1>`, `<PHONE_RU_1>`…); the cloud model only ever sees those, and
/// the originals are put back into its answer here. The placeholder map is
/// kept in memory for one job and never sent or saved.
///
/// Detection is the Cloud.ru Guardrails rule engine (regex + checksums),
/// ported to Swift in `MeteoraCore/PIIMasking.swift`. It runs locally and
/// needs no network or key.
public struct PIIGuard: Sendable {
    public private(set) var map = PIIMap()
    let scanner: PIIScanner

    /// `speakers`: names the user gave to speakers; they are hidden too.
    public init(speakers: [String] = []) throws {
        scanner = try PIIScanner(terms: speakers)
    }

    /// Masks `text`. A second pass checks the result; if anything is still
    /// found after three passes, throws instead of letting it through.
    public mutating func mask(_ text: String) throws -> String {
        var out = text
        for _ in 0..<3 {
            if scanner.matches(in: out).isEmpty { return out }
            out = scanner.mask(out, map: &map)
        }
        if scanner.matches(in: out).isEmpty { return out }
        throw PIIGuardError.residual
    }

    public func unmask(_ text: String) -> String { map.unmask(text) }

    /// Added to the system prompt when something was hidden.
    public static let modelNote = """
    — Персональные данные в расшифровке заменены метками вида <FIO_1>, <PHONE_RU_1>, <EMAIL_1>. \
    Метка <FIO_N> обозначает человека. Переноси метки в ответ ровно как они написаны: не склоняй, \
    не переводи, не расшифровывай и не придумывай новых.
    """
}

public enum PIIGuardError: Error, LocalizedError, Equatable {
    case residual

    public var errorDescription: String? {
        switch self {
        case .residual: return "Не удалось скрыть все персональные данные."
        }
    }
}

extension PIIGuard {
    /// Self-test of local masking, no network: every sample in
    /// `PIISamples.positives` must be hidden with the expected type and
    /// restored exactly; `PIISamples.negatives` (ordinary meeting phrases)
    /// must stay untouched; speaker names and model-mangled placeholders
    /// must round-trip; a long transcript is timed.
    public static func runSelfTest() -> [String: Any] {
        var report: [String: Any] = [
            "engine": "Cloud.ru guardrails-llm-filter v0.1.2 rules (Apache-2.0), ported to Swift; local, no network",
            "rules": PIIRules.standard.count,
            "upstreamRules": PIIRules.upstream.count,
            "meteoraRules": PIIRules.meteora.count,
        ]
        var errors: [String] = []
        let scanner: PIIScanner
        do {
            scanner = try PIIScanner()
        } catch {
            report["errors"] = ["compile: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"]
            report["ok"] = false
            return report
        }

        var missed: [String] = []
        for (text, type) in PIISamples.positives {
            var map = PIIMap()
            let masked = scanner.mask(text, map: &map)
            if map.counts[type] == nil { missed.append("\(type): \(text) → \(masked)") }
            if map.unmask(masked) != text { errors.append("round trip: \(text)") }
        }
        var falsePositives: [String] = []
        for text in PIISamples.negatives {
            var map = PIIMap()
            let masked = scanner.mask(text, map: &map)
            if masked != text { falsePositives.append("\(text) → \(masked)") }
        }
        report["positives"] = PIISamples.positives.count
        report["negatives"] = PIISamples.negatives.count
        report["missed"] = missed
        report["falsePositives"] = falsePositives

        // Speakers, consistency, reserved literals and mangled placeholders.
        do {
            var g = try PIIGuard(speakers: ["Мария Иванова", "Пётр", "Спикер 3"])
            let lines = ["[0:01] Мария Иванова: Пётр, позвоните на +7 916 123-45-67.",
                         "[0:09] Пётр: Хорошо, Петру и Марии напомню. В шаблоне уже есть <EMAIL_1>.",
                         "[0:15] Спикер 3: Пишите на a.petrova@example.ru, Мария Иванова в копии."]
            let masked = try lines.map { try g.mask($0) }
            let leaked = ["Мария", "Иванова", "Пётр", "Петру", "Марии", "916", "a.petrova"].filter { w in masked.contains { $0.contains(w) } }
            if !leaked.isEmpty { errors.append("speaker leak: \(leaked)") }
            if !masked[2].hasPrefix("[0:15] Спикер 3:") { errors.append("generic speaker label was masked") }
            if !masked[1].contains("<EMAIL_1>") || g.map.placeholderToOriginal["<EMAIL_1>"] != nil {
                errors.append("literal placeholder was reused")
            }
            if zip(lines, masked).contains(where: { g.unmask($0.1) != $0.0 }) { errors.append("speaker round trip") }
            let fio = g.map.placeholderToOriginal.first(where: { $0.value == "Мария Иванова" })?.key ?? "<FIO_1>"
            let bare = fio.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let answer = "\(fio) поручила: \(bare.replacingOccurrences(of: "_", with: "\\_")) — &lt;\(bare)&gt;, <FIO_99>."
            let restored = g.unmask(answer)
            if restored != "Мария Иванова поручила: Мария Иванова — Мария Иванова, <FIO_99>." {
                errors.append("unmask variants: \(restored)")
            }
            report["speakerPlaceholders"] = g.map.counts
        } catch {
            errors.append("guard: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }

        // Speed on a long transcript (~200k characters).
        let line = "[1:02:03] Спикер 1: Обсудили бюджет на 2027 год, 1 500 000 рублей, срок до 15.11.2026, ответственная Анна Смирнова, телефон +7 916 123-45-67. "
        let long = String(repeating: line, count: 1400)
        let t0 = Date()
        var map = PIIMap()
        let maskedLong = scanner.mask(long, map: &map)
        report["longChars"] = long.count
        report["longSeconds"] = Date().timeIntervalSince(t0)
        if maskedLong.contains("Смирнова") || maskedLong.contains("916") { errors.append("long transcript leak") }
        if map.unmask(maskedLong) != long { errors.append("long round trip") }

        report["errors"] = errors
        report["ok"] = errors.isEmpty && missed.isEmpty && falsePositives.isEmpty
        return report
    }
}
