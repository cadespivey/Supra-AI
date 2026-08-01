import Darwin
import Foundation
import GRDB

/// Launch-safe restore state. The values carry no user content or filesystem
/// paths and can therefore be persisted by the later controller/audit work.
public enum RestoreActivationStatus: String, Codable, Equatable, Sendable {
    case noPendingRestore
    case activated
    case failedAndRolledBack
    case recoveryRequired
}

/// Content-free failure categories for launch routing and future restore UI.
public enum RestoreActivationFailure: String, Codable, Equatable, Error, Sendable {
    case invalidIntent
    case stagedStateInvalid
    case safetyStateInvalid
    case blobInstallationFailed
    case databaseReplacementFailed
    case databaseOpenFailed
    case markerRemovalFailed
}

public struct RestoreActivationResult: Equatable, Sendable {
    public let status: RestoreActivationStatus
    public let activationFailure: RestoreActivationFailure?
    public let rollbackFailure: RestoreActivationFailure?
    /// Content-free identifiers copied from the authenticated pending intent.
    /// They let the newly opened store persist an outcome after activation has
    /// replaced the database that originally recorded the staging event.
    public let operationID: String?
    public let snapshotIdentifier: String?
    /// The verified staged safety database is exposed only in memory so the app
    /// can offer recovery when neither automatic activation nor rollback works.
    public let recoveryDatabaseURL: URL?

    private init(
        status: RestoreActivationStatus,
        activationFailure: RestoreActivationFailure? = nil,
        rollbackFailure: RestoreActivationFailure? = nil,
        operationID: String? = nil,
        snapshotIdentifier: String? = nil,
        recoveryDatabaseURL: URL? = nil
    ) {
        self.status = status
        self.activationFailure = activationFailure
        self.rollbackFailure = rollbackFailure
        self.operationID = operationID
        self.snapshotIdentifier = snapshotIdentifier
        self.recoveryDatabaseURL = recoveryDatabaseURL
    }

    static let noPendingRestore = RestoreActivationResult(status: .noPendingRestore)
    static func activated(_ intent: RestoreIntent) -> RestoreActivationResult {
        RestoreActivationResult(
            status: .activated,
            operationID: intent.operationID,
            snapshotIdentifier: intent.selectedSnapshotIdentifier
        )
    }

    static func failedAndRolledBack(
        _ failure: RestoreActivationFailure,
        intent: RestoreIntent
    ) -> RestoreActivationResult {
        RestoreActivationResult(
            status: .failedAndRolledBack,
            activationFailure: failure,
            operationID: intent.operationID,
            snapshotIdentifier: intent.selectedSnapshotIdentifier
        )
    }

    static func recoveryRequired(
        activation failure: RestoreActivationFailure,
        rollback rollbackFailure: RestoreActivationFailure?,
        intent: RestoreIntent? = nil,
        safetyDatabaseURL: URL?
    ) -> RestoreActivationResult {
        RestoreActivationResult(
            status: .recoveryRequired,
            activationFailure: failure,
            rollbackFailure: rollbackFailure,
            operationID: intent?.operationID,
            snapshotIdentifier: intent?.selectedSnapshotIdentifier,
            recoveryDatabaseURL: safetyDatabaseURL
        )
    }
}

/// Durable, display-safe record of the most recent attempted restore activation.
/// It deliberately excludes filesystem locations and user/database content.
public struct RestoreOutcomeRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let lastOutcomeFileName = "last-restore-outcome.json"

    public let schemaVersion: Int
    public let operationID: String?
    public let snapshotIdentifier: String?
    public let status: RestoreActivationStatus
    public let activationFailure: RestoreActivationFailure?
    public let rollbackFailure: RestoreActivationFailure?
    public let completedAt: Date
    /// `nil` is a legacy terminal record and is retried conservatively. New
    /// terminal records transition from `true` to `false` only after the
    /// operation-tree unlink and containing-directory sync both succeed.
    public let operationTreeCleanupPending: Bool?

    init(result: RestoreActivationResult, completedAt: Date) {
        schemaVersion = Self.currentSchemaVersion
        operationID = result.operationID
        snapshotIdentifier = result.snapshotIdentifier
        status = result.status
        activationFailure = result.activationFailure
        rollbackFailure = result.rollbackFailure
        self.completedAt = completedAt
        operationTreeCleanupPending = result.status == .activated
            || result.status == .failedAndRolledBack
    }

    init(
        schemaVersion: Int,
        operationID: String?,
        snapshotIdentifier: String?,
        status: RestoreActivationStatus,
        activationFailure: RestoreActivationFailure?,
        rollbackFailure: RestoreActivationFailure?,
        completedAt: Date,
        operationTreeCleanupPending: Bool?
    ) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.snapshotIdentifier = snapshotIdentifier
        self.status = status
        self.activationFailure = activationFailure
        self.rollbackFailure = rollbackFailure
        self.completedAt = completedAt
        self.operationTreeCleanupPending = operationTreeCleanupPending
    }

    public static func encode(_ record: RestoreOutcomeRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(record)
    }

    public static func decode(_ data: Data) throws -> RestoreOutcomeRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RestoreOutcomeRecord.self, from: data)
    }
}

