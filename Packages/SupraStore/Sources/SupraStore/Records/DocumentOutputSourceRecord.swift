import Foundation
import GRDB
import SupraCore

/// A single cited source row within a source set (Milestone 3): the chunk/page/
/// cell locator behind one inline citation in a generated output.
public struct DocumentOutputSourceRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_output_sources"

    public var id: String
    public var sourceSetID: String
    public var structuredOutputVersionID: String?
    public var documentID: String?
    public var chunkID: String?
    /// Immutable extracted-text revision used when this citation was created.
    /// Nil is an explicit pre-lineage/unknown state, never an instruction to
    /// substitute whatever text happens to be current later.
    public var revisionID: String?
    public var citationLabel: String
    public var locatorJSON: String
    public var excerpt: String
    public var rank: Int
    public var warningsJSON: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        sourceSetID: String,
        structuredOutputVersionID: String? = nil,
        documentID: String? = nil,
        chunkID: String? = nil,
        revisionID: String? = nil,
        citationLabel: String,
        locatorJSON: String = "{}",
        excerpt: String = "",
        rank: Int = 0,
        warningsJSON: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceSetID = sourceSetID
        self.structuredOutputVersionID = structuredOutputVersionID
        self.documentID = documentID
        self.chunkID = chunkID
        self.revisionID = revisionID
        self.citationLabel = citationLabel
        self.locatorJSON = locatorJSON
        self.excerpt = excerpt
        self.rank = rank
        self.warningsJSON = warningsJSON
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceSetID = "source_set_id"
        case structuredOutputVersionID = "structured_output_version_id"
        case documentID = "document_id"
        case chunkID = "chunk_id"
        case revisionID = "revision_id"
        case citationLabel = "citation_label"
        case locatorJSON = "locator_json"
        case excerpt
        case rank
        case warningsJSON = "warnings_json"
        case createdAt = "created_at"
    }
}
