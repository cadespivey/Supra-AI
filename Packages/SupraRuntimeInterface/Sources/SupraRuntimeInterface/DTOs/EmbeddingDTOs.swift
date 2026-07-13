import Foundation
import SupraCore

// Milestone 3: explicit embedding model operations over the existing runtime XPC
// boundary (plan §1.4). Kept separate from chat generation DTOs so embedding work
// never overloads `generate`.

public enum EmbeddingModelState: String, Codable, Sendable {
    case unloaded
    case loading
    case loaded
    case failed
}

/// Request to load (or confirm loadable) a local embedding model into the runtime.
public struct LoadEmbeddingModelRequest: Codable, Sendable {
    public let embeddingModelID: DocumentEmbeddingModelID
    public let modelPath: String
    public let displayName: String
    public let revision: String?
    /// The vector dimension the app expects, when known, for a post-load check.
    public let expectedDimension: Int?
    /// A plain (non-security-scoped) bookmark of the model directory, minted by
    /// the app while it holds access, so the sandboxed runtime can read it.
    public let modelBookmark: Data?
    /// Canonical managed root used to reject traversal and symlink escapes.
    /// Custom user-selected model folders leave this nil.
    public let managedRootPath: String?

    public init(
        embeddingModelID: DocumentEmbeddingModelID,
        modelPath: String,
        displayName: String,
        revision: String? = nil,
        expectedDimension: Int? = nil,
        modelBookmark: Data? = nil,
        managedRootPath: String? = nil
    ) {
        self.embeddingModelID = embeddingModelID
        self.modelPath = modelPath
        self.displayName = displayName
        self.revision = revision
        self.expectedDimension = expectedDimension
        self.modelBookmark = modelBookmark
        self.managedRootPath = managedRootPath
    }
}

public struct LoadEmbeddingModelResponse: Codable, Sendable {
    public let state: EmbeddingModelState
    public let embeddingModelID: DocumentEmbeddingModelID?
    public let dimension: Int?
    public let loadTimeMs: Int?
    public let error: RuntimeError?

    public init(
        state: EmbeddingModelState,
        embeddingModelID: DocumentEmbeddingModelID? = nil,
        dimension: Int? = nil,
        loadTimeMs: Int? = nil,
        error: RuntimeError? = nil
    ) {
        self.state = state
        self.embeddingModelID = embeddingModelID
        self.dimension = dimension
        self.loadTimeMs = loadTimeMs
        self.error = error
    }
}

/// Request to embed a batch of texts with the currently loaded embedding model.
public struct EmbedTextRequest: Codable, Sendable {
    public let embeddingModelID: DocumentEmbeddingModelID
    public let texts: [String]
    /// When true (default), vectors are L2-normalized at the runtime so cosine
    /// similarity reduces to a dot product.
    public let normalize: Bool

    public init(embeddingModelID: DocumentEmbeddingModelID, texts: [String], normalize: Bool = true) {
        self.embeddingModelID = embeddingModelID
        self.texts = texts
        self.normalize = normalize
    }
}

public struct EmbedTextResponse: Codable, Sendable {
    public let state: EmbeddingModelState
    /// One vector per input text, in order. Empty on failure.
    public let vectors: [[Float]]
    public let dimension: Int?
    public let normalized: Bool
    public let error: RuntimeError?

    public init(
        state: EmbeddingModelState,
        vectors: [[Float]] = [],
        dimension: Int? = nil,
        normalized: Bool = true,
        error: RuntimeError? = nil
    ) {
        self.state = state
        self.vectors = vectors
        self.dimension = dimension
        self.normalized = normalized
        self.error = error
    }
}

/// Current embedding-runtime status, returned by `embeddingStatus()`.
public struct EmbeddingModelStatus: Codable, Sendable {
    public let state: EmbeddingModelState
    public let embeddingModelID: DocumentEmbeddingModelID?
    public let dimension: Int?
    public let message: String?

    public init(
        state: EmbeddingModelState,
        embeddingModelID: DocumentEmbeddingModelID? = nil,
        dimension: Int? = nil,
        message: String? = nil
    ) {
        self.state = state
        self.embeddingModelID = embeddingModelID
        self.dimension = dimension
        self.message = message
    }
}
