import Foundation
import GRDB
import SupraCore

/// A document instance within a matter. The same content blob may back several
/// instances in different folders; each instance owns its own folder, tags,
/// status, and deletion state (Milestone 3).
public struct MatterDocumentRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "matter_documents"

    public var id: String
    public var matterID: String
    public var blobID: String
    public var parentDocumentID: String?
    public var folderID: String?
    public var importBatchID: String?
    public var displayName: String
    public var importedRelativePath: String?
    public var sourceDisplayPath: String?
    public var status: String
    public var extractionStatus: String
    public var indexStatus: String
    public var sourceKind: String?
    public var extractionMethod: String?
    public var extractedTextChecksum: String?
    public var pagePartCount: Int?
    public var ocrConfidenceSummary: String?
    public var hasUserEditedText: Bool
    public var extractionWarningsJSON: String?
    public var extractionErrorsJSON: String?
    public var metadataCreatedAt: Date?
    public var metadataModifiedAt: Date?
    public var importedAt: Date
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        blobID: String,
        parentDocumentID: String? = nil,
        folderID: String? = nil,
        importBatchID: String? = nil,
        displayName: String,
        importedRelativePath: String? = nil,
        sourceDisplayPath: String? = nil,
        status: String = MatterDocumentStatus.importing.rawValue,
        extractionStatus: String = DocumentExtractionStatus.pending.rawValue,
        indexStatus: String = DocumentIndexStatus.notIndexed.rawValue,
        sourceKind: String? = nil,
        extractionMethod: String? = nil,
        extractedTextChecksum: String? = nil,
        pagePartCount: Int? = nil,
        ocrConfidenceSummary: String? = nil,
        hasUserEditedText: Bool = false,
        extractionWarningsJSON: String? = nil,
        extractionErrorsJSON: String? = nil,
        metadataCreatedAt: Date? = nil,
        metadataModifiedAt: Date? = nil,
        importedAt: Date = Date(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.matterID = matterID
        self.blobID = blobID
        self.parentDocumentID = parentDocumentID
        self.folderID = folderID
        self.importBatchID = importBatchID
        self.displayName = displayName
        self.importedRelativePath = importedRelativePath
        self.sourceDisplayPath = sourceDisplayPath
        self.status = status
        self.extractionStatus = extractionStatus
        self.indexStatus = indexStatus
        self.sourceKind = sourceKind
        self.extractionMethod = extractionMethod
        self.extractedTextChecksum = extractedTextChecksum
        self.pagePartCount = pagePartCount
        self.ocrConfidenceSummary = ocrConfidenceSummary
        self.hasUserEditedText = hasUserEditedText
        self.extractionWarningsJSON = extractionWarningsJSON
        self.extractionErrorsJSON = extractionErrorsJSON
        self.metadataCreatedAt = metadataCreatedAt
        self.metadataModifiedAt = metadataModifiedAt
        self.importedAt = importedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case blobID = "blob_id"
        case parentDocumentID = "parent_document_id"
        case folderID = "folder_id"
        case importBatchID = "import_batch_id"
        case displayName = "display_name"
        case importedRelativePath = "imported_relative_path"
        case sourceDisplayPath = "source_display_path"
        case status
        case extractionStatus = "extraction_status"
        case indexStatus = "index_status"
        case sourceKind = "source_kind"
        case extractionMethod = "extraction_method"
        case extractedTextChecksum = "extracted_text_checksum"
        case pagePartCount = "page_part_count"
        case ocrConfidenceSummary = "ocr_confidence_summary"
        case hasUserEditedText = "has_user_edited_text"
        case extractionWarningsJSON = "extraction_warnings_json"
        case extractionErrorsJSON = "extraction_errors_json"
        case metadataCreatedAt = "metadata_created_at"
        case metadataModifiedAt = "metadata_modified_at"
        case importedAt = "imported_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}
