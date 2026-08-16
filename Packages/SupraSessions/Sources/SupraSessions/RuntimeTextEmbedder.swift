import CryptoKit
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
    public nonisolated let modelRepoID: String
    public nonisolated let modelDisplayName: String
    public nonisolated let modelRevision: String?
    public nonisolated let artifactIdentitySHA256: String?
    public nonisolated let dimension: Int

    private let embeddingModelID: DocumentEmbeddingModelID
    private let modelPath: String
    private let runtimeClient: any ModelExecutionGateway
    private var modelExecutionGateway: any ModelExecutionGateway { runtimeClient }
    private let batchSize: Int
    private var loaded = false

    public init?(model: DocumentEmbeddingModelRecord, runtimeClient: any ModelExecutionGateway, batchSize: Int = 32) {
        guard let path = model.localPath, !path.isEmpty else { return nil }
        let artifactIdentitySHA256: String?
        if ManagedModelStorage.isManagedEmbedding(path: path) {
            guard
                let manifest = try? ManagedModelStorage.loadVerifiedManifest(
                    at: URL(fileURLWithPath: path, isDirectory: true)
                ),
                manifest.repositoryID == model.repoID,
                manifest.revision == model.revision,
                let identity = Self.artifactIdentitySHA256(manifest)
            else { return nil }
            artifactIdentitySHA256 = identity
        } else {
            artifactIdentitySHA256 = nil
        }
        self.modelID = model.id
        self.modelRepoID = model.repoID
        self.modelDisplayName = model.displayName
        self.modelRevision = model.revision
        self.artifactIdentitySHA256 = artifactIdentitySHA256
        self.dimension = model.dimension
        self.embeddingModelID = DocumentEmbeddingModelID(UUID(uuidString: model.id) ?? UUID())
        self.modelPath = path
        self.runtimeClient = runtimeClient
        self.batchSize = max(1, batchSize)
    }

    private nonisolated static func artifactIdentitySHA256(
        _ manifest: ModelArtifactManifest
    ) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(manifest.canonicalized()) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        try await ensureLoaded()
        var result: [[Float]] = []
        var index = 0
        while index < texts.count {
            let batch = Array(texts[index..<min(index + batchSize, texts.count)])
            let response = try await modelExecutionGateway.embedTexts(
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
        let embeddingModelURL = URL(fileURLWithPath: modelPath, isDirectory: true)
        let expectedDimension = dimension > 0 ? dimension : nil
        if ManagedModelStorage.isManagedEmbedding(path: modelPath) {
            let prepared = try await ContentBoundEmbeddingAuthorizationExecutor.live.prepare(
                modelDirectory: embeddingModelURL,
                managedRoot: ManagedModelStorage.embeddingModelsDirectory(),
                embeddingModelID: embeddingModelID,
                displayName: modelDisplayName,
                revision: modelRevision,
                expectedDimension: expectedDimension
            )
            let response = try await modelExecutionGateway.loadEmbeddingModel(prepared.request)
            _ = prepared.authorization
            guard response.state == .loaded else {
                throw TextEmbedderError.loadFailed(response.error?.message ?? "unknown error")
            }
            loaded = true
            return
        }

        let access = SecurityScopedModelAccess(
            url: embeddingModelURL
        )
        defer { access.release() }
        guard access.hasAccess,
              let authorization = access.makeTransferableAuthorization() else {
            throw TextEmbedderError.loadFailed("the model-folder security scope could not be activated")
        }
        let response = try await modelExecutionGateway.loadEmbeddingModel(
            LoadEmbeddingModelRequest(
                embeddingModelID: embeddingModelID,
                modelPath: modelPath,
                displayName: modelDisplayName,
                revision: modelRevision,
                // A non-positive dimension means "unknown" (custom model not yet
                // verified): skip the assertion rather than fail the load. Auto-verify
                // normally persists the real dimension before any indexing runs.
                expectedDimension: expectedDimension,
                modelBookmark: authorization.bookmark,
                managedRootPath: nil,
                modelDirectoryIdentity: authorization.directoryIdentity
            )
        )
        guard response.state == .loaded else {
            throw TextEmbedderError.loadFailed(response.error?.message ?? "unknown error")
        }
        loaded = true
    }
}
