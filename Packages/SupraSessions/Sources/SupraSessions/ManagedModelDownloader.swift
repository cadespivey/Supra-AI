import Foundation

/// Shared file-transfer engine for managed model downloads (text + embedding).
///
/// - **Parallel:** downloads a repo's files with bounded concurrency rather than one
///   at a time, so a multi-file model lands much faster.
/// - **Checkpointed:** a file already at its final path is complete (each file lands
///   atomically via the fetcher's temp→final move), so a re-run skips it and resumes
///   where an interrupted download left off. Callers must therefore NOT delete the
///   partially-downloaded folder on cancel/failure.
enum ManagedModelDownloader {
    /// Maximum simultaneous file transfers per model. Enough to saturate a fast link
    /// without overwhelming the connection or the Hub.
    static let maxConcurrentFiles = 4

    /// Downloads every file in `repoID` into `destinationRoot`, skipping files already
    /// present, reporting progress on the main actor as each completes. Throws on the
    /// first failure or on cancellation; completed files are left in place for resume.
    @MainActor
    static func downloadFiles(
        repoID: String,
        destinationRoot: URL,
        fetcher: ModelRepositoryFetching,
        maxConcurrent: Int = maxConcurrentFiles,
        onProgress: @MainActor (_ completedFiles: Int, _ totalFiles: Int, _ currentFile: String) -> Void
    ) async throws {
        let files = try await fetcher.listModelFiles(repoID: repoID)
        let fileManager = FileManager.default
        let pending = files.filter { file in
            let url = destinationRoot.appendingPathComponent(file)
            return !Self.isCompleteFile(url, fileManager: fileManager)
        }
        var completed = files.count - pending.count
        onProgress(completed, files.count, "")
        guard !pending.isEmpty else { return }

        try await withThrowingTaskGroup(of: String.self) { group in
            var iterator = pending.makeIterator()
            var inFlight = 0

            func startNext() {
                guard let file = iterator.next() else { return }
                let destination = destinationRoot.appendingPathComponent(file)
                group.addTask {
                    try await fetcher.downloadFile(repoID: repoID, file: file, to: destination)
                    return file
                }
                inFlight += 1
            }

            for _ in 0..<min(maxConcurrent, pending.count) { startNext() }
            while inFlight > 0 {
                let finishedFile = try await group.next() ?? ""
                inFlight -= 1
                completed += 1
                onProgress(completed, files.count, finishedFile)
                try Task.checkCancellation()
                startNext()
            }
        }

        let incomplete = files.filter {
            !Self.isCompleteFile(destinationRoot.appendingPathComponent($0), fileManager: fileManager)
        }
        if let first = incomplete.first {
            throw ManagedModelDownloadError.incompleteFile(first)
        }
    }

    private static func isCompleteFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }
}

enum ManagedModelDownloadError: LocalizedError, Equatable {
    case incompleteFile(String)

    var errorDescription: String? {
        switch self {
        case let .incompleteFile(file):
            return "Download did not produce a complete model file: \(file)."
        }
    }
}
