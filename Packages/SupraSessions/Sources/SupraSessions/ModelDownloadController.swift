import Combine
import Foundation
import SupraStore

/// Drives a guided Hugging Face model download: lists the repo's files,
/// downloads them into the app-managed models directory, and registers the
/// result in the model library so it can be loaded like any other model.
@MainActor
public final class ModelDownloadController: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case preparing(repoID: String)
        case downloading(repoID: String, completedFiles: Int, totalFiles: Int, currentFile: String)
        case finished(repoID: String, displayName: String)
        case failed(message: String)
    }

    @Published public private(set) var state: State = .idle

    private let store: SupraStore
    private let modelLibrary: ModelLibrary
    private let fetcher: ModelRepositoryFetching
    private let modelsDirectory: URL
    private var task: Task<Void, Never>?

    public init(
        store: SupraStore,
        modelLibrary: ModelLibrary,
        fetcher: ModelRepositoryFetching,
        modelsDirectory: URL = ManagedModelStorage.modelsDirectory()
    ) {
        self.store = store
        self.modelLibrary = modelLibrary
        self.fetcher = fetcher
        self.modelsDirectory = modelsDirectory
    }

    public var isBusy: Bool {
        switch state {
        case .preparing, .downloading: true
        default: false
        }
    }

    public func download(repoID: String, displayName: String? = nil) {
        guard !isBusy else { return }
        let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task = Task { await self.performDownload(repoID: trimmed, displayName: displayName) }
    }

    public func downloadCatalogModel(_ model: CatalogModel) {
        download(repoID: model.repoID, displayName: model.displayName)
    }

    public func cancel() {
        task?.cancel()
    }

    public func dismissResult() {
        if case .preparing = state { return }
        if case .downloading = state { return }
        state = .idle
    }

    func performDownload(repoID: String, displayName: String?) async {
        let name = displayName ?? repoID
        let destinationRoot = modelsDirectory
            .appendingPathComponent(ManagedModelStorage.folderName(forRepoID: repoID), isDirectory: true)

        state = .preparing(repoID: repoID)

        do {
            let files = try await fetcher.listModelFiles(repoID: repoID)

            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                state = .downloading(
                    repoID: repoID,
                    completedFiles: index,
                    totalFiles: files.count,
                    currentFile: file
                )
                try await fetcher.downloadFile(
                    repoID: repoID,
                    file: file,
                    to: destinationRoot.appendingPathComponent(file)
                )
            }
            try Task.checkCancellation()

            registerIfNeeded(displayName: name, path: destinationRoot.path)
            state = .finished(repoID: repoID, displayName: name)
        } catch {
            try? FileManager.default.removeItem(at: destinationRoot)
            // A user cancel surfaces as CancellationError (between files) or
            // URLError.cancelled (mid-download); both reset cleanly to idle.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                state = .idle
            } else {
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    private func registerIfNeeded(displayName: String, path: String) {
        let alreadyRegistered = (try? store.models.fetchModels())?.contains { $0.path == path } ?? false
        guard !alreadyRegistered else {
            modelLibrary.refresh()
            return
        }
        try? modelLibrary.addModel(displayName: displayName, path: path, bookmarkData: nil)
    }
}
