import Foundation
import GRDB
import SupraCore

/// One billable line within a draft (Milestone 4) — the unit exported to LEDES/CSV.
/// `seq` is a stable line id used to preserve manual edits across regeneration;
/// `userEdited` marks lines the attorney has changed.
public struct BillingLineItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "billing_line_items"

    public var id: String
    public var draftID: String
    public var seq: Int
    public var clientID: String?
    public var matterID: String?
    public var narrative: String
    public var hours: Double
    public var workDate: String
    public var utbmsTaskCode: String?
    public var utbmsActivityCode: String?
    public var timekeeperID: String?
    public var rate: Double?
    public var confidence: String
    public var evidenceJSON: String?
    public var codeNote: String?
    public var userEdited: Bool
    public var sourceEntryIDsJSON: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        draftID: String,
        seq: Int,
        clientID: String? = nil,
        matterID: String? = nil,
        narrative: String,
        hours: Double,
        workDate: String,
        utbmsTaskCode: String? = nil,
        utbmsActivityCode: String? = nil,
        timekeeperID: String? = nil,
        rate: Double? = nil,
        confidence: BillingConfidence = .medium,
        evidenceJSON: String? = nil,
        codeNote: String? = nil,
        userEdited: Bool = false,
        sourceEntryIDsJSON: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.draftID = draftID
        self.seq = seq
        self.clientID = clientID
        self.matterID = matterID
        self.narrative = narrative
        self.hours = hours
        self.workDate = workDate
        self.utbmsTaskCode = utbmsTaskCode
        self.utbmsActivityCode = utbmsActivityCode
        self.timekeeperID = timekeeperID
        self.rate = rate
        self.confidence = confidence.rawValue
        self.evidenceJSON = evidenceJSON
        self.codeNote = codeNote
        self.userEdited = userEdited
        self.sourceEntryIDsJSON = sourceEntryIDsJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Decoded stable ids of the note entries that produced this line.
    public var sourceEntryIDs: [String] { ScratchPadJSON.decodeStrings(sourceEntryIDsJSON) }

    private enum CodingKeys: String, CodingKey {
        case id
        case draftID = "draft_id"
        case seq
        case clientID = "client_id"
        case matterID = "matter_id"
        case narrative
        case hours
        case workDate = "work_date"
        case utbmsTaskCode = "utbms_task_code"
        case utbmsActivityCode = "utbms_activity_code"
        case timekeeperID = "timekeeper_id"
        case rate
        case confidence
        case evidenceJSON = "evidence_json"
        case codeNote = "code_note"
        case userEdited = "user_edited"
        case sourceEntryIDsJSON = "source_entry_ids_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
