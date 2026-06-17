import Foundation
import GRDB
import SupraCore

public final class StructuredOutputRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func createOutput(
        matterID: String,
        title: String,
        outputType: StructuredOutputType,
        chatID: String? = nil,
        researchSessionID: String? = nil,
        status: StructuredOutputStatus = .draft
    ) throws -> StructuredOutputRecord {
        let title = try Self.requireNonEmpty(title, fieldName: "title")
        return try writer.write { db in
            let now = Date()
            let record = StructuredOutputRecord(
                matterID: matterID,
                chatID: chatID,
                researchSessionID: researchSessionID,
                title: title,
                outputType: outputType.rawValue,
                status: status.rawValue,
                createdAt: now,
                updatedAt: now
            )
            try record.insert(db)
            return record
        }
    }

    @discardableResult
    public func createVersion(
        structuredOutputID: String,
        versionIndex: Int,
        contentMarkdown: String,
        requiredSections: [String],
        presentSections: [String],
        missingSections: [String],
        parentVersionID: String? = nil,
        repairReason: String? = nil,
        generationSessionID: String? = nil,
        makeActive: Bool = true
    ) throws -> StructuredOutputVersionRecord {
        let requiredSectionsJSON = try JSONCoding.encode(requiredSections)
        let presentSectionsJSON = try JSONCoding.encode(presentSections)
        let missingSectionsJSON = try JSONCoding.encode(missingSections)
        return try writer.write { db in
            let now = Date()
            let record = StructuredOutputVersionRecord(
                structuredOutputID: structuredOutputID,
                versionIndex: versionIndex,
                parentVersionID: parentVersionID,
                contentMarkdown: contentMarkdown,
                requiredSectionsJSON: requiredSectionsJSON,
                presentSectionsJSON: presentSectionsJSON,
                missingSectionsJSON: missingSectionsJSON,
                repairReason: repairReason,
                generationSessionID: generationSessionID,
                createdAt: now,
                updatedAt: now
            )
            try record.insert(db)
            if makeActive {
                try db.execute(
                    sql: """
                    UPDATE structured_outputs
                    SET active_version_id = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [record.id, now, structuredOutputID]
                )
            }
            return record
        }
    }

    public func updateStatus(outputID: String, status: StructuredOutputStatus) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE structured_outputs SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, Date(), outputID]
            )
        }
    }

    public func fetchOutputs(matterID: String) throws -> [StructuredOutputRecord] {
        try writer.read { db in
            try StructuredOutputRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM structured_outputs
                WHERE matter_id = ? AND deleted_at IS NULL
                ORDER BY updated_at DESC
                """,
                arguments: [matterID]
            )
        }
    }

    public func fetchVersions(structuredOutputID: String) throws -> [StructuredOutputVersionRecord] {
        try writer.read { db in
            try StructuredOutputVersionRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM structured_output_versions
                WHERE structured_output_id = ?
                ORDER BY version_index DESC
                """,
                arguments: [structuredOutputID]
            )
        }
    }

    private static func requireNonEmpty(_ value: String, fieldName: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StructuredOutputRepositoryError.requiredFieldMissing(fieldName)
        }
        return trimmed
    }
}

public enum StructuredOutputRepositoryError: Error, Equatable, Sendable {
    case requiredFieldMissing(String)
}
