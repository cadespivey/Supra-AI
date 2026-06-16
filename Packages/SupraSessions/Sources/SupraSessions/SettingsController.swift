import Combine
import Foundation
import SupraCore
import SupraStore

/// App settings backed by the store. Persists generation defaults (used by the
/// chat flow) and exposes storage/version info for the Settings screen.
@MainActor
public final class SettingsController: ObservableObject {
    static let generationDefaultsKey = "generation.default"

    @Published public var preset: GenerationPreset { didSet { persist() } }
    @Published public var temperature: Double { didSet { persist() } }
    @Published public var maxOutputTokens: Int { didSet { persist() } }

    public let modelsDirectoryPath: String
    public let appVersion: AppVersion

    private let store: SupraStore
    private var topP: Double
    private var contextLength: Int?

    public init(store: SupraStore, appVersion: AppVersion = .unknown) {
        self.store = store
        self.appVersion = appVersion
        self.modelsDirectoryPath = ManagedModelStorage.modelsDirectory().path

        let stored = (try? store.appSettings.getSetting(Self.generationDefaultsKey, as: GenerationOptions.self))
            ?? GenerationOptions()
        self.preset = stored.preset
        self.temperature = stored.temperature
        self.maxOutputTokens = stored.maxOutputTokens
        self.topP = stored.topP
        self.contextLength = stored.contextLength
    }

    public var currentOptions: GenerationOptions {
        GenerationOptions(
            preset: preset,
            temperature: temperature,
            topP: topP,
            maxOutputTokens: maxOutputTokens,
            contextLength: contextLength
        )
    }

    private func persist() {
        try? store.appSettings.setSetting(Self.generationDefaultsKey, value: currentOptions)
    }
}
