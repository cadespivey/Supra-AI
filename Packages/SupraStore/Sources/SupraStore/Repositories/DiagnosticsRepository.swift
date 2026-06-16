import Foundation
import GRDB

public final class DiagnosticsRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func recordDiagnosticEvent(_ event: DiagnosticEventRecord) throws {
        try writer.write { db in
            try event.insert(db)
        }
    }

    public func fetchRecentDiagnostics(limit: Int = 100) throws -> [DiagnosticEventRecord] {
        try writer.read { db in
            try DiagnosticEventRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM diagnostic_events
                ORDER BY timestamp DESC
                LIMIT ?
                """,
                arguments: [max(0, limit)]
            )
        }
    }
}
