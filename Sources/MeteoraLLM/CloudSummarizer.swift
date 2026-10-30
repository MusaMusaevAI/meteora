import Foundation
import MeteoraCore

/// A provider the user has a paid API key for. The transcript is sent to it
/// only when the user chose it explicitly in settings.
public enum CloudProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case anthropic, openai, gemini, compatible
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini (Google)"
        case .compatible: return "Другой, совместимый с OpenAI"
        }
    }

    /// Sensible defaults; the user can type any model id the account has.
    public var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5-5"
        case .openai: return "gpt-5.6-terra"
        case .gemini: return "gemini-flash-latest"
        case .compatible: return ""
        }
    }

    public var keyHint: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .gemini: return "AIza…"
        case .compatible: return "ключ провайдера"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .compatible: return "https://openrouter.ai/api/v1"
        }
    }
}

public struct CloudConfig: Sendable, Equatable {
    public var provider: CloudProvider
    public var model: String
    public var apiKey: String
    /// Only used by `.compatible` (e.g. OpenRouter, DeepSeek, a corporate gateway).
    public var baseURL: String
    /// Hide personal data on this Mac before sending (see `PIIGuard`).
    public var protectPersonalData: Bool

    public init(provider: CloudProvider, model: String, apiKey: String, baseURL: String? = nil,
                protectPersonalData: Bool = true) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL ?? provider.defaultBaseURL
        self.protectPersonalData = protectPersonalData
    }
}

public enum CloudError: Error, LocalizedError, Equatable {
    case noKey
    case badURL
    case http(Int, String)
    case emptyAnswer
    case network(String)
    /// Personal-data protection failed; nothing was sent.
    case guardFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noKey: return "Не указан ключ API."
        case .badURL: return "Адрес сервера должен начинаться с https://."
        case .http(let code, let msg):
            switch code {
            case 401, 403: return "Ключ не подошёл (\(code)). Проверьте его в настройках итогов."
            case 404: return "Модель не найдена (\(code)). Проверьте название модели. \(msg)"
            case 429: return "Провайдер просит подождать: превышен лимит запросов или закончились средства (429)."
            default: return "Ошибка сервера \(code). \(msg)"
            }
        case .emptyAnswer: return "Модель вернула пустой ответ."
        case .network(let m): return "Нет связи с сервером: \(m)"
        case .guardFailed(let m):
            return "Защита персональных данных не сработала (\(m)) — текст встречи не отправлен. Попробуйте ещё раз или выключите защиту в настройках итогов."
        }
    }
}

