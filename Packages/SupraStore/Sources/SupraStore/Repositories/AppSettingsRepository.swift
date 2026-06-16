import Foundation
import GRDB

public final class AppSettingsRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func getSetting<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        try writer.read { db in
            guard let record = try AppSettingRecord.fetchOne(db, key: key) else {
                return nil
            }
            return try JSONCoding.decode(T.self, from: record.valueJSON)
        }
    }

    public func setSetting<T: Encodable>(_ key: String, value: T) throws {
        let valueJSON = try JSONCoding.encode(value)
        try writer.write { db in
            let now = Date()
            if var existing = try AppSettingRecord.fetchOne(db, key: key) {
                existing.valueJSON = valueJSON
                existing.updatedAt = now
                try existing.update(db)
            } else {
                try AppSettingRecord(
                    key: key,
                    valueJSON: valueJSON,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
            }
        }
    }
}
