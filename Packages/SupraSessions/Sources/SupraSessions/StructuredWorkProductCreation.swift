import Foundation
import SupraCore
import SupraStore

public struct StructuredWorkProductCreationRequest: Equatable, Sendable {
    public let idempotencyKey: String
    public let type: StructuredOutputType
    public let instructionsAndFacts: String
    public let publicationMode: StructuredWorkProductPublicationMode
    public let acceptedResearchPacket: AcceptedResearchPacketReference?

    public init(
        idempotencyKey: String,
        type: StructuredOutputType,
        instructionsAndFacts: String,
        publicationMode: StructuredWorkProductPublicationMode,
        acceptedResearchPacket: AcceptedResearchPacketReference?
    ) {
        self.idempotencyKey = idempotencyKey
        self.type = type
        self.instructionsAndFacts = instructionsAndFacts
        self.publicationMode = publicationMode
        self.acceptedResearchPacket = acceptedResearchPacket
    }
}

public enum StructuredWorkProductBlockerReason: String, Equatable, Sendable {
    case reviewedAuthorityPacketUnavailable = "reviewed_authority_packet_unavailable"
}

public struct StructuredWorkProductBlocker: Equatable, Sendable {
    public let reason: StructuredWorkProductBlockerReason
    public let userMessage: String
    public let recoverySurfaces: Set<WorkSurface>
}

public enum StructuredWorkProductEligibilityReason: String, Equatable, Sendable {
    case provisionalIssueOutline = "provisional_issue_outline"
    case reviewRequired = "review_required"
    case eligible
}

public struct StructuredWorkProductEligibility: Equatable, Sendable {
    public let canExport: Bool
    public let canPromote: Bool
    public let reason: StructuredWorkProductEligibilityReason
}

public struct StructuredWorkProductCreationResult: Equatable, Sendable {
    public let receipt: StructuredWorkProductPublicationReceipt?
    public let blocker: StructuredWorkProductBlocker?
    public let failure: UserMutationFailure?
    public let retainedRequest: StructuredWorkProductCreationRequest?
    public let eligibility: StructuredWorkProductEligibility?

    public var didPublish: Bool { receipt != nil }
}
