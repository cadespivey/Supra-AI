import Foundation
import GRDB
import SupraCore

/// A version-scoped set of sources retrieved for a generated output (M3). While
/// generation is in progress `structuredOutputVersionID` may be nil.
public struct DocumentSourceSetRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_source_sets"

    public var id: String
    public var matterID: String
    public var structuredOutputVersionID: String?
    public var status: String
    public var mode: String
    public var scopeJSON: String
    public var retrievalQuery: String?
    /// Which retrieval tier produced this set — "fast" (preliminary, no rerank) or
    /// "deep" (wide pool + rerank). Nil for pre-tier rows (all were deep-equivalent).
    public var retrievalDepth: String?
    /// Canonical `DocumentPackingReport` JSON. Nil is explicit legacy/unknown.
    public var packingReportJSON: String?
    public var embeddingModelID: String?
    public var embeddingModelRevision: String?
    public var chunkerVersion: Int?
    public var retrievalConfigJSON: String?
    public var corpusSnapshotHash: String?
    /// Grounded-chat packet owner. Pending sets use this unique link until a
    /// later promotion attaches the same set to a structured output version.
    public var messageID: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        structuredOutputVersionID: String? = nil,
        status: String = DocumentSourceSetStatus.pending.rawValue,
        mode: String = DocumentSourceSetMode.autoSource.rawValue,
        scopeJSON: String = "{}",
        retrievalQuery: String? = nil,
        retrievalDepth: String? = nil,
        packingReportJSON: String? = nil,
        embeddingModelID: String? = nil,
        embeddingModelRevision: String? = nil,
        chunkerVersion: Int? = nil,
        retrievalConfigJSON: String? = nil,
        corpusSnapshotHash: String? = nil,
        messageID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.matterID = matterID
        self.structuredOutputVersionID = structuredOutputVersionID
        self.status = status
        self.mode = mode
        self.scopeJSON = scopeJSON
        self.retrievalQuery = retrievalQuery
        self.retrievalDepth = retrievalDepth
        self.packingReportJSON = packingReportJSON
        self.embeddingModelID = embeddingModelID
        self.embeddingModelRevision = embeddingModelRevision
        self.chunkerVersion = chunkerVersion
        self.retrievalConfigJSON = retrievalConfigJSON
        self.corpusSnapshotHash = corpusSnapshotHash
        self.messageID = messageID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case structuredOutputVersionID = "structured_output_version_id"
        case status
        case mode
        case scopeJSON = "scope_json"
        case retrievalQuery = "retrieval_query"
        case retrievalDepth = "retrieval_depth"
        case packingReportJSON = "packing_report_json"
        case embeddingModelID = "embedding_model_id"
        case embeddingModelRevision = "embedding_model_revision"
        case chunkerVersion = "chunker_version"
        case retrievalConfigJSON = "retrieval_config_json"
        case corpusSnapshotHash = "corpus_snapshot_hash"
        case messageID = "message_id"
        case createdAt = "created_at"
    }
}
