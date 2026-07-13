import CryptoKit
import Darwin
import Foundation

/// App-managed local storage layout for matter documents (plan §4.1). Imported
/// files are copied here (content-addressed by sha256); originals are never
/// modified and their absolute paths are never persisted in records/exports.
///
/// Layout:
/// ```
/// Application Support/SupraAI/MatterDocuments/
///   blobs/<sha256-prefix>/<sha256>.<ext>
///   previews/<document_id>/
///   temp/
///   exports/<matter_id>/
/// ```
public struct DocumentStorage: Sendable {
    public enum IngestStage: String, CaseIterable, Sendable {
        case beforeSourceRead
        case afterSourceReadChunk
        case beforeSynchronize
        case beforeInstall
    }

    public enum IngestDisposition: String, Sendable, Equatable {
        case installed
        case reusedVerified = "reused_verified"
    }

    public struct IngestResult: Sendable, Equatable {
        public let sha256: String
        public let byteSize: Int
        public let originalExtension: String
        public let managedRelativePath: String
        public let managedURL: URL
        public let disposition: IngestDisposition

        public init(
            sha256: String,
            byteSize: Int,
            originalExtension: String,
            managedRelativePath: String,
            managedURL: URL,
            disposition: IngestDisposition
        ) {
            self.sha256 = sha256
            self.byteSize = byteSize
            self.originalExtension = originalExtension
            self.managedRelativePath = managedRelativePath
            self.managedURL = managedURL
            self.disposition = disposition
        }
    }

    public enum IntegrityError: Error, Sendable, Equatable {
        case invalidSource
        case invalidManagedPath(String)
        case temporaryFileCreationFailed(Int32)
        case atomicInstallFailed(Int32)
        case missingManagedBlob(String)
        case corruptManagedBlob(String, Int, String)
        case reimportContentMismatch(expectedSHA256: String, actualSHA256: String)
    }

    public typealias IngestFaultInjector = @Sendable (IngestStage) throws -> Void

    public let root: URL
    private let ingestFaultInjector: IngestFaultInjector

    public init(
        root: URL,
        ingestFaultInjector: @escaping IngestFaultInjector = { _ in }
    ) {
        self.root = root
        self.ingestFaultInjector = ingestFaultInjector
    }

