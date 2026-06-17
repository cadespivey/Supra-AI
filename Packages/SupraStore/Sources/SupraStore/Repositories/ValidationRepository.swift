import Foundation
import GRDB
import SupraCore

public final class ValidationRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func createValidationRun(
        modelID: String,
        suiteID: String,
        suiteVersion: Int
    ) throws -> ModelValidationRunRecord {
        try writer.write { db in
            let now = Date()
            let record = ModelValidationRunRecord(
                modelID: modelID,
                suiteID: suiteID,
                suiteVersion: suiteVersion,
                status: ValidationRunStatus.partial.rawValue,
                startedAt: now,
                createdAt: now,
                updatedAt: now
            )
            try record.insert(db)
            return record
        }
    }

    public func appendValidationTest(
        runID: String,
        testID: String,
        name: String,
        status: ValidationTestStatus,
        outputExcerpt: String,
        warnings: [String] = [],
        errors: [String] = [],
        startedAt: Date = Date(),
        completedAt: Date? = Date()
    ) throws -> ModelValidationTestRecord {
        let warningsJSON = try JSONCoding.encode(warnings)
        let errorsJSON = try JSONCoding.encode(errors)
        return try writer.write { db in
            let record = ModelValidationTestRecord(
                runID: runID,
                testID: testID,
                name: name,
                status: status.rawValue,
                outputExcerpt: outputExcerpt,
                warningsJSON: warningsJSON,
                errorsJSON: errorsJSON,
                startedAt: startedAt,
                completedAt: completedAt
            )
            try record.insert(db)
            return record
        }
    }

    public func completeValidationRun(
        runID: String,
        status: ValidationRunStatus,
        summary: String? = nil,
        warnings: [String] = [],
        errors: [String] = [],
        completedAt: Date = Date()
    ) throws {
        let warningsJSON = try JSONCoding.encode(warnings)
        let errorsJSON = try JSONCoding.encode(errors)
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE model_validation_runs
                SET status = ?,
                    completed_at = ?,
                    summary = ?,
                    warnings_json = ?,
                    errors_json = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                arguments: [status.rawValue, completedAt, summary, warningsJSON, errorsJSON, Date(), runID]
            )
        }
    }

    /// Marks any run that never reached a terminal state (no `completed_at`) as
    /// cancelled. A `completed_at` of NULL is the seed state set by
    /// `createValidationRun`; only `completeValidationRun` clears it. A run left
    /// in that state was abandoned — typically because the app quit or the
    /// runtime service died mid-suite. Call at launch so such rows don't linger
    /// indistinguishable from in-progress runs.
    public func markUnfinishedRunsCancelled(completedAt: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE model_validation_runs
                SET status = ?, completed_at = ?, updated_at = ?
                WHERE completed_at IS NULL
                """,
                arguments: [ValidationRunStatus.cancelled.rawValue, completedAt, completedAt]
            )
        }
    }

    public func fetchValidationRuns(modelID: String? = nil) throws -> [ModelValidationRunRecord] {
        try writer.read { db in
            if let modelID {
                return try ModelValidationRunRecord.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM model_validation_runs
                    WHERE model_id = ?
                    ORDER BY started_at DESC
                    """,
                    arguments: [modelID]
                )
            } else {
                return try ModelValidationRunRecord.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM model_validation_runs
                    ORDER BY started_at DESC
                    """
                )
            }
        }
    }

    public func fetchValidationTests(runID: String) throws -> [ModelValidationTestRecord] {
        try writer.read { db in
            try ModelValidationTestRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM model_validation_tests
                WHERE run_id = ?
                ORDER BY started_at ASC
                """,
                arguments: [runID]
            )
        }
    }
}
