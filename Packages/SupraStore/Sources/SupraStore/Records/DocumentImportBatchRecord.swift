import Foundation
import GRDB
import SupraCore

/// A batch import operation for a matter (Milestone 3). The full per-file import
/// report is stored in `reportJSON`; headline counters mirror its totals.
public struct DocumentImportBatchRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_import_batches"

    public var id: String
    public var matterID: String
    public var status: String
    public var sourceRootDisplay: String?
    public var targetFolderID: String?
    public var targetFolderRequested: Bool
    public var discoveredCount: Int
    public var importedCount: Int
    public var failedCount: Int
    public var reportJSON: String?
    public var startedAt: Date
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        status: String = DocumentImportBatchStatus.discovering.rawValue,
        sourceRootDisplay: String? = nil,
        targetFolderID: String? = nil,
        targetFolderRequested: Bool = false,
        discoveredCount: Int = 0,
        importedCount: Int = 0,
        failedCount: Int = 0,
        reportJSON: String? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.matterID = matterID
        self.status = status
        self.sourceRootDisplay = sourceRootDisplay
        self.targetFolderID = targetFolderID
        self.targetFolderRequested = targetFolderRequested
        self.discoveredCount = discoveredCount
        self.importedCount = importedCount
        self.failedCount = failedCount
        self.reportJSON = reportJSON
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case status
        case sourceRootDisplay = "source_root_display"
        case targetFolderID = "target_folder_id"
        case targetFolderRequested = "target_folder_requested"
        case discoveredCount = "discovered_count"
        case importedCount = "imported_count"
        case failedCount = "failed_count"
        case reportJSON = "report_json"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
