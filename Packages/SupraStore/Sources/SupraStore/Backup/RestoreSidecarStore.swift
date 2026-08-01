import Darwin
import Foundation

/// Coarse, content-free failure categories that remain safe to persist after
/// the live database writer has been closed for restore staging.
public enum RestoreStagingFailureReason: String, Codable, Equatable, Sendable {
    case liveDatabasePathMismatch
    case liveDatabaseCloseFailed
    case selectedSnapshotUnavailable
    case selectedSnapshotChanged
    case selectedSnapshotIncompatible
    case liveStateInvalid
    case stagingVolumeMismatch
    case copiedStateInvalid
    case stagingIOFailed
}

/// Database-independent handoff for a failed staging attempt. It deliberately
/// contains neither paths, source labels, error descriptions, nor user data.
public struct RestoreStagingFailureRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let lastFailureFileName = "last-restore-staging-failure.json"

    public let schemaVersion: Int
    public let operationID: String
    public let reason: RestoreStagingFailureReason
    public let failedAt: Date

    fileprivate init(operationID: UUID, reason: RestoreStagingFailureReason, failedAt: Date) {
        schemaVersion = Self.currentSchemaVersion
        self.operationID = operationID.uuidString.lowercased()
        self.reason = reason
        self.failedAt = Date(timeIntervalSince1970: floor(failedAt.timeIntervalSince1970))
    }

    fileprivate static func encode(_ record: RestoreStagingFailureRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(record)
    }

    fileprivate static func decode(_ data: Data) throws -> RestoreStagingFailureRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RestoreStagingFailureRecord.self, from: data)
    }
}

/// Durable read/write/ack boundary for restore sidecars that cannot depend on
/// the live SQLite store. Every mutating call synchronizes its containing
/// directory before returning.
public enum RestoreSidecarStore {
    @discardableResult
    public static func recordStagingFailure(
        operationID: UUID,
        reason: RestoreStagingFailureReason,
        stagingRootDirectory: URL,
        failedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> RestoreStagingFailureRecord {
        try fileManager.createDirectory(
            at: stagingRootDirectory,
            withIntermediateDirectories: true
        )
        let record = RestoreStagingFailureRecord(
            operationID: operationID,
            reason: reason,
            failedAt: failedAt
        )
        let destination = stagingRootDirectory
            .appendingPathComponent(RestoreStagingFailureRecord.lastFailureFileName)
        try SystemRestoreFileOperations(fileManager: fileManager)
            .writeIntentAtomically(RestoreStagingFailureRecord.encode(record), to: destination)
        return record
    }

    public static func readStagingFailure(
        stagingRootDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> RestoreStagingFailureRecord? {
        let source = stagingRootDirectory
            .appendingPathComponent(RestoreStagingFailureRecord.lastFailureFileName)
        guard itemExists(at: source) else { return nil }
        guard RestoreValidation.isContainedRegularFile(
            source,
            in: stagingRootDirectory,
            fileManager: fileManager
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let record = try RestoreStagingFailureRecord.decode(Data(contentsOf: source))
        guard record.schemaVersion == RestoreStagingFailureRecord.currentSchemaVersion,
              let operationID = UUID(uuidString: record.operationID),
              operationID.uuidString.lowercased() == record.operationID
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record
    }

    public static func acknowledgeStagingFailure(
        stagingRootDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let destination = stagingRootDirectory
            .appendingPathComponent(RestoreStagingFailureRecord.lastFailureFileName)
        guard itemExists(at: destination) else { return }
        guard RestoreValidation.isContainedRegularFile(
            destination,
            in: stagingRootDirectory,
            fileManager: fileManager
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try fileManager.removeItem(at: destination)
        try SystemRestoreFileOperations(fileManager: fileManager)
            .synchronizeItem(at: stagingRootDirectory)
    }

    private static func itemExists(at url: URL) -> Bool {
        var information = stat()
        return Darwin.lstat(url.path, &information) == 0
    }
}
