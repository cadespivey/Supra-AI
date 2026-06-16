import Foundation
import GRDB

public struct DiagnosticEventRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "diagnostic_events"

    public var id: String
    public var timestamp: Date
    public var severity: String
    public var category: String?
    public var message: String
    public var technicalDetails: String?
    public var generationID: String?
    public var modelID: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        severity: String,
        category: String? = nil,
        message: String,
        technicalDetails: String? = nil,
        generationID: String? = nil,
        modelID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.category = category
        self.message = message
        self.technicalDetails = technicalDetails
        self.generationID = generationID
        self.modelID = modelID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case severity
        case category
        case message
        case technicalDetails = "technical_details"
        case generationID = "generation_id"
        case modelID = "model_id"
        case createdAt = "created_at"
    }
}
