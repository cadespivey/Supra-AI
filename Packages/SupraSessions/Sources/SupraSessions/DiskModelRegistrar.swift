import Foundation

/// Rebuilds a model registry from DISK truth for an isolated probe launch
/// (measurement qualification, review finding #5): every subdirectory of the managed
/// model root whose completion manifest verifies (`ManagedModelStorage.
/// loadVerifiedManifest` — existence, sizes, and a valid config) is registered into
/// the supplied library's (throwaway) store.
///
/// This is what lets the headless probes answer "which models are downloaded, and
/// can they hold the typed schema" WITHOUT opening the user's database: the model
/// files live in the app container and are readable by the app, while the user's
/// registry rows, role assignments, and active-model selection stay untouched.
public enum DiskModelRegistrar {
    /// Registers every manifest-verified model folder under `root` into `library`.
    /// Deterministic (folders scanned in name order) and duplicate-safe (a path the
    /// library already carries is not re-registered). Returns the display names of
    /// the models registered by THIS call, in registration order.
    @MainActor
    @discardableResult
    public static func registerVerifiedModels(
        into library: ModelLibrary,
        root: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        let folders = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let knownPaths = Set(library.models.map(\.path))
        var registered: [String] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard !knownPaths.contains(folder.path) else { continue }
            // Fail closed per folder: anything that does not verify is skipped, never
            // guessed at — a probe registry must not be more permissive than the app.
            guard let manifest = try? ManagedModelStorage.loadVerifiedManifest(at: folder) else { continue }
            let displayName = manifest.repositoryID
            if (try? library.addModel(displayName: displayName, path: folder.path, bookmarkData: nil)) != nil {
                registered.append(displayName)
            }
        }
        return registered
    }
}
