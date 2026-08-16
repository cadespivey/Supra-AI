import Foundation
import GRDB

public enum ResearchPacketState: String, Codable, Equatable, Sendable {
    case executed
    case reviewed
    case accepted
    case cancelled
}

public enum ResearchPacketReviewerAction: String, Codable, Equatable, Sendable {
    case approvedForAuthorityUse = "approved_for_authority_use"
}

/// Opaque proof that Store may record one egress-backed research execution.
/// Ordinary package clients can only obtain this value from the Sessions
/// receipt registrar; primitive grant fields are not a public construction
/// surface.
public struct ResearchPacketEgressAuthority: Equatable, Sendable {
    enum Storage: Equatable, Sendable {
        case approvedGrant(id: String, version: Int)
        case registeredConsumption(ResearchPacketEgressConsumptionCapability)
    }

    let storage: Storage

    /// Compatibility fixture for Store's pre-receipt tests. This remains
    /// internal so `@testable import SupraStore` can exercise the legacy
    /// aggregate without exposing a production bypass.
    static func approvedGrant(id: String, version: Int) -> Self {
        Self(storage: .approvedGrant(id: id, version: version))
    }

    static func registeredConsumption(
        _ capability: ResearchPacketEgressConsumptionCapability
    ) -> Self {
        Self(storage: .registeredConsumption(capability))
    }
}

/// Opaque Store-minted capability. Ordinary callers can pass a registered
/// capability onward but cannot construct one from primitive receipt fields.
public struct ResearchPacketEgressConsumptionCapability: Equatable, Sendable {
    let receiptID: String

    init(receiptID: String) {
        self.receiptID = receiptID
    }
}

@_spi(ResearchPacketEgressRegistration)
public struct ResearchPacketEgressConsumptionRegistrationCommand: Equatable, Sendable {
    public let receiptID: String
    public let providerID: String
    public let grantVersion: Int
    public let origin: String
    public let matterID: String?
    public let researchSessionID: String?
    public let classification: String
    public let querySHA256: String
    public let bindingDigestSHA256: String
    public let registeredAt: Date

    public init(
        receiptID: String,
        providerID: String,
        grantVersion: Int,
        origin: String,
        matterID: String?,
        researchSessionID: String?,
        classification: String,
        querySHA256: String,
        bindingDigestSHA256: String,
        registeredAt: Date
    ) {
        self.receiptID = receiptID
        self.providerID = providerID
        self.grantVersion = grantVersion
        self.origin = origin
        self.matterID = matterID
        self.researchSessionID = researchSessionID
        self.classification = classification
        self.querySHA256 = querySHA256
        self.bindingDigestSHA256 = bindingDigestSHA256
        self.registeredAt = registeredAt
    }
}

public struct ResearchPacketEgressConsumptionRegistration: Codable, FetchableRecord,
    PersistableRecord, Equatable, Sendable
{
    public static let databaseTableName = "research_packet_egress_consumptions"

    public let receiptID: String
    public let requestDigestSHA256: String
    public let providerID: String
    public let grantVersion: Int
    public let origin: String
    public let matterID: String?
    public let researchSessionID: String?
    public let classification: String
    public let querySHA256: String
    public let bindingDigestSHA256: String
    public let registeredAt: Date
    public let usedByExecutionID: String?
    public let usedAt: Date?

    enum CodingKeys: String, CodingKey {
        case receiptID = "receipt_id"
        case requestDigestSHA256 = "request_digest_sha256"
        case providerID = "provider_id"
        case grantVersion = "grant_version"
        case origin
        case matterID = "matter_id"
        case researchSessionID = "research_session_id"
        case classification
        case querySHA256 = "query_sha256"
        case bindingDigestSHA256 = "binding_digest_sha256"
        case registeredAt = "registered_at"
        case usedByExecutionID = "used_by_execution_id"
        case usedAt = "used_at"
    }
}

public struct ResearchPacketExecutedResult: Equatable, Sendable {
    public let researchResultID: String
    public let providerResultID: String

    public init(researchResultID: String, providerResultID: String) {
        self.researchResultID = researchResultID
        self.providerResultID = providerResultID
    }
}

public struct ResearchPacketExecutionCommand: Equatable, Sendable {
    public let packetID: String
    public let executionID: String
    public let matterID: String
    public let researchSessionID: String
    public let researchQueryID: String
    public let providerID: String
    public let egressAuthority: ResearchPacketEgressAuthority
    public let exactQueryBytes: Data
    public let orderedResults: [ResearchPacketExecutedResult]
    public let executedAt: Date

