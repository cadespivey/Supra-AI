import Foundation
import GRDB

public final class MattersRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func createMatter(name: String) throws -> MatterRecord {
        try writer.write { db in
            let record = MatterRecord(name: name)
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

    public func renameMatter(id: String, name: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE matters SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [name, Date(), id]
            )
        }
    }
}
