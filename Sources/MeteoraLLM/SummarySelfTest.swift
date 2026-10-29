import Foundation
import MeteoraCore

extension MeetingSummarizer {
    /// Folder CI may pre-fill with the hash-pinned GGUF (restored from the
    /// actions cache by scripts/fetch_summary_model.sh) so a run doesn't
    /// download 2.7 GB. Only consulted under METEORA_SELFTEST=1, and the file
    /// still goes through the full SHA-256 check.
    static var ciModelFile: URL {
        var home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return home.appendingPathComponent("Downloads/Meteora-CI-models", isDirectory: true)
            .appendingPathComponent(selfTestTier.spec.fileName)
    }

    public static var selfTestTierPublic: SummaryModelTier { selfTestTier }

    /// CI tests the light tier (small download, same family and template).
    static var selfTestTier: SummaryModelTier {
        SummaryModelTier(rawValue: ProcessInfo.processInfo.environment["METEORA_LLM_TIER"] ?? "") ?? .light
    }

    /// Self-test for CI: installs the model (CI cache or download), summarizes
    /// `transcriptText`, writes summary.json / summary.md / summary-raw.txt
    /// into `output`, and reports timing, tokens/s, whether Metal was used and
    /// the parsed result. `report["ok"]` is true when a non-empty summary
    /// with a title was produced.
    public static func runSelfTest(transcriptText: String, output: URL) async -> [String: Any] {
        var report: [String: Any] = [
            "model": selfTestTier.spec.displayName, "file": selfTestTier.spec.fileName,
            "revision": selfTestTier.spec.revision, "sha256": selfTestTier.spec.sha256,
            "gpuDevices": LlamaEngine.gpuDevices,
            "forceCPU": ProcessInfo.processInfo.environment["METEORA_LLM_FORCE_CPU"] == "1",
        ]
        var errors: [String] = []
        let store = SummaryModelStore.store(for: selfTestTier)
        let noCancel: @Sendable () -> Bool = { false }

        // 1. Model
        let t0 = Date()
        if !store.isInstalled {
            let ci = ciModelFile
            if ProcessInfo.processInfo.environment["METEORA_SELFTEST"] == "1",
               FileManager.default.fileExists(atPath: ci.path) {
                report["source"] = "ci-cache"
                do { try store.installFromLocalFile(ci) } catch { errors.append("model import: \(error.localizedDescription)") }
            } else {
                report["source"] = "download"
                do {
                    try await store.install(progress: { _ in }, isCancelled: noCancel)
                } catch {
                    errors.append("model download: \(error.localizedDescription)")
                }
            }
            report["installSeconds"] = Date().timeIntervalSince(t0)
        } else {
            report["source"] = "already-installed"
        }
        report["installed"] = store.isInstalled
        guard store.isInstalled else {
            report["errors"] = errors
            report["ok"] = false
            return report
        }

        // 2. Transcript from plain text: one "phrase" per sentence, 6 s each.
        var segments: [TranscriptSegment] = []
        var t = 0.0
        for raw in transcriptText.components(separatedBy: CharacterSet(charactersIn: ".!?\n")) {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            segments.append(TranscriptSegment(start: t, end: t + 5.5, text: s + "."))
            t += 6
        }
        let transcript = Transcript(sourceName: "selftest", duration: t, engine: "selftest", segments: segments)

        // 3. Summary. Small context: CI VMs have 7 GB of RAM.
        let summarizer = MeetingSummarizer(store: store, options: LLMOptions(contextTokens: 4096))
        let t1 = Date()
        do {
            let date = ISO8601DateFormatter().date(from: "2026-10-29T11:30:00Z")
            let summary = try await summarizer.summarize(transcript, meetingDate: date)
            let seconds = Date().timeIntervalSince(t1)
            report["seconds"] = seconds
            if let e = summarizer.loadedEngine {
                report["usesMetal"] = e.usesGPU
                report["device"] = e.deviceDescription
                report["contextTokens"] = e.contextTokens
                report["loadSeconds"] = e.loadSeconds
                report["modelBytes"] = e.modelBytes
            }
            let results = summarizer.lastResults
            report["requests"] = results.count
            report["promptTokens"] = results.reduce(0) { $0 + $1.promptTokens }
            report["generatedTokens"] = results.reduce(0) { $0 + $1.generatedTokens }
            report["promptTokensPerSecond"] = results.last?.promptTokensPerSecond ?? 0
            report["tokensPerSecond"] = results.last?.tokensPerSecond ?? 0
            report["hitTokenLimit"] = results.contains { $0.hitTokenLimit }
            report["summary"] = [
                "title": summary.title, "summary": summary.summary, "keyPoints": summary.keyPoints,
                "decisions": summary.decisions, "actionItems": summary.actionItems,
            ] as [String: Any]
            report["parsedFromJSON"] = summarizer.lastRawAnswers.last.map { MeetingSummaryParser.parse($0).fromJSON } ?? false

            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try? enc.encode(summary).write(to: output.appendingPathComponent("summary.json"))
            try? summary.markdown().write(to: output.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
            if summary.summary.isEmpty { errors.append("LLM: empty summary") }
            if summary.title.isEmpty { errors.append("LLM: empty title") }
        } catch {
            report["seconds"] = Date().timeIntervalSince(t1)
            errors.append("LLM: \(error.localizedDescription)")
        }
        try? summarizer.lastRawAnswers.joined(separator: "\n\n-----\n\n")
            .write(to: output.appendingPathComponent("summary-raw.txt"), atomically: true, encoding: .utf8)
        try? LlamaLog.recent.joined(separator: "\n")
            .write(to: output.appendingPathComponent("llama-log.txt"), atomically: true, encoding: .utf8)
        summarizer.unload()
        report["errors"] = errors
        report["ok"] = errors.isEmpty
        return report
    }
}
