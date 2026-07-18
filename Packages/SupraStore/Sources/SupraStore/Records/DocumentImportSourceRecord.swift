import Foundation
import GRDB
import SupraCore

/// Durable per-source import accounting introduced by migration v059.
public struct DocumentImportSourceRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_import_sources"

    public var id: String
    public var importBatchID: String
    public var matterID: String
    public var sourceKey: String
    public var sourceDisplayPath: String
    public var sourceBookmark: Data?
    public var parentSourceID: String?
    public var state: String
    public var rejectionCode: String?
    public var reason: String?
    public var documentID: String?
    public var blobSHA256: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        importBatchID: String,
        matterID: String,
        sourceKey: String,
        sourceDisplayPath: String,
        sourceBookmark: Data? = nil,
        parentSourceID: String? = nil,
        state: String = DocumentImportSourceState.discovered.rawValue,
        rejectionCode: String? = nil,
        reason: String? = nil,
        documentID: String? = nil,
        blobSHA256: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.importBatchID = importBatchID
        self.matterID = matterID
        self.sourceKey = sourceKey
        self.sourceDisplayPath = sourceDisplayPath
        self.sourceBookmark = sourceBookmark
        self.parentSourceID = parentSourceID
        self.state = state
        self.rejectionCode = rejectionCode
        self.reason = reason
        self.documentID = documentID
        self.blobSHA256 = blobSHA256
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var sourceState: DocumentImportSourceState? {
        DocumentImportSourceState(rawValue: state)
    }

    public var isTerminal: Bool {
        sourceState?.isTerminal == true
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case importBatchID = "import_batch_id"
        case matterID = "matter_id"
        case sourceKey = "source_key"
        case sourceDisplayPath = "source_display_path"
        case sourceBookmark = "source_bookmark"
        case parentSourceID = "parent_source_id"
        case state
        case rejectionCode = "rejection_code"
        case reason
        case documentID = "document_id"
        case blobSHA256 = "blob_sha256"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Exact persisted accounting buckets for one import batch.
public struct DocumentImportSourcesSummary: Equatable, Sendable {
    public let totalCount: Int
    public let terminalCount: Int
    public let unfinishedCount: Int
    public let contentDenominator: Int
    public let admittedCount: Int
    public let containerCompletedCount: Int
    public let rejectedCount: Int
    public let unsupportedByPolicyCount: Int
    public let failedCount: Int
    public let cancelledCount: Int
    public let interruptedCount: Int
    public let excludedHiddenCount: Int
    public let excludedByUserCount: Int
    public let balanceErrorCount: Int
}
