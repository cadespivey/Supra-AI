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
            let manifest = try await fetcher.fetchManifest(repoID: repoID)
            try manifest.validateStructure()
            guard manifest.repositoryID == repoID else {
                throw ManagedModelIntegrityError.manifestMismatch
            }
            // Reject incompatible architectures up front, before downloading
            // gigabytes of weights for a model the runtime can't load. This probe is
            // pinned to the same resolved revision and fails closed.
            guard let configJSON = try await fetcher.fetchConfigJSON(
                repoID: repoID,
                revision: manifest.revision
            ) else {
                throw ManagedModelIntegrityError.missingRequiredFile("config.json")
            }
            guard let configArtifact = manifest.files.first(where: { $0.relativePath == "config.json" }) else {
                throw ManagedModelIntegrityError.missingRequiredFile("config.json")
            }
            try ModelArtifactIntegrity.verify(configJSON, against: configArtifact)
            if let reason = ModelCompatibility.unsupportedReason(configJSON: configJSON) {
                state = .failed(message: reason)
                return
            }

            try await ManagedModelDownloader.downloadFiles(
                manifest: manifest,
                destinationRoot: destinationRoot,
                fetcher: fetcher
            ) { [weak self] completed, total, file in
                self?.state = .downloading(
                    repoID: repoID, completedFiles: completed, totalFiles: total, currentFile: file
                )
            }

            let installed = try ManagedModelStorage.loadVerifiedManifest(at: destinationRoot)
            guard installed == manifest.canonicalized() else {
                throw ManagedModelIntegrityError.manifestMismatch
            }
            try registerIfNeeded(displayName: name, path: destinationRoot.path)
            state = .finished(repoID: repoID, displayName: name)
        } catch {
            // Keep completed files in place so a re-run resumes rather than restarts.
            // A user cancel surfaces as CancellationError or URLError.cancelled; both
            // reset cleanly to idle.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                state = .idle
            } else {
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    private func registerIfNeeded(displayName: String, path: String) throws {
        let alreadyRegistered = (try? store.models.fetchModels())?.contains { $0.path == path } ?? false
        guard !alreadyRegistered else {
            modelLibrary.refresh()
            return
        }
        _ = try modelLibrary.addModel(displayName: displayName, path: path, bookmarkData: nil)
    }
}
