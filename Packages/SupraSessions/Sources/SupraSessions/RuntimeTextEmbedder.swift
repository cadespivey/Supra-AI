import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

public enum TextEmbedderError: Error, LocalizedError {
    case modelNotDownloaded
    case loadFailed(String)
    case embedFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotDownloaded: "The embedding model is not downloaded."
        case .loadFailed(let m): "The embedding model failed to load: \(m)"
        case .embedFailed(let m): "Embedding failed: \(m)"
        }
    }
}

/// `TextEmbedder` backed by the runtime XPC service. Loads the embedding model on
/// first use and embeds in batches (plan §1.4, §7.3).
public actor RuntimeTextEmbedder: TextEmbedder {
    public nonisolated let modelID: String
    public nonisolated let modelDisplayName: String
    public nonisolated let modelRevision: String?
    public nonisolated let dimension: Int

    private let embeddingModelID: DocumentEmbeddingModelID
    private let modelPath: String
    private let runtimeClient: any RuntimeClientProtocol
    private let batchSize: Int
    private var loaded = false

    public init?(model: DocumentEmbeddingModelRecord, runtimeClient: any RuntimeClientProtocol, batchSize: Int = 32) {
        guard let path = model.localPath, !path.isEmpty else { return nil }
        self.modelID = model.id
        self.modelDisplayName = model.displayName
        self.modelRevision = model.revision
        self.dimension = model.dimension
        self.embeddingModelID = DocumentEmbeddingModelID(UUID(uuidString: model.id) ?? UUID())
        self.modelPath = path
        self.runtimeClient = runtimeClient
        self.batchSize = max(1, batchSize)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        try await ensureLoaded()
        var result: [[Float]] = []
        var index = 0
        while index < texts.count {
            let batch = Array(texts[index..<min(index + batchSize, texts.count)])
            let response = try await runtimeClient.embedTexts(
                EmbedTextRequest(embeddingModelID: embeddingModelID, texts: batch, normalize: true)
            )
            guard response.state == .loaded, response.vectors.count == batch.count else {
                throw TextEmbedderError.embedFailed(response.error?.message ?? "incomplete embedding batch")
            }
            result.append(contentsOf: response.vectors)
            index += batchSize
        }
        return result
    }

    private func ensureLoaded() async throws {
        if loaded { return }
        let bookmark = try? URL(fileURLWithPath: modelPath, isDirectory: true).bookmarkData(options: [])
        let response = try await runtimeClient.loadEmbeddingModel(
            LoadEmbeddingModelRequest(
                embeddingModelID: embeddingModelID,
                modelPath: modelPath,
                displayName: modelDisplayName,
                revision: modelRevision,
                expectedDimension: dimension,
                modelBookmark: bookmark
            )
        )
        guard response.state == .loaded else {
            throw TextEmbedderError.loadFailed(response.error?.message ?? "unknown error")
        }
        loaded = true
    }
}
