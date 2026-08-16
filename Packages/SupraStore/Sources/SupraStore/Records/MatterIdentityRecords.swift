import Foundation
import GRDB

public struct CourtIdentityResolutionQueueItem: Equatable, Sendable {
    public let matterID: String
    public let legacyCourtText: String?
    public let conversionReceiptID: String
    public let identityRevision: Int

    public init(
        matterID: String,
        legacyCourtText: String?,
        conversionReceiptID: String,
        identityRevision: Int
    ) {
        self.matterID = matterID
        self.legacyCourtText = legacyCourtText
        self.conversionReceiptID = conversionReceiptID
        self.identityRevision = identityRevision
    }
}

public struct CourtIdentityResolutionReceipt: Equatable, Sendable {
    public let decisionID: String
    public let matterID: String
    public let sourceConversionReceiptID: String
    public let legacyCourtText: String?
    public let priorIdentityRevision: Int
    public let resultIdentityRevision: Int
    public let canonicalJurisdictionID: String
    public let canonicalCourtID: String
    public let resolutionSource: String
    public let actor: String
    public let purpose: String
    public let catalogVersion: String
    public let catalogSemanticDigest: String
    public let requestDigestSHA256: String
    public let decidedAt: Date
}

extension CourtIdentityResolutionReceipt: FetchableRecord {
    public init(row: Row) throws {
        decisionID = row["id"]
        matterID = row["matter_id"]
        sourceConversionReceiptID = row["source_conversion_receipt_id"]
        legacyCourtText = row["legacy_court"]
        priorIdentityRevision = row["prior_identity_revision"]
        resultIdentityRevision = row["result_identity_revision"]
        canonicalJurisdictionID = row["canonical_jurisdiction_id"]
        canonicalCourtID = row["canonical_court_id"]
        resolutionSource = row["resolution_source"]
        actor = row["actor"]
        purpose = row["purpose"]
        catalogVersion = row["canonical_catalog_version"]
        catalogSemanticDigest = row["canonical_catalog_digest_sha256"]
        requestDigestSHA256 = row["request_digest_sha256"]
        decidedAt = row["decided_at"]
    }
}

public enum CourtIdentityResolutionError: Error, Equatable, Sendable {
    case conflictingDecision
    case matterUnavailable
    case sourceReceiptUnavailable
    case staleIdentityRevision
    case invalidField(String)
}