    public init(
        packetID: String,
        executionID: String,
        matterID: String,
        researchSessionID: String,
        researchQueryID: String,
        providerID: String,
        egressAuthority: ResearchPacketEgressAuthority,
        exactQueryBytes: Data,
        orderedResults: [ResearchPacketExecutedResult],
        executedAt: Date
    ) {
        self.packetID = packetID
        self.executionID = executionID
        self.matterID = matterID
        self.researchSessionID = researchSessionID
        self.researchQueryID = researchQueryID
        self.providerID = providerID
        self.egressAuthority = egressAuthority
        self.exactQueryBytes = exactQueryBytes
        self.orderedResults = orderedResults
        self.executedAt = executedAt
    }
}

public struct ResearchPacketAuthoritySelection: Equatable, Sendable {
    public let researchResultID: String
    public let providerResultID: String
    public let authorityID: String
    public let groundKey: AuthorityReviewedPropositionGround
    public let expectedReviewedPropositionBindingSHA256: String

    public init(
        researchResultID: String,
        providerResultID: String,
        authorityID: String,
        groundKey: AuthorityReviewedPropositionGround,
        expectedReviewedPropositionBindingSHA256: String
    ) {
        self.researchResultID = researchResultID
        self.providerResultID = providerResultID
        self.authorityID = authorityID
        self.groundKey = groundKey
        self.expectedReviewedPropositionBindingSHA256 =
            expectedReviewedPropositionBindingSHA256
    }
}

public struct ResearchPacketReviewCommand: Equatable, Sendable {
    public let executionID: String
    public let expectedExecutionDigestSHA256: String
    public let reviewerID: String
    public let action: ResearchPacketReviewerAction
    public let orderedAuthorities: [ResearchPacketAuthoritySelection]
    public let expectedSourceDigestSHA256: String
    public let reviewedAt: Date

    public init(
        executionID: String,
        expectedExecutionDigestSHA256: String,
        reviewerID: String,
        action: ResearchPacketReviewerAction,
        orderedAuthorities: [ResearchPacketAuthoritySelection],
        expectedSourceDigestSHA256: String,
        reviewedAt: Date
    ) {
        self.executionID = executionID
        self.expectedExecutionDigestSHA256 = expectedExecutionDigestSHA256
        self.reviewerID = reviewerID
        self.action = action
        self.orderedAuthorities = orderedAuthorities
        self.expectedSourceDigestSHA256 = expectedSourceDigestSHA256
        self.reviewedAt = reviewedAt
    }
}

public struct ResearchPacketAcceptanceCommand: Equatable, Sendable {
    public let acceptedVersionID: String
    public let idempotencyKey: String
    public let executionID: String
    public let expectedReviewDigestSHA256: String
    public let acceptedAt: Date

    public init(
        acceptedVersionID: String,
        idempotencyKey: String,
        executionID: String,
        expectedReviewDigestSHA256: String,
        acceptedAt: Date
    ) {
        self.acceptedVersionID = acceptedVersionID
        self.idempotencyKey = idempotencyKey
        self.executionID = executionID
        self.expectedReviewDigestSHA256 = expectedReviewDigestSHA256
        self.acceptedAt = acceptedAt
    }
}

public struct ResearchPacketExecutedReceipt: Equatable, Sendable {
    public let packetID: String
    public let executionID: String
    public let state: ResearchPacketState
    public let matterID: String
    public let researchSessionID: String
    public let researchQueryID: String
    public let providerID: String
    public let egressGrantID: String
    public let egressGrantVersion: Int
    public let exactQuerySHA256: String
    public let executionDigestSHA256: String
    public let orderedResearchResultIDs: [String]
    public let orderedProviderResultIDs: [String]
}

public struct ResearchPacketReviewedReceipt: Equatable, Sendable {
    public let packetID: String
    public let executionID: String
    public let state: ResearchPacketState
    public let sourceDigestSHA256: String
    public let executionDigestSHA256: String
    public let reviewDigestSHA256: String
    public let reviewerID: String
    public let reviewerAction: ResearchPacketReviewerAction
}

