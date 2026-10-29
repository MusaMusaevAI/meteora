import Foundation
import Security
import MeteoraCore
import MeteoraASR
import MeteoraLLM

/// Which engine writes meeting summaries: one of three local models, or a
/// cloud model with the user's own API key.
enum SummaryEngine: Equatable, Hashable {
    case local(SummaryModelTier)
    case cloud(CloudProvider)

    var raw: String {
        switch self {
        case .local(let t): return "local:\(t.rawValue)"
        case .cloud(let p): return "cloud:\(p.rawValue)"
        }
    }

    init?(raw: String) {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0] == "local", let t = SummaryModelTier(rawValue: parts[1]) { self = .local(t); return }
        if parts[0] == "cloud", let p = CloudProvider(rawValue: parts[1]) { self = .cloud(p); return }
        return nil
    }

    var isCloud: Bool { if case .cloud = self { return true }; return false }
}

/// API keys live in the login Keychain of this Mac, never in files or
/// preferences.
enum APIKeychain {
    private static let service = "com.musamusaev.meteora.api-key"

    static func key(for p: CloudProvider) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: p.rawValue, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ key: String?, for p: CloudProvider) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: p.rawValue]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "Meteora — ключ \(p.title)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Summary engine settings and the downloadable local models, shared by
/// all windows.
@MainActor
final class SummaryModelController: ObservableObject {
    static let shared = SummaryModelController()

    @Published var engine: SummaryEngine { didSet { UserDefaults.standard.set(engine.raw, forKey: "summary.engine") } }
    @Published private(set) var installed: Set<SummaryModelTier> = []
    /// The tier being downloaded and its progress.
    @Published private(set) var downloading: SummaryModelTier?
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    @Published private(set) var keyed: Set<CloudProvider> = []
    private var token: CancelToken?
    private var summarizers: [SummaryModelTier: MeetingSummarizer] = [:]

    init() {
        engine = UserDefaults.standard.string(forKey: "summary.engine").flatMap(SummaryEngine.init(raw:)) ?? .local(.medium)
        refresh()
    }

    func refresh() {
        installed = Set(SummaryModelTier.allCases.filter { SummaryModelStore.store(for: $0).isInstalled })
        keyed = Set(CloudProvider.allCases.filter { !(APIKeychain.key(for: $0) ?? "").isEmpty })
    }

    // MARK: Status for the UI

    var isInstalled: Bool { isReady }

    /// The chosen engine can run right now (model on disk / key saved).
    var isReady: Bool {
        switch engine {
        case .local(let t): return installed.contains(t)
        case .cloud(let p): return keyed.contains(p) && (p != .compatible || !baseURL.isEmpty)
        }
    }

    var engineTitle: String {
        switch engine {
        case .local(let t): return "\(t.title) · \(t.spec.displayName)"
        case .cloud(let p): return "\(p.title) · \(model(for: p))"
        }
    }

    var sizeText: String {
        if case .local(let t) = engine { return FileSizeText.string(t.spec.fileSize) }
        return ""
    }

    // MARK: Cloud settings

    func model(for p: CloudProvider) -> String {
        let m = UserDefaults.standard.string(forKey: "summary.model.\(p.rawValue)") ?? ""
        return m.isEmpty ? p.defaultModel : m
    }

    func setModel(_ m: String, for p: CloudProvider) {
        UserDefaults.standard.set(m.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "summary.model.\(p.rawValue)")
        objectWillChange.send()
    }

    var baseURL: String {
        get { UserDefaults.standard.string(forKey: "summary.baseURL") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "summary.baseURL"); objectWillChange.send() }
    }

    func saveKey(_ key: String, for p: CloudProvider) {
        APIKeychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: p)
        refresh()
    }

    func removeKey(for p: CloudProvider) {
        APIKeychain.set(nil, for: p)
        refresh()
    }

    func cloudConfig(_ p: CloudProvider) -> CloudConfig? {
        guard let key = APIKeychain.key(for: p), !key.isEmpty else { return nil }
        return CloudConfig(provider: p, model: model(for: p), apiKey: key,
                           baseURL: p == .compatible ? baseURL : nil)
    }

    /// Sends a tiny request to check the key and model; nil = OK.
    func check(_ p: CloudProvider) async -> String? {
        guard let cfg = cloudConfig(p) else { return CloudError.noKey.errorDescription }
        do {
            try await CloudSummarizer(config: cfg).check()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The user agreed that transcripts go to this provider.
    func hasConsent(_ p: CloudProvider) -> Bool { UserDefaults.standard.bool(forKey: "summary.consent.\(p.rawValue)") }
    func giveConsent(_ p: CloudProvider) { UserDefaults.standard.set(true, forKey: "summary.consent.\(p.rawValue)") }

    // MARK: Local models

    @discardableResult
    func download() async -> Bool {
        guard case .local(let t) = engine else { return true }
        return await download(t)
    }

    @discardableResult
    func download(_ tier: SummaryModelTier) async -> Bool {
        guard progress == nil else { return false }
        let t = CancelToken()
        token = t
        error = nil
        downloading = tier
        progress = 0
        defer { progress = nil; downloading = nil; token = nil; refresh() }
        do {
            try await SummaryModelStore.store(for: tier).install(progress: { p in
                Task { @MainActor in if SummaryModelController.shared.progress != nil { SummaryModelController.shared.progress = p } }
            }, isCancelled: { t.isCancelled })
            return true
        } catch ModelError.cancelled {
            return false
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func cancel() { token?.cancel() }

    func remove(_ tier: SummaryModelTier) {
        summarizers[tier]?.unload()
        summarizers[tier] = nil
        try? SummaryModelStore.store(for: tier).remove()
        refresh()
    }

    func unloadAll() {
        summarizers.values.forEach { $0.unload() }
        summarizers = [:]
    }

    func summarizer(for tier: SummaryModelTier) -> MeetingSummarizer {
        if let s = summarizers[tier] { return s }
        // Only one local model in memory at a time.
        for (t, s) in summarizers where t != tier { s.unload() }
        summarizers = summarizers.filter { $0.key == tier }
        let s = MeetingSummarizer(store: SummaryModelStore.store(for: tier),
                                  options: LLMOptions(contextTokens: min(tier.spec.contextTokens, LLMOptions.recommendedContextTokens)))
        summarizers[tier] = s
        return s
    }

    /// Summarizes with the chosen engine.
    func summarize(_ tr: Transcript, meetingDate: Date?,
                   progress: @escaping @Sendable (SummaryProgress) -> Void,
                   isCancelled: @escaping @Sendable () -> Bool) async throws -> MeetingSummary {
        switch engine {
        case .local(let tier):
            return try await summarizer(for: tier).summarize(tr, meetingDate: meetingDate, progress: progress, isCancelled: isCancelled)
        case .cloud(let p):
            guard let cfg = cloudConfig(p) else { throw CloudError.noKey }
            return try await CloudSummarizer(config: cfg).summarize(tr, meetingDate: meetingDate, progress: progress, isCancelled: isCancelled)
        }
    }
}
