import Combine
import Foundation
import SupraCore
import SupraStore

/// Firm-wide ScratchPad billing settings (Milestone 4 Phase 7, spec §9): the global
/// billing instructions, time/rounding behaviour, the auto-coding toggle, and the
/// single configured timekeeper + firm identity. Backed by the store: every edit
/// persists immediately (didSet → persist), under one `scratchpad.billing` blob, so
/// the billing engine and the next launch read the same configuration.
@MainActor
public final class BillingSettingsController: ObservableObject {
    public static let storageKey = "scratchpad.billing"

    @Published public var globalInstructions: String { didSet { persist() } }
    @Published public var narrativeTerminal: BillingNarrativeTerminal { didSet { persist() } }
    @Published public var autoTimestamp: Bool { didSet { persist() } }
    @Published public var sensitivity: Double { didSet { persist() } }
    @Published public var roundingIncrement: Double { didSet { persist() } }
    @Published public var utbmsAutoCoding: Bool { didSet { persist() } }
    @Published public var timekeeperID: String { didSet { persist() } }
    @Published public var timekeeperName: String { didSet { persist() } }
    @Published public var timekeeperClassification: String { didSet { persist() } }
    @Published public var timekeeperRate: Double { didSet { persist() } }
    @Published public var lawFirmID: String { didSet { persist() } }

    private let store: SupraStore
    /// Suppresses persistence while the initializer seeds the published values.
    private var isLoading = true

    public init(store: SupraStore) {
        self.store = store
        let stored = (try? store.appSettings.getSetting(Self.storageKey, as: BillingSettings.self)) ?? .default
        self.globalInstructions = stored.globalInstructions
        self.narrativeTerminal = stored.narrativeTerminal
        self.autoTimestamp = stored.autoTimestamp
        self.sensitivity = stored.sensitivity
        self.roundingIncrement = stored.roundingIncrement
        self.utbmsAutoCoding = stored.utbmsAutoCoding
        self.timekeeperID = stored.timekeeper.id
        self.timekeeperName = stored.timekeeper.name
        self.timekeeperClassification = stored.timekeeper.classification
        self.timekeeperRate = stored.timekeeper.defaultRate
        self.lawFirmID = stored.timekeeper.lawFirmID
        self.isLoading = false
    }

    /// The current configuration as the value type the engine consumes.
    public var settings: BillingSettings {
        BillingSettings(
            globalInstructions: globalInstructions,
            autoTimestamp: autoTimestamp,
            sensitivity: sensitivity,
            roundingIncrement: roundingIncrement,
            utbmsAutoCoding: utbmsAutoCoding,
            timekeeper: timekeeper,
            narrativeTerminal: narrativeTerminal
        )
    }

    public var timekeeper: BillingTimekeeper {
        BillingTimekeeper(
            id: timekeeperID.trimmingCharacters(in: .whitespacesAndNewlines),
            name: timekeeperName.trimmingCharacters(in: .whitespacesAndNewlines),
            classification: timekeeperClassification.trimmingCharacters(in: .whitespacesAndNewlines),
            defaultRate: max(0, timekeeperRate),
            lawFirmID: lawFirmID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func persist() {
        guard !isLoading else { return }
        try? store.appSettings.setSetting(Self.storageKey, value: settings)
    }
}
