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
        onProgress: @escaping @MainActor (ModelDownloadProgress) -> Void
    ) async throws {
        let manifest = suppliedManifest.canonicalized()
        try manifest.validateStructure()
        let totalFiles = manifest.files.count
        let totalBytes = manifest.files.reduce(Int64(0)) { $0 + $1.size }
        let alreadyComplete = try prepare(destinationRoot: destinationRoot, manifest: manifest)
        if alreadyComplete {
            onProgress(ModelDownloadProgress(
                completedFiles: totalFiles, totalFiles: totalFiles, currentFile: "",
                bytesReceived: totalBytes, totalBytes: totalBytes
            ))
            return
        }

        let pending = manifest.files.filter { artifact in
            guard let destination = try? ManagedModelStorage.safeDestination(
                for: artifact.relativePath,
                in: destinationRoot
            ) else { return true }
            return !isVerified(destination, artifact: artifact)
        }
        // Files reused from an interrupted earlier run count as received bytes
        // from the very first emission, so a resumed bar starts partly filled.
        let aggregator = ProgressAggregator(
            completedFiles: totalFiles - pending.count,
            totalFiles: totalFiles,
            verifiedBytes: totalBytes - pending.reduce(Int64(0)) { $0 + $1.size },
            totalBytes: totalBytes,
            onProgress: onProgress
        )
        aggregator.emit(currentFile: "", force: true)

        if !pending.isEmpty {
            try await withThrowingTaskGroup(of: ModelArtifactManifest.File.self) { group in
                var iterator = pending.makeIterator()
                var inFlight = 0

                func startNext() {
                    guard let artifact = iterator.next() else { return }
                    group.addTask {
                        try await download(
                            artifact,
                            manifest: manifest,
                            destinationRoot: destinationRoot,
                            fetcher: fetcher,
                            onBytes: { bytes in
                                await aggregator.reportInFlightBytes(bytes, for: artifact)
                            }
                        )
                        return artifact
                    }
                    inFlight += 1
                }

                for _ in 0..<min(max(1, maxConcurrent), pending.count) { startNext() }
                while inFlight > 0 {
                    guard let finished = try await group.next() else { break }
                    inFlight -= 1
                    aggregator.completeFile(finished)
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

    /// Serializes byte reports from up to `maxConcurrent` transfer tasks into
    /// monotonic whole-download progress emissions. Emissions are throttled to
    /// ~0.5% steps of the total (always on file completion), so a 17 GB repo
    /// publishes a few hundred state updates instead of tens of thousands.
    @MainActor
    private final class ProgressAggregator {
        private var completedFiles: Int
        private let totalFiles: Int
        private var verifiedBytes: Int64
        private let totalBytes: Int64
        private var inFlight: [String: Int64] = [:]
        private var lastEmittedBytes: Int64 = -1
        private let emitStride: Int64
        private let onProgress: @MainActor (ModelDownloadProgress) -> Void

        init(
            completedFiles: Int,
            totalFiles: Int,
            verifiedBytes: Int64,
            totalBytes: Int64,
            onProgress: @escaping @MainActor (ModelDownloadProgress) -> Void
        ) {
            self.completedFiles = completedFiles
            self.totalFiles = totalFiles
            self.verifiedBytes = verifiedBytes
            self.totalBytes = totalBytes
            self.emitStride = max(1, totalBytes / 200)
            self.onProgress = onProgress
        }

        func reportInFlightBytes(_ bytes: Int64, for artifact: ModelArtifactManifest.File) {
            // Reports are cumulative but can arrive out of order across executor
            // hops; keep the max and clamp to the manifest size so a transfer
            // can never account for more than its artifact.
            let clamped = min(max(bytes, inFlight[artifact.relativePath] ?? 0), artifact.size)
            inFlight[artifact.relativePath] = clamped
            emit(currentFile: artifact.relativePath, force: false)
        }

        func completeFile(_ artifact: ModelArtifactManifest.File) {
            inFlight[artifact.relativePath] = nil
            verifiedBytes += artifact.size
            completedFiles += 1
            emit(currentFile: artifact.relativePath, force: true)
        }

        func emit(currentFile: String, force: Bool) {
            let received = min(totalBytes, verifiedBytes + inFlight.values.reduce(0, +))
            guard force || received - lastEmittedBytes >= emitStride else { return }
            lastEmittedBytes = received
            onProgress(ModelDownloadProgress(
                completedFiles: completedFiles,
                totalFiles: totalFiles,
                currentFile: currentFile,
                bytesReceived: received,
                totalBytes: totalBytes
            ))
        }
    }

    private static func download(
        _ artifact: ModelArtifactManifest.File,
        manifest: ModelArtifactManifest,
        destinationRoot: URL,
        fetcher: ModelRepositoryFetching,
        onBytes: @escaping @Sendable (Int64) async -> Void
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
            to: partial,
            onBytes: onBytes
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
