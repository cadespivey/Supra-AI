import Foundation
import GRDB

public final class SupraDatabase: @unchecked Sendable {
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try SupraMigrator.makeMigrator().migrate(writer)
    }

    public convenience init(url: URL) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try self.init(writer: queue)
    }

    public static func openAppSupportDatabase(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "ai.supra.SupraAI"
    ) throws -> SupraDatabase {
        let url = try DatabasePath.appSupportDatabaseURL(
            fileManager: fileManager,
            bundleIdentifier: bundleIdentifier
        )
        return try SupraDatabase(url: url)
    }

    #if DEBUG
    public func resetForDebug() throws {
        try writer.write { db in
            try SupraMigrator.deleteAllTables(db)
        }
        try SupraMigrator.makeMigrator().migrate(writer)
    }
    #endif
}
