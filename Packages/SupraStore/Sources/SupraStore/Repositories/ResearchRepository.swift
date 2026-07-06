import Foundation
import GRDB
import SupraCore

public final class ResearchRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func createSession(
        matterID: String,
        title: String,
        issueText: String,
        jurisdiction: String,
        preferredCourts: [String] = [],
        excludedCourts: [String] = [],
        dateRangeStart: Date? = nil,
        dateRangeEnd: Date? = nil,
        status: ResearchSessionStatus = .draft
    ) throws -> ResearchSessionRecord {
        let title = try Self.requireNonEmpty(title, fieldName: "title")
        let issueText = try Self.requireNonEmpty(issueText, fieldName: "issue_text")
        let jurisdiction = try Self.requireNonEmpty(jurisdiction, fieldName: "jurisdiction")
        let preferredCourtsJSON = try JSONCoding.encode(preferredCourts)
        let excludedCourtsJSON = try JSONCoding.encode(excludedCourts)

        return try writer.write { db in
            let now = Date()
            let record = ResearchSessionRecord(
                matterID: matterID,
                title: title,
                issueText: issueText,
                jurisdiction: jurisdiction,
                preferredCourtsJSON: preferredCourtsJSON,
                excludedCourtsJSON: excludedCourtsJSON,
                dateRangeStart: dateRangeStart,
                dateRangeEnd: dateRangeEnd,
                status: status.rawValue,
                createdAt: now,
                updatedAt: now
            )
            try record.insert(db)
            return record
        }
    }

    @discardableResult
    public func createQuery(
        researchSessionID: String,
        queryText: String,
        queryIndex: Int,
        courtFilter: String? = nil,
        dateFiledAfter: Date? = nil,
        dateFiledBefore: Date? = nil,
        status: ResearchQueryStatus = .draft
    ) throws -> ResearchQueryRecord {
        let queryText = try Self.requireNonEmpty(queryText, fieldName: "query_text")
        return try writer.write { db in
            let now = Date()
            let record = ResearchQueryRecord(
                researchSessionID: researchSessionID,
                queryText: queryText,
                queryIndex: queryIndex,
                courtFilter: Self.trimOptional(courtFilter),
                dateFiledAfter: dateFiledAfter,
                dateFiledBefore: dateFiledBefore,
                status: status.rawValue,
                createdAt: now,
                updatedAt: now
            )
            try record.insert(db)
            return record
        }
    }

    @discardableResult
    public func insertResult(_ result: ResearchResultRecord) throws -> ResearchResultRecord {
        try writer.write { db in
            try result.insert(db)
            return result
        }
    }

    public func updateSessionStatus(
        sessionID: String,
        status: ResearchSessionStatus,
        completedAt: Date? = nil
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE research_sessions
                SET status = ?, completed_at = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [status.rawValue, completedAt, Date(), sessionID]
            )
        }
    }

    public func updateQueryExecution(
        queryID: String,
        status: ResearchQueryStatus,
        resultCount: Int? = nil,
        nextURL: String? = nil,
        executedAt: Date? = Date(),
        requestMetadataJSON: String? = nil,
        responseMetadataJSON: String? = nil,
        errorMessage: String? = nil
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE research_queries
                SET status = ?,
                    result_count = ?,
                    next_url = ?,
                    executed_at = ?,
                    request_metadata_json = ?,
                    response_metadata_json = ?,
                    error_message = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    status.rawValue,
                    resultCount,
                    nextURL,
                    executedAt,
                    requestMetadataJSON,
                    responseMetadataJSON,
                    errorMessage,
                    Date(),
                    queryID
                ]
            )
        }
    }

    /// Edits a saved query's text (results-view review). Resets its run state to
    /// `approved` and clears the prior run's counters so a re-run replaces, rather
    /// than layers on top of, the old outcome.
    public func updateQueryText(queryID: String, text: String) throws {
        let text = try Self.requireNonEmpty(text, fieldName: "query_text")
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE research_queries
                SET query_text = ?,
                    status = ?,
                    result_count = NULL,
                    next_url = NULL,
                    error_message = NULL,
                    executed_at = NULL,
                    updated_at = ?
                WHERE id = ?
                """,
                arguments: [text, ResearchQueryStatus.approved.rawValue, Date(), queryID]
            )
        }
    }

    /// Clears a query's stored results so a re-run starts clean.
    public func deleteResults(queryID: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM research_results WHERE research_query_id = ?",
                arguments: [queryID]
            )
        }
    }

    public func updateResultReviewState(
        resultID: String,
        reviewState: ResearchResultReviewState
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE research_results
                SET review_state = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [reviewState.rawValue, Date(), resultID]
            )
        }
    }

    public func fetchSessions(matterID: String) throws -> [ResearchSessionRecord] {
        try writer.read { db in
            try ResearchSessionRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM research_sessions
                WHERE matter_id = ?
                ORDER BY updated_at DESC
                """,
                arguments: [matterID]
            )
        }
    }

    public func fetchQueries(sessionID: String) throws -> [ResearchQueryRecord] {
        try writer.read { db in
            try ResearchQueryRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM research_queries
                WHERE research_session_id = ?
                ORDER BY query_index ASC
                """,
                arguments: [sessionID]
            )
        }
    }

    public func fetchResults(queryID: String) throws -> [ResearchResultRecord] {
        try writer.read { db in
            try ResearchResultRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM research_results
                WHERE research_query_id = ?
                ORDER BY created_at ASC
                """,
                arguments: [queryID]
            )
        }
    }

    public func fetchResult(resultID: String) throws -> ResearchResultRecord? {
        try writer.read { db in
            try ResearchResultRecord.fetchOne(
                db,
                sql: "SELECT * FROM research_results WHERE id = ?",
                arguments: [resultID]
            )
        }
    }

    private static func requireNonEmpty(_ value: String, fieldName: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ResearchRepositoryError.requiredFieldMissing(fieldName)
        }
        return trimmed
    }

    private static func trimOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public enum ResearchRepositoryError: Error, Equatable, Sendable {
    case requiredFieldMissing(String)
}
