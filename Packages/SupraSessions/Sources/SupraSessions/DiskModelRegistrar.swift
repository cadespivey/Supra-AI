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
public struct VerifiedModelArtifactBinding {
    public let model: ModelSummary
    public let repositoryID: String
    public let revision: String
    public let manifestSHA256: String
    public let contentBindingAlgorithm: String
    public let contentBindingSchemaVersion: Int
    public let artifactFingerprintSHA256: String
}

public enum DiskModelRegistrar {
    /// Registers only the manifest-verified model whose repository identity exactly
    /// matches `repositoryID`. Folder names are storage details, never identity.
    @MainActor
    public static func registerVerifiedModel(
        into library: ModelLibrary,
        root: URL,
        repositoryID: String,
        confinedTo confinementRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> ModelSummary? {
        registerVerifiedModelBinding(
            into: library,
            root: root,
            repositoryID: repositoryID,
            confinedTo: confinementRoot,
            fileManager: fileManager
        )?.model
    }

    /// Returns the registered model together with the exact verified manifest binding
    /// used to qualify it. The manifest digest is a canonical SHA-256 over the complete
    /// revision-pinned manifest, including every artifact path, size, and digest.
    @MainActor
    public static func registerVerifiedModelBinding(
        into library: ModelLibrary,
        root: URL,
        repositoryID: String,
        confinedTo confinementRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> VerifiedModelArtifactBinding? {
        guard let root = confinedRoot(root, to: confinementRoot) else { return nil }
        let folders = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let manifest = try? ManagedModelStorage.loadVerifiedManifest(at: folder),
                  manifest.repositoryID == repositoryID,
                  let manifestSHA256 = manifestSHA256(manifest),
                  let contentBinding = try? SignedReleaseModelAuthorization.inspectContentBinding(
                      modelDirectory: folder,
                      managedRoot: root
                  )
            else { continue }

            let model: ModelSummary
            if let existing = library.models.first(where: { $0.path == folder.path }) {
                model = existing
            } else {
                guard (try? library.addModel(
                    displayName: manifest.repositoryID,
                    path: folder.path,
                    bookmarkData: nil
                )) != nil,
                      let registered = library.models.first(where: { $0.path == folder.path })
                else { return nil }
                model = registered
            }
            return VerifiedModelArtifactBinding(
                model: model,
                repositoryID: manifest.repositoryID,
                revision: manifest.revision,
                manifestSHA256: manifestSHA256,
                contentBindingAlgorithm: contentBinding.algorithm,
                contentBindingSchemaVersion: contentBinding.schemaVersion,
                artifactFingerprintSHA256: contentBinding.fingerprintSHA256
            )
        }
        return nil
    }

    /// Re-verifies the exact manifest and content binding immediately before a probe
    /// executes. Runtime loading independently enforces the same artifact fingerprint.
    public static func bindingStillVerified(
        _ binding: VerifiedModelArtifactBinding,
        root: URL,
        confinedTo confinementRoot: URL? = nil
    ) -> Bool {
        guard let managedRoot = confinedRoot(root, to: confinementRoot) else { return false }
        let modelDirectory = URL(fileURLWithPath: binding.model.path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard modelDirectory.path.hasPrefix(managedRoot.path + "/"),
              let manifest = try? ManagedModelStorage.loadVerifiedManifest(at: modelDirectory),
              let currentManifestSHA256 = manifestSHA256(manifest),
              let contentBinding = try? SignedReleaseModelAuthorization.inspectContentBinding(
                  modelDirectory: modelDirectory,
                  managedRoot: managedRoot
              )
        else { return false }

        return manifest.repositoryID == binding.repositoryID
            && manifest.revision == binding.revision
            && currentManifestSHA256 == binding.manifestSHA256
            && contentBinding.algorithm == binding.contentBindingAlgorithm
            && contentBinding.schemaVersion == binding.contentBindingSchemaVersion
            && contentBinding.fingerprintSHA256 == binding.artifactFingerprintSHA256
    }

    private static func manifestSHA256(_ manifest: ModelArtifactManifest) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(manifest.canonicalized()) else { return nil }
        return ModelArtifactIntegrity.sha256Hex(data)
    }

    /// Registers every manifest-verified model folder under `root` into `library`.
    /// Deterministic (folders scanned in name order) and duplicate-safe (a path the
    /// library already carries is not re-registered). Returns the display names of
    /// the models registered by THIS call, in registration order.
    @MainActor
    @discardableResult
    public static func registerVerifiedModels(
        into library: ModelLibrary,
        root: URL,
        confinedTo confinementRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> [String] {
        guard let root = confinedRoot(root, to: confinementRoot) else { return [] }
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
            guard let manifest = try? ManagedModelStorage.loadVerifiedManifest(at: folder) else { continue }
            let displayName = manifest.repositoryID
            if (try? library.addModel(displayName: displayName, path: folder.path, bookmarkData: nil)) != nil {
                registered.append(displayName)
            }
        }
        return registered
    }

    private static func confinedRoot(_ root: URL, to confinementRoot: URL?) -> URL? {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedConfinement = (confinementRoot ?? root.deletingLastPathComponent())
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard resolvedRoot.path.hasPrefix(resolvedConfinement.path + "/") else { return nil }
        return resolvedRoot
    }
}
