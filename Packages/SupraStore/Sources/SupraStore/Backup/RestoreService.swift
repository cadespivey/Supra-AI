import Darwin
import Foundation
import GRDB

/// Explicit locations used by restore staging. The caller must quiesce the app's
/// live store before invoking this core service; activation belongs to the
/// separate cold-start work order.
public struct RestoreLiveLayout: Equatable, Sendable {
    public let databaseURL: URL
    public let blobsDirectory: URL
    public let stagingRootDirectory: URL

    public init(databaseURL: URL, blobsDirectory: URL, stagingRootDirectory: URL) {
        self.databaseURL = databaseURL
        self.blobsDirectory = blobsDirectory
        self.stagingRootDirectory = stagingRootDirectory
    }
}

/// Content-free handoff written last after both the current safety copy and the
/// selected restore copy have passed database, blob-size, and blob-digest checks.
public struct RestoreIntent: Codable, Equatable, Sendable {
    public static let pendingFileName = "pending-restore.json"
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let operationID: String
    public let createdAt: Date
    public let selectedSnapshotIdentifier: String
    public let selectedSnapshotCreatedAt: Date
    public let stagedDatabaseSHA256: String
    public let safetyDatabaseSHA256: String
    public let selectedBlobCount: Int
    public let safetyBlobCount: Int

    public static func encode(_ intent: RestoreIntent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(intent)
    }

    public static func decode(_ data: Data) throws -> RestoreIntent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RestoreIntent.self, from: data)
    }
}

public struct RestoreStagingResult: Equatable, Sendable {
    public let intent: RestoreIntent
    public let markerURL: URL
    public let operationDirectoryURL: URL
    public let safetyDatabaseURL: URL
    public let safetyBlobsDirectory: URL
    public let stagedDatabaseURL: URL
    public let stagedBlobsDirectory: URL
}

public enum RestoreStageError: Error, Equatable, LocalizedError {
    case restoreAlreadyPending
    case sourceSnapshotUnavailable
    case sourceSnapshotChanged
    case sourceSnapshotIncompatible(RestoreIncompatibility)
    case liveDatabaseMissing
    case liveStateIncompatible(RestoreIncompatibility)
    case stagingVolumeMismatch
    case copiedSafetyStateMismatch
    case copiedSelectedStateMismatch

    public var errorDescription: String? {
        switch self {
        case .restoreAlreadyPending:
            return "A restore is already staged and waiting for restart."
        case .sourceSnapshotUnavailable:
            return "The selected backup snapshot is no longer available."
        case .sourceSnapshotChanged:
            return "The selected backup snapshot changed after it was inspected. Select it again before restoring."
        case let .sourceSnapshotIncompatible(reason):
            return reason.errorDescription
        case .liveDatabaseMissing:
            return "The current database could not be found, so a safety copy was not created."
        case let .liveStateIncompatible(reason):
            return "The current data could not be verified for rollback. \(reason.localizedDescription)"
        case .stagingVolumeMismatch:
            return "Restore staging must be on the same disk as the current database."
        case .copiedSafetyStateMismatch:
            return "The current-data safety copy did not pass verification."
        case .copiedSelectedStateMismatch:
            return "The staged backup copy did not pass verification."
        }
    }
}

/// Injectable filesystem/durability boundary. Tests fail each step without
/// weakening the package's public staging API.
protocol RestoreFileOperations {
    func createDatabaseSnapshot(from source: URL, to target: URL) throws
    func copyItem(from source: URL, to target: URL) throws
    func moveItem(from source: URL, to target: URL) throws
    func synchronizeItem(at url: URL) throws
    func writeIntentAtomically(_ data: Data, to url: URL) throws
}

struct SystemRestoreFileOperations: RestoreFileOperations {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createDatabaseSnapshot(from source: URL, to target: URL) throws {
        let queue = try DatabaseQueue(path: source.path)
        try queue.vacuum(into: target.path)
    }

    func copyItem(from source: URL, to target: URL) throws {
        try fileManager.copyItem(at: source, to: target)
    }

    func moveItem(from source: URL, to target: URL) throws {
        try fileManager.moveItem(at: source, to: target)
    }

    func synchronizeItem(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(path: url.path) }
        defer { close(descriptor) }

