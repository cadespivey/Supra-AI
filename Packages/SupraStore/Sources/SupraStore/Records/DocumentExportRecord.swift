import Foundation
import GRDB
import SupraCore

/// An exported generated document output file (Milestone 3).
public struct DocumentExportRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_exports"

    public var id: String
    public var structuredOutputID: String?
    public var structuredOutputVersionID: String?
    public var matterID: String
    public var format: String
    public var managedRelativePath: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        structuredOutputID: String? = nil,
        structuredOutputVersionID: String? = nil,
        matterID: String,
        format: String,
        managedRelativePath: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.structuredOutputID = structuredOutputID
        self.structuredOutputVersionID = structuredOutputVersionID
        self.matterID = matterID
        self.format = format
        self.managedRelativePath = managedRelativePath
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case structuredOutputID = "structured_output_id"
        case structuredOutputVersionID = "structured_output_version_id"
        case matterID = "matter_id"
        case format
        case managedRelativePath = "managed_relative_path"
        case createdAt = "created_at"
    }
}
