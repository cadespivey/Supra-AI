import Foundation
import GRDB
import SupraCore

/// A natural source part of a document instance — a PDF page, image, sheet,
/// email part, or converted-document section — holding normalized extracted
/// text plus a stable source locator (Milestone 3).
public struct DocumentPagePartRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_pages_parts"

    public var id: String
    public var documentID: String
    public var partIndex: Int
    public var sourceKind: String
    public var pageIndex: Int?
    public var pageLabel: String?
    public var sheetName: String?
    public var cellRange: String?
    public var emailPartPath: String?
    public var normalizedText: String
    public var charCount: Int
    public var ocrConfidence: Double?
    public var boundingBoxesJSON: String?
    public var currentRevisionID: String?
    public var currentSelectionID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        documentID: String,
        partIndex: Int,
        sourceKind: String,
        pageIndex: Int? = nil,
        pageLabel: String? = nil,
        sheetName: String? = nil,
        cellRange: String? = nil,
        emailPartPath: String? = nil,
        normalizedText: String = "",
        charCount: Int = 0,
        ocrConfidence: Double? = nil,
        boundingBoxesJSON: String? = nil,
        currentRevisionID: String? = nil,
        currentSelectionID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.documentID = documentID
        self.partIndex = partIndex
        self.sourceKind = sourceKind
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.sheetName = sheetName
        self.cellRange = cellRange
        self.emailPartPath = emailPartPath
        self.normalizedText = normalizedText
        self.charCount = charCount
        self.ocrConfidence = ocrConfidence
        self.boundingBoxesJSON = boundingBoxesJSON
        self.currentRevisionID = currentRevisionID
        self.currentSelectionID = currentSelectionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case documentID = "document_id"
        case partIndex = "part_index"
        case sourceKind = "source_kind"
        case pageIndex = "page_index"
        case pageLabel = "page_label"
        case sheetName = "sheet_name"
        case cellRange = "cell_range"
        case emailPartPath = "email_part_path"
        case normalizedText = "normalized_text"
        case charCount = "char_count"
        case ocrConfidence = "ocr_confidence"
        case boundingBoxesJSON = "bounding_boxes_json"
        case currentRevisionID = "current_revision_id"
        case currentSelectionID = "current_selection_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
