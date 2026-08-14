import Foundation
import GRDB
import SupraCore

/// An app-managed export artifact. Structured Output identifiers can be nil for
/// compatibility artifacts that historically owned a separate eligibility path.
public struct DocumentExportRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_exports"

    public var id: String
    public var structuredOutputID: String?
    public var structuredOutputVersionID: String?
    public var publicationIntentID: String?
    public var matterID: String
    public var format: String
    public var managedRelativePath: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        structuredOutputID: String? = nil,
        structuredOutputVersionID: String? = nil,
        publicationIntentID: String? = nil,
        matterID: String,
        format: String,
        managedRelativePath: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.structuredOutputID = structuredOutputID
        self.structuredOutputVersionID = structuredOutputVersionID
        self.publicationIntentID = publicationIntentID
        self.matterID = matterID
        self.format = format
        self.managedRelativePath = managedRelativePath
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case structuredOutputID = "structured_output_id"
        case structuredOutputVersionID = "structured_output_version_id"
        case publicationIntentID = "publication_intent_id"
        case matterID = "matter_id"
        case format
        case managedRelativePath = "managed_relative_path"
        case createdAt = "created_at"
    }
}