public struct ResearchPacketCandidateRecord: Codable, FetchableRecord,
    PersistableRecord, Equatable, Sendable
{
    public static let databaseTableName = "research_packet_candidates"

    public let executionID: String
    public let packetID: String
    public let matterID: String
    public let researchSessionID: String
    public let researchQueryID: String
    public let state: ResearchPacketState
    public let providerID: String
    public let egressAuthorityKind: String
    public let egressGrantID: String
    public let egressGrantVersion: Int
    public let exactQuerySHA256: String
    public let executionDigestSHA256: String
    public let sourceDigestSHA256: String?
    public let reviewDigestSHA256: String?
    public let reviewerID: String?
    public let reviewerAction: ResearchPacketReviewerAction?
    public let reviewedAt: Date?
    public let cancelledBy: String?
    public let cancelledAt: Date?
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case executionID = "id"
        case packetID = "packet_id"
        case matterID = "matter_id"
        case researchSessionID = "research_session_id"
        case researchQueryID = "research_query_id"
        case state
        case providerID = "provider_id"
        case egressAuthorityKind = "egress_authority_kind"
        case egressGrantID = "egress_grant_id"
        case egressGrantVersion = "egress_grant_version"
        case exactQuerySHA256 = "exact_query_sha256"
        case executionDigestSHA256 = "execution_digest_sha256"
        case sourceDigestSHA256 = "source_digest_sha256"
        case reviewDigestSHA256 = "review_digest_sha256"
        case reviewerID = "reviewer_id"
        case reviewerAction = "reviewer_action"
        case reviewedAt = "reviewed_at"
        case cancelledBy = "cancelled_by"
        case cancelledAt = "cancelled_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ResearchPacketCandidateSourceRecord: Codable, FetchableRecord,
    PersistableRecord, Equatable, Sendable
{
    static let databaseTableName = "research_packet_candidate_sources"

    let executionID: String
    let sourceIndex: Int
    let researchResultID: String
    let providerResultID: String
    var authorityID: String?
    var groundKey: String?
    var reviewedPropositionBindingSHA256: String?
    var excerpt: String?
    var excerptSHA256: String?

    enum CodingKeys: String, CodingKey {
        case executionID = "execution_id"
        case sourceIndex = "source_index"
        case researchResultID = "research_result_id"
        case providerResultID = "provider_result_id"
        case authorityID = "authority_id"
        case groundKey = "ground_key"
        case reviewedPropositionBindingSHA256 =
            "reviewed_proposition_binding_sha256"
        case excerpt
        case excerptSHA256 = "excerpt_sha256"
    }
}

public struct AcceptedResearchPacketSource: Codable, Equatable, Sendable {
    public let sourceIndex: Int
    public let researchResultID: String
    public let providerResultID: String
    public let authorityID: String
    public let groundKey: AuthorityReviewedPropositionGround
    public let excerpt: String
    public let excerptSHA256: String
    public let reviewedPropositionBindingSHA256: String
}

struct AcceptedResearchPacketVersionRecord: Codable, FetchableRecord,
    PersistableRecord, Equatable, Sendable
{
    static let databaseTableName = "accepted_research_packet_versions"

    let id: String
    let packetID: String
    let executionID: String
    let versionIndex: Int
    let state: ResearchPacketState
    let matterID: String
    let researchSessionID: String
    let researchQueryID: String
    let providerID: String
    let egressGrantID: String
    let egressGrantVersion: Int
    let exactQuerySHA256: String
    let sourceDigestSHA256: String
    let reviewDigestSHA256: String
    let reviewerID: String
    let reviewerAction: ResearchPacketReviewerAction
    let aggregateDigestSHA256: String
    let auditEventID: String
    let acceptedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case packetID = "packet_id"
        case executionID = "execution_id"
        case versionIndex = "version_index"
        case state
        case matterID = "matter_id"
        case researchSessionID = "research_session_id"
        case researchQueryID = "research_query_id"
        case providerID = "provider_id"
        case egressGrantID = "egress_grant_id"
        case egressGrantVersion = "egress_grant_version"
        case exactQuerySHA256 = "exact_query_sha256"
        case sourceDigestSHA256 = "source_digest_sha256"
        case reviewDigestSHA256 = "review_digest_sha256"
        case reviewerID = "reviewer_id"
        case reviewerAction = "reviewer_action"
        case aggregateDigestSHA256 = "aggregate_digest_sha256"
        case auditEventID = "audit_event_id"
        case acceptedAt = "accepted_at"
    }
}

struct AcceptedResearchPacketSourceRecord: Codable, FetchableRecord,
    PersistableRecord, Equatable, Sendable
{
    static let databaseTableName = "accepted_research_packet_sources"

    let packetVersionID: String
    let sourceIndex: Int
    let researchResultID: String
    let providerResultID: String
    let authorityID: String
    let groundKey: String
    let excerpt: String
    let excerptSHA256: String
    let reviewedPropositionBindingSHA256: String

    enum CodingKeys: String, CodingKey {
        case packetVersionID = "packet_version_id"
        case sourceIndex = "source_index"
        case researchResultID = "research_result_id"
        case providerResultID = "provider_result_id"
        case authorityID = "authority_id"
        case groundKey = "ground_key"
        case excerpt
        case excerptSHA256 = "excerpt_sha256"
        case reviewedPropositionBindingSHA256 =
            "reviewed_proposition_binding_sha256"
    }
}

public struct AcceptedResearchPacketVersion: Codable, Equatable, Sendable {
    public let id: String
    public let packetID: String
    public let executionID: String
    public let versionIndex: Int
    public let state: ResearchPacketState
    public let matterID: String
    public let researchSessionID: String
    public let researchQueryID: String
    public let providerID: String
    public let egressGrantID: String
    public let egressGrantVersion: Int
    public let exactQuerySHA256: String
    public let sourceDigestSHA256: String
    public let reviewDigestSHA256: String
    public let reviewerID: String
    public let reviewerAction: ResearchPacketReviewerAction
    public let aggregateDigestSHA256: String
    public let auditEventID: String
    public let acceptedAt: Date
    public let sources: [AcceptedResearchPacketSource]
}