/// Small mutation boundary used to inject replacement, durability, and marker
/// faults without teaching the production API about test-only failure points.
protocol RestoreActivationFileOperations {
    func copyItem(from source: URL, to target: URL) throws
    func synchronizeItem(at url: URL) throws
    func atomicallyReplaceItem(at destination: URL, withItemAt prepared: URL) throws
    func removeItem(at url: URL) throws
    func writeOutcomeAtomically(_ data: Data, to url: URL) throws
}

struct SystemRestoreActivationFileOperations: RestoreActivationFileOperations {
    let fileManager: FileManager
    private let stagingOperations: SystemRestoreFileOperations

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.stagingOperations = SystemRestoreFileOperations(fileManager: fileManager)
    }

    func copyItem(from source: URL, to target: URL) throws {
        try fileManager.copyItem(at: source, to: target)
    }

    func synchronizeItem(at url: URL) throws {
        try stagingOperations.synchronizeItem(at: url)
    }

    func atomicallyReplaceItem(at destination: URL, withItemAt prepared: URL) throws {
        guard Darwin.rename(prepared.path, destination.path) == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSFilePathErrorKey: destination.path]
            )
        }
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func writeOutcomeAtomically(_ data: Data, to url: URL) throws {
        try stagingOperations.writeIntentAtomically(data, to: url)
    }
}

/// Runs only at a cold-start boundary, before the app constructs its store or
/// any controller that can retain a database writer.
public enum RestoreActivationService {
    public static func activatePendingRestore(
        liveLayout: RestoreLiveLayout,
        knownMigrationIdentifiers: [String] = SupraMigrator.makeMigrator().migrations,
        fileManager: FileManager = .default
    ) -> RestoreActivationResult {
        activatePendingRestore(
            liveLayout: liveLayout,
            knownMigrationIdentifiers: knownMigrationIdentifiers,
            fileManager: fileManager,
            operations: SystemRestoreActivationFileOperations(fileManager: fileManager),
            openDatabase: { try SupraDatabase(url: $0) }
        )
    }

    static func activatePendingRestore(
        liveLayout: RestoreLiveLayout,
        knownMigrationIdentifiers: [String],
        fileManager: FileManager = .default,
        operations: any RestoreActivationFileOperations,
        openDatabase: (URL) throws -> SupraDatabase
    ) -> RestoreActivationResult {
        try? RestoreSidecarStore.retryTerminalOperationCleanup(
            stagingRootDirectory: liveLayout.stagingRootDirectory,
            fileManager: fileManager,
            operations: operations
        )
        let result = performPendingRestore(
            liveLayout: liveLayout,
            knownMigrationIdentifiers: knownMigrationIdentifiers,
            fileManager: fileManager,
            operations: operations,
            openDatabase: openDatabase
        )
        guard result.status != .noPendingRestore else { return result }
        let outcome = try? RestoreSidecarStore.recordActivationOutcome(
            result,
            stagingRootDirectory: liveLayout.stagingRootDirectory,
            completedAt: Date(),
            fileManager: fileManager,
            operations: operations
        )
        if let outcome {
            try? RestoreSidecarStore.cleanupTerminalOperation(
                outcome,
                stagingRootDirectory: liveLayout.stagingRootDirectory,
                fileManager: fileManager,
                operations: operations
            )
        }
        return result
    }

