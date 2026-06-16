import Foundation
import GRDB

public final class ExportedReportsRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func recordExportedReport(_ report: ExportedReportRecord) throws {
        try writer.write { db in
            try report.insert(db)
        }
    }

    public func fetchExportedReports(validationRunID: String? = nil) throws -> [ExportedReportRecord] {
        try writer.read { db in
            if let validationRunID {
                return try ExportedReportRecord.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM exported_reports
                    WHERE validation_run_id = ?
                    ORDER BY created_at DESC
                    """,
                    arguments: [validationRunID]
                )
            } else {
                return try ExportedReportRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM exported_reports ORDER BY created_at DESC"
                )
            }
        }
    }
}
