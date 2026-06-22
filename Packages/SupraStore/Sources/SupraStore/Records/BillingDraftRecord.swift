import Foundation
import GRDB
import SupraCore

/// A generated set of billing entries for a day (Milestone 4). Versioned — each
/// regeneration is a new row, so prior drafts are never destroyed.
public struct BillingDraftRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "billing_drafts"

    public var id: String
    public var dayID: String
    public var version: Int
    public var modelID: String?
    /// Sensitivity slider value in [0, 1] used for this generation.
    public var sensitivity: Double
    public var status: String
    /// Deterministically-computed day reconciliation (total, gaps, overlaps, flags), as JSON.
    public var reconciliationJSON: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        dayID: String,
        version: Int,
        modelID: String? = nil,
        sensitivity: Double = BillingSensitivity.defaultValue,
        status: BillingDraftStatus = .draft,
        reconciliationJSON: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.dayID = dayID
        self.version = version
        self.modelID = modelID
        self.sensitivity = sensitivity
        self.status = status.rawValue
        self.reconciliationJSON = reconciliationJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case dayID = "day_id"
        case version
        case modelID = "model_id"
        case sensitivity
        case status
        case reconciliationJSON = "reconciliation_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