    private static func performPendingRestore(
        liveLayout: RestoreLiveLayout,
        knownMigrationIdentifiers: [String],
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations,
        openDatabase: (URL) throws -> SupraDatabase
    ) -> RestoreActivationResult {
        let markerURL = liveLayout.stagingRootDirectory
            .appendingPathComponent(RestoreIntent.pendingFileName)
        guard itemExists(at: markerURL) else {
            return .noPendingRestore
        }

        let context: ActivationContext
        do {
            context = try loadContext(
                markerURL: markerURL,
                liveLayout: liveLayout,
                fileManager: fileManager
            )
        } catch {
            return .recoveryRequired(
                activation: .invalidIntent,
                rollback: nil,
                safetyDatabaseURL: nil
            )
        }

        let safetyValidation: ValidatedRestoreDatabase
        do {
            safetyValidation = try validateStagedState(
                databaseURL: context.safetyDatabaseURL,
                blobsDirectory: context.safetyBlobsDirectory,
                containmentRoot: liveLayout.stagingRootDirectory,
                expectedDatabaseSHA256: context.intent.safetyDatabaseSHA256,
                expectedBlobCount: context.intent.safetyBlobCount,
                knownMigrationIdentifiers: knownMigrationIdentifiers,
                fileManager: fileManager
            )
        } catch {
            return .recoveryRequired(
                activation: .safetyStateInvalid,
                rollback: .safetyStateInvalid,
                intent: context.intent,
                safetyDatabaseURL: nil
            )
        }

        let selectedValidation: ValidatedRestoreDatabase
        do {
            selectedValidation = try validateStagedState(
                databaseURL: context.selectedDatabaseURL,
                blobsDirectory: context.selectedBlobsDirectory,
                containmentRoot: liveLayout.stagingRootDirectory,
                expectedDatabaseSHA256: context.intent.stagedDatabaseSHA256,
                expectedBlobCount: context.intent.selectedBlobCount,
                knownMigrationIdentifiers: knownMigrationIdentifiers,
                fileManager: fileManager
            )
        } catch {
            return finishFailure(
                .stagedStateInvalid,
                context: context,
                safetyValidation: safetyValidation,
                liveLayout: liveLayout,
                knownMigrationIdentifiers: knownMigrationIdentifiers,
                fileManager: fileManager,
                operations: operations,
                openDatabase: openDatabase
            )
        }

        let activationFailure: RestoreActivationFailure
        do {
            try installBlobs(
                selectedValidation.blobs,
                from: context.selectedBlobsDirectory,
                into: liveLayout.blobsDirectory,
                operationID: context.intent.operationID,
                phase: .activate,
                fileManager: fileManager,
                operations: operations
            )
        } catch {
            activationFailure = .blobInstallationFailed
            return finishFailure(
                activationFailure,
                context: context,
                safetyValidation: safetyValidation,
                liveLayout: liveLayout,
                knownMigrationIdentifiers: knownMigrationIdentifiers,
                fileManager: fileManager,
                operations: operations,
                openDatabase: openDatabase
            )
        }

        do {
            try replaceLiveDatabase(
                from: context.selectedDatabaseURL,
                liveDatabaseURL: liveLayout.databaseURL,
                operationID: context.intent.operationID,
                phase: .activate,
                fileManager: fileManager,
                operations: operations
            )
        } catch {
            activationFailure = .databaseReplacementFailed
            return finishFailure(
                activationFailure,
                context: context,
                safetyValidation: safetyValidation,
                liveLayout: liveLayout,
                knownMigrationIdentifiers: knownMigrationIdentifiers,
                fileManager: fileManager,
                operations: operations,
                openDatabase: openDatabase
            )
        }

        do {
            try openAndValidate(
                databaseURL: liveLayout.databaseURL,
                blobsDirectory: liveLayout.blobsDirectory,
                expectedBlobs: selectedValidation.blobs,
                knownMigrationIdentifiers: knownMigrationIdentifiers,
                fileManager: fileManager,
                openDatabase: openDatabase
            )
        } catch {
            activationFailure = .databaseOpenFailed
            return finishFailure(
                activationFailure,
                context: context,
                safetyValidation: safetyValidation,
                liveLayout: liveLayout,
                knownMigrationIdentifiers: knownMigrationIdentifiers,
                fileManager: fileManager,
                operations: operations,
                openDatabase: openDatabase
            )
        }

        do {
            try consumePendingMarker(
                context: context,
                stagingRootDirectory: liveLayout.stagingRootDirectory,
                operations: operations
            )
        } catch {
            activationFailure = .markerRemovalFailed
            return finishFailure(
                activationFailure,
                context: context,
                safetyValidation: safetyValidation,
                liveLayout: liveLayout,
                knownMigrationIdentifiers: knownMigrationIdentifiers,
                fileManager: fileManager,
                operations: operations,
                openDatabase: openDatabase
            )
        }

        return .activated(context.intent)
    }

