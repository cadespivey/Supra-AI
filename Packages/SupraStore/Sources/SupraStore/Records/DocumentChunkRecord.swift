import Foundation
import GRDB
import SupraCore

/// A deterministic retrieval chunk of a document instance with a stable source
/// locator (Milestone 3).
public struct DocumentChunkRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_chunks"

    public var id: String
    public var documentID: String
    public var pagePartID: String?
    public var revisionID: String?
    public var nodeID: String?
    public var unitKind: String?
    public var chunkerVersion: Int
    public var chunkIndex: Int
    public var sourceKind: String
    public var pageIndex: Int?
    public var pageLabel: String?
    public var sheetName: String?
    public var cellRange: String?
    public var emailPartPath: String?
    public var charStart: Int?
    public var charEnd: Int?
    public var normalizedText: String
    public var displayExcerpt: String?
    public var boundingBoxesJSON: String?
    public var ocrConfidence: Double?
    public var tokenCount: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        documentID: String,
        pagePartID: String? = nil,
        revisionID: String? = nil,
        nodeID: String? = nil,
        unitKind: String? = nil,
        chunkerVersion: Int = 1,
        chunkIndex: Int,
        sourceKind: String,
        pageIndex: Int? = nil,
        pageLabel: String? = nil,
        sheetName: String? = nil,
        cellRange: String? = nil,
        emailPartPath: String? = nil,
        charStart: Int? = nil,
        charEnd: Int? = nil,
        normalizedText: String = "",
        displayExcerpt: String? = nil,
        boundingBoxesJSON: String? = nil,
        ocrConfidence: Double? = nil,
        tokenCount: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.documentID = documentID
        self.pagePartID = pagePartID
        self.revisionID = revisionID
        self.nodeID = nodeID
        self.unitKind = unitKind
        self.chunkerVersion = chunkerVersion
        self.chunkIndex = chunkIndex
        self.sourceKind = sourceKind
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.sheetName = sheetName
        self.cellRange = cellRange
        self.emailPartPath = emailPartPath
        self.charStart = charStart
        self.charEnd = charEnd
        self.normalizedText = normalizedText
        self.displayExcerpt = displayExcerpt
        self.boundingBoxesJSON = boundingBoxesJSON
        self.ocrConfidence = ocrConfidence
        self.tokenCount = tokenCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case documentID = "document_id"
        case pagePartID = "page_part_id"
        case revisionID = "revision_id"
        case nodeID = "node_id"
        case unitKind = "unit_kind"
        case chunkerVersion = "chunker_version"
        case chunkIndex = "chunk_index"
        case sourceKind = "source_kind"
        case pageIndex = "page_index"
        case pageLabel = "page_label"
        case sheetName = "sheet_name"
        case cellRange = "cell_range"
        case emailPartPath = "email_part_path"
        case charStart = "char_start"
        case charEnd = "char_end"
        case normalizedText = "normalized_text"
        case displayExcerpt = "display_excerpt"
        case boundingBoxesJSON = "bounding_boxes_json"
        case ocrConfidence = "ocr_confidence"
        case tokenCount = "token_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
