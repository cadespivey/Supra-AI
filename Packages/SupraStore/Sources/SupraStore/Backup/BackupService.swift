import Darwin
import Foundation
import GRDB

/// Testable boundary around the three operations whose ordering and durability
/// make the manifest a trustworthy completion marker.
protocol BackupFileOperations {
    func createSnapshot(writer: any DatabaseWriter, at url: URL) throws
    func synchronizeFile(at url: URL) throws
    func writeManifestAtomically(_ data: Data, to url: URL) throws
}

struct SystemBackupFileOperations: BackupFileOperations {
    func createSnapshot(writer: any DatabaseWriter, at url: URL) throws {
        try writer.vacuum(into: url.path)
    }

    func synchronizeFile(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(path: url.path) }
        defer { close(descriptor) }

        // F_FULLFSYNC asks macOS to flush through the device cache. Some
        // user-selected filesystems do not support it; fsync remains the
        // strongest available durability boundary there.
        guard fcntl(descriptor, F_FULLFSYNC) != 0 else { return }
        guard fsync(descriptor) == 0 else { throw posixError(path: url.path) }
    }

    func writeManifestAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try synchronizeFile(at: url)
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

/// One backup snapshot's metadata, stored beside it as JSON. Deliberately minimal:
/// only what restore validation needs. The manifest is written LAST in a backup
/// run, so its presence marks the snapshot as complete.
public struct BackupManifest: Codable, Equatable, Sendable {
    public var appVersion: String
    public var appBuild: String
    /// The source database's applied migrations, in registration order. Restore
    /// refuses a backup whose identifiers are ahead of the running app's registry.
    public var schemaMigrationIdentifiers: [String]
    public var createdAt: Date
    /// Byte size of the snapshot file (a compacted VACUUM INTO copy).
    public var sourceDbBytes: Int
    /// Number of managed blobs referenced by the snapshot (all guaranteed
    /// present in the destination pool before this manifest is written).
    public var referencedBlobCount: Int

    public init(
        appVersion: String,
        appBuild: String,
        schemaMigrationIdentifiers: [String],
        createdAt: Date,
        sourceDbBytes: Int,
        referencedBlobCount: Int
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.schemaMigrationIdentifiers = schemaMigrationIdentifiers
        self.createdAt = createdAt
        self.sourceDbBytes = sourceDbBytes
        self.referencedBlobCount = referencedBlobCount
    }

    /// Deterministic encoding (sorted keys + ISO8601 dates) — the on-disk format
    /// is a frozen contract (golden-tested); restore must parse old manifests.
    public static func encode(_ manifest: BackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    public static func decode(_ data: Data) throws -> BackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupManifest.self, from: data)
    }
}

/// The outcome of one backup run.
public struct BackupResult: Equatable, Sendable {
    public let snapshotURL: URL
    public let manifestURL: URL
    /// Blobs newly copied into the pool by this run.
    public let copiedBlobCount: Int
    /// Total managed blobs in the source at snapshot time.
    public let referencedBlobCount: Int
}

public enum BackupError: Error, Equatable, LocalizedError {
    /// The timestamped snapshot target already exists. A backup never overwrites
    /// an existing snapshot.
    case snapshotTargetExists(URL)
    /// A configured blob root exists but is not a readable directory.
    case invalidBlobsDirectory(URL)
    /// The source tree could not be enumerated without silently skipping files.
    case blobEnumerationFailed(URL)
    /// A database-managed blob path is absolute, escaping, or otherwise invalid.
    case invalidReferencedBlobPath(String)
    /// A snapshot references a blob absent from both the pool and source tree.
    case referencedBlobMissing(String)
    /// The completed snapshot's byte size could not be read for its manifest.
    case snapshotMetadataUnavailable(URL)

