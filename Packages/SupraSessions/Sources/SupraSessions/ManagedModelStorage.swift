import Foundation
import SupraDocuments

/// Resolves the app-managed directory where downloaded models are stored, inside
/// the app's Application Support container. Models the app downloads live here
/// (as opposed to user-selected folders, which are reached via security-scoped
/// bookmarks). Used by both the downloader and the load path.
public enum ManagedModelStorage {
    public static let manifestFileName = ".supra-model-manifest.json"
    static let downloadStateFileName = ".supra-model-download-state.json"
    /// A single legacy filename emitted during the July 2026 local qualification
    /// workflow. Recovery is deliberately exact: this is not a general search for
    /// arbitrary JSON that could be promoted into load authority.
    private static let recoverableMisnamedManifestFileName = " .json"

    public static func modelsDirectory(
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
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// The app-managed directory for downloaded embedding models (Milestone 3),
    /// kept separate from runtime text models so the two are never confused.
    public static func embeddingModelsDirectory(
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
            .appendingPathComponent("EmbeddingModels", isDirectory: true)
    }

    /// Whether a stored model path lives inside the managed models directory,
    /// meaning the app owns it and can mint a bookmark directly (no security scope).
    public static func isManaged(path: String, fileManager: FileManager = .default) -> Bool {
        isManaged(path: path, roots: [modelsDirectory(fileManager: fileManager)])
    }

    /// Whether a path belongs to the app-managed embedding-model root.
    public static func isManagedEmbedding(path: String, fileManager: FileManager = .default) -> Bool {
        isManaged(path: path, roots: [embeddingModelsDirectory(fileManager: fileManager)])
    }

    static func isManaged(path: String, roots: [URL]) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return roots.contains { rootURL in
            let root = rootURL.standardizedFileURL.path
            return candidate == root || candidate.hasPrefix(root + "/")
        }
    }

    /// A filesystem-safe folder name for a Hugging Face repo id (e.g. "org/name").
    public static func folderName(forRepoID repoID: String) -> String {
        repoID.replacingOccurrences(of: "/", with: "__")
    }

    public static func manifestURL(in modelDirectory: URL) -> URL {
        modelDirectory.appendingPathComponent(manifestFileName, isDirectory: false)
    }

    static func hasRecoverableMisnamedManifest(
        in modelDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let canonicalURL = manifestURL(in: modelDirectory)
        let candidateURL = modelDirectory.appendingPathComponent(
            recoverableMisnamedManifestFileName,
            isDirectory: false
        )
        return !fileManager.fileExists(atPath: canonicalURL.path)
            && fileManager.fileExists(atPath: candidateURL.path)
    }

    /// Recovers only the known legacy filename after validating the candidate
    /// manifest and re-hashing every artifact it authorizes. The canonical
    /// manifest is written atomically, and the candidate is removed only after
    /// the installed manifest is re-read successfully. Any mismatch leaves the
    /// candidate in place and creates no load authority.
    @discardableResult
    static func repairMisnamedManifest(
        in modelDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> ModelArtifactManifest {
        let canonicalURL = manifestURL(in: modelDirectory)
        if fileManager.fileExists(atPath: canonicalURL.path) {
            return try loadVerifiedManifest(at: modelDirectory)
        }

        let candidateURL = modelDirectory.appendingPathComponent(
            recoverableMisnamedManifestFileName,
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: candidateURL.path) else {
            throw ManagedModelIntegrityError.manifestMissing
        }

        let candidate = try readManifest(at: candidateURL)
        try verifyFiles(in: modelDirectory, manifest: candidate)
        try writeManifest(candidate, to: canonicalURL)

        do {
            let installed = try readManifest(at: canonicalURL)
            guard installed == candidate else {
                throw ManagedModelIntegrityError.manifestMismatch
            }
            try fileManager.removeItem(at: candidateURL)
            return installed
        } catch {
            try? fileManager.removeItem(at: canonicalURL)
            throw error
        }
    }

    static func downloadStateURL(in modelDirectory: URL) -> URL {
        modelDirectory.appendingPathComponent(downloadStateFileName, isDirectory: false)
    }

    /// Reads the completion manifest and verifies every required file before a
    /// managed model can be registered or loaded.
    public static func loadVerifiedManifest(at modelDirectory: URL) throws -> ModelArtifactManifest {
        let manifest = try readManifest(at: manifestURL(in: modelDirectory))
        try verifyFiles(in: modelDirectory, manifest: manifest)
        return manifest
    }

    static func readManifest(at url: URL) throws -> ModelArtifactManifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ManagedModelIntegrityError.manifestMissing
        }
        guard !isSymbolicLink(url) else {
            throw ManagedModelIntegrityError.unsafeDestination(url.lastPathComponent)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 10 * 1_024 * 1_024 else {
            throw ManagedModelIntegrityError.manifestMismatch
        }
        let manifest = try JSONDecoder().decode(ModelArtifactManifest.self, from: Data(contentsOf: url))
            .canonicalized()
        try manifest.validateStructure()
        return manifest
    }

    static func writeManifest(_ manifest: ModelArtifactManifest, to url: URL) throws {
        let canonical = manifest.canonicalized()
        try canonical.validateStructure()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(canonical)
        try DurableFileWriter().write(data, to: url) { temporary in
            let decoded = try JSONDecoder().decode(
                ModelArtifactManifest.self,
                from: Data(contentsOf: temporary)
            ).canonicalized()
            guard decoded == canonical else { throw ManagedModelIntegrityError.manifestMismatch }
        }
    }

    static func verifyFiles(in modelDirectory: URL, manifest: ModelArtifactManifest) throws {
        try manifest.validateStructure()
        for artifact in manifest.files {
            let url = try safeDestination(for: artifact.relativePath, in: modelDirectory)
            try ModelArtifactIntegrity.verify(url, against: artifact)
        }

        let configURL = try safeDestination(for: "config.json", in: modelDirectory)
        let data = try Data(contentsOf: configURL)
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let modelType = object["model_type"] as? String,
            !modelType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ManagedModelIntegrityError.invalidConfiguration
        }
    }

    static func safeDestination(for relativePath: String, in modelDirectory: URL) throws -> URL {
        try ModelArtifactManifest.validate(relativePath: relativePath)
        let root = modelDirectory.standardizedFileURL
        guard root.isFileURL else {
            throw ManagedModelIntegrityError.unsafeDestination(relativePath)
        }
        if isSymbolicLink(root) {
            throw ManagedModelIntegrityError.unsafeDestination(relativePath)
        }

        let destination = relativePath.split(separator: "/").reduce(root) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }.standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else {
            throw ManagedModelIntegrityError.unsafeDestination(relativePath)
        }
        if isSymbolicLink(destination) {
            throw ManagedModelIntegrityError.unsafeDestination(relativePath)
        }

        var current = root
        for component in relativePath.split(separator: "/").dropLast() {
            current.appendPathComponent(String(component), isDirectory: true)
            if isSymbolicLink(current) {
                throw ManagedModelIntegrityError.unsafeDestination(relativePath)
            }
        }
        return destination
    }

    static func containsSymbolicLinks(in directory: URL) -> Bool {
        if isSymbolicLink(directory) { return true }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) else { return false }
        for case let url as URL in enumerator {
            if isSymbolicLink(url) { return true }
        }
        return false
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
