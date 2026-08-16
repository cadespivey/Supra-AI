import Foundation

/// Optimistic, Store-owned publication of one newly selected immutable part
/// revision and all document-level invalidation derived from that selection.
public struct DocumentRevisionSelectionTransitionCommand: Sendable {
    public let documentID: String
    public let partID: String
    public let expectedCurrentRevisionID: String
    public let expectedCurrentSelectionID: String
    public let revision: DocumentPartRevisionRecord
    public let selection: DocumentPartSelectionRecord

    public init(
        documentID: String,
        partID: String,
        expectedCurrentRevisionID: String,
        expectedCurrentSelectionID: String,
        revision: DocumentPartRevisionRecord,
        selection: DocumentPartSelectionRecord
    ) {
        self.documentID = documentID
        self.partID = partID
        self.expectedCurrentRevisionID = expectedCurrentRevisionID
        self.expectedCurrentSelectionID = expectedCurrentSelectionID
        self.revision = revision
        self.selection = selection
    }
}

public struct DocumentRevisionSelectionTransitionReceipt: Sendable {
    public let documentID: String
    public let partID: String
    public let revisionID: String
    public let selectionID: String
    public let readinessReceipt: DocumentReadinessReceipt

    init(
        documentID: String,
        partID: String,
        revisionID: String,
        selectionID: String,
        readinessReceipt: DocumentReadinessReceipt
    ) {
        self.documentID = documentID
        self.partID = partID
        self.revisionID = revisionID
        self.selectionID = selectionID
        self.readinessReceipt = readinessReceipt
    }
}

/// Selects one model only when its immutable identity and successful load-test
/// evidence still exactly match the caller's observed values.
public struct DocumentVerifiedEmbeddingModelSelectionCommand: Sendable {
    public let expectedModel: DocumentReadinessEmbeddingModelIdentity
    public let verifiedAt: Date
    public let setupInvalidationReason: String

    public init(
        expectedModel: DocumentReadinessEmbeddingModelIdentity,
        verifiedAt: Date,
        setupInvalidationReason: String
    ) {
        self.expectedModel = expectedModel
        self.verifiedAt = verifiedAt
        self.setupInvalidationReason = setupInvalidationReason
    }
}

public struct DocumentVerifiedEmbeddingModelSelectionReceipt: Sendable {
    public let activeModel: DocumentReadinessEmbeddingModelIdentity
    public let verifiedAt: Date
    public let setupInvalidationReason: String

    init(
        activeModel: DocumentReadinessEmbeddingModelIdentity,
        verifiedAt: Date,
        setupInvalidationReason: String
    ) {
        self.activeModel = activeModel
        self.verifiedAt = verifiedAt
        self.setupInvalidationReason = setupInvalidationReason
    }
}

/// Publishes a complete replacement text index only if the current selected
/// revision graph and configured chunker still match the producer's snapshot.
public struct DocumentTextIndexCommitCommand: Sendable {
    public let documentID: String
    public let expectedPartBindings: [DocumentReadinessPartBinding]
    public let expectedChunkerVersion: Int
    /// The persisted default observed by the producer. Normally this equals
    /// `expectedChunkerVersion`. A coordinated rollout may keep the prior
    /// default active while staging a complete target projection, then flip the
    /// default once every matter has staged successfully.
    public let expectedActiveChunkerVersion: Int
    /// Whether a complete semantic batch is expected to follow this text
    /// commit. The Store uses this intent to publish an honest in-progress
    /// document status in the same transaction as the chunks and FTS rows.
    public let semanticIndexExpected: Bool
    public let chunks: [DocumentChunkRecord]

    public init(
        documentID: String,
        expectedPartBindings: [DocumentReadinessPartBinding],
        expectedChunkerVersion: Int,
        expectedActiveChunkerVersion: Int? = nil,
        semanticIndexExpected: Bool = false,
        chunks: [DocumentChunkRecord]
    ) {
        self.documentID = documentID
        self.expectedPartBindings = expectedPartBindings
        self.expectedChunkerVersion = expectedChunkerVersion
        self.expectedActiveChunkerVersion = expectedActiveChunkerVersion
            ?? expectedChunkerVersion
        self.semanticIndexExpected = semanticIndexExpected
        self.chunks = chunks
    }
}

