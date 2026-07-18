import Foundation
import GRDB
import SupraCore

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
    public var verificationStatus: String
    public var verificationVersion: String?
    public var verificationJSON: String?
    public var verifiedAt: Date?
    public var promptBuilderVersion: String?
    public var assuranceState: String?
    public var staleReason: String?
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
        verificationStatus: String = OutputVerificationStatus.legacyUnverified.rawValue,
        verificationVersion: String? = nil,
        verificationJSON: String? = nil,
        verifiedAt: Date? = nil,
        promptBuilderVersion: String? = nil,
        assuranceState: String? = nil,
        staleReason: String? = nil,
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
        self.verificationStatus = verificationStatus
        self.verificationVersion = verificationVersion
        self.verificationJSON = verificationJSON
        self.verifiedAt = verifiedAt
        self.promptBuilderVersion = promptBuilderVersion
        self.assuranceState = assuranceState
        self.staleReason = staleReason
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
        case verificationStatus = "verification_status"
        case verificationVersion = "verification_version"
        case verificationJSON = "verification_json"
        case verifiedAt = "verified_at"
        case promptBuilderVersion = "prompt_builder_version"
        case assuranceState = "assurance_state"
        case staleReason = "stale_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
