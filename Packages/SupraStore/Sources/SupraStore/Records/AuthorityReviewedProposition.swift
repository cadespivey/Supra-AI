import Foundation

/// A proposition-specific human review bound to exact persisted authority bytes.
/// The record is stored as a versioned JSON envelope on `authorities`; consumers
/// must obtain it through `AuthorityRepository.reviewedPropositionState` so every
/// binding is recomputed against the live row before use.
public struct AuthorityReviewedProposition: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumExcerptUTF8Bytes = 2_000

    public let schemaVersion: Int
    public let authorityID: String
    public let groundKey: AuthorityReviewedPropositionGround
    public let sourceKind: AuthorityReviewedPropositionSourceKind
    public let excerpt: String
    public let excerptByteStart: Int
    public let excerptByteLength: Int
    public let opinionSHA256: String
    public let excerptSHA256: String
    public let effectiveCitationSHA256: String
    public let courtSHA256: String
    public let bindingSHA256: String
    public let reviewedBy: String
    public let reviewedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        authorityID: String,
        groundKey: AuthorityReviewedPropositionGround,
        sourceKind: AuthorityReviewedPropositionSourceKind = .storedOpinionText,
        excerpt: String,
        excerptByteStart: Int,
        excerptByteLength: Int,
        opinionSHA256: String,
        excerptSHA256: String,
        effectiveCitationSHA256: String,
        courtSHA256: String,
        bindingSHA256: String,
        reviewedBy: String,
        reviewedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.authorityID = authorityID
        self.groundKey = groundKey
        self.sourceKind = sourceKind
        self.excerpt = excerpt
        self.excerptByteStart = excerptByteStart
        self.excerptByteLength = excerptByteLength
        self.opinionSHA256 = opinionSHA256
        self.excerptSHA256 = excerptSHA256
        self.effectiveCitationSHA256 = effectiveCitationSHA256
        self.courtSHA256 = courtSHA256
        self.bindingSHA256 = bindingSHA256
        self.reviewedBy = reviewedBy
        self.reviewedAt = reviewedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case authorityID = "authority_id"
        case groundKey = "ground_key"
        case sourceKind = "source_kind"
        case excerpt
        case excerptByteStart = "excerpt_byte_start"
        case excerptByteLength = "excerpt_byte_length"
        case opinionSHA256 = "opinion_sha256"
        case excerptSHA256 = "excerpt_sha256"
        case effectiveCitationSHA256 = "effective_citation_sha256"
        case courtSHA256 = "court_sha256"
        case bindingSHA256 = "binding_sha256"
        case reviewedBy = "reviewed_by"
        case reviewedAt = "reviewed_at"
    }
}

public enum AuthorityReviewedPropositionGround: String, Codable, CaseIterable, Equatable, Sendable {
    case failureToStateClaim = "mtd.failureToStateClaim"
}

public enum AuthorityReviewedPropositionSourceKind: String, Codable, CaseIterable, Equatable, Sendable {
    case storedOpinionText = "stored_opinion_text"
}

public enum AuthorityReviewedPropositionBlockReason: String, Codable, Equatable, Sendable {
    case authorityNotFound = "authority_not_found"
    case authorityNotLive = "authority_not_live"
    case authorityEligibilityChanged = "authority_eligibility_changed"
    case malformedEvidence = "malformed_evidence"
    case unsupportedEvidence = "unsupported_evidence"
    case forgedEvidence = "forged_evidence"
    case staleEvidence = "stale_evidence"
}

public enum AuthorityReviewedPropositionState: Equatable, Sendable {
    case notReviewed
    case ready(AuthorityReviewedProposition)
    case blocked(AuthorityReviewedPropositionBlockReason)
}

public enum AuthorityRepositoryError: Error, Equatable, Sendable {
    case untrustedPropositionEvidenceOnInsert
    case authorityNotFound
    case reviewRequiresLiveAuthority
    case reviewRequiresNotAdverse
    case reviewRequiresUserMarkedVerified
    case opinionTextUnavailable
    case effectiveCitationUnavailable
    case reviewerRequired
    case excerptEmpty
    case excerptTooLong(maximumUTF8Bytes: Int)
    case excerptNotFound
    case excerptNotUnique
    case propositionReviewNotFound
}
