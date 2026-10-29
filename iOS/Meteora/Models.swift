import Foundation
import SwiftUI
import Security
import MeteoraCore
import MeteoraASR
import MeteoraLLM

/// Downloadable on-device models: speech (GigaAM-v3), voices (speakers) and
/// the summary model. One shared download at a time per kind.
@MainActor
final class Models: ObservableObject {
    static let shared = Models()

    @Published private(set) var speechInstalled = ModelStore.shared.isInstalled
    @Published private(set) var speakersInstalled = SpeakerModel.defaultTier.isInstalled
    @Published private(set) var summaryInstalled: Set<SummaryModelTier> = []

    /// What is downloading and how far.
    @Published private(set) var downloading: Kind?
    @Published private(set) var progress: Double = 0
    @Published var error: String?
    private var token: CancelToken?

    enum Kind: Equatable {
        case speech, speakers, summary(SummaryModelTier)
        var title: String {
            switch self {
            case .speech: return "модель речи"
            case .speakers: return "модель голосов"
            case .summary(let t): return "модель итогов «\(t.title)»"
            }
        }
    }

    /// Tiers offered on iPhone: the 3 GB one doesn't fit next to the app.
    static let summaryTiers: [SummaryModelTier] = [.light, .medium]

    @Published var summaryTier: SummaryModelTier {
        didSet { UserDefaults.standard.set(summaryTier.rawValue, forKey: "summary.tier") }
    }

    private init() {
        summaryTier = UserDefaults.standard.string(forKey: "summary.tier").flatMap(SummaryModelTier.init(rawValue:)) ?? .light
        refresh()
    }

    func refresh() {
        speechInstalled = ModelStore.shared.isInstalled
        speakersInstalled = SpeakerModel.defaultTier.isInstalled
        summaryInstalled = Set(Self.summaryTiers.filter { SummaryModelStore.store(for: $0).isInstalled })
    }

    var speechSize: String { Format.size(SpeechModel.totalSize) }
    var speakersSize: String { Format.size(SpeakerModel.defaultTier.totalSize) }
    func summarySize(_ t: SummaryModelTier) -> String { Format.size(t.spec.fileSize) }

    static var vadURL: URL? { Bundle.main.url(forResource: "silero_vad", withExtension: "onnx") }

    @discardableResult
    func download(_ kind: Kind) async -> Bool {
        guard downloading == nil else { return false }
        let t = CancelToken()
        token = t
        error = nil
        progress = 0
        downloading = kind
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            downloading = nil
            token = nil
            UIApplication.shared.isIdleTimerDisabled = false
            refresh()
        }
        let report: @Sendable (Double) -> Void = { p in Task { @MainActor in Models.shared.progress = p } }
        do {
            switch kind {
            case .speech:
                try await ModelStore.shared.install(progress: report, isCancelled: { t.isCancelled })
                try? await ModelStore.shared.installExtras(isCancelled: { t.isCancelled })
            case .speakers:
                try await SpeakerModel.defaultTier.install(progress: report, isCancelled: { t.isCancelled })
            case .summary(let tier):
                try await SummaryModelStore.store(for: tier).install(progress: report, isCancelled: { t.isCancelled })
            }
            return true
        } catch {
            if !t.isCancelled { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            return false
        }
    }

    func cancel() { token?.cancel() }

    func remove(_ kind: Kind) {
        switch kind {
        case .speech: try? ModelStore.shared.remove()
        case .speakers: try? SpeakerModel.defaultTier.remove()
        case .summary(let t): try? SummaryModelStore.store(for: t).remove()
        }
        refresh()
    }
}

// MARK: - Summary engine

/// Which engine writes summaries: a local model or a cloud provider by key.
@MainActor
final class SummarySettings: ObservableObject {
    static let shared = SummarySettings()

    enum Engine: Equatable {
        case local
        case cloud(CloudProvider)
    }

    @Published var engine: Engine {
        didSet {
            switch engine {
            case .local: UserDefaults.standard.set("local", forKey: "summary.engine")
            case .cloud(let p): UserDefaults.standard.set(p.rawValue, forKey: "summary.engine")
            }
        }
    }
    @Published var protectPersonalData: Bool {
        didSet { UserDefaults.standard.set(protectPersonalData, forKey: "summary.guardrails") }
    }
    /// The user agreed that transcripts may go to this provider.
    @Published private(set) var consented: Set<CloudProvider> = []

    private init() {
        let raw = UserDefaults.standard.string(forKey: "summary.engine") ?? "local"
        engine = CloudProvider(rawValue: raw).map { .cloud($0) } ?? .local
        protectPersonalData = UserDefaults.standard.object(forKey: "summary.guardrails") as? Bool ?? true
        consented = Set((UserDefaults.standard.stringArray(forKey: "summary.consent") ?? []).compactMap(CloudProvider.init(rawValue:)))
    }

    func consent(_ p: CloudProvider) {
        consented.insert(p)
        UserDefaults.standard.set(consented.map(\.rawValue), forKey: "summary.consent")
    }

    func model(for p: CloudProvider) -> String {
        UserDefaults.standard.string(forKey: "summary.model.\(p.rawValue)") ?? p.defaultModel
    }

    func setModel(_ m: String, for p: CloudProvider) {
        UserDefaults.standard.set(m, forKey: "summary.model.\(p.rawValue)")
        objectWillChange.send()
    }

    func baseURL(for p: CloudProvider) -> String {
        UserDefaults.standard.string(forKey: "summary.base.\(p.rawValue)") ?? p.defaultBaseURL
    }

    func setBaseURL(_ s: String, for p: CloudProvider) {
        UserDefaults.standard.set(s, forKey: "summary.base.\(p.rawValue)")
        objectWillChange.send()
    }

    func config(for p: CloudProvider) -> CloudConfig? {
        guard let key = APIKeychain.key(for: p), !key.isEmpty else { return nil }
        return CloudConfig(provider: p, model: model(for: p), apiKey: key, baseURL: baseURL(for: p),
                           protectPersonalData: protectPersonalData)
    }
}

/// API keys stay in the iPhone's Keychain, this device only.
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
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
