import Combine
import Foundation
import SupraCore
import SupraNetworking
import SupraResearch
import SupraStore

/// App settings backed by the store. Persists generation defaults (used by the
/// chat flow) and exposes storage/version info for the Settings screen.
@MainActor
public final class SettingsController: ObservableObject {
    static let generationDefaultsKey = "generation.default"

    public enum CourtListenerTokenSource: String, Sendable {
        case none
        case keychain
        case environment
    }

    /// True when a CourtListener API token is stored in the Keychain. Published
    /// so the Settings UI reflects save/clear without re-reading the Keychain.
    @Published public private(set) var hasCourtListenerToken = false
    @Published public private(set) var courtListenerTokenSource: CourtListenerTokenSource = .none
    /// Services with a saved (or environment-provided) API key, and the subset coming from the
    /// environment (which the UI shows as read-only). Published so Settings reflects save/clear.
    @Published public private(set) var configuredAPIKeys: Set<APIKeyService> = []
    @Published public private(set) var environmentAPIKeys: Set<APIKeyService> = []
    /// Live verification state per service (and for the CourtListener token), driven by the
    /// "Verify" buttons so the user knows a saved key actually works.
    @Published public private(set) var keyVerification: [APIKeyService: KeyVerificationState] = [:]
    @Published public private(set) var courtListenerVerification: KeyVerificationState = .idle
    /// Verification state for the free, key-less sources (eCFR, Federal Register, Open
    /// Legal Codes), keyed by source id — a reachability check, not a key check.
    @Published public private(set) var keylessVerification: [String: KeyVerificationState] = [:]
    private let tokenStore: any APIKeyStoreProtocol

    public enum KeyVerificationState: Sendable, Equatable {
        case idle
        case verifying
        case valid
        case invalid(String)
        case unreachable(String)
    }

    /// Choosing a preset snaps temperature/topP to that preset's character so
    /// the picker actually changes generation (the runtime reads temperature/
    /// topP, not the preset label). Manual temperature tweaks afterwards are
    /// preserved; the preset only re-applies when it is explicitly changed.
    @Published public var preset: GenerationPreset {
        didSet {
            guard preset != oldValue else { return }
            let defaults = preset.defaultOptions
            topP = defaults.topP
            topK = defaults.topK
            maxContextTokens = defaults.maxContextTokens
            thinkingBudget = defaults.thinkingBudget
            maxOutputTokens = defaults.maxOutputTokens
            temperature = defaults.temperature // persists via temperature's didSet
        }
    }
    @Published public var temperature: Double { didSet { persist() } }
    @Published public var maxOutputTokens: Int { didSet { persist() } }

    public let modelsDirectoryPath: String
    public let appVersion: AppVersion

    private let store: SupraStore
    private var topP: Double
    private var topK: Int?
    private var maxContextTokens: Int
    private var thinkingBudget: ThinkingBudget

    public init(
        store: SupraStore,
        appVersion: AppVersion = .unknown,
        tokenStore: (any APIKeyStoreProtocol)? = nil
    ) {
        self.store = store
        self.appVersion = appVersion
        self.modelsDirectoryPath = ManagedModelStorage.modelsDirectory().path
        self.tokenStore = tokenStore ?? EnvironmentBackedTokenStore(primary: KeychainTokenStore())

        let stored = (try? store.appSettings.getSetting(Self.generationDefaultsKey, as: GenerationOptions.self))
            ?? GenerationOptions()
        self.preset = stored.preset
        self.temperature = stored.temperature
        self.maxOutputTokens = stored.maxOutputTokens
        self.topP = stored.topP
        self.topK = stored.topK
        self.maxContextTokens = stored.maxContextTokens
        self.thinkingBudget = stored.thinkingBudget
        refreshCourtListenerTokenState()
        refreshAPIKeyState()
    }

