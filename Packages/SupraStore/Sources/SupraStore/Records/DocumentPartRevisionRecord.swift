import Foundation
import GRDB

/// Immutable extracted-text candidate for one natural document part.
public struct DocumentPartRevisionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "document_part_revisions"

    public var id: String
    public var documentID: String
    public var partIndex: Int
    public var derivationKey: String
    public var origin: String
    public var method: String
    public var text: String
    public var charCount: Int
    public var ocrConfidence: Double?
    public var boundingBoxesJSON: String?
    public var toolchainVersion: String?
    public var author: String?
    public var reason: String?
    public var supersedesRevisionID: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        documentID: String,
        partIndex: Int,
        derivationKey: String,
        origin: String,
        method: String,
        text: String,
        charCount: Int,
        ocrConfidence: Double? = nil,
        boundingBoxesJSON: String? = nil,
        toolchainVersion: String? = nil,
        author: String? = nil,
        reason: String? = nil,
        supersedesRevisionID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.documentID = documentID
        self.partIndex = partIndex
        self.derivationKey = derivationKey
        self.origin = origin
        self.method = method
        self.text = text
        self.charCount = charCount
        self.ocrConfidence = ocrConfidence
        self.boundingBoxesJSON = boundingBoxesJSON
        self.toolchainVersion = toolchainVersion
        self.author = author
        self.reason = reason
        self.supersedesRevisionID = supersedesRevisionID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case documentID = "document_id"
        case partIndex = "part_index"
        case derivationKey = "derivation_key"
        case origin
        case method
        case text
        case charCount = "char_count"
        case ocrConfidence = "ocr_confidence"
        case boundingBoxesJSON = "bounding_boxes_json"
        case toolchainVersion = "toolchain_version"
        case author
        case reason
        case supersedesRevisionID = "supersedes_revision_id"
        case createdAt = "created_at"
    }
}
