import Foundation

/// Stable identifier for a jurisdiction in the canonical court catalog.
public struct CanonicalJurisdictionID: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Stable identifier for a court in the canonical court catalog.
public struct CanonicalCourtID: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Persisted resolution state for a matter's court identity.
public enum MatterCourtResolutionState: String, Codable, CaseIterable, Hashable, Sendable {
    case unresolved
    case jurisdictionOnly = "jurisdiction_only"
    case court
    case notApplicable = "not_applicable"
}

/// A party's role in the case, independent of whether the party is represented
/// by the app user's firm.
public enum MatterPartyBaseRole: String, Codable, CaseIterable, Hashable, Sendable {
    case plaintiff
    case defendant
    case petitioner
    case respondent
    case appellant
    case appellee
    case movant
    case thirdParty = "third_party"
    case nonparty
    case other
}

/// Whether a matter party is represented by the app user's firm.
public enum MatterPartyClientStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case represented
    case notRepresented = "not_represented"
    case unresolved
}

/// Canonical, structured identity for one matter party.
public struct MatterPartyIdentity: Codable, Hashable, Sendable {
    public let id: String
    public let matterID: String
    public let displayName: String
    public let captionName: String
    public let baseRole: MatterPartyBaseRole
    public let captionOrder: Int
    public let clientStatus: MatterPartyClientStatus

    public init(
        id: String,
        matterID: String,
        displayName: String,
        captionName: String,
        baseRole: MatterPartyBaseRole,
        captionOrder: Int,
        clientStatus: MatterPartyClientStatus
    ) {
        self.id = id
        self.matterID = matterID
        self.displayName = displayName
        self.captionName = captionName
        self.baseRole = baseRole
        self.captionOrder = captionOrder
        self.clientStatus = clientStatus
    }
}

/// How a representative is related to the party it represents.
public enum MatterRepresentationRelationshipKind: String, Codable, CaseIterable, Hashable,
    Sendable
{
    case counsel
    case selfRepresented = "self_represented"
    case guardian
    case other
}

/// Structured service address for a matter representation.
public struct MatterServiceAddress: Codable, Hashable, Sendable {
    public let street: String
    public let city: String
    public let state: String
    public let postalCode: String

    public init(
        street: String,
        city: String,
        state: String,
        postalCode: String
    ) {
        self.street = street
        self.city = city
        self.state = state
        self.postalCode = postalCode
    }
}

/// Canonical representation and service identity associated with a matter
/// party. Optional fields mirror the persisted schema instead of inventing
/// fallback firm, address, or ordering values.
public struct MatterRepresentationIdentity: Codable, Hashable, Sendable {
    public let id: String
    public let matterID: String
    public let representedPartyID: String
    public let relationshipKind: MatterRepresentationRelationshipKind
    public let representativeName: String
    public let firmName: String?
    public let serviceAddress: MatterServiceAddress?
    public let serviceEmails: [String]
    public let serviceOrder: Int?

    public init(
        id: String,
        matterID: String,
        representedPartyID: String,
        relationshipKind: MatterRepresentationRelationshipKind,
        representativeName: String,
        firmName: String?,
        serviceAddress: MatterServiceAddress?,
        serviceEmails: [String],
        serviceOrder: Int?
    ) {
        self.id = id
        self.matterID = matterID
        self.representedPartyID = representedPartyID
        self.relationshipKind = relationshipKind
        self.representativeName = representativeName
        self.firmName = firmName
        self.serviceAddress = serviceAddress
        self.serviceEmails = serviceEmails
        self.serviceOrder = serviceOrder
    }
}

/// Content-free binding that must be confirmed before a caller may override
/// the represented party selected by canonical matter identity.
public struct PartyConflictConfirmationRequest: Codable, Hashable, Sendable {
    public let matterID: String
    public let identityRevision: Int
    public let canonicalRepresentedPartyID: String
    public let requestedRepresentedPartyID: String
    public let purpose: String
    public let requestDigestSHA256: String

    public init(
        matterID: String,
        identityRevision: Int,
        canonicalRepresentedPartyID: String,
        requestedRepresentedPartyID: String,
        purpose: String,
        requestDigestSHA256: String
    ) {
        self.matterID = matterID
        self.identityRevision = identityRevision
        self.canonicalRepresentedPartyID = canonicalRepresentedPartyID
        self.requestedRepresentedPartyID = requestedRepresentedPartyID
        self.purpose = purpose
        self.requestDigestSHA256 = requestDigestSHA256
    }
}

/// Durable evidence that a specific party-selection conflict was confirmed.
/// The receipt contains only identifiers and binding metadata, never party or
/// matter content.
public struct PartyConflictConfirmationReceipt: Codable, Hashable, Sendable {
    public let id: String
    public let matterID: String
    public let identityRevision: Int
    public let canonicalRepresentedPartyID: String
    public let requestedRepresentedPartyID: String
    public let purpose: String
    public let requestDigestSHA256: String
    public let actor: String
    public let confirmedAt: Date

    public init(
        id: String,
        matterID: String,
        identityRevision: Int,
        canonicalRepresentedPartyID: String,
        requestedRepresentedPartyID: String,
        purpose: String,
        requestDigestSHA256: String,
        actor: String,
        confirmedAt: Date
    ) {
        self.id = id
        self.matterID = matterID
        self.identityRevision = identityRevision
        self.canonicalRepresentedPartyID = canonicalRepresentedPartyID
        self.requestedRepresentedPartyID = requestedRepresentedPartyID
        self.purpose = purpose
        self.requestDigestSHA256 = requestDigestSHA256
        self.actor = actor
        self.confirmedAt = confirmedAt
    }
}
