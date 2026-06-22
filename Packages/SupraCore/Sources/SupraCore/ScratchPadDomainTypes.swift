import Foundation

// Milestone 4 (ScratchPad -> billing) shared domain types. Pure value types with
// stable String raw values so they persist as text columns and round-trip across
// the store, sessions, and runtime boundaries. See Docs/ScratchPad-SPEC.md.

/// What a day-level attachment represents, for evidence weighting.
public enum BillingEvidenceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case email
    case workProduct = "work_product"
    case filing
    case other
}

/// Lifecycle of a generated billing draft.
public enum BillingDraftStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case draft
    case reviewed
    case exported
}

/// Confidence the engine attaches to a suggested line (drives review flags).
public enum BillingConfidence: String, Codable, CaseIterable, Hashable, Sendable {
    case high
    case medium
    case low
}

/// Which code set governs a matter's UTBMS task codes. Litigation matters use the
/// L-phase codes; non-litigation matters use the firm's transactional/advisory set
/// (or a blank task code per the e-bill spec).
public enum BillingCodeSet: String, Codable, CaseIterable, Hashable, Sendable {
    case litigation
    case transactional
    case advisory
    case none
}

extension BillingCodeSet {
    /// Whether a matter on this code set requires an explicit UTBMS task code on
    /// each fee line before LEDES export. `.none` legitimately bills with a blank
    /// task code (spec §8); the other sets must carry the firm's task code.
    public var requiresTaskCode: Bool { self != .none }

    /// A short human label for pickers and prompt rendering.
    public var displayLabel: String {
        switch self {
        case .litigation: "Litigation (UTBMS L-codes)"
        case .transactional: "Transactional"
        case .advisory: "Counseling / Advisory"
        case .none: "No task codes"
        }
    }
}

/// How freely the time engine infers durations. Persisted as a continuous value in
/// [0, 1] (0 = most conservative, 1 = most generous); the buckets are for display
/// and prompt phrasing.
public enum BillingSensitivity: String, Codable, CaseIterable, Hashable, Sendable {
    case conservative
    case balanced
    case generous

    /// The default slider value when no preference is set.
    public static let defaultValue: Double = 0.5

    /// Clamp an arbitrary value into the valid [0, 1] range (NaN -> default).
    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(1, max(0, value))
    }

    /// Bucket a slider value for display / prompt phrasing.
    public init(value: Double) {
        switch BillingSensitivity.clamp(value) {
        case ..<0.34: self = .conservative
        case ..<0.67: self = .balanced
        default: self = .generous
        }
    }
}

/// The firm-wide ScratchPad billing configuration (spec §9): the global instruction
/// text, the time/rounding behaviour, the auto-coding toggle, and the single
/// configured timekeeper + firm identity. Persisted as one JSON blob under the
/// `scratchpad.billing` settings key. Decoding is field-tolerant so a stored blob
/// from an earlier app version still loads (missing fields fall back to defaults).
public struct BillingSettings: Codable, Sendable, Equatable {
    /// Standing instructions layered into every billing-draft prompt.
    public var globalInstructions: String
    /// Whether new ScratchPad entries are silently timestamped as time evidence
    /// (spec §0.2 / locked decision 2). On by default.
    public var autoTimestamp: Bool
    /// Time-inference sensitivity slider, [0, 1] (precise ↔ generous).
    public var sensitivity: Double
    /// Hours rounding increment for billing lines (default 0.1h).
    public var roundingIncrement: Double
    /// Whether the model proposes UTBMS task/activity codes (spec §L.b). When off,
    /// codes are left blank for the attorney to assign.
    public var utbmsAutoCoding: Bool
    /// The single configured timekeeper + firm identity used to populate fee lines.
    public var timekeeper: BillingTimekeeper

    public static let defaultRoundingIncrement: Double = 0.1

    public static let `default` = BillingSettings()

    public init(
        globalInstructions: String = "",
        autoTimestamp: Bool = true,
        sensitivity: Double = BillingSensitivity.defaultValue,
        roundingIncrement: Double = BillingSettings.defaultRoundingIncrement,
        utbmsAutoCoding: Bool = true,
        timekeeper: BillingTimekeeper = BillingTimekeeper(id: "", name: "", classification: "", defaultRate: 0, lawFirmID: "")
    ) {
        self.globalInstructions = globalInstructions
        self.autoTimestamp = autoTimestamp
        self.sensitivity = BillingSensitivity.clamp(sensitivity)
        self.roundingIncrement = roundingIncrement > 0 ? roundingIncrement : BillingSettings.defaultRoundingIncrement
        self.utbmsAutoCoding = utbmsAutoCoding
        self.timekeeper = timekeeper
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BillingSettings.default
        self.init(
            globalInstructions: (try container.decodeIfPresent(String.self, forKey: .globalInstructions)) ?? fallback.globalInstructions,
            autoTimestamp: (try container.decodeIfPresent(Bool.self, forKey: .autoTimestamp)) ?? fallback.autoTimestamp,
            sensitivity: (try container.decodeIfPresent(Double.self, forKey: .sensitivity)) ?? fallback.sensitivity,
            roundingIncrement: (try container.decodeIfPresent(Double.self, forKey: .roundingIncrement)) ?? fallback.roundingIncrement,
            utbmsAutoCoding: (try container.decodeIfPresent(Bool.self, forKey: .utbmsAutoCoding)) ?? fallback.utbmsAutoCoding,
            timekeeper: (try container.decodeIfPresent(BillingTimekeeper.self, forKey: .timekeeper)) ?? fallback.timekeeper
        )
    }

    private enum CodingKeys: String, CodingKey {
        case globalInstructions, autoTimestamp, sensitivity, roundingIncrement, utbmsAutoCoding, timekeeper
    }
}
