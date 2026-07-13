import Darwin
import Foundation

/// Shared, revision-pinned transfer engine for managed text and embedding models.
/// Completed files are reusable only when an atomically written download-state
/// manifest exactly matches fresh repository metadata and each file re-hashes.
enum ManagedModelDownloader {
    static let maxConcurrentFiles = 4

    @MainActor
    static func downloadFiles(
        manifest suppliedManifest: ModelArtifactManifest,
        destinationRoot: URL,
        fetcher: ModelRepositoryFetching,
        maxConcurrent: Int = maxConcurrentFiles,
        onProgress: @MainActor (_ completedFiles: Int, _ totalFiles: Int, _ currentFile: String) -> Void
    ) async throws {
        let manifest = suppliedManifest.canonicalized()
        try manifest.validateStructure()
        let alreadyComplete = try prepare(destinationRoot: destinationRoot, manifest: manifest)
        if alreadyComplete {
            onProgress(manifest.files.count, manifest.files.count, "")
            return
        }

        let pending = manifest.files.filter { artifact in
            guard let destination = try? ManagedModelStorage.safeDestination(
                for: artifact.relativePath,
                in: destinationRoot
            ) else { return true }
            return !isVerified(destination, artifact: artifact)
        }
        var completed = manifest.files.count - pending.count
        onProgress(completed, manifest.files.count, "")

        if !pending.isEmpty {
            try await withThrowingTaskGroup(of: String.self) { group in
                var iterator = pending.makeIterator()
                var inFlight = 0

                func startNext() {
                    guard let artifact = iterator.next() else { return }
                    group.addTask {
                        try await download(
                            artifact,
                            manifest: manifest,
                            destinationRoot: destinationRoot,
                            fetcher: fetcher
                        )
                        return artifact.relativePath
                    }
                    inFlight += 1
                }

                for _ in 0..<min(max(1, maxConcurrent), pending.count) { startNext() }
                while inFlight > 0 {
                    let finishedFile = try await group.next() ?? ""
                    inFlight -= 1
                    completed += 1
                    onProgress(completed, manifest.files.count, finishedFile)
                    try Task.checkCancellation()
                    startNext()
                }
            }
        }

        try ManagedModelStorage.verifyFiles(in: destinationRoot, manifest: manifest)
        try ManagedModelStorage.writeManifest(
            manifest,
            to: ManagedModelStorage.manifestURL(in: destinationRoot)
        )
        try? FileManager.default.removeItem(at: ManagedModelStorage.downloadStateURL(in: destinationRoot))
        removePartialFiles(in: destinationRoot)
    }

    private static func prepare(
        destinationRoot: URL,
        manifest: ModelArtifactManifest
    ) throws -> Bool {
        let fileManager = FileManager.default
        let completionURL = ManagedModelStorage.manifestURL(in: destinationRoot)
        let stateURL = ManagedModelStorage.downloadStateURL(in: destinationRoot)
        var preserveVerifiedFiles = false

        if fileManager.fileExists(atPath: completionURL.path),
           let installed = try? ManagedModelStorage.readManifest(at: completionURL),
           installed == manifest {
            if (try? ManagedModelStorage.verifyFiles(in: destinationRoot, manifest: manifest)) != nil {
                try? fileManager.removeItem(at: stateURL)
                removePartialFiles(in: destinationRoot)
                return true
            }
            // This exact revision was previously complete. Preserve the files that
            // still hash correctly and repair only corrupt/missing artifacts.
            preserveVerifiedFiles = !ManagedModelStorage.containsSymbolicLinks(in: destinationRoot)
            try? fileManager.removeItem(at: completionURL)
        } else if !fileManager.fileExists(atPath: completionURL.path),
                  fileManager.fileExists(atPath: stateURL.path),
                  let state = try? ManagedModelStorage.readManifest(at: stateURL),
                  state == manifest {
            preserveVerifiedFiles = !ManagedModelStorage.containsSymbolicLinks(in: destinationRoot)
        }

        if !preserveVerifiedFiles, fileManager.fileExists(atPath: destinationRoot.path) {
            try fileManager.removeItem(at: destinationRoot)
        }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        removePartialFiles(in: destinationRoot)
        try ManagedModelStorage.writeManifest(manifest, to: stateURL)
        return false
    }

    private static func download(
        _ artifact: ModelArtifactManifest.File,
        manifest: ModelArtifactManifest,
        destinationRoot: URL,
        fetcher: ModelRepositoryFetching
    ) async throws {
        try Task.checkCancellation()
        var destination = try ManagedModelStorage.safeDestination(
            for: artifact.relativePath,
            in: destinationRoot
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Re-resolve after directory creation so an injected symlink cannot turn a
        // previously absent parent into an escape between validation and transfer.
        destination = try ManagedModelStorage.safeDestination(
            for: artifact.relativePath,
            in: destinationRoot
        )
        let partial = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).partial-\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: partial) }

        try await fetcher.downloadFile(
            repoID: manifest.repositoryID,
            revision: manifest.revision,
            artifact: artifact,
            to: partial
        )
        try Task.checkCancellation()

        let handle = try FileHandle(forWritingTo: partial)
        try handle.synchronize()
        try handle.close()
        try ModelArtifactIntegrity.verify(partial, against: artifact)
        try Task.checkCancellation()
        try atomicInstall(partial, at: destination, artifact: artifact.relativePath)
    }

    private static func atomicInstall(_ source: URL, at destination: URL, artifact: String) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw ManagedModelIntegrityError.atomicInstallFailed(artifact)
        }
    }

    private static func isVerified(_ url: URL, artifact: ModelArtifactManifest.File) -> Bool {
        do {
            try ModelArtifactIntegrity.verify(url, against: artifact)
            return true
        } catch {
            return false
        }
    }

    private static func removePartialFiles(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return }
        for case let url as URL in enumerator where url.lastPathComponent.contains(".partial-") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
