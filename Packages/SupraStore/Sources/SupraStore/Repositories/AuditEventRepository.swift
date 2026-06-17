import Foundation
import GRDB

public final class AuditEventRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func recordEvent(_ event: AuditEventRecord) throws -> AuditEventRecord {
        try writer.write { db in
            try event.insert(db)
            return event
        }
    }

    @discardableResult
    public func recordEvent(
        matterID: String? = nil,
        eventType: String,
        actor: String,
        summary: String,
        relatedTable: String? = nil,
        relatedID: String? = nil,
        metadataJSON: String? = nil
    ) throws -> AuditEventRecord {
        let event = AuditEventRecord(
            matterID: matterID,
            eventType: eventType,
            actor: actor,
            summary: summary,
            relatedTable: relatedTable,
            relatedID: relatedID,
            metadataJSON: metadataJSON
        )
        return try recordEvent(event)
    }

    public func fetchEvents(matterID: String, limit: Int = 100) throws -> [AuditEventRecord] {
        try writer.read { db in
            try AuditEventRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM audit_events
                WHERE matter_id = ?
                ORDER BY timestamp DESC
                LIMIT ?
                """,
                arguments: [matterID, max(0, limit)]
            )
        }
    }
}
