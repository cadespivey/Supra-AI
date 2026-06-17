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
}
