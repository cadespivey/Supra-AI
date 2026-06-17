import Foundation
import GRDB
import SupraCore

/// Content-addressed raw imported file blob (Milestone 3). Shared across
/// document instances to avoid duplicate file storage.
public struct DocumentBlobRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_blobs"

    public var id: String
    public var sha256: String
    public var byteSize: Int
    public var originalExtension: String
    public var managedRelativePath: String
    public var mimeType: String?
    public var utType: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        sha256: String,
        byteSize: Int,
        originalExtension: String,
        managedRelativePath: String,
        mimeType: String? = nil,
        utType: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sha256 = sha256
        self.byteSize = byteSize
        self.originalExtension = originalExtension
        self.managedRelativePath = managedRelativePath
        self.mimeType = mimeType
        self.utType = utType
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sha256
        case byteSize = "byte_size"
        case originalExtension = "original_extension"
        case managedRelativePath = "managed_relative_path"
        case mimeType = "mime_type"
        case utType = "ut_type"
        case createdAt = "created_at"
    }
}
