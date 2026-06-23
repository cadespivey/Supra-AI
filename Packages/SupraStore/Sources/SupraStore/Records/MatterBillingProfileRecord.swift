import Foundation
import GRDB
import SupraCore

/// Per-matter billing overrides (Milestone 4): free-text instructions layered on
/// top of the global billing instructions, plus which code set governs the matter's
/// UTBMS task codes. Uploaded client billing-guideline documents are stored as
/// `MatterDocumentRecord`s tagged "billing guideline" and linked via the document
/// tag system, so they are not duplicated here.
public struct MatterBillingProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "matter_billing_profiles"

    public var id: String
    public var matterID: String
    public var overrideInstructions: String?
    public var billingCodeSet: String
    /// The matter's narrative terminal-punctuation override (`BillingNarrativeTerminal`
    /// raw value), or nil to inherit the firm-wide setting.
    public var narrativeTerminal: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        overrideInstructions: String? = nil,
        billingCodeSet: BillingCodeSet = .none,
        narrativeTerminal: BillingNarrativeTerminal? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.matterID = matterID
        self.overrideInstructions = overrideInstructions
        self.billingCodeSet = billingCodeSet.rawValue
        self.narrativeTerminal = narrativeTerminal?.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The decoded terminal override, or nil to inherit the firm-wide setting.
    public var narrativeTerminalValue: BillingNarrativeTerminal? {
        narrativeTerminal.flatMap(BillingNarrativeTerminal.init(rawValue:))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case overrideInstructions = "override_instructions"
        case billingCodeSet = "billing_code_set"
        case narrativeTerminal = "narrative_terminal"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
