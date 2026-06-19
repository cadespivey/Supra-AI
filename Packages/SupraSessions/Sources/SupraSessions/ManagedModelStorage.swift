import Foundation

/// Resolves the app-managed directory where downloaded models are stored, inside
/// the app's Application Support container. Models the app downloads live here
/// (as opposed to user-selected folders, which are reached via security-scoped
/// bookmarks). Used by both the downloader and the load path.
public enum ManagedModelStorage {
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
        let root = modelsDirectory(fileManager: fileManager).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    /// A filesystem-safe folder name for a Hugging Face repo id (e.g. "org/name").
    public static func folderName(forRepoID repoID: String) -> String {
        repoID.replacingOccurrences(of: "/", with: "__")
    }
}
