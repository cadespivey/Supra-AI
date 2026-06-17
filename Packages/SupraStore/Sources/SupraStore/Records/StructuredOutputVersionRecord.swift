import Foundation
import GRDB

public struct StructuredOutputVersionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "structured_output_versions"

    public var id: String
    public var structuredOutputID: String
    public var versionIndex: Int
    public var parentVersionID: String?
    public var contentMarkdown: String
    public var requiredSectionsJSON: String
    public var presentSectionsJSON: String
    public var missingSectionsJSON: String
    public var repairReason: String?
    public var generationSessionID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        structuredOutputID: String,
        versionIndex: Int,
        parentVersionID: String? = nil,
        contentMarkdown: String,
        requiredSectionsJSON: String = "[]",
        presentSectionsJSON: String = "[]",
        missingSectionsJSON: String = "[]",
        repairReason: String? = nil,
        generationSessionID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.structuredOutputID = structuredOutputID
        self.versionIndex = versionIndex
        self.parentVersionID = parentVersionID
        self.contentMarkdown = contentMarkdown
        self.requiredSectionsJSON = requiredSectionsJSON
        self.presentSectionsJSON = presentSectionsJSON
        self.missingSectionsJSON = missingSectionsJSON
        self.repairReason = repairReason
        self.generationSessionID = generationSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case structuredOutputID = "structured_output_id"
        case versionIndex = "version_index"
        case parentVersionID = "parent_version_id"
        case contentMarkdown = "content_markdown"
        case requiredSectionsJSON = "required_sections_json"
        case presentSectionsJSON = "present_sections_json"
        case missingSectionsJSON = "missing_sections_json"
        case repairReason = "repair_reason"
        case generationSessionID = "generation_session_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
