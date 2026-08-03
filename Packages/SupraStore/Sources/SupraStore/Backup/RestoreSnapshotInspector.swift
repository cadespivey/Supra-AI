import CryptoKit
import Foundation
import GRDB

/// A deterministic, display-safe reason that a completed backup cannot be
/// selected for restore. No case carries a filesystem path or user content.
public enum RestoreIncompatibility: String, Codable, CaseIterable, Error, LocalizedError, Sendable {
    case malformedManifest
    case missingSnapshotDatabase
    case snapshotMetadataMismatch
    case databaseIntegrityFailed
    case foreignKeyIntegrityFailed
    case manifestMigrationMismatch
    case incompatibleMigrationHistory
    case unsupportedFutureSchema
    case invalidReferencedBlobPath
    case missingReferencedBlob
    case blobMetadataMismatch
    case referencedBlobCountMismatch

    public var errorDescription: String? {
        switch self {
        case .malformedManifest:
            return "The backup completion record is malformed."
        case .missingSnapshotDatabase:
            return "The backup database is missing."
        case .snapshotMetadataMismatch:
            return "The backup database no longer matches its completion record."
        case .databaseIntegrityFailed:
            return "The backup database did not pass SQLite integrity validation."
        case .foreignKeyIntegrityFailed:
            return "The backup database contains invalid record relationships."
        case .manifestMigrationMismatch:
            return "The backup database and its schema record do not match."
        case .incompatibleMigrationHistory:
            return "The backup uses an incompatible schema history."
        case .unsupportedFutureSchema:
            return "This backup was created by a newer unsupported database schema."
        case .invalidReferencedBlobPath:
            return "The backup contains an unsafe managed-document reference."
        case .missingReferencedBlob:
            return "A managed document required by the backup is missing."
        case .blobMetadataMismatch:
            return "A managed document no longer matches the backup database."
        case .referencedBlobCountMismatch:
            return "The backup document count does not match its completion record."
        }
    }
}

/// One content-addressed managed blob referenced by a validated database.
/// `relativePath` is relative to the backup/live `blobs/` root and has already
/// passed traversal and symlink containment checks.
public struct RestoreBlobReference: Codable, Equatable, Hashable, Sendable {
    public let relativePath: String
    public let byteSize: Int
    public let sha256: String

    public init(relativePath: String, byteSize: Int, sha256: String) {
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.sha256 = sha256
    }
}

/// Read-only facts suitable for the future Settings confirmation surface.
public struct RestoreSnapshotSummary: Equatable, Sendable {
    public let createdAt: Date
    public let appVersion: String
    public let appBuild: String
    public let databaseBytes: Int
    public let referencedBlobCount: Int

    public init(
        createdAt: Date,
        appVersion: String,
        appBuild: String,
        databaseBytes: Int,
        referencedBlobCount: Int
    ) {
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.databaseBytes = databaseBytes
        self.referencedBlobCount = referencedBlobCount
    }
}

/// The inspection result for one manifest-backed snapshot. A malformed
/// manifest is still returned so the UI can name it as blocked; a manifest-less
/// SQLite file is interrupted work and is deliberately absent from discovery.
public struct RestoreSnapshotCandidate: Equatable, Sendable {
    public let identifier: String
    public let backupDirectoryURL: URL
    public let snapshotURL: URL
    public let manifestURL: URL
    public let manifest: BackupManifest?
    public let summary: RestoreSnapshotSummary?
    /// SHA-256 of the inspected SQLite file. Staging recomputes this after its
    /// raw copy so a same-size source replacement cannot pass validation.
    public let databaseSHA256: String?
    public let referencedBlobs: [RestoreBlobReference]
    public let incompatibility: RestoreIncompatibility?

    public var isRestorable: Bool { incompatibility == nil }

