import Foundation
import GRDB

public struct RemediationRecoverySummary: Sendable, Equatable {
    public let pendingCount: Int
    public let pendingByKind: [RemediationRecoveryKind: Int]

    public init(pendingCount: Int, pendingByKind: [RemediationRecoveryKind: Int]) {
        self.pendingCount = pendingCount
        self.pendingByKind = pendingByKind
    }
}

/// Durable, content-free recovery queue created by the remediation migration.
/// Rows identify product objects by opaque id; source text, filenames, queries,
/// private paths, and generated content are deliberately excluded.
public final class RemediationRecoveryRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func requireReview(
        kind: RemediationRecoveryKind,
        matterID: String?,
        relatedTable: String,
        relatedID: String
    ) throws -> RemediationRecoveryItemRecord {
        try writer.write { db in
            if let existing = try RemediationRecoveryItemRecord.fetchOne(
                db,
                sql: "SELECT * FROM remediation_recovery_items WHERE kind = ? AND related_table = ? AND related_id = ?",
                arguments: [kind.rawValue, relatedTable, relatedID]
            ) {
                return existing
            }
            let item = RemediationRecoveryItemRecord(
                kind: kind,
                matterID: matterID,
                relatedTable: relatedTable,
                relatedID: relatedID
            )
            try item.insert(db)
            return item
        }
    }

    public func pendingItem(
        kind: RemediationRecoveryKind,
        relatedID: String
    ) throws -> RemediationRecoveryItemRecord? {
        try writer.read { db in
            try RemediationRecoveryItemRecord.fetchOne(
                db,
                sql: "SELECT * FROM remediation_recovery_items WHERE kind = ? AND related_id = ? AND status = ?",
                arguments: [kind.rawValue, relatedID, RemediationRecoveryStatus.pending.rawValue]
            )
        }
    }

    public func pendingItems(limit: Int = 500) throws -> [RemediationRecoveryItemRecord] {
        let bounded = min(max(limit, 1), 2_000)
        return try writer.read { db in
            try RemediationRecoveryItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM remediation_recovery_items WHERE status = ? ORDER BY created_at, id LIMIT ?",
                arguments: [RemediationRecoveryStatus.pending.rawValue, bounded]
            )
        }
    }

    public func summary() throws -> RemediationRecoverySummary {
        let items = try pendingItems(limit: 2_000)
        let counts = Dictionary(grouping: items.compactMap { RemediationRecoveryKind(rawValue: $0.kind) }, by: { $0 })
            .mapValues(\.count)
        return RemediationRecoverySummary(pendingCount: items.count, pendingByKind: counts)
    }

    public func resolve(
        id: String,
        resolution: RemediationRecoveryResolution,
        actor: String
    ) throws {
        try writer.write { db in
            guard let item = try RemediationRecoveryItemRecord.fetchOne(db, key: id),
                  item.status == RemediationRecoveryStatus.pending.rawValue
            else { return }
            let now = Date()
            try db.execute(
                sql: "UPDATE remediation_recovery_items SET status = ?, resolution = ?, resolved_at = ? WHERE id = ?",
                arguments: [
                    RemediationRecoveryStatus.resolved.rawValue,
                    resolution.rawValue,
                    now,
                    id,
                ]
            )
            let event = AuditEventRecord(
                matterID: item.matterID,
                timestamp: now,
                eventType: "remediation_recovery_resolved",
                actor: String(actor.prefix(32)),
                summary: "Resolved a \(item.kind) remediation review as \(resolution.rawValue).",
                relatedTable: RemediationRecoveryItemRecord.databaseTableName,
                relatedID: item.id,
                metadataJSON: nil
            )
            try event.insert(db)
        }
    }
}
