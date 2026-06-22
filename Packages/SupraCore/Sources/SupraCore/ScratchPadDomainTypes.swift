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
