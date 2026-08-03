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
    private static let stagingFailureAcknowledgementFileName =
        ".last-restore-staging-failure.acknowledging"
    private static let activationOutcomeAcknowledgementFileName =
        ".last-restore-outcome.acknowledging"

    @discardableResult
    public static func recordStagingFailure(
        operationID: UUID,
        reason: RestoreStagingFailureReason,
        stagingRootDirectory: URL,
        failedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> RestoreStagingFailureRecord {
        try recordStagingFailure(
            operationID: operationID,
            reason: reason,
            stagingRootDirectory: stagingRootDirectory,
            failedAt: failedAt,
            fileManager: fileManager,
            operations: SystemRestoreActivationFileOperations(fileManager: fileManager)
        )
    }

    @discardableResult
    static func recordStagingFailure(
        operationID: UUID,
        reason: RestoreStagingFailureReason,
        stagingRootDirectory: URL,
        failedAt: Date = Date(),
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations
    ) throws -> RestoreStagingFailureRecord {
        let rootExisted = itemExists(at: stagingRootDirectory)
        let existingAncestor = nearestExistingAncestor(
            of: stagingRootDirectory,
            fileManager: fileManager
        )
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
        try operations.writeOutcomeAtomically(
            RestoreStagingFailureRecord.encode(record),
            to: destination
        )
        try synchronizeDirectoryParents(
            of: stagingRootDirectory,
            through: rootExisted
                ? stagingRootDirectory.deletingLastPathComponent()
                : existingAncestor,
            operations: operations
        )
        return record
    }

    public static func readStagingFailure(
        stagingRootDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> RestoreStagingFailureRecord? {
        try readStagingFailure(
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager,
            operations: SystemRestoreActivationFileOperations(fileManager: fileManager)
        )
    }

    static func readStagingFailure(
        stagingRootDirectory: URL,
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations
    ) throws -> RestoreStagingFailureRecord? {
        try reconcileAcknowledgementTombstones(
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager,
            operations: operations
        )
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
        try acknowledgeStagingFailure(
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager,
            operations: SystemRestoreActivationFileOperations(fileManager: fileManager)
        )
    }

    static func acknowledgeStagingFailure(
        stagingRootDirectory: URL,
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations
    ) throws {
        guard try readStagingFailure(
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager
        ) != nil else { return }
        try acknowledgeSidecar(
            named: RestoreStagingFailureRecord.lastFailureFileName,
            tombstoneName: stagingFailureAcknowledgementFileName,
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager,
            operations: operations
        )
    }

    /// Reads the most recent display-safe activation outcome without requiring
    /// a live database. Malformed, future-version, or path-like sidecars fail
    /// closed instead of being accepted as launch status.
    public static func readActivationOutcome(
        stagingRootDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> RestoreOutcomeRecord? {
        try readActivationOutcome(
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager,
            operations: SystemRestoreActivationFileOperations(fileManager: fileManager)
        )
    }

    static func readActivationOutcome(
        stagingRootDirectory: URL,
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations
    ) throws -> RestoreOutcomeRecord? {
        try reconcileAcknowledgementTombstones(
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager,
            operations: operations
        )
        let source = stagingRootDirectory
            .appendingPathComponent(RestoreOutcomeRecord.lastOutcomeFileName)
        guard itemExists(at: source) else { return nil }
        guard RestoreValidation.isContainedRegularFile(
            source,
            in: stagingRootDirectory,
            fileManager: fileManager
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let record = try RestoreOutcomeRecord.decode(Data(contentsOf: source))
        guard record.schemaVersion >= 1,
              record.schemaVersion <= RestoreOutcomeRecord.currentSchemaVersion,
              record.status != .noPendingRestore,
              isValidOperationID(record.operationID, required: record.status != .recoveryRequired),
              isValidSnapshotIdentifier(
                  record.snapshotIdentifier,
                  required: record.status != .recoveryRequired
              ),
              record.schemaVersion == 1
                  ? record.scheduledAt == nil
                  : record.status == .recoveryRequired || record.scheduledAt != nil,
              record.status != .recoveryRequired
                  || record.operationTreeCleanupPending != true
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record
    }

    /// Acknowledges the last activation outcome only after any terminal
    /// operation tree has been removed. Recovery-required trees are preserved.
    public static func acknowledgeActivationOutcome(
        stagingRootDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try acknowledgeActivationOutcome(
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager,
            operations: SystemRestoreActivationFileOperations(fileManager: fileManager)
        )
    }

    static func acknowledgeActivationOutcome(
        stagingRootDirectory: URL,
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations
    ) throws {
        guard let record = try readActivationOutcome(
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager
        ) else { return }
        guard record.status != .recoveryRequired else { return }
        try cleanupTerminalOperation(
            record,
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager,
            operations: operations
        )
        try acknowledgeSidecar(
            named: RestoreOutcomeRecord.lastOutcomeFileName,
            tombstoneName: activationOutcomeAcknowledgementFileName,
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager,
            operations: operations
        )
    }

    @discardableResult
    static func recordActivationOutcome(
        _ result: RestoreActivationResult,
        stagingRootDirectory: URL,
        completedAt: Date,
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations
    ) throws -> RestoreOutcomeRecord {
        try fileManager.createDirectory(
            at: stagingRootDirectory,
            withIntermediateDirectories: true
        )
        let record = RestoreOutcomeRecord(result: result, completedAt: completedAt)
        let destination = stagingRootDirectory
            .appendingPathComponent(RestoreOutcomeRecord.lastOutcomeFileName)
        try operations.writeOutcomeAtomically(
            RestoreOutcomeRecord.encode(record),
            to: destination
        )
        return record
    }

    /// Best-effort launch retry hook. A terminal outcome is the durable key for
    /// an operation whose pending marker was already consumed before cleanup.
    static func retryTerminalOperationCleanup(
        stagingRootDirectory: URL,
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations
    ) throws {
        guard let record = try readActivationOutcome(
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager
        ) else { return }
        try cleanupTerminalOperation(
            record,
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager,
            operations: operations
        )
    }

    /// Removes only the exact operation tree named by a persisted staging
    /// schedule when no pending marker or activation outcome can still claim
    /// any staging tree. This is the bounded cold-start cleanup for a process
    /// that exited midway through staging, before it could publish a marker.
    @discardableResult
    public static func cleanupInterruptedStagingOperation(
        operationID: UUID,
        stagingRootDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        try cleanupInterruptedStagingOperation(
            operationID: operationID,
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager,
            operations: SystemRestoreActivationFileOperations(fileManager: fileManager)
        )
    }

    @discardableResult
    static func cleanupInterruptedStagingOperation(
        operationID: UUID,
        stagingRootDirectory: URL,
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations
    ) throws -> Bool {
        let markerURL = stagingRootDirectory
            .appendingPathComponent(RestoreIntent.pendingFileName)
        let outcomeURL = stagingRootDirectory
            .appendingPathComponent(RestoreOutcomeRecord.lastOutcomeFileName)
        guard !itemExists(at: markerURL), !itemExists(at: outcomeURL) else {
            return false
        }

        let identifier = operationID.uuidString.lowercased()
        try removeTerminalOperationTree(
            operationID: identifier,
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager,
            operations: operations
        )
        return true
    }

    private static func acknowledgeSidecar(
        named fileName: String,
        tombstoneName: String,
        stagingRootDirectory: URL,
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations
    ) throws {
        let source = stagingRootDirectory.appendingPathComponent(fileName)
        let tombstone = stagingRootDirectory.appendingPathComponent(tombstoneName)
        guard itemExists(at: source), !itemExists(at: tombstone),
              RestoreValidation.isContainedRegularFile(
                  source,
                  in: stagingRootDirectory,
                  fileManager: fileManager
              )
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard Darwin.rename(source.path, tombstone.path) == 0 else {
            throw posixError(path: source.path)
        }
        // The first sync makes the rename durable, so a crash can reveal only
        // the source or its acknowledgement tombstone. The second publishes
        // tombstone removal. Cold reads reconcile either incomplete phase.
        try operations.synchronizeItem(at: stagingRootDirectory)
        try operations.removeItem(at: tombstone)
        try operations.synchronizeItem(at: stagingRootDirectory)
    }

    private static func reconcileAcknowledgementTombstones(
        stagingRootDirectory: URL,
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations
    ) throws {
        guard itemExists(at: stagingRootDirectory) else { return }
        guard isContainedDirectory(
            stagingRootDirectory,
            in: stagingRootDirectory,
            fileManager: fileManager
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for (sourceName, tombstoneName) in [
            (RestoreStagingFailureRecord.lastFailureFileName,
             stagingFailureAcknowledgementFileName),
            (RestoreOutcomeRecord.lastOutcomeFileName,
             activationOutcomeAcknowledgementFileName),
        ] {
            let source = stagingRootDirectory.appendingPathComponent(sourceName)
            let tombstone = stagingRootDirectory.appendingPathComponent(tombstoneName)
            guard itemExists(at: tombstone) else { continue }
            guard !itemExists(at: source),
                  RestoreValidation.isContainedRegularFile(
                      tombstone,
                      in: stagingRootDirectory,
                      fileManager: fileManager
                  )
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try operations.removeItem(at: tombstone)
        }
        // Even with no visible tombstone, this publishes an acknowledgement
        // unlink that failed its final sync in the preceding process.
        try operations.synchronizeItem(at: stagingRootDirectory)
        try operations.synchronizeItem(at: stagingRootDirectory.deletingLastPathComponent())
    }

    private static func synchronizeDirectoryParents(
        of createdRoot: URL,
        through existingAncestor: URL,
        operations: any RestoreActivationFileOperations
    ) throws {
        let root = createdRoot.standardizedFileURL
        let ancestor = existingAncestor.standardizedFileURL
        guard root.path.hasPrefix(ancestor.path + "/") else {
            throw CocoaError(.fileWriteUnknown)
        }
        var directory = root.deletingLastPathComponent().standardizedFileURL
        while true {
            try operations.synchronizeItem(at: directory)
            guard directory != ancestor else { return }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            guard parent != directory else { throw CocoaError(.fileWriteUnknown) }
            directory = parent
        }
    }

    private static func nearestExistingAncestor(
        of url: URL,
        fileManager: FileManager
    ) -> URL {
        var candidate = url.standardizedFileURL
        while !fileManager.fileExists(atPath: candidate.path),
              candidate != candidate.deletingLastPathComponent().standardizedFileURL {
            candidate.deleteLastPathComponent()
        }
        return candidate.standardizedFileURL
    }

    static func cleanupTerminalOperation(
        _ record: RestoreOutcomeRecord,
        stagingRootDirectory: URL,
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations
    ) throws {
        guard record.status == .activated || record.status == .failedAndRolledBack,
              record.operationTreeCleanupPending != false,
              let operationID = record.operationID
        else { return }
        try removeTerminalOperationTree(
            operationID: operationID,
            stagingRootDirectory: stagingRootDirectory,
            fileManager: fileManager,
            operations: operations
        )
        let completed = RestoreOutcomeRecord(
            schemaVersion: record.schemaVersion,
            operationID: record.operationID,
            snapshotIdentifier: record.snapshotIdentifier,
            scheduledAt: record.scheduledAt,
            status: record.status,
            activationFailure: record.activationFailure,
            rollbackFailure: record.rollbackFailure,
            completedAt: record.completedAt,
            operationTreeCleanupPending: false
        )
        let destination = stagingRootDirectory
            .appendingPathComponent(RestoreOutcomeRecord.lastOutcomeFileName)
        try operations.writeOutcomeAtomically(
            RestoreOutcomeRecord.encode(completed),
            to: destination
        )
    }

    private static func removeTerminalOperationTree(
        operationID: String,
        stagingRootDirectory: URL,
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations
    ) throws {
        guard isValidOperationID(operationID, required: true) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let operationsDirectory = stagingRootDirectory
            .appendingPathComponent("operations", isDirectory: true)
        guard itemExists(at: operationsDirectory) else { return }
        guard isContainedDirectory(
            operationsDirectory,
            in: stagingRootDirectory,
            fileManager: fileManager
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let operationDirectory = operationsDirectory
            .appendingPathComponent(operationID, isDirectory: true)
        if itemExists(at: operationDirectory) {
            guard isContainedDirectory(
                operationDirectory,
                in: operationsDirectory,
                fileManager: fileManager
            ) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try operations.removeItem(at: operationDirectory)
        }
        try operations.synchronizeItem(at: operationsDirectory)
    }

    private static func isValidOperationID(_ value: String?, required: Bool) -> Bool {
        guard let value else { return !required }
        guard let identifier = UUID(uuidString: value) else { return false }
        return identifier.uuidString.lowercased() == value
    }

    static func isValidSnapshotIdentifier(_ value: String?, required: Bool) -> Bool {
        guard let value else { return !required }
        guard value.hasPrefix(BackupService.snapshotPrefix) else { return false }
        let suffix = value.dropFirst(BackupService.snapshotPrefix.count)
        let components = suffix.split(separator: "-", omittingEmptySubsequences: false)
        guard components.map(\.utf8.count) == [8, 6, 3] else { return false }
        return components.allSatisfy { component in
            component.utf8.allSatisfy { (48...57).contains($0) }
        }
    }

    private static func isContainedDirectory(
        _ directory: URL,
        in root: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }
        do {
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
        } catch {
            return false
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedDirectory == resolvedRoot
            || resolvedDirectory.hasPrefix(resolvedRoot + "/")
    }

    private static func posixError(path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: path]
        )
    }

    private static func itemExists(at url: URL) -> Bool {
        var information = stat()
        return Darwin.lstat(url.path, &information) == 0
    }
}
