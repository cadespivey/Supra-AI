import Foundation
import GRDB

/// A single calendar day's ScratchPad (Milestone 4). Exactly one row per date.
public struct ScratchPadDayRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "scratch_pad_days"

    public var id: String
    /// Calendar day in ISO `YYYY-MM-DD` form (unique).
    public var day: String
    /// Set when the day is finalized/locked after export; nil while open. Reversible.
    public var lockedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        day: String,
        lockedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.day = day
        self.lockedAt = lockedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case day
        case lockedAt = "locked_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
