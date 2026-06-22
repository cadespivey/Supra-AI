import Foundation
import GRDB

/// One line/entry of a day's running note (Milestone 4). `createdAt` doubles as
/// the silent auto-timestamp used as time evidence; `updatedAt` records the last edit.
public struct ScratchPadEntryRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "scratch_pad_entries"

    public var id: String
    public var dayID: String
    public var seq: Int
    public var text: String
    /// JSON array of resolved `@matter` matter IDs in this line (nil/empty -> inferred).
    public var mentionsJSON: String?
    /// JSON array of `#tags` in this line.
    public var tagsJSON: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        dayID: String,
        seq: Int,
        text: String,
        mentionsJSON: String? = nil,
        tagsJSON: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.dayID = dayID
        self.seq = seq
        self.text = text
        self.mentionsJSON = mentionsJSON
        self.tagsJSON = tagsJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Decoded `@matter` IDs (empty if none/unparseable).
    public var mentions: [String] { ScratchPadJSON.decodeStrings(mentionsJSON) }
    /// Decoded `#tags` (empty if none/unparseable).
    public var tags: [String] { ScratchPadJSON.decodeStrings(tagsJSON) }

    private enum CodingKeys: String, CodingKey {
        case id
        case dayID = "day_id"
        case seq
        case text
        case mentionsJSON = "mentions_json"
        case tagsJSON = "tags_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// JSON helpers for ScratchPad string-array columns (mentions, tags, source entry ids).
public enum ScratchPadJSON {
    public static func encodeStrings(_ values: [String]) -> String? {
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(cleaned) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodeStrings(_ json: String?) -> [String] {
        guard let json,
              let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values
    }
}
