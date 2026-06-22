import Foundation
import GRDB
import SupraCore

/// A file dropped on a day (or a specific entry) and used as billing evidence
/// (Milestone 4). The file itself is imported as a `MatterDocumentRecord`; this row
/// links it to the day and carries the extracted evidence signals.
public struct ScratchPadAttachmentRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "scratch_pad_attachments"

    public var id: String
    public var dayID: String
    /// The entry this was dropped on, or nil if attached to the day generally.
    public var entryID: String?
    /// The imported document instance backing this attachment, once imported.
    public var matterDocumentID: String?
    /// The resolved matter, or nil until resolved/corrected.
    public var matterID: String?
    public var evidenceKind: String
    /// JSON of extracted signals (page/word counts, email headers/dates, file-stamp, classifier output).
    public var evidenceSignalsJSON: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        dayID: String,
        entryID: String? = nil,
        matterDocumentID: String? = nil,
        matterID: String? = nil,
        evidenceKind: BillingEvidenceKind = .other,
        evidenceSignalsJSON: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.dayID = dayID
        self.entryID = entryID
        self.matterDocumentID = matterDocumentID
        self.matterID = matterID
        self.evidenceKind = evidenceKind.rawValue
        self.evidenceSignalsJSON = evidenceSignalsJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case dayID = "day_id"
        case entryID = "entry_id"
        case matterDocumentID = "matter_document_id"
        case matterID = "matter_id"
        case evidenceKind = "evidence_kind"
        case evidenceSignalsJSON = "evidence_signals_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