    private static func finishFailure(
        _ activationFailure: RestoreActivationFailure,
        context: ActivationContext,
        safetyValidation: ValidatedRestoreDatabase,
        liveLayout: RestoreLiveLayout,
        knownMigrationIdentifiers: [String],
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations,
        openDatabase: (URL) throws -> SupraDatabase
    ) -> RestoreActivationResult {
        do {
            try installBlobs(
                safetyValidation.blobs,
                from: context.safetyBlobsDirectory,
                into: liveLayout.blobsDirectory,
                operationID: context.intent.operationID,
                phase: .rollback,
                fileManager: fileManager,
                operations: operations
            )
        } catch {
            return .recoveryRequired(
                activation: activationFailure,
                rollback: .blobInstallationFailed,
                intent: context.intent,
                safetyDatabaseURL: context.safetyDatabaseURL
            )
        }

        do {
            try replaceLiveDatabase(
                from: context.safetyDatabaseURL,
                liveDatabaseURL: liveLayout.databaseURL,
                operationID: context.intent.operationID,
                phase: .rollback,
                fileManager: fileManager,
                operations: operations
            )
        } catch {
            return .recoveryRequired(
                activation: activationFailure,
                rollback: .databaseReplacementFailed,
                intent: context.intent,
                safetyDatabaseURL: context.safetyDatabaseURL
            )
        }

        do {
            try openAndValidate(
                databaseURL: liveLayout.databaseURL,
                blobsDirectory: liveLayout.blobsDirectory,
                expectedBlobs: safetyValidation.blobs,
                knownMigrationIdentifiers: knownMigrationIdentifiers,
                fileManager: fileManager,
                openDatabase: openDatabase
            )
        } catch {
            return .recoveryRequired(
                activation: activationFailure,
                rollback: .databaseOpenFailed,
                intent: context.intent,
                safetyDatabaseURL: context.safetyDatabaseURL
            )
        }

        do {
            try consumePendingMarker(
                context: context,
                stagingRootDirectory: liveLayout.stagingRootDirectory,
                operations: operations
            )
        } catch {
            return .recoveryRequired(
                activation: activationFailure,
                rollback: .markerRemovalFailed,
                safetyDatabaseURL: context.safetyDatabaseURL
            )
        }

        return .failedAndRolledBack(
            activationFailure,
            intent: context.intent
        )
    }

    /// Consume an authenticated request only after the selected state or the
    /// safety rollback has been fully validated. Synchronizing the containing
    /// directory is part of consumption: without it, a crash may resurrect a
    /// marker and replay a restore that already reached a terminal outcome.
    private static func consumePendingMarker(
        context: ActivationContext,
        stagingRootDirectory: URL,
        operations: any RestoreActivationFileOperations
    ) throws {
        if itemExists(at: context.markerURL) {
            guard try Data(contentsOf: context.markerURL) == context.markerData else {
                throw RestoreActivationFailure.invalidIntent
            }
            try operations.removeItem(at: context.markerURL)
        }
        try operations.synchronizeItem(at: stagingRootDirectory)
    }