    /// Saves an API key for `service` in the Keychain. Empty input is rejected.
    public func saveAPIKey(_ key: String, for service: APIKeyService) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? tokenStore.saveAPIKey(trimmed, for: service)
        keyVerification[service] = .idle   // a new key must be re-verified
        refreshAPIKeyState()
    }

    public func clearAPIKey(for service: APIKeyService) {
        try? tokenStore.deleteAPIKey(for: service)
        keyVerification[service] = .idle
        refreshAPIKeyState()
    }

    public func hasAPIKey(_ service: APIKeyService) -> Bool { configuredAPIKeys.contains(service) }
    public func isEnvironmentAPIKey(_ service: APIKeyService) -> Bool { environmentAPIKeys.contains(service) }
    public func verificationState(_ service: APIKeyService) -> KeyVerificationState { keyVerification[service] ?? .idle }

    /// Runs a live round-trip to confirm the saved key for `service` is accepted by the API.
    public func verifyAPIKey(_ service: APIKeyService) async {
        keyVerification[service] = .verifying
        keyVerification[service] = Self.verificationState(from: await makeVerifier().verify(service))
    }

    /// Runs a live round-trip to confirm the saved CourtListener token is accepted.
    public func verifyCourtListenerToken() async {
        courtListenerVerification = .verifying
        courtListenerVerification = Self.verificationState(from: await makeVerifier().verifyCourtListener())
    }

    public func keylessVerificationState(_ sourceID: String) -> KeyVerificationState {
        keylessVerification[sourceID] ?? .idle
    }

    /// Confirms a free, key-less source (eCFR / Federal Register / Open Legal Codes) is
    /// reachable — the "Verify" affordance for sources that have no key.
    public func verifyKeylessSource(_ sourceID: String) async {
        guard let source = LegalDataKeyVerifier.KeylessLegalSource(rawValue: sourceID) else { return }
        keylessVerification[sourceID] = .verifying
        keylessVerification[sourceID] = Self.verificationState(from: await makeVerifier().verifyReachable(source))
    }

    private func makeVerifier() -> LegalDataKeyVerifier {
        let http = AuthorizedHTTPClient(
            keyStore: tokenStore,
            policy: NetworkPolicyService(),
            logger: NetworkRequestLogger(repository: store.networkRequests)
        )
        return LegalDataKeyVerifier(httpClient: http, tokenStore: tokenStore)
    }

    private static func verificationState(from result: KeyVerificationResult) -> KeyVerificationState {
        switch result {
        case .valid: return .valid
        case let .invalid(message): return .invalid(message)
        case let .unreachable(message): return .unreachable(message)
        case .missingKey: return .idle
        }
    }

    /// Stores a CourtListener API token in the Keychain (spec §2.4). Empty
    /// input is rejected.
    public func saveCourtListenerToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? tokenStore.saveCourtListenerToken(trimmed)
        courtListenerVerification = .idle
        refreshCourtListenerTokenState()
    }

    public func clearCourtListenerToken() {
        try? tokenStore.deleteCourtListenerToken()
        courtListenerVerification = .idle
        refreshCourtListenerTokenState()
    }

    public var currentOptions: GenerationOptions {
        GenerationOptions(
            preset: preset,
            temperature: temperature,
            topP: topP,
            topK: topK,
            maxContextTokens: maxContextTokens,
            maxOutputTokens: maxOutputTokens,
            thinkingBudget: thinkingBudget
        )
    }

    private func persist() {
        try? store.appSettings.setSetting(Self.generationDefaultsKey, value: currentOptions)
    }

    private func refreshAPIKeyState() {
        var configured: Set<APIKeyService> = []
        var fromEnvironment: Set<APIKeyService> = []
        let environmentStore = tokenStore as? EnvironmentBackedTokenStore
        for service in APIKeyService.allCases {
            if (try? tokenStore.hasAPIKey(for: service)) == true { configured.insert(service) }
            if environmentStore?.hasEnvironmentAPIKey(for: service) == true { fromEnvironment.insert(service) }
        }
        configuredAPIKeys = configured
        environmentAPIKeys = fromEnvironment
    }

    private func refreshCourtListenerTokenState() {
        hasCourtListenerToken = (try? tokenStore.hasCourtListenerToken()) ?? false
        if let environmentStore = tokenStore as? EnvironmentBackedTokenStore,
           environmentStore.hasEnvironmentCourtListenerToken {
            courtListenerTokenSource = .environment
        } else if hasCourtListenerToken {
            courtListenerTokenSource = .keychain
        } else {
            courtListenerTokenSource = .none
        }
    }
}
