import Foundation
import SupraDraftingCore

// Concrete adapters + the default slot resolver (NoticeAppearance §1 / §6).
// `FirmProfile` is the drafting-time projection of an AssistantProfile (it adds the bar / e-mail /
// office fields the base profile lacks). The resolver fills SlotValues from matter metadata,
// the firm profile, and the party model — no user questions for a slot-fill kind.

public struct FirmProfile: DraftingProfile, Sendable {
    public var firmName: String
    public var signingAttorney: String
    public var barNumber: String
    public var office: OfficeBlock
    public var primaryEmail: String
    public var secondaryEmails: [String]
    public var tagline: String

    public init(firmName: String, signingAttorney: String, barNumber: String, office: OfficeBlock,
                primaryEmail: String, secondaryEmails: [String] = [], tagline: String = "Attorneys at Law") {
        self.firmName = firmName
        self.signingAttorney = signingAttorney
        self.barNumber = barNumber
        self.office = office
        self.primaryEmail = primaryEmail
        self.secondaryEmails = secondaryEmails
        self.tagline = tagline
    }

    public var identity: [String: String] {
        [
            "firm": firmName,
            "signingAttorney": signingAttorney,
            "barNumber": barNumber,
            "primaryEmail": primaryEmail,
            "tagline": tagline
        ]
    }
}

/// A simple in-memory matter context for the slice (the real one wraps the matter store +
/// DocumentRetrievalService). Facts carry [S#] labels for the provenance gate.
public struct StaticMatterContext: MatterContext, Sendable {
    public var metadata: [String: String]
    public var facts: [GroundedFact]

    public init(metadata: [String: String], facts: [GroundedFact] = []) {
        self.metadata = metadata
        self.facts = facts
    }

    public func retrieve(_ query: String, limit: Int) async -> [GroundedFact] {
        Array(facts.prefix(limit))
    }
}

/// Validation for the serializable validator keys (NoticeAppearance §3.1).
public enum SlotValidators {
    public static func validate(_ key: SlotValidatorKey, value: String) -> ValidationOutcome {
        switch key {
        case .none:
            return .ok
        case .caseNumberFormat:
            // e.g. "2026-CA-001847" — year-letters-number, lenient.
            let pattern = #"^\d{4}-[A-Z]{1,3}-\d{4,8}$"#
            return value.range(of: pattern, options: .regularExpression) != nil
                ? .ok : .invalid("Case number '\(value)' is not in the expected NNNN-XX-NNNNNN format.")
        case .emailFormat:
            let pattern = #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#
            return value.range(of: pattern, options: .regularExpression) != nil
                ? .ok : .invalid("'\(value)' is not a valid e-mail address.")
        }
    }
}

public enum ValidationOutcome: Sendable, Equatable {
    case ok
    case invalid(String)
}
