import Foundation
import GRDB
import SupraCore

/// One persisted embedding vector per chunk per embedding model (M3). Vectors
/// are stored as little-endian Float32 BLOBs, normalized at write time so cosine
/// similarity reduces to a dot product.
public struct DocumentChunkEmbeddingRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_chunk_embeddings"

    public var id: String
    public var chunkID: String
    public var documentID: String
    public var embeddingModelID: String
    public var modelDisplayName: String
    public var modelRevision: String?
    public var dimension: Int
    public var normalized: Bool
    public var vector: Data
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        chunkID: String,
        documentID: String,
        embeddingModelID: String,
        modelDisplayName: String,
        modelRevision: String? = nil,
        dimension: Int,
        normalized: Bool = true,
        vector: Data,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.chunkID = chunkID
        self.documentID = documentID
        self.embeddingModelID = embeddingModelID
        self.modelDisplayName = modelDisplayName
        self.modelRevision = modelRevision
        self.dimension = dimension
        self.normalized = normalized
        self.vector = vector
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case chunkID = "chunk_id"
        case documentID = "document_id"
        case embeddingModelID = "embedding_model_id"
        case modelDisplayName = "model_display_name"
        case modelRevision = "model_revision"
        case dimension
        case normalized
        case vector
        case createdAt = "created_at"
    }
}
