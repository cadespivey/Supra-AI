import Foundation

/// Opaque continuation for the Store-owned semantic vector scan. Ordering is
/// the stable chunk primary key, so callers never hold a database cursor across
/// an async boundary or transaction.
public struct DocumentEmbeddingScanCursor: Hashable, Sendable {
    public let lastChunkID: String

    public init(lastChunkID: String) {
        self.lastChunkID = lastChunkID
    }
}

/// One content-free identity plus one persisted vector payload. Chunk text and
/// document metadata are deliberately absent; winners are hydrated only after
/// bounded ranking completes.
public struct DocumentEmbeddingScanEntry: Sendable {
    public let chunkID: String
    public let documentID: String
    public let dimension: Int
    public let vector: Data

    init(chunkID: String, documentID: String, dimension: Int, vector: Data) {
        self.chunkID = chunkID
        self.documentID = documentID
        self.dimension = dimension
        self.vector = vector
    }
}

public struct DocumentEmbeddingScanPage: Sendable {
    public let entries: [DocumentEmbeddingScanEntry]
    public let nextCursor: DocumentEmbeddingScanCursor?

    init(entries: [DocumentEmbeddingScanEntry], nextCursor: DocumentEmbeddingScanCursor?) {
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

public enum DocumentEmbeddingScanError: Error, LocalizedError, Equatable, Sendable {
    case invalidPageSize(Int)
    case emptyDocumentScope
    case settingsNotFound
    case activeModelMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPageSize(let size):
            "Embedding scan page size \(size) must be positive."
        case .emptyDocumentScope:
            "Embedding scan document scope is empty."
        case .settingsNotFound:
            "Document Intelligence settings do not exist."
        case .activeModelMismatch(let modelID):
            "Embedding model \(modelID) is not the exact selected and verified model."
        }
    }
}
