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
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        structuredOutputVersionID: String? = nil,
        status: String = DocumentSourceSetStatus.pending.rawValue,
        mode: String = DocumentSourceSetMode.autoSource.rawValue,
        scopeJSON: String = "{}",
        retrievalQuery: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.matterID = matterID
        self.structuredOutputVersionID = structuredOutputVersionID
        self.status = status
        self.mode = mode
        self.scopeJSON = scopeJSON
        self.retrievalQuery = retrievalQuery
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
        case createdAt = "created_at"
    }
}