/// Meeting summaries through a cloud model. Same prompts and parser as the
/// local model, so results look the same. Requests go straight from this Mac
/// to the provider over HTTPS; nothing is cached or logged. With
/// `protectPersonalData` the transcript is masked on this Mac first and the
/// provider only sees placeholders (fail closed: if masking fails, nothing
/// is sent).
/// The transcript and the key go only to the address the user set: a redirect
/// elsewhere is refused.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class CloudSummarizer: @unchecked Sendable {
    public let config: CloudConfig
    /// Transcripts longer than this are summarized in parts (cloud contexts
    /// are large; this only guards against very long recordings).
    static let singlePassCharacters = 400_000
    static let maxResponseBytes = 2 << 20

    private let session: URLSession

    public init(config: CloudConfig) {
        self.config = config
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 180
        c.timeoutIntervalForResource = 600
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// A tiny request to check the key and the model name.
    public func check() async throws {
        let answer = try await complete([ChatMessage(.user, "Ответь одним словом: готово")], maxTokens: 20)
        if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw CloudError.emptyAnswer }
    }

    public func summarize(_ transcript: Transcript, meetingDate: Date? = nil,
                          progress: @escaping @Sendable (SummaryProgress) -> Void = { _ in },
                          isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> MeetingSummary {
        var lines = MeetingTranscriptText.lines(transcript)
        guard !lines.isEmpty else { throw SummaryError.emptyTranscript }
        guard SummaryGrounding.assess(SummaryGrounding.spokenText(transcript)) == .ok else { throw SummaryError.notAMeeting }
        let groundingIndex = SummaryGrounding.Index(lines.joined(separator: "\n"))
        var speakers = MeetingTranscriptText.speakers(transcript)

        // Personal data never leaves the Mac: mask lines and speaker names,
        // keep the map here, put originals back into the answer below.
        var pii: PIIGuard?
        if config.protectPersonalData {
            progress(SummaryProgress(stage: .protectingData, fraction: 0.02))
            do {
                var g = try PIIGuard(speakers: speakers)
                var maskedLines: [String] = []
                maskedLines.reserveCapacity(lines.count)
                for (i, line) in lines.enumerated() {
                    if i % 200 == 0 && isCancelled() { throw LLMError.cancelled }
                    maskedLines.append(try g.mask(line))
                }
                var maskedSpeakers: [String] = []
                for s in speakers { maskedSpeakers.append(try g.mask(s)) }
                lines = maskedLines
                speakers = maskedSpeakers
                pii = g
            } catch LLMError.cancelled {
                throw LLMError.cancelled
            } catch {
                throw CloudError.guardFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        let guarded = !(pii?.map.isEmpty ?? true)
        func ask(_ messages: [ChatMessage], maxTokens: Int) async throws -> String {
            try await complete(guarded ? Self.withPIINote(messages) : messages, maxTokens: maxTokens)
        }
        let full = lines.joined(separator: "\n")

        var parsed: MeetingSummaryParser.Parsed
        if full.count <= Self.singlePassCharacters {
            progress(SummaryProgress(stage: .writing, fraction: 0.1))
            parsed = MeetingSummaryParser.parse(try await ask(Prompts.final(transcript: full, speakers: speakers), maxTokens: 2000))
        } else {
            let chunks = MeetingTranscriptText.chunks(lines, budget: Self.singlePassCharacters / 2, count: { $0.count })
            var notes: [String] = []
            for (i, chunk) in chunks.enumerated() {
                if isCancelled() { throw LLMError.cancelled }
                progress(SummaryProgress(stage: .readingPart(index: i + 1, count: chunks.count),
                                         fraction: 0.8 * Double(i) / Double(chunks.count)))
                let p = MeetingSummaryParser.parse(try await ask(
                    Prompts.map(chunk: chunk, index: i + 1, count: chunks.count, speakers: speakers), maxTokens: 1500))
                notes.append(MeetingSummarizer.notes(p, part: i + 1, range: MeetingSummarizer.timeRange(chunk)))
            }
            progress(SummaryProgress(stage: .combining, fraction: 0.85))
            parsed = MeetingSummaryParser.parse(try await ask(
                Prompts.reduce(notes: notes.joined(separator: "\n\n"), speakers: speakers), maxTokens: 2000))
        }
        if isCancelled() { throw LLMError.cancelled }
        guard !parsed.isEmpty else { throw SummaryError.unreadableAnswer }
        // Originals back in, on this Mac. Intermediate notes stay masked.
        if let g = pii {
            parsed.title = g.unmask(parsed.title)
            parsed.summary = g.unmask(parsed.summary)
            parsed.keyPoints = parsed.keyPoints.map { g.unmask($0) }
            parsed.decisions = parsed.decisions.map { g.unmask($0) }
            parsed.actionItems = parsed.actionItems.map { g.unmask($0) }
        }
        parsed = SummaryGrounding.filter(parsed, against: groundingIndex)
        if SummaryGrounding.isVoid(parsed) { throw SummaryError.notAMeeting }
        var topic = parsed.title
        if topic.isEmpty {
            topic = parsed.summary.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? ""
        }
        progress(SummaryProgress(stage: .writing, fraction: 1))
        return MeetingSummary(title: MeetingSummary.composeTitle(topic: topic, date: meetingDate),
                              summary: parsed.summary, keyPoints: parsed.keyPoints,
                              decisions: parsed.decisions, actionItems: parsed.actionItems)
    }

    /// Tells the model what the placeholders are (system message).
    static func withPIINote(_ messages: [ChatMessage]) -> [ChatMessage] {
        var out = messages
        if let i = out.firstIndex(where: { $0.role == .system }) {
            out[i].content += "\n" + PIIGuard.modelNote
        } else {
            out.insert(ChatMessage(.system, PIIGuard.modelNote), at: 0)
        }
        return out
    }

    // MARK: Requests

    func complete(_ messages: [ChatMessage], maxTokens: Int) async throws -> String {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudError.noKey }
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system }

        var request: URLRequest
        var body: [String: Any]
        switch config.provider {
        case .anthropic:
            request = try Self.request(config.baseURL, path: "/v1/messages")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model.isEmpty ? config.provider.defaultModel : model, "max_tokens": maxTokens,
                    "messages": turns.map { ["role": $0.role.rawValue, "content": $0.content] }]
            if !system.isEmpty { body["system"] = system }
        case .openai, .compatible:
            request = try Self.request(config.baseURL, path: "/chat/completions")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": model.isEmpty ? config.provider.defaultModel : model,
                    "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }]
            // Current OpenAI models take max_completion_tokens; other
            // OpenAI-compatible servers still expect max_tokens.
            body[config.provider == .openai ? "max_completion_tokens" : "max_tokens"] = config.provider == .openai ? maxTokens * 4 : maxTokens
        case .gemini:
            let m = model.isEmpty ? config.provider.defaultModel : model
            guard m.allSatisfy({ $0.isLetter || $0.isNumber || "-._".contains($0) }) else { throw CloudError.http(404, m) }
            request = try Self.request(config.baseURL, path: "/models/\(m):generateContent")
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            body = ["contents": turns.map { ["role": $0.role == .assistant ? "model" : "user", "parts": [["text": $0.content]]] },
                    "generationConfig": ["maxOutputTokens": maxTokens * 4]]
            if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw LLMError.cancelled
        } catch let e as URLError where e.code == .cancelled {
            throw LLMError.cancelled
        } catch {
            throw CloudError.network(error.localizedDescription)
        }
        guard data.count <= Self.maxResponseBytes else { throw CloudError.http(0, "слишком большой ответ") }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(code) else {
            throw CloudError.http(code, Self.errorMessage(json) ?? "")
        }
        let text = Self.text(from: json, provider: config.provider)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudError.emptyAnswer }
        return text
    }

    static func request(_ base: String, path: String) throws -> URLRequest {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard b.lowercased().hasPrefix("https://"), let url = URL(string: b + path), url.host != nil else { throw CloudError.badURL }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    static func text(from json: [String: Any]?, provider: CloudProvider) -> String? {
        guard let json else { return nil }
        switch provider {
        case .anthropic:
            let blocks = json["content"] as? [[String: Any]] ?? []
            return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case .openai, .compatible:
            let choices = json["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any]
            return message?["content"] as? String
        case .gemini:
            let candidates = json["candidates"] as? [[String: Any]] ?? []
            let content = candidates.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            return parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        }
    }

    static func errorMessage(_ json: [String: Any]?) -> String? {
        guard let json else { return nil }
        if let e = json["error"] as? [String: Any], let m = e["message"] as? String { return String(m.prefix(200)) }
        if let m = json["message"] as? String { return String(m.prefix(200)) }
        return nil
    }
}
