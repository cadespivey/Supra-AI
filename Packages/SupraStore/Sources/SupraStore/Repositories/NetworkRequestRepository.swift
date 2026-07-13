import Foundation
import GRDB

public final class NetworkRequestRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func recordRequest(_ record: NetworkRequestRecord) throws -> NetworkRequestRecord {
        try writer.write { db in
            try record.insert(db)
            return record
        }
    }

    @discardableResult
    public func createRequest(
        domain: String,
        method: String,
        endpoint: String,
        approved: Bool,
        relatedResearchSessionID: String? = nil,
        blockedReason: String? = nil,
        requestMetadataJSON: String? = nil
    ) throws -> NetworkRequestRecord {
        let record = NetworkRequestRecord(
            domain: domain,
            method: method,
            endpoint: endpoint,
            approved: approved,
            relatedResearchSessionID: relatedResearchSessionID,
            blockedReason: blockedReason,
            requestMetadataJSON: requestMetadataJSON
        )
        return try recordRequest(record)
    }

    public func finishRequest(
        id: String,
        statusCode: Int?,
        errorMessage: String? = nil,
        responseMetadataJSON: String? = nil
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE network_requests
                SET status_code = ?,
                    error_message = ?,
                    response_metadata_json = ?
                WHERE id = ?
                """,
                arguments: [statusCode, errorMessage, responseMetadataJSON, id]
            )
        }
    }

    public func fetchRecent(limit: Int = 100) throws -> [NetworkRequestRecord] {
        try writer.read { db in
            try NetworkRequestRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM network_requests
                ORDER BY timestamp DESC
                LIMIT ?
                """,
                arguments: [max(0, limit)]
            )
        }
    }

    /// Removes query material—including legacy unkeyed fingerprints—from stored
    /// request audit metadata. Header metadata is retained when the JSON is valid;
    /// malformed legacy metadata is cleared in full so a private value cannot
    /// survive merely because it could not be parsed.
    @discardableResult
    public func removeStoredQueryMetadata() throws -> Int {
        try writer.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, request_metadata_json FROM network_requests WHERE request_metadata_json IS NOT NULL"
            )
            var changed = 0
            for row in rows {
                let id: String = row["id"]
                let raw: String = row["request_metadata_json"]
                guard let data = raw.data(using: .utf8),
                      var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    try db.execute(
                        sql: "UPDATE network_requests SET request_metadata_json = NULL WHERE id = ?",
                        arguments: [id]
                    )
                    changed += 1
                    continue
                }
                guard object.removeValue(forKey: "query") != nil else { continue }
                let replacement: String?
                if object.isEmpty {
                    replacement = nil
                } else {
                    let sanitized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                    replacement = String(data: sanitized, encoding: .utf8)
                }
                try db.execute(
                    sql: "UPDATE network_requests SET request_metadata_json = ? WHERE id = ?",
                    arguments: [replacement, id]
                )
                changed += 1
            }
            return changed
        }
    }
}
