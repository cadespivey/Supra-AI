import Foundation
import GRDB

public enum RemediationRecoveryKind: String, Codable, CaseIterable, Sendable {
    case legacyStructuredOutput = "legacy_structured_output"
    case legacyDraftArtifact = "legacy_draft_artifact"
    case multiMatterBillingDraft = "multi_matter_billing_draft"
    case blobRepair = "blob_repair"
    case modelRedownload = "model_redownload"
}

public enum RemediationRecoveryStatus: String, Codable, Sendable {
    case pending
    case resolved
}

public enum RemediationRecoveryResolution: String, Codable, Sendable {
    case reverified
    case regenerated
    case replaced
    case userReviewed = "user_reviewed"
    case repaired
    case redownloaded
}

public struct RemediationRecoveryItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "remediation_recovery_items"

    public var id: String
    public var kind: String
    public var matterID: String?
    public var relatedTable: String
    public var relatedID: String
    public var status: String
    public var resolution: String?
    public var createdAt: Date
    public var resolvedAt: Date?

    public init(
        id: String = UUID().uuidString,
        kind: RemediationRecoveryKind,
        matterID: String?,
        relatedTable: String,
        relatedID: String,
        status: RemediationRecoveryStatus = .pending,
        resolution: RemediationRecoveryResolution? = nil,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind.rawValue
        self.matterID = matterID
        self.relatedTable = relatedTable
        self.relatedID = relatedID
        self.status = status.rawValue
        self.resolution = resolution?.rawValue
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, status, resolution
        case matterID = "matter_id"
        case relatedTable = "related_table"
        case relatedID = "related_id"
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }
}