    public init(
        identifier: String,
        backupDirectoryURL: URL,
        snapshotURL: URL,
        manifestURL: URL,
        manifest: BackupManifest?,
        summary: RestoreSnapshotSummary?,
        databaseSHA256: String?,
        referencedBlobs: [RestoreBlobReference],
        incompatibility: RestoreIncompatibility?
    ) {
        self.identifier = identifier
        self.backupDirectoryURL = backupDirectoryURL
        self.snapshotURL = snapshotURL
        self.manifestURL = manifestURL
        self.manifest = manifest
        self.summary = summary
        self.databaseSHA256 = databaseSHA256
        self.referencedBlobs = referencedBlobs
        self.incompatibility = incompatibility
    }
}

/// Discovers and validates manifest-backed backup snapshots without modifying
/// the backup destination, snapshot databases, or shared blob pool.
public enum RestoreSnapshotInspector {
    public static func discover(
        in backupDirectory: URL,
        knownMigrationIdentifiers: [String] = SupraMigrator.makeMigrator().migrations,
        fileManager: FileManager = .default
    ) throws -> [RestoreSnapshotCandidate] {
        let dbDirectory = backupDirectory.appendingPathComponent("db", isDirectory: true)
        guard fileManager.fileExists(atPath: dbDirectory.path) else { return [] }

        let entries = try fileManager.contentsOfDirectory(
            at: dbDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let manifests = try entries.filter { url in
            guard url.pathExtension == "json",
                  isSnapshotIdentifier(url.deletingPathExtension().lastPathComponent)
            else { return false }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.map { dbDirectory.appendingPathComponent($0.lastPathComponent) }

        return manifests
            .map {
                inspect(
                    manifestURL: $0,
                    backupDirectory: backupDirectory,
                    knownMigrationIdentifiers: knownMigrationIdentifiers,
                    fileManager: fileManager
                )
            }
            .sorted { $0.identifier > $1.identifier }
    }

    private static func isSnapshotIdentifier(_ identifier: String) -> Bool {
        guard identifier.hasPrefix(BackupService.snapshotPrefix) else { return false }
        let suffix = identifier.dropFirst(BackupService.snapshotPrefix.count)
        let components = suffix.split(separator: "-", omittingEmptySubsequences: false)
        guard components.map(\.utf8.count) == [8, 6, 3] else { return false }
        return components.allSatisfy { component in
            component.utf8.allSatisfy { (48...57).contains($0) }
        }
    }

    static func inspect(
        manifestURL: URL,
        backupDirectory: URL,
        knownMigrationIdentifiers: [String],
        fileManager: FileManager
    ) -> RestoreSnapshotCandidate {
        let identifier = manifestURL.deletingPathExtension().lastPathComponent
        let snapshotURL = manifestURL.deletingPathExtension().appendingPathExtension("sqlite")
        let dbDirectory = backupDirectory.appendingPathComponent("db", isDirectory: true)

        guard RestoreValidation.isContainedRegularFile(
            manifestURL, in: dbDirectory, fileManager: fileManager
        ) else {
            return candidate(
                identifier: identifier,
                backupDirectory: backupDirectory,
                snapshotURL: snapshotURL,
                manifestURL: manifestURL,
                incompatibility: .malformedManifest
            )
        }

        let manifest: BackupManifest
        do {
            manifest = try BackupManifest.decode(Data(contentsOf: manifestURL))
        } catch {
            return candidate(
                identifier: identifier,
                backupDirectory: backupDirectory,
                snapshotURL: snapshotURL,
                manifestURL: manifestURL,
                incompatibility: .malformedManifest
            )
        }

        let summary = RestoreSnapshotSummary(
            createdAt: manifest.createdAt,
            appVersion: manifest.appVersion,
            appBuild: manifest.appBuild,
            databaseBytes: manifest.sourceDbBytes,
            referencedBlobCount: manifest.referencedBlobCount
        )
        guard !manifest.appVersion.isEmpty,
              !manifest.appBuild.isEmpty,
              manifest.sourceDbBytes > 0,
              manifest.referencedBlobCount >= 0,
              !manifest.schemaMigrationIdentifiers.isEmpty,
              Set(manifest.schemaMigrationIdentifiers).count == manifest.schemaMigrationIdentifiers.count
        else {
            return candidate(
                identifier: identifier,
                backupDirectory: backupDirectory,
                snapshotURL: snapshotURL,
                manifestURL: manifestURL,
                manifest: manifest,
                summary: summary,
                incompatibility: .malformedManifest
            )
        }
        guard RestoreValidation.isContainedRegularFile(
            snapshotURL, in: dbDirectory, fileManager: fileManager
        ) else {
            return candidate(
                identifier: identifier,
                backupDirectory: backupDirectory,
                snapshotURL: snapshotURL,
                manifestURL: manifestURL,
                manifest: manifest,
                summary: summary,
                incompatibility: .missingSnapshotDatabase
            )
        }
        do {
            let fileSize = try snapshotURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard fileSize == manifest.sourceDbBytes else {
                return candidate(
                    identifier: identifier,
                    backupDirectory: backupDirectory,
                    snapshotURL: snapshotURL,
                    manifestURL: manifestURL,
                    manifest: manifest,
                    summary: summary,
                    incompatibility: .snapshotMetadataMismatch
                )
            }
        } catch {
            return candidate(
                identifier: identifier,
                backupDirectory: backupDirectory,
                snapshotURL: snapshotURL,
                manifestURL: manifestURL,
                manifest: manifest,
                summary: summary,
                incompatibility: .snapshotMetadataMismatch
            )
        }

        let pool = backupDirectory.appendingPathComponent("blobs", isDirectory: true)
        switch RestoreValidation.validateDatabase(
            at: snapshotURL,
            blobPool: pool,
            knownMigrationIdentifiers: knownMigrationIdentifiers,
            expectedManifest: manifest,
            fileManager: fileManager
        ) {
        case let .success(validated):
            let databaseSHA256: String
            do {
                databaseSHA256 = try RestoreValidation.sha256(of: snapshotURL)
            } catch {
                return candidate(
                    identifier: identifier,
                    backupDirectory: backupDirectory,
                    snapshotURL: snapshotURL,
                    manifestURL: manifestURL,
                    manifest: manifest,
                    summary: summary,
                    incompatibility: .snapshotMetadataMismatch
                )
            }
            return candidate(
                identifier: identifier,
                backupDirectory: backupDirectory,
                snapshotURL: snapshotURL,
                manifestURL: manifestURL,
                manifest: manifest,
                summary: summary,
                databaseSHA256: databaseSHA256,
                referencedBlobs: validated.blobs
            )
        case let .failure(reason):
            return candidate(
                identifier: identifier,
                backupDirectory: backupDirectory,
                snapshotURL: snapshotURL,
                manifestURL: manifestURL,
                manifest: manifest,
                summary: summary,
                incompatibility: reason
            )
        }
    }

    private static func candidate(
        identifier: String,
        backupDirectory: URL,
        snapshotURL: URL,
        manifestURL: URL,
        manifest: BackupManifest? = nil,
        summary: RestoreSnapshotSummary? = nil,
        databaseSHA256: String? = nil,
        referencedBlobs: [RestoreBlobReference] = [],
        incompatibility: RestoreIncompatibility? = nil
    ) -> RestoreSnapshotCandidate {
        RestoreSnapshotCandidate(
            identifier: identifier,
            backupDirectoryURL: backupDirectory,
            snapshotURL: snapshotURL,
            manifestURL: manifestURL,
            manifest: manifest,
            summary: summary,
            databaseSHA256: databaseSHA256,
            referencedBlobs: referencedBlobs,
            incompatibility: incompatibility
        )
    }
}

struct ValidatedRestoreDatabase: Equatable {
    let migrationIdentifiers: [String]
    let blobs: [RestoreBlobReference]
}

enum RestoreValidation {
    static func validateDatabase(
        at databaseURL: URL,
        blobPool: URL,
        knownMigrationIdentifiers: [String],
        expectedManifest: BackupManifest?,
        fileManager: FileManager
    ) -> Result<ValidatedRestoreDatabase, RestoreIncompatibility> {
        let databaseFacts: (migrations: [String], blobs: [RestoreBlobReference])
        do {
            var configuration = Configuration()
            configuration.readonly = true
            let reader = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            databaseFacts = try reader.read { db in
                let integrityRows = try String.fetchAll(db, sql: "PRAGMA integrity_check")
                guard integrityRows == ["ok"] else {
                    throw RestoreValidationSignal.databaseIntegrity
                }
                let foreignKeyFailures = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"
                ) ?? 0
                guard foreignKeyFailures == 0 else {
                    throw RestoreValidationSignal.foreignKeyIntegrity
                }
                guard try db.tableExists("grdb_migrations") else {
                    throw RestoreValidationSignal.databaseIntegrity
                }
                let migrations = try String.fetchAll(
                    db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
                )
                let blobs: [RestoreBlobReference]
                if try db.tableExists("document_blobs") {
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT sha256, byte_size, managed_relative_path
                            FROM document_blobs
                            ORDER BY managed_relative_path
                            """
                    )
                    blobs = try rows.map { row in
                        let managedPath: String = row["managed_relative_path"]
                        guard let relativePath = normalizedBlobRelativePath(managedPath) else {
                            throw RestoreValidationSignal.invalidBlobPath
                        }
                        let byteSize: Int = row["byte_size"]
                        let sha256: String = row["sha256"]
                        guard byteSize >= 0, !sha256.isEmpty else {
                            throw RestoreValidationSignal.blobMetadata
                        }
                        return RestoreBlobReference(
                            relativePath: relativePath,
                            byteSize: byteSize,
                            sha256: sha256.lowercased()
                        )
                    }
                } else {
                    blobs = []
                }
                return (migrations, blobs)
            }
        } catch RestoreValidationSignal.foreignKeyIntegrity {
            return .failure(.foreignKeyIntegrityFailed)
        } catch RestoreValidationSignal.invalidBlobPath {
            return .failure(.invalidReferencedBlobPath)
        } catch RestoreValidationSignal.blobMetadata {
            return .failure(.blobMetadataMismatch)
        } catch {
            return .failure(.databaseIntegrityFailed)
        }

        if databaseFacts.migrations.isEmpty {
            return .failure(.incompatibleMigrationHistory)
        }
        if let expectedManifest,
           databaseFacts.migrations != expectedManifest.schemaMigrationIdentifiers {
            return .failure(.manifestMigrationMismatch)
        }
        if databaseFacts.migrations.contains(where: { !knownMigrationIdentifiers.contains($0) })
            || databaseFacts.migrations.count > knownMigrationIdentifiers.count {
            return .failure(.unsupportedFutureSchema)
        }
        if Array(knownMigrationIdentifiers.prefix(databaseFacts.migrations.count))
            != databaseFacts.migrations {
            return .failure(.incompatibleMigrationHistory)
        }
        if let expectedManifest,
           databaseFacts.blobs.count != expectedManifest.referencedBlobCount {
            return .failure(.referencedBlobCountMismatch)
        }

        for blob in databaseFacts.blobs {
            let target = blobPool.appendingPathComponent(blob.relativePath)
            guard isContainedRegularFile(target, in: blobPool, fileManager: fileManager) else {
                return .failure(.missingReferencedBlob)
            }
            do {
                let fileSize = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard fileSize == blob.byteSize,
                      try sha256(of: target) == blob.sha256
                else {
                    return .failure(.blobMetadataMismatch)
                }
            } catch {
                return .failure(.blobMetadataMismatch)
            }
        }
        return .success(ValidatedRestoreDatabase(
            migrationIdentifiers: databaseFacts.migrations,
            blobs: databaseFacts.blobs
        ))
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedBlobRelativePath(_ managedPath: String) -> String? {
        guard !managedPath.hasPrefix("/"), !managedPath.contains("\0") else { return nil }
        let components = managedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return nil }
        let relative = components.first == "blobs" ? components.dropFirst() : components[...]
        guard !relative.isEmpty else { return nil }
        return relative.joined(separator: "/")
    }

    static func isContainedRegularFile(
        _ file: URL,
        in pool: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: file.path)
        else { return false }
        do {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        } catch {
            return false
        }
        let resolvedPool = pool.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedFile.hasPrefix(resolvedPool + "/")
    }
}

private enum RestoreValidationSignal: Error {
    case databaseIntegrity
    case foreignKeyIntegrity
    case invalidBlobPath
    case blobMetadata
}
