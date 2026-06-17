import Foundation
import CryptoKit

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
    public let root: URL

    public init(root: URL) {
        self.root = root
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
