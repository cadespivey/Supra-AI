import Foundation
import GRDB
import SupraCore

public enum StructuredWorkProductPublicationMode: String, Codable, Equatable, Sendable {
    case ordinary
    case governedAuthority = "governed_authority"
    case provisionalIssueOutline = "provisional_issue_outline"
}

public struct AcceptedResearchPacketReference: Codable, Equatable, Sendable {
    public let versionID: String
    public let versionIndex: Int
    public let expectedAggregateDigestSHA256: String

    public init(
        versionID: String,
        versionIndex: Int,
        expectedAggregateDigestSHA256: String
    ) {
        self.versionID = versionID
        self.versionIndex = versionIndex
        self.expectedAggregateDigestSHA256 = expectedAggregateDigestSHA256
    }
}

/// The complete terminal aggregate passed to the existing structured-output
/// publication boundary. Every member is persisted in one writer transaction.
public struct StructuredWorkProductPublicationCommand: Sendable {
    public let publicationMode: StructuredWorkProductPublicationMode
    public let idempotencyKey: String
    public let versionIndex: Int
    public let structuredOutputID: String
    public let newOutput: StructuredOutputRecord?
    public let sourceSet: DocumentSourceSetRecord
    public let orderedSources: [DocumentOutputSourceRecord]
    public let contentMarkdown: String
    public let requiredSections: [String]
    public let presentSections: [String]
    public let missingSections: [String]
    public let parentVersionID: String?
    public let repairReason: String?
    public let verificationStatus: OutputVerificationStatus
    public let verificationVersion: String?
    public let verificationResults: [PropositionSupportResult]
    public let verificationDimensions: VerificationDimensions?
    public let outputStatus: StructuredOutputStatus
    public let generationSession: GenerationSessionRecord
    public let promptBuilderVersion: String?
    public let assuranceState: OutputAssuranceState
    public let acceptedResearchPacket: AcceptedResearchPacketReference?
    public let auditEvent: AuditEventRecord

    public init(
        publicationMode: StructuredWorkProductPublicationMode,
        idempotencyKey: String,
        versionIndex: Int,
        structuredOutputID: String,
        newOutput: StructuredOutputRecord?,
        sourceSet: DocumentSourceSetRecord,
        orderedSources: [DocumentOutputSourceRecord],
        contentMarkdown: String,
        requiredSections: [String],
        presentSections: [String],
        missingSections: [String],
        parentVersionID: String?,
        repairReason: String?,
        verificationStatus: OutputVerificationStatus,
        verificationVersion: String?,
        verificationResults: [PropositionSupportResult],
        verificationDimensions: VerificationDimensions?,
        outputStatus: StructuredOutputStatus,
        generationSession: GenerationSessionRecord,
        promptBuilderVersion: String?,
        assuranceState: OutputAssuranceState,
        acceptedResearchPacket: AcceptedResearchPacketReference?,
        auditEvent: AuditEventRecord
    ) {
        self.publicationMode = publicationMode
        self.idempotencyKey = idempotencyKey
        self.versionIndex = versionIndex
        self.structuredOutputID = structuredOutputID
        self.newOutput = newOutput
        self.sourceSet = sourceSet
        self.orderedSources = orderedSources
        self.contentMarkdown = contentMarkdown
        self.requiredSections = requiredSections
        self.presentSections = presentSections
        self.missingSections = missingSections
        self.parentVersionID = parentVersionID
        self.repairReason = repairReason
        self.verificationStatus = verificationStatus
        self.verificationVersion = verificationVersion
        self.verificationResults = verificationResults
        self.verificationDimensions = verificationDimensions
        self.outputStatus = outputStatus
        self.generationSession = generationSession
        self.promptBuilderVersion = promptBuilderVersion
        self.assuranceState = assuranceState
        self.acceptedResearchPacket = acceptedResearchPacket
        self.auditEvent = auditEvent
    }
}

public struct StructuredWorkProductPublicationReceipt: Codable, FetchableRecord,
    PersistableRecord, Equatable, Sendable
{
    public static let databaseTableName = "structured_work_product_publications"

    public let publicationMode: StructuredWorkProductPublicationMode
    public let idempotencyKey: String
    public let requestDigestSHA256: String
    public let matterID: String
    public let structuredOutputID: String
    public let versionID: String
    public let versionIndex: Int
    public let sourceSetID: String
    public let generationSessionID: String
    public let auditEventID: String
    public let aggregateDigestSHA256: String
    public let acceptedResearchPacketVersionID: String?
    public let acceptedResearchPacketVersionIndex: Int?
    public let acceptedResearchPacketAggregateDigestSHA256: String?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case publicationMode = "publication_mode"
        case idempotencyKey = "idempotency_key"
        case requestDigestSHA256 = "request_digest_sha256"
        case matterID = "matter_id"
        case structuredOutputID = "structured_output_id"
        case versionID = "structured_output_version_id"
        case versionIndex = "version_index"
        case sourceSetID = "source_set_id"
        case generationSessionID = "generation_session_id"
        case auditEventID = "audit_event_id"
        case aggregateDigestSHA256 = "aggregate_digest_sha256"
        case acceptedResearchPacketVersionID = "accepted_packet_version_id"
        case acceptedResearchPacketVersionIndex = "accepted_packet_version_index"
        case acceptedResearchPacketAggregateDigestSHA256 =
            "accepted_packet_aggregate_digest_sha256"
        case createdAt = "created_at"
    }
}

public enum StructuredWorkProductPublicationError: Error, Equatable, Sendable {
    case idempotencyConflict(String)
    case invalidCommand(String)
    case acceptedResearchPacketUnavailable
    case persistence(String)
}

extension StructuredWorkProductPublicationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .idempotencyConflict(key):
            "A different publication already uses idempotency key \(key)."
        case let .invalidCommand(reason):
            "The structured work publication is invalid: \(reason)."
        case .acceptedResearchPacketUnavailable:
            "The exact accepted research packet version is unavailable."
        case let .persistence(message):
            message
        }
    }
}
