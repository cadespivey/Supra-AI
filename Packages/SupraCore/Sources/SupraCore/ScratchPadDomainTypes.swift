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

/// How a billing narrative's terminal punctuation is normalized at export time.
/// Many timekeeping styles want narratives with no trailing period (so they paste
/// cleanly into time-entry software); some clients want a trailing semicolon.
public enum BillingNarrativeTerminal: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    /// Leave the narrative exactly as the model wrote it (default — backward-compatible).
    case asWritten
    /// Strip any trailing period or semicolon — punctuation-free narratives.
    case noPeriod
    /// End every narrative with a semicolon (e.g. a client's house rule).
    case semicolon

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .asWritten: "As written"
        case .noPeriod: "No terminal period"
        case .semicolon: "End with semicolon"
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
    /// Firm-wide narrative terminal-punctuation style, applied at export unless a
    /// matter overrides it. Defaults to `.asWritten` so existing drafts are unchanged.
    public var narrativeTerminal: BillingNarrativeTerminal

    public static let defaultRoundingIncrement: Double = 0.1

    /// The starter global billing instructions a fresh install begins with: general
    /// timekeeping hygiene (specific narrative voice, no vague phrases, task-type
    /// splitting, conservative inference, exclusions) plus the scratch-pad shorthand
    /// the billing engine should understand. Attorneys edit this in Settings.
    public static let defaultGlobalInstructions = """
    NARRATIVE VOICE — write each narrative in one of these constructions, choosing what fits the work, and ground every term in the notes/evidence (never invent theories, posture, strategy, participants, or topics):
    - Communicate/confer with [client | litigation team | opposing counsel | local counsel | partner] re: [specific issue]
    - Receive/review/analyze [filing | order | discovery | transcript | document] re: [specific issue or consequence]
    - Draft [document] addressing [specific issue]
    - Revise [document] regarding [specific issue]
    - Research [jurisdiction / body of law] regarding [specific legal issue]
    - Review/analyze [document set] for [specific purpose]
    - Prepare for [hearing | trial | deposition | mediation | meeting] re: [specific issue]
    Never use vague phrases: "attention to matter," "work on matter," "case review," "review file," "correspondence," "conference," "preparation," bare "legal research," or bare "analyze." Use "research" only with a named body of law and a specific issue.

    ENTRY SPLITTING — separate entries by task type: research, drafting, revision, filing/order review, document review, client comms, opposing-counsel comms, internal conferences, hearings, mediations, depositions, trial prep. Consolidate same-day emails only when the matter, participant group, and subject all match; never merge email with drafting/research/review/conferences.

    TIME — minimum billable entry 0.2; round to the configured increment; preserve recorded time already a valid increment ≥ 0.2; raise anything below 0.2 to 0.2.

    SPLIT MATTERS — "[A x N]" means N separate allocations of A hours each across related matters; do not collapse into one row. A single total that must be split → divide across the implicated matters (equal unless evidence shows otherwise), one row per matter, and append "(split)" to the narrative.

    NOTE SHORTHAND — "[1.8] <task>" = 1.8 recorded hours; "0.4 <task>" = 0.4 recorded hours; "[A x N] <task>" = N split allocations of A; "#IDENTIFIER" = a matter identifier to map to the matter on file.

    EXCLUDE unless tied to dated attorney work: open to-dos, passive file presence, automatic downloads, routine docket notices, and purely administrative saving/filing/renaming/calendaring.
    """

    public static let `default` = BillingSettings()

    public init(
        globalInstructions: String = BillingSettings.defaultGlobalInstructions,
        autoTimestamp: Bool = true,
        sensitivity: Double = BillingSensitivity.defaultValue,
        roundingIncrement: Double = BillingSettings.defaultRoundingIncrement,
        utbmsAutoCoding: Bool = true,
        timekeeper: BillingTimekeeper = BillingTimekeeper(id: "", name: "", classification: "", defaultRate: 0, lawFirmID: ""),
        narrativeTerminal: BillingNarrativeTerminal = .asWritten
    ) {
        self.globalInstructions = globalInstructions
        self.autoTimestamp = autoTimestamp
        self.sensitivity = BillingSensitivity.clamp(sensitivity)
        self.roundingIncrement = roundingIncrement > 0 ? roundingIncrement : BillingSettings.defaultRoundingIncrement
        self.utbmsAutoCoding = utbmsAutoCoding
        self.timekeeper = timekeeper
        self.narrativeTerminal = narrativeTerminal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BillingSettings.default
        self.init(
            // A stored blob from before this field existed keeps its own (possibly
            // empty) instructions; only a truly fresh install gets the default.
            globalInstructions: (try container.decodeIfPresent(String.self, forKey: .globalInstructions)) ?? fallback.globalInstructions,
            autoTimestamp: (try container.decodeIfPresent(Bool.self, forKey: .autoTimestamp)) ?? fallback.autoTimestamp,
            sensitivity: (try container.decodeIfPresent(Double.self, forKey: .sensitivity)) ?? fallback.sensitivity,
            roundingIncrement: (try container.decodeIfPresent(Double.self, forKey: .roundingIncrement)) ?? fallback.roundingIncrement,
            utbmsAutoCoding: (try container.decodeIfPresent(Bool.self, forKey: .utbmsAutoCoding)) ?? fallback.utbmsAutoCoding,
            timekeeper: (try container.decodeIfPresent(BillingTimekeeper.self, forKey: .timekeeper)) ?? fallback.timekeeper,
            narrativeTerminal: (try container.decodeIfPresent(BillingNarrativeTerminal.self, forKey: .narrativeTerminal)) ?? .asWritten
        )
    }

    private enum CodingKeys: String, CodingKey {
        case globalInstructions, autoTimestamp, sensitivity, roundingIncrement, utbmsAutoCoding, timekeeper, narrativeTerminal
    }
}