    public var errorDescription: String? {
        switch self {
        case let .snapshotTargetExists(url):
            return "A backup snapshot already exists at \(url.lastPathComponent)."
        case let .invalidBlobsDirectory(url):
            return "The managed blobs location is not a readable directory: \(url.path)."
        case let .blobEnumerationFailed(url):
            return "The managed blobs directory could not be fully read at \(url.path)."
        case let .invalidReferencedBlobPath(path):
            return "The backup database contains an invalid managed blob path: \(path)."
        case let .referencedBlobMissing(path):
            return "A blob referenced by the backup database is missing: \(path)."
        case let .snapshotMetadataUnavailable(url):
            return "The backup snapshot size could not be read at \(url.path)."
        }
    }
}

/// The backup engine (backup plan P1): writes one consistent database snapshot
/// plus an incrementally-mirrored, add-only pool of managed document blobs into a
/// destination folder. Pure over the injected writer and directories — no
/// bookmarks, scheduling, or UI here (that's the P2 controller's job).
///
/// Destination layout:
/// ```
/// <destination>/
///   blobs/<relative path>            add-only shared pool (never rewritten)
///   db/SupraAI-<stamp>.sqlite        one VACUUM INTO snapshot per run
///   db/SupraAI-<stamp>.json          manifest, written LAST (= run complete)
/// ```
/// Run order is blobs → snapshot → reconcile the snapshot's exact blob paths →
/// manifest. An interrupted run can leave extra pool blobs or a manifest-less
/// snapshot, but never a manifest for an incomplete backup.
public enum BackupService {
    static let snapshotPrefix = "SupraAI-"
    public static let defaultKeep = 10

    /// Runs one full backup. `blobsDirectory` is the managed blob root; nil or
    /// missing is valid for a database-only store, but fails closed if the
    /// resulting snapshot references documents. Prunes `db/` to the newest
    /// `keep` snapshot+manifest pairs afterward.
    @discardableResult
    public static func runBackup(
        writer: any DatabaseWriter,
        blobsDirectory: URL?,
        destination: URL,
        appVersion: String,
        appBuild: String,
        migrator: DatabaseMigrator = SupraMigrator.makeMigrator(),
        keep: Int = BackupService.defaultKeep,
        fileManager: FileManager = .default,
        now: () -> Date = { Date() }
    ) throws -> BackupResult {
        try runBackup(
            writer: writer,
            blobsDirectory: blobsDirectory,
            destination: destination,
            appVersion: appVersion,
            appBuild: appBuild,
            migrator: migrator,
            keep: keep,
            fileManager: fileManager,
            now: now,
            operations: SystemBackupFileOperations()
        )
    }