public struct DocumentTextIndexCommitReceipt: Sendable {
    public let documentID: String
    public let partBindings: [DocumentReadinessPartBinding]
    public let chunkerVersion: Int
    public let chunkIDs: [String]
    public let readinessReceipt: DocumentReadinessReceipt

    init(
        documentID: String,
        partBindings: [DocumentReadinessPartBinding],
        chunkerVersion: Int,
        chunkIDs: [String],
        readinessReceipt: DocumentReadinessReceipt
    ) {
        self.documentID = documentID
        self.partBindings = partBindings
        self.chunkerVersion = chunkerVersion
        self.chunkIDs = chunkIDs
        self.readinessReceipt = readinessReceipt
    }
}

/// Publishes exactly one complete current-chunk vector batch under one selected,
/// verified model identity before promoting terminal document flags.
public struct DocumentSemanticIndexCommitCommand: Sendable {
    public let documentID: String
    public let expectedChunkIDs: [String]
    public let expectedActiveModel: DocumentReadinessEmbeddingModelIdentity
    public let expectedModelVerifiedAt: Date
    public let embeddings: [DocumentChunkEmbeddingRecord]

    public init(
        documentID: String,
        expectedChunkIDs: [String],
        expectedActiveModel: DocumentReadinessEmbeddingModelIdentity,
        expectedModelVerifiedAt: Date,
        embeddings: [DocumentChunkEmbeddingRecord]
    ) {
        self.documentID = documentID
        self.expectedChunkIDs = expectedChunkIDs
        self.expectedActiveModel = expectedActiveModel
        self.expectedModelVerifiedAt = expectedModelVerifiedAt
        self.embeddings = embeddings
    }
}

public struct DocumentSemanticIndexCommitReceipt: Sendable {
    public let documentID: String
    public let chunkIDs: [String]
    public let activeModel: DocumentReadinessEmbeddingModelIdentity
    public let verifiedAt: Date
    public let embeddingIDs: [String]
    public let readinessReceipt: DocumentReadinessReceipt

    init(
        documentID: String,
        chunkIDs: [String],
        activeModel: DocumentReadinessEmbeddingModelIdentity,
        verifiedAt: Date,
        embeddingIDs: [String],
        readinessReceipt: DocumentReadinessReceipt
    ) {
        self.documentID = documentID
        self.chunkIDs = chunkIDs
        self.activeModel = activeModel
        self.verifiedAt = verifiedAt
        self.embeddingIDs = embeddingIDs
        self.readinessReceipt = readinessReceipt
    }
}

/// Persists one bounded prefix of the current semantic projection without
/// publishing terminal readiness. Completed batches are intentionally durable
/// so a crash or cancellation can resume at the first uncommitted chunk.
public struct DocumentSemanticIndexBatchCommitCommand: Sendable {
    public let documentID: String
    public let expectedChunkIDs: [String]
    public let expectedActiveModel: DocumentReadinessEmbeddingModelIdentity
    public let expectedModelVerifiedAt: Date
    public let embeddings: [DocumentChunkEmbeddingRecord]

    public init(
        documentID: String,
        expectedChunkIDs: [String],
        expectedActiveModel: DocumentReadinessEmbeddingModelIdentity,
        expectedModelVerifiedAt: Date,
        embeddings: [DocumentChunkEmbeddingRecord]
    ) {
        self.documentID = documentID
        self.expectedChunkIDs = expectedChunkIDs
        self.expectedActiveModel = expectedActiveModel
        self.expectedModelVerifiedAt = expectedModelVerifiedAt
        self.embeddings = embeddings
    }
}

public struct DocumentSemanticIndexBatchCommitReceipt: Sendable {
    public let documentID: String
    public let committedChunkIDs: [String]
    public let completedChunkCount: Int
    public let totalChunkCount: Int
    public let readinessReceipt: DocumentReadinessReceipt

