import Foundation
import GRDB
import SupraCore

/// Singleton app-wide Document Intelligence setup state (Milestone 3).
public struct DocumentIntelligenceSettingsRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "document_intelligence_settings"

    /// Fixed primary key for the single settings row.
    public static let singletonID = "default"

    public var id: String
    public var selectedChatModelID: String?
    public var chatModelLastLoadedAt: Date?
    public var selectedEmbeddingModelID: String?
    public var embeddingModelLastTestedAt: Date?
    public var converterToolchainVersion: String?
    public var converterCapabilityJSON: String?
    public var ocrAvailable: Bool?
    public var ocrCheckedAt: Date?
    public var notificationPermissionStatus: String?
    public var storageInitializedAt: Date?
    public var setupCompletedAt: Date?
    public var setupInvalidatedReason: String?
    /// Internal rollout flag. Version 1 remains the shipping default until the
    /// benchmark promotion decision explicitly changes this value.
    public var chunkerVersion: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = DocumentIntelligenceSettingsRecord.singletonID,
        selectedChatModelID: String? = nil,
        chatModelLastLoadedAt: Date? = nil,
        selectedEmbeddingModelID: String? = nil,
        embeddingModelLastTestedAt: Date? = nil,
        converterToolchainVersion: String? = nil,
        converterCapabilityJSON: String? = nil,
        ocrAvailable: Bool? = nil,
        ocrCheckedAt: Date? = nil,
        notificationPermissionStatus: String? = nil,
        storageInitializedAt: Date? = nil,
        setupCompletedAt: Date? = nil,
        setupInvalidatedReason: String? = nil,
        chunkerVersion: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.selectedChatModelID = selectedChatModelID
        self.chatModelLastLoadedAt = chatModelLastLoadedAt
        self.selectedEmbeddingModelID = selectedEmbeddingModelID
        self.embeddingModelLastTestedAt = embeddingModelLastTestedAt
        self.converterToolchainVersion = converterToolchainVersion
        self.converterCapabilityJSON = converterCapabilityJSON
        self.ocrAvailable = ocrAvailable
        self.ocrCheckedAt = ocrCheckedAt
        self.notificationPermissionStatus = notificationPermissionStatus
        self.storageInitializedAt = storageInitializedAt
        self.setupCompletedAt = setupCompletedAt
        self.setupInvalidatedReason = setupInvalidatedReason
        self.chunkerVersion = chunkerVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case selectedChatModelID = "selected_chat_model_id"
        case chatModelLastLoadedAt = "chat_model_last_loaded_at"
        case selectedEmbeddingModelID = "selected_embedding_model_id"
        case embeddingModelLastTestedAt = "embedding_model_last_tested_at"
        case converterToolchainVersion = "converter_toolchain_version"
        case converterCapabilityJSON = "converter_capability_json"
        case ocrAvailable = "ocr_available"
        case ocrCheckedAt = "ocr_checked_at"
        case notificationPermissionStatus = "notification_permission_status"
        case storageInitializedAt = "storage_initialized_at"
        case setupCompletedAt = "setup_completed_at"
        case setupInvalidatedReason = "setup_invalidated_reason"
        case chunkerVersion = "chunker_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
