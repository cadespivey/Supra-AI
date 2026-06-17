import Foundation
import GRDB
import SupraCore

public final class MattersRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func createMatter(
        name: String,
        jurisdiction: String = "Unspecified",
        partyPerspective: PartyPerspective = .neutral,
        court: String? = nil,
        judge: String? = nil,
        docketNumber: String? = nil,
        practiceArea: String? = nil,
        notes: String? = nil
    ) throws -> MatterRecord {
        let normalized = try Self.validateMatterFields(
            name: name,
            jurisdiction: jurisdiction,
            partyPerspective: partyPerspective
        )
        return try writer.write { db in
            let now = Date()
            let record = MatterRecord(
                name: normalized.name,
                jurisdiction: normalized.jurisdiction,
                partyPerspective: partyPerspective.rawValue,
                court: Self.trimOptional(court),
                judge: Self.trimOptional(judge),
                docketNumber: Self.trimOptional(docketNumber),
                practiceArea: Self.trimOptional(practiceArea),
                notes: Self.trimOptional(notes),
                createdAt: now,
                updatedAt: now
            )
            try record.insert(db)
            return record
        }
    }

    public func fetchMatters() throws -> [MatterRecord] {
        try writer.read { db in
            try MatterRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM matters
                WHERE deleted_at IS NULL
                ORDER BY updated_at DESC
                """
            )
        }
    }

    public func fetchMatter(id: String) throws -> MatterRecord? {
        try writer.read { db in
            try MatterRecord.fetchOne(
                db,
                sql: """
                SELECT * FROM matters
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [id]
            )
        }
    }

    public func renameMatter(id: String, name: String) throws {
        let trimmed = try Self.requireNonEmpty(name, fieldName: "name")
        try writer.write { db in
            try db.execute(
                sql: "UPDATE matters SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [trimmed, Date(), id]
            )
        }
    }

    public func updateMatter(
        id: String,
        name: String,
        jurisdiction: String,
        partyPerspective: PartyPerspective,
        court: String? = nil,
        judge: String? = nil,
        docketNumber: String? = nil,
        practiceArea: String? = nil,
        notes: String? = nil
    ) throws {
        let normalized = try Self.validateMatterFields(
            name: name,
            jurisdiction: jurisdiction,
            partyPerspective: partyPerspective
        )
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE matters
                SET name = ?,
                    jurisdiction = ?,
                    party_perspective = ?,
                    court = ?,
                    judge = ?,
                    docket_number = ?,
                    practice_area = ?,
                    notes = ?,
                    updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [
                    normalized.name,
                    normalized.jurisdiction,
                    partyPerspective.rawValue,
                    Self.trimOptional(court),
                    Self.trimOptional(judge),
                    Self.trimOptional(docketNumber),
                    Self.trimOptional(practiceArea),
                    Self.trimOptional(notes),
                    Date(),
                    id
                ]
            )
        }
    }

    public func softDeleteMatter(id: String, deletedAt: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE matters
                SET deleted_at = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [deletedAt, deletedAt, id]
            )
        }
    }

    private static func validateMatterFields(
        name: String,
        jurisdiction: String,
        partyPerspective: PartyPerspective
    ) throws -> (name: String, jurisdiction: String) {
        (
            try requireNonEmpty(name, fieldName: "name"),
            try requireNonEmpty(jurisdiction, fieldName: "jurisdiction")
        )
    }

    private static func requireNonEmpty(_ value: String, fieldName: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MatterRepositoryError.requiredFieldMissing(fieldName)
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

public enum MatterRepositoryError: Error, Equatable, Sendable {
    case requiredFieldMissing(String)
}
