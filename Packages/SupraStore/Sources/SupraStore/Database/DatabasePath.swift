import Foundation

public enum DatabasePath {
    public static let databaseFileName = "SupraAI.sqlite"

    public static func appSupportDirectory(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "ai.supra.SupraAI"
    ) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = baseURL.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    public static func appSupportDatabaseURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "ai.supra.SupraAI"
    ) throws -> URL {
        try appSupportDirectory(
            fileManager: fileManager,
            bundleIdentifier: bundleIdentifier
        )
        .appendingPathComponent(databaseFileName, isDirectory: false)
    }
}