        var isDirectory: ObjCBool = false
        let directory = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        if !directory, fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw posixError(path: url.path) }
    }

    func writeIntentAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try synchronizeItem(at: url)
        try synchronizeItem(at: url.deletingLastPathComponent())
    }

    private func posixError(path: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}

/// Core restore staging only. It never replaces the live database and never
/// installs live blobs; the marker is consumed by the cold-start activation
/// work order after the existing controller graph has exited.
public enum RestoreService {
    static let safetyDatabaseFileName = "restore-safety.sqlite"
    static let stagedDatabaseFileName = "restore-selected.sqlite"

    public static func stageRestore(
        candidate: RestoreSnapshotCandidate,
        liveLayout: RestoreLiveLayout,
        knownMigrationIdentifiers: [String] = SupraMigrator.makeMigrator().migrations,
        fileManager: FileManager = .default,
        now: () -> Date = { Date() }
    ) throws -> RestoreStagingResult {
        try stageRestore(
            candidate: candidate,
            liveLayout: liveLayout,
            knownMigrationIdentifiers: knownMigrationIdentifiers,
            fileManager: fileManager,
            now: now,
            operationID: { UUID() },
            operations: SystemRestoreFileOperations(fileManager: fileManager)
        )
    }

    static func stageRestore(
        candidate: RestoreSnapshotCandidate,
        liveLayout: RestoreLiveLayout,
        knownMigrationIdentifiers: [String],
        fileManager: FileManager = .default,
        now: () -> Date = { Date() },
        operationID: () -> UUID = { UUID() },
        operations: any RestoreFileOperations
    ) throws -> RestoreStagingResult {
        let refreshed = RestoreSnapshotInspector.inspect(
            manifestURL: candidate.manifestURL,
            backupDirectory: candidate.backupDirectoryURL,
            knownMigrationIdentifiers: knownMigrationIdentifiers,
            fileManager: fileManager
        )
        guard refreshed.identifier == candidate.identifier,
              refreshed.manifestURL.standardizedFileURL == candidate.manifestURL.standardizedFileURL
        else {
            throw RestoreStageError.sourceSnapshotUnavailable
        }
        if let incompatibility = refreshed.incompatibility {
            throw RestoreStageError.sourceSnapshotIncompatible(incompatibility)
        }
        let selectedManifest = try refreshed.manifest.unwrap(
            or: RestoreStageError.sourceSnapshotUnavailable
        )
        let selectedDatabaseSHA256 = try refreshed.databaseSHA256.unwrap(
            or: RestoreStageError.sourceSnapshotUnavailable
        )
        guard refreshed.manifest == candidate.manifest,
              refreshed.databaseSHA256 == candidate.databaseSHA256,
              refreshed.referencedBlobs == candidate.referencedBlobs
        else {
            throw RestoreStageError.sourceSnapshotChanged
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: liveLayout.databaseURL.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            throw RestoreStageError.liveDatabaseMissing
        }
        let pendingMarker = liveLayout.stagingRootDirectory
            .appendingPathComponent(RestoreIntent.pendingFileName)
        guard !fileManager.fileExists(atPath: pendingMarker.path) else {
            throw RestoreStageError.restoreAlreadyPending
        }
        guard try sameVolume(
            liveDatabaseURL: liveLayout.databaseURL,
            stagingRootDirectory: liveLayout.stagingRootDirectory,
            fileManager: fileManager
        ) else {
            throw RestoreStageError.stagingVolumeMismatch
        }

        let liveValidation: ValidatedRestoreDatabase
        switch RestoreValidation.validateDatabase(
            at: liveLayout.databaseURL,
            blobPool: liveLayout.blobsDirectory,
            knownMigrationIdentifiers: knownMigrationIdentifiers,
            expectedManifest: nil,
            fileManager: fileManager
        ) {
        case let .success(validated):
            liveValidation = validated
        case let .failure(reason):
            throw RestoreStageError.liveStateIncompatible(reason)
        }

        let operationsRoot = liveLayout.stagingRootDirectory
            .appendingPathComponent("operations", isDirectory: true)
        try fileManager.createDirectory(at: operationsRoot, withIntermediateDirectories: true)
        let operationIdentifier = operationID().uuidString.lowercased()
        let operationDirectory = operationsRoot
            .appendingPathComponent(operationIdentifier, isDirectory: true)
        guard !fileManager.fileExists(atPath: operationDirectory.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.createDirectory(at: operationDirectory, withIntermediateDirectories: false)

        var markerPublished = false
        defer {
            if !markerPublished {
                // An injected or system durability failure can occur after an
                // atomic writer has made the marker visible. Remove the marker
                // before its operation tree; if marker removal itself fails,
                // preserve the complete tree rather than leave a dangling marker.
                if fileManager.fileExists(atPath: pendingMarker.path) {
                    try? fileManager.removeItem(at: pendingMarker)
                }
                if !fileManager.fileExists(atPath: pendingMarker.path) {
                    try? fileManager.removeItem(at: operationDirectory)
                }
            }
        }

        let safetyTemporary = operationDirectory.appendingPathComponent("safety.tmp", isDirectory: true)
        let selectedTemporary = operationDirectory.appendingPathComponent("selected.tmp", isDirectory: true)
        let safetyFinal = operationDirectory.appendingPathComponent("safety", isDirectory: true)
        let selectedFinal = operationDirectory.appendingPathComponent("selected", isDirectory: true)
        try fileManager.createDirectory(at: safetyTemporary, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: selectedTemporary, withIntermediateDirectories: false)

        let safetyDatabaseTemporary = safetyTemporary.appendingPathComponent(safetyDatabaseFileName)
        let safetyBlobsTemporary = safetyTemporary.appendingPathComponent("blobs", isDirectory: true)
        try fileManager.createDirectory(at: safetyBlobsTemporary, withIntermediateDirectories: true)
        try operations.createDatabaseSnapshot(
            from: liveLayout.databaseURL,
            to: safetyDatabaseTemporary
        )
        try operations.synchronizeItem(at: safetyDatabaseTemporary)
        try copyBlobs(
            liveValidation.blobs,
            from: liveLayout.blobsDirectory,
            to: safetyBlobsTemporary,
            fileManager: fileManager,
            operations: operations
        )
        guard case let .success(safetyValidation) = RestoreValidation.validateDatabase(
            at: safetyDatabaseTemporary,
            blobPool: safetyBlobsTemporary,
            knownMigrationIdentifiers: knownMigrationIdentifiers,
            expectedManifest: nil,
            fileManager: fileManager
        ), safetyValidation == liveValidation else {
            throw RestoreStageError.copiedSafetyStateMismatch
        }
        try synchronizeDirectoryTree(
            at: safetyTemporary,
            fileManager: fileManager,
            operations: operations
        )
        try operations.moveItem(from: safetyTemporary, to: safetyFinal)
        try operations.synchronizeItem(at: operationDirectory)

        let selectedDatabaseTemporary = selectedTemporary.appendingPathComponent(stagedDatabaseFileName)
        let selectedBlobsTemporary = selectedTemporary.appendingPathComponent("blobs", isDirectory: true)
        try fileManager.createDirectory(at: selectedBlobsTemporary, withIntermediateDirectories: true)
        try operations.copyItem(from: refreshed.snapshotURL, to: selectedDatabaseTemporary)
        try operations.synchronizeItem(at: selectedDatabaseTemporary)
        guard try RestoreValidation.sha256(of: selectedDatabaseTemporary)
            == selectedDatabaseSHA256 else {
            throw RestoreStageError.copiedSelectedStateMismatch
        }
        try copyBlobs(
            refreshed.referencedBlobs,
            from: refreshed.backupDirectoryURL.appendingPathComponent("blobs", isDirectory: true),
            to: selectedBlobsTemporary,
            fileManager: fileManager,
            operations: operations
        )
        guard case let .success(selectedValidation) = RestoreValidation.validateDatabase(
            at: selectedDatabaseTemporary,
            blobPool: selectedBlobsTemporary,
            knownMigrationIdentifiers: knownMigrationIdentifiers,
            expectedManifest: selectedManifest,
            fileManager: fileManager
        ), selectedValidation.blobs == refreshed.referencedBlobs else {
            throw RestoreStageError.copiedSelectedStateMismatch
        }
        try synchronizeDirectoryTree(
            at: selectedTemporary,
            fileManager: fileManager,
            operations: operations
        )
        try operations.moveItem(from: selectedTemporary, to: selectedFinal)
        try operations.synchronizeItem(at: operationDirectory)

        let safetyDatabaseFinal = safetyFinal.appendingPathComponent(safetyDatabaseFileName)
        let selectedDatabaseFinal = selectedFinal.appendingPathComponent(stagedDatabaseFileName)
        // JSONEncoder's ISO-8601 strategy persists whole seconds. Normalize the
        // returned value to that same durable representation so callers never
        // observe an intent different from the marker they will consume.
        let createdAt = Date(timeIntervalSince1970: floor(now().timeIntervalSince1970))
        let intent = RestoreIntent(
            schemaVersion: RestoreIntent.currentSchemaVersion,
            operationID: operationIdentifier,
            createdAt: createdAt,
            selectedSnapshotIdentifier: refreshed.identifier,
            selectedSnapshotCreatedAt: selectedManifest.createdAt,
            stagedDatabaseSHA256: selectedDatabaseSHA256,
            safetyDatabaseSHA256: try RestoreValidation.sha256(of: safetyDatabaseFinal),
            selectedBlobCount: refreshed.referencedBlobs.count,
            safetyBlobCount: liveValidation.blobs.count
        )
        try operations.synchronizeItem(at: operationsRoot)
        try operations.synchronizeItem(at: liveLayout.stagingRootDirectory)
        try operations.writeIntentAtomically(RestoreIntent.encode(intent), to: pendingMarker)
        markerPublished = true

        return RestoreStagingResult(
            intent: intent,
            markerURL: pendingMarker,
            operationDirectoryURL: operationDirectory,
            safetyDatabaseURL: safetyDatabaseFinal,
            safetyBlobsDirectory: safetyFinal.appendingPathComponent("blobs", isDirectory: true),
            stagedDatabaseURL: selectedDatabaseFinal,
            stagedBlobsDirectory: selectedFinal.appendingPathComponent("blobs", isDirectory: true)
        )
    }

    private static func copyBlobs(
        _ blobs: [RestoreBlobReference],
        from sourceRoot: URL,
        to targetRoot: URL,
        fileManager: FileManager,
        operations: any RestoreFileOperations
    ) throws {
        for blob in blobs {
            let source = sourceRoot.appendingPathComponent(blob.relativePath)
            let target = targetRoot.appendingPathComponent(blob.relativePath)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try operations.copyItem(from: source, to: target)
            try operations.synchronizeItem(at: target)
        }
    }

    /// Synchronizes directory entries from the leaves to the root. Individual
    /// database and blob bytes are synchronized as they are written; this pass
    /// makes the completed tree durable before its final-directory rename.
    private static func synchronizeDirectoryTree(
        at root: URL,
        fileManager: FileManager,
        operations: any RestoreFileOperations
    ) throws {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var directories: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            if try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                directories.append(item)
            }
        }
        if let enumerationError { throw enumerationError }

        for directory in directories.sorted(by: {
            $0.pathComponents.count > $1.pathComponents.count
        }) {
            try operations.synchronizeItem(at: directory)
        }
        try operations.synchronizeItem(at: root)
    }

    private static func sameVolume(
        liveDatabaseURL: URL,
        stagingRootDirectory: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let stagingExistingAncestor = nearestExistingAncestor(
            of: stagingRootDirectory, fileManager: fileManager
        )
        let liveAttributes = try fileManager.attributesOfFileSystem(
            forPath: liveDatabaseURL.deletingLastPathComponent().path
        )
        let stagingAttributes = try fileManager.attributesOfFileSystem(
            forPath: stagingExistingAncestor.path
        )
        guard let liveSystem = liveAttributes[.systemNumber] as? NSNumber,
              let stagingSystem = stagingAttributes[.systemNumber] as? NSNumber
        else { return false }
        return liveSystem == stagingSystem
    }

    private static func nearestExistingAncestor(
        of url: URL,
        fileManager: FileManager
    ) -> URL {
        var candidate = url
        while !fileManager.fileExists(atPath: candidate.path),
              candidate.path != candidate.deletingLastPathComponent().path {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