    private static func loadContext(
        markerURL: URL,
        liveLayout: RestoreLiveLayout,
        fileManager: FileManager
    ) throws -> ActivationContext {
        guard RestoreValidation.isContainedRegularFile(
            markerURL,
            in: liveLayout.stagingRootDirectory,
            fileManager: fileManager
        ) else {
            throw RestoreActivationFailure.invalidIntent
        }
        let markerData = try Data(contentsOf: markerURL)
        let intent = try RestoreIntent.decode(markerData)
        guard intent.schemaVersion == RestoreIntent.currentSchemaVersion,
              let uuid = UUID(uuidString: intent.operationID),
              uuid.uuidString.lowercased() == intent.operationID,
              RestoreSidecarStore.isValidSnapshotIdentifier(
                  intent.selectedSnapshotIdentifier,
                  required: true
              ),
              intent.selectedBlobCount >= 0,
              intent.safetyBlobCount >= 0,
              isSHA256(intent.stagedDatabaseSHA256),
              isSHA256(intent.safetyDatabaseSHA256)
        else {
            throw RestoreActivationFailure.invalidIntent
        }

        let operationDirectory = liveLayout.stagingRootDirectory
            .appendingPathComponent("operations", isDirectory: true)
            .appendingPathComponent(intent.operationID, isDirectory: true)
        let selectedDirectory = operationDirectory.appendingPathComponent("selected", isDirectory: true)
        let safetyDirectory = operationDirectory.appendingPathComponent("safety", isDirectory: true)
        return ActivationContext(
            intent: intent,
            markerURL: markerURL,
            markerData: markerData,
            selectedDatabaseURL: selectedDirectory
                .appendingPathComponent(RestoreService.stagedDatabaseFileName),
            selectedBlobsDirectory: selectedDirectory.appendingPathComponent("blobs", isDirectory: true),
            safetyDatabaseURL: safetyDirectory
                .appendingPathComponent(RestoreService.safetyDatabaseFileName),
            safetyBlobsDirectory: safetyDirectory.appendingPathComponent("blobs", isDirectory: true)
        )
    }

    private static func validateStagedState(
        databaseURL: URL,
        blobsDirectory: URL,
        containmentRoot: URL,
        expectedDatabaseSHA256: String,
        expectedBlobCount: Int,
        knownMigrationIdentifiers: [String],
        fileManager: FileManager
    ) throws -> ValidatedRestoreDatabase {
        guard RestoreValidation.isContainedRegularFile(
            databaseURL,
            in: containmentRoot,
            fileManager: fileManager
        ), isContainedDirectory(
            blobsDirectory,
            in: containmentRoot,
            fileManager: fileManager
        ), try RestoreValidation.sha256(of: databaseURL) == expectedDatabaseSHA256,
              case let .success(validation) = RestoreValidation.validateDatabase(
                  at: databaseURL,
                  blobPool: blobsDirectory,
                  knownMigrationIdentifiers: knownMigrationIdentifiers,
                  expectedManifest: nil,
                  fileManager: fileManager
              ), validation.blobs.count == expectedBlobCount
        else {
            throw RestoreActivationFailure.stagedStateInvalid
        }
        return validation
    }

    private static func installBlobs(
        _ blobs: [RestoreBlobReference],
        from sourceRoot: URL,
        into liveRoot: URL,
        operationID: String,
        phase: ReplacementPhase,
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations
    ) throws {
        try fileManager.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        let resolvedLiveRoot = liveRoot.resolvingSymlinksInPath().standardizedFileURL

        for blob in blobs {
            let source = sourceRoot.appendingPathComponent(blob.relativePath)
            let target = liveRoot.appendingPathComponent(blob.relativePath)
            if itemExists(at: target) {
                guard RestoreValidation.isContainedRegularFile(
                    target, in: liveRoot, fileManager: fileManager
                ), try matches(blob, at: target) else {
                    throw RestoreActivationFailure.blobInstallationFailed
                }
                continue
            }

            let parent = target.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedParent.path == resolvedLiveRoot.path
                || resolvedParent.path.hasPrefix(resolvedLiveRoot.path + "/")
            else {
                throw RestoreActivationFailure.blobInstallationFailed
            }

            let temporary = parent.appendingPathComponent(
                ".\(target.lastPathComponent).\(phase.rawValue)-\(operationID).tmp"
            )
            if itemExists(at: temporary) {
                try operations.removeItem(at: temporary)
            }
            defer {
                if itemExists(at: temporary) {
                    try? operations.removeItem(at: temporary)
                }
            }
            try operations.copyItem(from: source, to: temporary)
            try operations.synchronizeItem(at: temporary)
            guard try matches(blob, at: temporary) else {
                throw RestoreActivationFailure.blobInstallationFailed
            }

            if itemExists(at: target) {
                guard try matches(blob, at: target) else {
                    throw RestoreActivationFailure.blobInstallationFailed
                }
                try operations.removeItem(at: temporary)
            } else {
                try operations.atomicallyReplaceItem(at: target, withItemAt: temporary)
                try synchronizeAncestors(
                    from: parent,
                    through: liveRoot,
                    operations: operations
                )
            }
        }
    }