    /// The default managed storage root inside the app's Application Support
    /// container.
    public static func defaultRoot(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "ai.supra.SupraAI"
    ) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("MatterDocuments", isDirectory: true)
    }

    public static func makeDefault(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "ai.supra.SupraAI"
    ) -> DocumentStorage {
        DocumentStorage(root: defaultRoot(fileManager: fileManager, bundleIdentifier: bundleIdentifier))
    }

    public var blobsDirectory: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    public var previewsDirectory: URL { root.appendingPathComponent("previews", isDirectory: true) }
    public var tempDirectory: URL { root.appendingPathComponent("temp", isDirectory: true) }
    public var exportsDirectory: URL { root.appendingPathComponent("exports", isDirectory: true) }

    /// Creates the top-level managed directories. Returns the root on success.
    @discardableResult
    public func initializeStorage(fileManager: FileManager = .default) throws -> URL {
        for directory in [root, blobsDirectory, previewsDirectory, tempDirectory, exportsDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return root
    }

    public func isInitialized(fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: blobsDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Blob paths

    /// The managed relative path for a blob, sharded by the first two sha256 hex
    /// characters: `blobs/<ab>/<sha256>.<ext>`.
    public static func blobRelativePath(sha256: String, fileExtension: String) -> String {
        let prefix = String(sha256.prefix(2))
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        let fileName = ext.isEmpty ? sha256 : "\(sha256).\(ext)"
        return "blobs/\(prefix)/\(fileName)"
    }

    public func blobURL(sha256: String, fileExtension: String) -> URL {
        root.appendingPathComponent(Self.blobRelativePath(sha256: sha256, fileExtension: fileExtension))
    }

    public func url(forManagedRelativePath relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    public func previewsDirectory(forDocumentID documentID: String) -> URL {
        previewsDirectory.appendingPathComponent(documentID, isDirectory: true)
    }

    public func exportsDirectory(forMatterID matterID: String) -> URL {
        exportsDirectory.appendingPathComponent(matterID, isDirectory: true)
    }

    // MARK: - Managed blob ingest and verification

    /// Reads the caller-owned source exactly once into an app-managed staging
    /// file while computing its digest and byte count. Only those staged bytes
    /// are installed into content-addressed storage; the mutable source is never
    /// opened again during ingest.
    public func ingest(source: URL) throws -> IngestResult {
        guard source.isFileURL, !source.lastPathComponent.isEmpty else {
            throw IntegrityError.invalidSource
        }
        try initializeStorage()
        try Task.checkCancellation()

        let stagedURL = tempDirectory.appendingPathComponent(
            ".blob-ingest-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let stagedHandle = try Self.createExclusiveFile(at: stagedURL)
        var stagedHandleOpen = true
        defer {
            if stagedHandleOpen { try? stagedHandle.close() }
            try? FileManager.default.removeItem(at: stagedURL)
        }

        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { try? sourceHandle.close() }
        var hasher = SHA256()
        var byteSize = 0

        try ingestFaultInjector(.beforeSourceRead)
        while true {
            try Task.checkCancellation()
            guard let chunk = try sourceHandle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            byteSize += chunk.count
            try stagedHandle.write(contentsOf: chunk)
            try ingestFaultInjector(.afterSourceReadChunk)
        }

        try Task.checkCancellation()
        try ingestFaultInjector(.beforeSynchronize)
        try stagedHandle.synchronize()
        try stagedHandle.close()
        stagedHandleOpen = false

        let sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let originalExtension = source.pathExtension
        let relativePath = Self.blobRelativePath(sha256: sha256, fileExtension: originalExtension)
        let destination = try managedURL(forRelativePath: relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try Task.checkCancellation()
        try ingestFaultInjector(.beforeInstall)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try verifyFile(
                at: destination,
                expectedSHA256: sha256,
                expectedByteSize: byteSize,
                relativePath: relativePath
            )
            return IngestResult(
                sha256: sha256,
                byteSize: byteSize,
                originalExtension: originalExtension,
                managedRelativePath: relativePath,
                managedURL: destination,
                disposition: .reusedVerified
            )
        }

        // macOS `RENAME_EXCL` atomically moves the synchronized staging inode
        // without overwriting a destination that won a concurrent race.
        let renameResult = stagedURL.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        if renameResult != 0 {
            if errno == EEXIST {
                _ = try verifyFile(
                    at: destination,
                    expectedSHA256: sha256,
                    expectedByteSize: byteSize,
                    relativePath: relativePath
                )
                return IngestResult(
                    sha256: sha256,
                    byteSize: byteSize,
                    originalExtension: originalExtension,
                    managedRelativePath: relativePath,
                    managedURL: destination,
                    disposition: .reusedVerified
                )
            }
            throw IntegrityError.atomicInstallFailed(errno)
        }
        try Self.synchronizeDirectory(destination.deletingLastPathComponent())

        return IngestResult(
            sha256: sha256,
            byteSize: byteSize,
            originalExtension: originalExtension,
            managedRelativePath: relativePath,
            managedURL: destination,
            disposition: .installed
        )
    }

    /// Resolves a persisted managed path only when it remains contained beneath
    /// this storage root. This is intentionally stricter than the legacy helper,
    /// which remains for non-integrity UI paths until their migration.
    public func managedURL(forRelativePath relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw IntegrityError.invalidManagedPath(relativePath)
        }
        let standardizedRoot = root.standardizedFileURL
        let candidate = standardizedRoot.appendingPathComponent(relativePath).standardizedFileURL
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(standardizedRoot.path + "/"),
              resolvedParent.path.hasPrefix(resolvedRoot.path + "/") else {
            throw IntegrityError.invalidManagedPath(relativePath)
        }
        return candidate
    }

    /// Verifies both identity properties recorded by the database before a
    /// managed file is reused by import, extraction, OCR, or reconciliation.
    @discardableResult
    public func verifyManagedBlob(
        relativePath: String,
        expectedSHA256: String,
        expectedByteSize: Int
    ) throws -> URL {
        guard relativePath.split(separator: "/").first == "blobs" else {
            throw IntegrityError.invalidManagedPath(relativePath)
        }
        let url = try managedURL(forRelativePath: relativePath)
        return try verifyFile(
            at: url,
            expectedSHA256: expectedSHA256,
            expectedByteSize: expectedByteSize,
            relativePath: relativePath
        )
    }

    /// Repairs a missing or corrupt managed path from a caller-selected copy.
    /// The source must have the exact recorded digest; a different document can
    /// never be installed under an existing content-addressed identity. The old
    /// destination remains in place until `DurableFileWriter` validates and
    /// atomically replaces it.
    @discardableResult
    public func repair(
        source: URL,
        expectedSHA256: String,
        expectedByteSize: Int,
        managedRelativePath: String
    ) throws -> URL {
        let staged = try stageSource(source)
        defer { try? FileManager.default.removeItem(at: staged.url) }
        guard staged.sha256 == expectedSHA256, staged.byteSize == expectedByteSize else {
            throw IntegrityError.reimportContentMismatch(
                expectedSHA256: expectedSHA256,
                actualSHA256: staged.sha256
            )
        }

        let destination = try managedURL(forRelativePath: managedRelativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableFileWriter().write(
            to: destination,
            writer: { sink in
                let handle = try FileHandle(forReadingFrom: staged.url)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try sink.write(chunk)
                }
            },
            validator: { candidate in
                _ = try verifyFile(
                    at: candidate,
                    expectedSHA256: expectedSHA256,
                    expectedByteSize: expectedByteSize,
                    relativePath: managedRelativePath
                )
            }
        )
        return try verifyManagedBlob(
            relativePath: managedRelativePath,
            expectedSHA256: expectedSHA256,
            expectedByteSize: expectedByteSize
        )
    }

    private struct StagedSource {
        let url: URL
        let sha256: String
        let byteSize: Int
    }

    private func stageSource(_ source: URL) throws -> StagedSource {
        try initializeStorage()
        let stagedURL = tempDirectory.appendingPathComponent(".blob-repair-\(UUID().uuidString).tmp")
        let output = try Self.createExclusiveFile(at: stagedURL)
        var outputOpen = true
        var completed = false
        defer {
            if outputOpen { try? output.close() }
            if !completed { try? FileManager.default.removeItem(at: stagedURL) }
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var hasher = SHA256()
        var size = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
            size += chunk.count
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        try output.close()
        outputOpen = false
        completed = true
        return StagedSource(
            url: stagedURL,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            byteSize: size
        )
    }

    @discardableResult
    private func verifyFile(
        at url: URL,
        expectedSHA256: String,
        expectedByteSize: Int,
        relativePath: String
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw IntegrityError.missingManagedBlob(relativePath)
        }
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedFile = url.resolvingSymlinksInPath()
        guard resolvedFile.path.hasPrefix(resolvedRoot.path + "/") else {
            throw IntegrityError.invalidManagedPath(relativePath)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.intValue ?? -1
        guard actualSize == expectedByteSize else {
            throw IntegrityError.corruptManagedBlob(
                expectedSHA256,
                expectedByteSize,
                "size_mismatch"
            )
        }
        let actualSHA256 = try Self.sha256Hex(ofFileAt: url)
        guard actualSHA256 == expectedSHA256 else {
            throw IntegrityError.corruptManagedBlob(
                expectedSHA256,
                expectedByteSize,
                "digest_mismatch"
            )
        }
        return url
    }

    private static func createExclusiveFile(at url: URL) throws -> FileHandle {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw IntegrityError.temporaryFileCreationFailed(errno)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw IntegrityError.atomicInstallFailed(errno) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw IntegrityError.atomicInstallFailed(errno)
        }
    }

    // MARK: - Hashing

    /// Computes a hex sha256 of a file by streaming it, so large files do not
    /// have to be fully resident in memory.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension DocumentStorage.IntegrityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "The selected source is not a readable file."
        case .invalidManagedPath:
            return "The managed blob path is invalid."
        case .temporaryFileCreationFailed:
            return "A managed staging file could not be created."
        case .atomicInstallFailed:
            return "The managed blob could not be installed durably."
        case .missingManagedBlob:
            return "The managed document file is missing."
        case .corruptManagedBlob:
            return "The managed document file does not match its recorded identity."
        case .reimportContentMismatch:
            return "The selected replacement is not the same document content."
        }
    }
}