    /// Internal overload that makes failure and durability ordering observable
    /// without weakening the public package-only API.
    @discardableResult
    static func runBackup(
        writer: any DatabaseWriter,
        blobsDirectory: URL?,
        destination: URL,
        appVersion: String,
        appBuild: String,
        migrator: DatabaseMigrator = SupraMigrator.makeMigrator(),
        keep: Int = BackupService.defaultKeep,
        fileManager: FileManager = .default,
        now: () -> Date = { Date() },
        operations: any BackupFileOperations
    ) throws -> BackupResult {
        // 1. Mirror blobs first: a snapshot must never reference an uncopied blob.
        let mirrored = try mirrorBlobs(
            from: blobsDirectory,
            toPoolAt: destination.appendingPathComponent("blobs", isDirectory: true),
            fileManager: fileManager,
            operations: operations
        )

        // 2. Consistent, compacted database snapshot through the live writer.
        let dbDirectory = destination.appendingPathComponent("db", isDirectory: true)
        try fileManager.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: now())
        let snapshotURL = dbDirectory.appendingPathComponent("\(snapshotPrefix)\(stamp).sqlite")
        guard !fileManager.fileExists(atPath: snapshotURL.path) else {
            throw BackupError.snapshotTargetExists(snapshotURL)
        }
        let manifestURL = dbDirectory.appendingPathComponent("\(snapshotPrefix)\(stamp).json")
        do {
            try operations.createSnapshot(writer: writer, at: snapshotURL)
            try operations.synchronizeFile(at: snapshotURL)

            // A live writer can commit a new document between the first mirror
            // and VACUUM. Reconcile the immutable snapshot's exact references,
            // so manifest-present still guarantees every required blob exists.
            let snapshotPaths = try referencedBlobPaths(in: snapshotURL)
            let reconciledCopies = try reconcileSnapshotBlobs(
                managedPaths: snapshotPaths ?? [],
                sourceRoot: blobsDirectory,
                pool: destination.appendingPathComponent("blobs", isDirectory: true),
                fileManager: fileManager,
                operations: operations
            )
            let referencedCount = snapshotPaths?.count ?? mirrored.total

            // 3. Manifest last — its presence marks the backup complete.
            let identifiers = try writer.read { db in try migrator.appliedMigrations(db) }
            let attributes = try fileManager.attributesOfItem(atPath: snapshotURL.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw BackupError.snapshotMetadataUnavailable(snapshotURL)
            }
            let manifest = BackupManifest(
                appVersion: appVersion,
                appBuild: appBuild,
                schemaMigrationIdentifiers: identifiers,
                createdAt: now(),
                sourceDbBytes: size.intValue,
                referencedBlobCount: referencedCount
            )
            try operations.writeManifestAtomically(
                BackupManifest.encode(manifest), to: manifestURL
            )

            pruneSnapshots(in: dbDirectory, keep: keep, fileManager: fileManager)

            return BackupResult(
                snapshotURL: snapshotURL,
                manifestURL: manifestURL,
                copiedBlobCount: mirrored.copied + reconciledCopies,
                referencedBlobCount: referencedCount
            )
        } catch {
            // SQLite may leave a partial VACUUM INTO target. A failed run must
            // not leave it to consume a retention slot on the next success.
            try? fileManager.removeItem(at: manifestURL)
            try? fileManager.removeItem(at: snapshotURL)
            throw error
        }
    }

    /// Incrementally mirrors the managed blob tree into the add-only pool: only
    /// files absent from the pool are copied, each atomically (copy to a `.tmp`
    /// sibling, then rename into place). Existing pool files are NEVER rewritten —
    /// blobs are content-addressed, so same relative path means same content.
    static func mirrorBlobs(
        from source: URL?,
        toPoolAt pool: URL,
        fileManager: FileManager
    ) throws -> (copied: Int, total: Int) {
        try mirrorBlobs(
            from: source,
            toPoolAt: pool,
            fileManager: fileManager,
            operations: SystemBackupFileOperations()
        )
    }

    private static func mirrorBlobs(
        from source: URL?,
        toPoolAt pool: URL,
        fileManager: FileManager,
        operations: any BackupFileOperations
    ) throws -> (copied: Int, total: Int) {
        guard let source, fileManager.fileExists(atPath: source.path) else { return (0, 0) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: source.path)
        else {
            throw BackupError.invalidBlobsDirectory(source)
        }
        try fileManager.createDirectory(at: pool, withIntermediateDirectories: true)

        var copied = 0
        var total = 0
        var enumerationFailure: URL?
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, _ in
                enumerationFailure = url
                return false
            }
        ) else {
            throw BackupError.blobEnumerationFailed(source)
        }
        let sourcePrefix = source.standardizedFileURL.path + "/"
        while let fileURL = enumerator.nextObject() as? URL {
            guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let path = fileURL.standardizedFileURL.path
            guard path.hasPrefix(sourcePrefix) else {
                throw BackupError.blobEnumerationFailed(fileURL)
            }
            let relativePath = String(path.dropFirst(sourcePrefix.count))
            total += 1

            let target = pool.appendingPathComponent(relativePath)
            if try copyBlob(
                from: fileURL,
                to: target,
                fileManager: fileManager,
                operations: operations
            ) {
                copied += 1
            }
        }
        if let enumerationFailure {
            throw BackupError.blobEnumerationFailed(enumerationFailure)
        }
        return (copied, total)
    }

    /// Returns nil for a non-Supra fixture database that predates the document
    /// schema; real app snapshots always return their exact managed paths.
    private static func referencedBlobPaths(in snapshot: URL) throws -> [String]? {
        var configuration = Configuration()
        configuration.readonly = true
        let reader = try DatabaseQueue(path: snapshot.path, configuration: configuration)
        return try reader.read { db in
            guard try db.tableExists("document_blobs") else { return nil }
            return try String.fetchAll(
                db,
                sql: "SELECT managed_relative_path FROM document_blobs ORDER BY managed_relative_path"
            )
        }
    }

    private static func reconcileSnapshotBlobs(
        managedPaths: [String],
        sourceRoot: URL?,
        pool: URL,
        fileManager: FileManager,
        operations: any BackupFileOperations
    ) throws -> Int {
        var copied = 0
        for managedPath in managedPaths {
            let relativePath = try blobRelativePath(for: managedPath)
            let target = pool.appendingPathComponent(relativePath)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            guard let sourceRoot else {
                throw BackupError.referencedBlobMissing(managedPath)
            }
            let source = sourceRoot.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                throw BackupError.referencedBlobMissing(managedPath)
            }
            if try copyBlob(
                from: source,
                to: target,
                fileManager: fileManager,
                operations: operations
            ) {
                copied += 1
            }
        }
        return copied
    }

    private static func blobRelativePath(for managedPath: String) throws -> String {
        guard !managedPath.hasPrefix("/") else {
            throw BackupError.invalidReferencedBlobPath(managedPath)
        }
        let components = managedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw BackupError.invalidReferencedBlobPath(managedPath)
        }
        let relativeComponents = components.first == "blobs" ? components.dropFirst() : components[...]
        guard !relativeComponents.isEmpty else {
            throw BackupError.invalidReferencedBlobPath(managedPath)
        }
        return relativeComponents.joined(separator: "/")
    }

    private static func copyBlob(
        from source: URL,
        to target: URL,
        fileManager: FileManager,
        operations: any BackupFileOperations
    ) throws -> Bool {
        guard !fileManager.fileExists(atPath: target.path) else { return false }
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }

        try fileManager.copyItem(at: source, to: temporary)
        try operations.synchronizeFile(at: temporary)
        do {
            try fileManager.moveItem(at: temporary, to: target)
            return true
        } catch {
            // The blob appeared concurrently (another backup run) — same
            // content by construction, so drop ours and move on.
            guard fileManager.fileExists(atPath: target.path) else { throw error }
            return false
        }
    }

    /// Deletes all but the newest `keep` snapshot+manifest pairs. Lexicographic
    /// filename order is chronological (zero-padded UTC stamp). Best-effort: a
    /// pruning failure must never fail the backup that just completed.
    static func pruneSnapshots(in dbDirectory: URL, keep: Int, fileManager: FileManager) {
        let keep = max(1, keep)
        let entries = (try? fileManager.contentsOfDirectory(
            at: dbDirectory, includingPropertiesForKeys: nil
        )) ?? []
        let snapshots = entries
            .filter { $0.lastPathComponent.hasPrefix(snapshotPrefix) && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Manifest-less VACUUM debris is incomplete and must not consume a
        // retained slot. Do not delete it here: another backup run may still be
        // writing that snapshot. A run that throws removes its own partial file.
        let completeSnapshots = snapshots.filter { snapshot in
            let manifest = snapshot.deletingPathExtension().appendingPathExtension("json")
            return fileManager.fileExists(atPath: manifest.path)
        }
        let snapshotStems = Set(snapshots.map { $0.deletingPathExtension().lastPathComponent })
        for manifest in entries where manifest.lastPathComponent.hasPrefix(snapshotPrefix)
            && manifest.pathExtension == "json"
            && !snapshotStems.contains(manifest.deletingPathExtension().lastPathComponent)
        {
            try? fileManager.removeItem(at: manifest)
        }

        guard completeSnapshots.count > keep else { return }
        for snapshot in completeSnapshots.prefix(completeSnapshots.count - keep) {
            let manifest = snapshot.deletingPathExtension().appendingPathExtension("json")
            // Remove the completeness marker first. If that fails, retaining
            // both files is safer than leaving a manifest without its database.
            do {
                try fileManager.removeItem(at: manifest)
            } catch {
                continue
            }
            try? fileManager.removeItem(at: snapshot)
        }
    }

    /// Zero-padded, lexicographically-sortable UTC stamp (millisecond resolution).
    /// The format is a pinned contract — tests and retention sorting rely on it.
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}