    private static func replaceLiveDatabase(
        from source: URL,
        liveDatabaseURL: URL,
        operationID: String,
        phase: ReplacementPhase,
        fileManager: FileManager,
        operations: any RestoreActivationFileOperations
    ) throws {
        let parent = liveDatabaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let prepared = parent.appendingPathComponent(
            ".\(liveDatabaseURL.lastPathComponent).\(phase.rawValue)-\(operationID).tmp"
        )
        if itemExists(at: prepared) {
            try operations.removeItem(at: prepared)
        }
        defer {
            if itemExists(at: prepared) {
                try? operations.removeItem(at: prepared)
            }
        }

        try operations.copyItem(from: source, to: prepared)
        try operations.synchronizeItem(at: prepared)
        guard try RestoreValidation.sha256(of: prepared) == RestoreValidation.sha256(of: source) else {
            throw RestoreActivationFailure.databaseReplacementFailed
        }

        // No prior SQLite sidecar may be allowed to attach to the newly renamed
        // database. A hot rollback journal is as dangerous here as stale WAL.
        for suffix in ["-journal", "-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: liveDatabaseURL.path + suffix)
            if itemExists(at: sidecar) {
                try operations.removeItem(at: sidecar)
            }
        }
        try operations.atomicallyReplaceItem(at: liveDatabaseURL, withItemAt: prepared)
        try operations.synchronizeItem(at: parent)
    }

    private static func openAndValidate(
        databaseURL: URL,
        blobsDirectory: URL,
        expectedBlobs: [RestoreBlobReference],
        knownMigrationIdentifiers: [String],
        fileManager: FileManager,
        openDatabase: (URL) throws -> SupraDatabase
    ) throws {
        let database = try openDatabase(databaseURL)
        guard case let .success(validation) = RestoreValidation.validateDatabase(
            at: databaseURL,
            blobPool: blobsDirectory,
            knownMigrationIdentifiers: knownMigrationIdentifiers,
            expectedManifest: nil,
            fileManager: fileManager
        ), validation.migrationIdentifiers == knownMigrationIdentifiers,
           validation.blobs == expectedBlobs else {
            throw RestoreActivationFailure.databaseOpenFailed
        }
        withExtendedLifetime(database) {}
    }

    private static func matches(_ blob: RestoreBlobReference, at url: URL) throws -> Bool {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let sha256 = try RestoreValidation.sha256(of: url)
        return size == blob.byteSize && sha256 == blob.sha256
    }

    private static func synchronizeAncestors(
        from directory: URL,
        through root: URL,
        operations: any RestoreActivationFileOperations
    ) throws {
        let root = root.standardizedFileURL
        var directory = directory.standardizedFileURL
        while directory.path == root.path || directory.path.hasPrefix(root.path + "/") {
            try operations.synchronizeItem(at: directory)
            if directory.path == root.path { return }
            directory.deleteLastPathComponent()
        }
        throw RestoreActivationFailure.blobInstallationFailed
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    /// Unlike `FileManager.fileExists`, this detects dangling symlinks. Restore
    /// must fail closed instead of replacing an unexpected directory entry.
    private static func itemExists(at url: URL) -> Bool {
        var information = stat()
        return Darwin.lstat(url.path, &information) == 0
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
        return resolvedDirectory.hasPrefix(resolvedRoot + "/")
    }
}

private struct ActivationContext {
    let intent: RestoreIntent
    let markerURL: URL
    let markerData: Data
    let selectedDatabaseURL: URL
    let selectedBlobsDirectory: URL
    let safetyDatabaseURL: URL
    let safetyBlobsDirectory: URL
}

private enum ReplacementPhase: String {
    case activate
    case rollback
}