    init(
        documentID: String,
        committedChunkIDs: [String],
        completedChunkCount: Int,
        totalChunkCount: Int,
        readinessReceipt: DocumentReadinessReceipt
    ) {
        self.documentID = documentID
        self.committedChunkIDs = committedChunkIDs
        self.completedChunkCount = completedChunkCount
        self.totalChunkCount = totalChunkCount
        self.readinessReceipt = readinessReceipt
    }
}

/// Promotes terminal semantic readiness only after every current chunk has a
/// validated vector for the still-selected, still-verified model identity.
public struct DocumentSemanticIndexFinalizationCommand: Sendable {
    public let documentID: String
    public let expectedChunkIDs: [String]
    public let expectedActiveModel: DocumentReadinessEmbeddingModelIdentity
    public let expectedModelVerifiedAt: Date

    public init(
        documentID: String,
        expectedChunkIDs: [String],
        expectedActiveModel: DocumentReadinessEmbeddingModelIdentity,
        expectedModelVerifiedAt: Date
    ) {
        self.documentID = documentID
        self.expectedChunkIDs = expectedChunkIDs
        self.expectedActiveModel = expectedActiveModel
        self.expectedModelVerifiedAt = expectedModelVerifiedAt
    }
}

public enum DocumentReadinessTransitionError: Error, LocalizedError, Equatable, Sendable {
    case documentNotFound(String)
    case settingsNotFound
    case partNotFound(documentID: String, partID: String)
    case stalePartSelection(documentID: String, partID: String)
    case invalidRevisionSelection(String)
    case modelNotFound(String)
    case modelIdentityChanged(String)
    case modelNotVerified(String)
    case modelVerificationChanged(String)
    case modelSelectionInconsistent(String)
    case chunkerVersionChanged(expected: Int, actual: Int)
    case partBindingsChanged(String)
    case invalidChunkBatch(String)
    case chunksChanged(String)
    case invalidEmbeddingBatch(String)
    case textIndexPostconditionFailed(String)
    case semanticIndexPostconditionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .documentNotFound(let documentID):
            "Document \(documentID) does not exist."
        case .settingsNotFound:
            "Document Intelligence settings do not exist."
        case .partNotFound(let documentID, let partID):
            "Part \(partID) does not belong to document \(documentID)."
        case .stalePartSelection(let documentID, let partID):
            "Part \(partID) changed after the transition for document \(documentID) was prepared."
        case .invalidRevisionSelection(let reason):
            "The revision-selection transition is invalid: \(reason)."
        case .modelNotFound(let modelID):
            "Embedding model \(modelID) does not exist."
        case .modelIdentityChanged(let modelID):
            "Embedding model \(modelID) no longer matches the expected immutable identity."
        case .modelNotVerified(let modelID):
            "Embedding model \(modelID) does not have a successful verification result."
        case .modelVerificationChanged(let modelID):
            "Embedding model \(modelID) verification changed after this operation was prepared."
        case .modelSelectionInconsistent(let modelID):
            "Embedding model \(modelID) is not the one exact active selection."
        case .chunkerVersionChanged(let expected, let actual):
            "The configured chunker changed from version \(expected) to \(actual)."
        case .partBindingsChanged(let documentID):
            "Selected revisions changed before the text index for document \(documentID) was committed."
        case .invalidChunkBatch(let reason):
            "The text-index batch is invalid: \(reason)."
        case .chunksChanged(let documentID):
            "Current chunks changed before the semantic index for document \(documentID) was committed."
        case .invalidEmbeddingBatch(let reason):
            "The semantic-index batch is invalid: \(reason)."
        case .textIndexPostconditionFailed(let documentID):
            "Document \(documentID) did not reach a complete current text-index state."
        case .semanticIndexPostconditionFailed(let documentID):
            "Document \(documentID) did not reach a complete current semantic-index state."
        }
    }
}
