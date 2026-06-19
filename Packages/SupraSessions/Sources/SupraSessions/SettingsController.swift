import Combine
import Foundation
import SupraCore
import SupraNetworking
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
    private let tokenStore: any APIKeyStoreProtocol

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
    }

    /// Stores a CourtListener API token in the Keychain (spec §2.4). Empty
    /// input is rejected.
    public func saveCourtListenerToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? tokenStore.saveCourtListenerToken(trimmed)
        refreshCourtListenerTokenState()
    }

    public func clearCourtListenerToken() {
        try? tokenStore.deleteCourtListenerToken()
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
