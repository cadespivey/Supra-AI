import Foundation
import GRDB

public enum DraftArtifactIntentStatus: String, Codable, Sendable {
    case prepared
    case completed
    case aborted
    case recoveryRequired = "recovery_required"
}

public enum DraftArtifactIntentFormat: String, Codable, Sendable {
    case docx
    case markdown
}

public enum DraftArtifactIntentKind: String, Codable, Sendable {
    case noticeAppearance
    case motionToDismiss
    case letterDemand
    case customDescription
}

public struct DraftArtifactIntentRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "draft_artifact_intents"

    public var id: String
    public var matterID: String
    public var artifactKind: String
    public var format: String
    public var fileName: String
    public var outputSHA256: String
    public var outputByteSize: Int
    public var auditMetadataJSON: String
    public var auditMetadataSHA256: String
    public var motionSnapshotRequestJSON: String?
    public var motionSnapshotSHA256: String?
    public var status: String
    public var createdAt: Date
    public var updatedAt: Date
    public var terminalAt: Date?

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        artifactKind: String,
        format: DraftArtifactIntentFormat,
        fileName: String,
        outputSHA256: String,
        outputByteSize: Int,
        auditMetadataJSON: String,
        auditMetadataSHA256: String,
        motionSnapshotRequestJSON: String? = nil,
        motionSnapshotSHA256: String? = nil,
        status: DraftArtifactIntentStatus = .prepared,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        terminalAt: Date? = nil
    ) {
        self.id = id
        self.matterID = matterID
        self.artifactKind = artifactKind
        self.format = format.rawValue
        self.fileName = fileName
        self.outputSHA256 = outputSHA256
        self.outputByteSize = outputByteSize
        self.auditMetadataJSON = auditMetadataJSON
        self.auditMetadataSHA256 = auditMetadataSHA256
        self.motionSnapshotRequestJSON = motionSnapshotRequestJSON
        self.motionSnapshotSHA256 = motionSnapshotSHA256
        self.status = status.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.terminalAt = terminalAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, format, status
        case matterID = "matter_id"
        case artifactKind = "artifact_kind"
        case fileName = "file_name"
        case outputSHA256 = "output_sha256"
        case outputByteSize = "output_byte_size"
        case auditMetadataJSON = "audit_metadata_json"
        case auditMetadataSHA256 = "audit_metadata_sha256"
        case motionSnapshotRequestJSON = "motion_snapshot_request_json"
        case motionSnapshotSHA256 = "motion_snapshot_sha256"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case terminalAt = "terminal_at"
    }
}
