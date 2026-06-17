import Combine
import Foundation
import SupraCore
import SupraStore

/// Drives a guided Hugging Face embedding-model download into app-managed
/// storage and registers the result as a `DocumentEmbeddingModelRecord` so it can
/// be selected and test-loaded during Document Intelligence setup (plan §2.2).
/// Separate from `ModelDownloadController`, which handles chat models.
@MainActor
public final class EmbeddingModelDownloadController: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case preparing(repoID: String)
        case downloading(repoID: String, completedFiles: Int, totalFiles: Int, currentFile: String)
        case finished(repoID: String, displayName: String)
        case failed(message: String)
    }

    @Published public private(set) var state: State = .idle

    private let store: SupraStore
    private let fetcher: ModelRepositoryFetching
    private let modelsDirectory: URL
    private var task: Task<Void, Never>?

    public init(
        store: SupraStore,
        fetcher: ModelRepositoryFetching,
        modelsDirectory: URL = ManagedModelStorage.embeddingModelsDirectory()
    ) {
        self.store = store
        self.fetcher = fetcher
        self.modelsDirectory = modelsDirectory
    }

    public var isBusy: Bool {
        switch state {
        case .preparing, .downloading: true
        default: false
        }
    }

    public func downloadCatalogModel(_ model: CatalogEmbeddingModel) {
        download(
            repoID: model.repoID,
            displayName: model.displayName,
            dimension: model.dimension,
            runtimeFamily: model.runtimeFamily,
            selectAfterDownload: true
        )
    }

    public func download(
        repoID: String,
        displayName: String,
        dimension: Int,
        runtimeFamily: String,
        selectAfterDownload: Bool
    ) {
        guard !isBusy else { return }
        let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task = Task {
            await self.performDownload(
                repoID: trimmed,
                displayName: displayName,
                dimension: dimension,
                runtimeFamily: runtimeFamily,
                selectAfterDownload: selectAfterDownload
            )
        }
    }

    public func cancel() {
        task?.cancel()
    }

    public func dismissResult() {
        if case .preparing = state { return }
        if case .downloading = state { return }
        state = .idle
    }

    func performDownload(
        repoID: String,
        displayName: String,
        dimension: Int,
        runtimeFamily: String,
        selectAfterDownload: Bool
    ) async {
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

            try registerModel(
                repoID: repoID,
                displayName: displayName,
                dimension: dimension,
                runtimeFamily: runtimeFamily,
                path: destinationRoot.path,
                select: selectAfterDownload
            )
            state = .finished(repoID: repoID, displayName: displayName)
        } catch {
            try? FileManager.default.removeItem(at: destinationRoot)
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                state = .idle
            } else {
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    private func registerModel(
        repoID: String,
        displayName: String,
        dimension: Int,
        runtimeFamily: String,
        path: String,
        select: Bool
    ) throws {
        // Reuse an existing record for this repo if one is already registered.
        let existing = (try? store.documentSettings.fetchEmbeddingModels())?.first { $0.repoID == repoID }
        let record = DocumentEmbeddingModelRecord(
            id: existing?.id ?? UUID().uuidString,
            repoID: repoID,
            localPath: path,
            displayName: displayName,
            dimension: dimension,
            runtimeFamily: runtimeFamily,
            isDefault: existing?.isDefault ?? (repoID == EmbeddingModelCatalog.defaultModel.repoID),
            isSelected: existing?.isSelected ?? false,
            createdAt: existing?.createdAt ?? Date()
        )
        try store.documentSettings.upsertEmbeddingModel(record)
        if select {
            try store.documentSettings.selectEmbeddingModel(id: record.id)
            // Selecting a new embedding model invalidates prior setup completion.
            try? store.documentSettings.invalidateSetup(reason: "embedding model changed")
            _ = try? store.auditEvents.recordEvent(
                eventType: "document_intelligence_setup_changed",
                actor: "user",
                summary: "Selected embedding model \(displayName)",
                relatedTable: "document_embedding_models",
                relatedID: record.id
            )
        }
    }
}