struct ResearchPacketAcceptanceReceiptRecord: Codable, FetchableRecord,
    PersistableRecord, Equatable, Sendable
{
    static let databaseTableName = "research_packet_acceptance_receipts"

    let idempotencyKey: String
    let requestDigestSHA256: String
    let acceptedVersionID: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case requestDigestSHA256 = "request_digest_sha256"
        case acceptedVersionID = "accepted_version_id"
        case createdAt = "created_at"
    }
}

public enum ResearchPacketVersionDispositionKind: String, Codable, Equatable,
    Sendable
{
    case superseded
    case revoked
}

public struct ResearchPacketVersionDispositionCommand: Equatable, Sendable {
    public let idempotencyKey: String
    public let packetVersionID: String
    public let kind: ResearchPacketVersionDispositionKind
    public let replacementPacketVersionID: String?
    public let actor: String
    public let reason: String
    public let occurredAt: Date

    public init(
        idempotencyKey: String,
        packetVersionID: String,
        kind: ResearchPacketVersionDispositionKind,
        replacementPacketVersionID: String?,
        actor: String,
        reason: String,
        occurredAt: Date
    ) {
        self.idempotencyKey = idempotencyKey
        self.packetVersionID = packetVersionID
        self.kind = kind
        self.replacementPacketVersionID = replacementPacketVersionID
        self.actor = actor
        self.reason = reason
        self.occurredAt = occurredAt
    }
}

public struct ResearchPacketVersionDisposition: Codable, FetchableRecord,
    PersistableRecord, Equatable, Sendable
{
    public static let databaseTableName = "research_packet_version_dispositions"

    public let idempotencyKey: String
    public let requestDigestSHA256: String
    public let packetVersionID: String
    public let kind: ResearchPacketVersionDispositionKind
    public let replacementPacketVersionID: String?
    public let actor: String
    public let reason: String
    public let occurredAt: Date
    public let auditEventID: String

    enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case requestDigestSHA256 = "request_digest_sha256"
        case packetVersionID = "packet_version_id"
        case kind
        case replacementPacketVersionID = "replacement_packet_version_id"
        case actor
        case reason
        case occurredAt = "occurred_at"
        case auditEventID = "audit_event_id"
    }
}

public struct ResearchPacketWorkProductBindingCommand: Equatable, Sendable {
    public let idempotencyKey: String
    public let structuredOutputVersionID: String
    public let acceptedPacketVersionID: String
    public let expectedPacketAggregateDigestSHA256: String
    public let boundAt: Date

    public init(
        idempotencyKey: String,
        structuredOutputVersionID: String,
        acceptedPacketVersionID: String,
        expectedPacketAggregateDigestSHA256: String,
        boundAt: Date
    ) {
        self.idempotencyKey = idempotencyKey
        self.structuredOutputVersionID = structuredOutputVersionID
        self.acceptedPacketVersionID = acceptedPacketVersionID
        self.expectedPacketAggregateDigestSHA256 =
            expectedPacketAggregateDigestSHA256
        self.boundAt = boundAt
    }
}

public struct ResearchPacketWorkProductBinding: Codable, FetchableRecord,
    PersistableRecord, Equatable, Sendable
{
    public static let databaseTableName = "research_packet_work_product_bindings"

    public let idempotencyKey: String
    public let requestDigestSHA256: String
    public let structuredOutputVersionID: String
    public let acceptedPacketVersionID: String
    public let packetAggregateDigestSHA256: String
    public let createdAt: Date
    public let auditEventID: String

    enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case requestDigestSHA256 = "request_digest_sha256"
        case structuredOutputVersionID = "structured_output_version_id"
        case acceptedPacketVersionID = "packet_version_id"
        case packetAggregateDigestSHA256 = "packet_aggregate_digest_sha256"
        case createdAt = "created_at"
        case auditEventID = "audit_event_id"
    }
}

public enum ResearchPacketRepositoryError: Error, Equatable, Sendable {
    case invalidTransition(expected: ResearchPacketState, actual: ResearchPacketState)
    case cancelled
    case conflictingRetry
    case packetDigestMismatch
    case reviewEvidenceChanged
    case workProductAlreadyBound
    case recordNotFound
    case invalidCommand
    case provenanceMismatch
    case queryMismatch
    case resultMismatch
    case versionUnavailable
    case crossMatter
    case invalidDisposition
    case egressConsumptionUnavailable
    case egressConsumptionAlreadyUsed
}
