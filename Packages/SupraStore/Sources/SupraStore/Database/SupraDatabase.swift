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

    /// An in-memory database (migrations applied). Used as the app's absolute
    /// last-resort store so a launch can degrade gracefully instead of crashing
    /// when no on-disk database can be opened.
    public static func inMemory() throws -> SupraDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return try SupraDatabase(writer: DatabaseQueue(configuration: configuration))
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
