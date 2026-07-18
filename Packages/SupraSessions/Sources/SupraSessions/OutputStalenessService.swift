import Foundation
import SupraStore

/// Matter-scoped dependency invalidation for saved document artifacts. The
/// Store repository owns the deterministic lineage joins and transaction; this
/// facade gives document workflows one event-oriented API.
public final class OutputStalenessService: @unchecked Sendable {
    private let store: SupraStore

    public init(store: SupraStore) {
        self.store = store
    }

    @discardableResult
    public func sourceRevisionChanged(
        matterID: String,
        documentID: String,
        fromRevisionID: String,
        toRevisionID: String
    ) throws -> Int {
        try store.structuredOutputs.markStaleForSourceRevision(
            matterID: matterID,
            documentID: documentID,
            fromRevisionID: fromRevisionID,
            toRevisionID: toRevisionID
        )
    }

    @discardableResult
    public func documentReprocessed(
        matterID: String,
        documentID: String
    ) throws -> Int {
        try store.structuredOutputs.markStaleForDocumentReprocess(
            matterID: matterID,
            documentID: documentID
        )
    }

    @discardableResult
    public func embeddingModelRevisionChanged(
        matterID: String,
        modelID: String,
        fromRevision: String,
        toRevision: String
    ) throws -> Int {
        try store.structuredOutputs.markStaleForEmbeddingModelRevision(
            matterID: matterID,
            modelID: modelID,
            fromRevision: fromRevision,
            toRevision: toRevision
        )
    }

    @discardableResult
    public func embeddingModelChanged(
        matterID: String,
        fromModelID: String,
        fromRevision: String,
        toModelID: String,
        toRevision: String
    ) throws -> Int {
        try store.structuredOutputs.markStaleForEmbeddingModelSelection(
            matterID: matterID,
            fromModelID: fromModelID,
            fromRevision: fromRevision,
            toModelID: toModelID,
            toRevision: toRevision
        )
    }

    @discardableResult
    public func chunkerVersionChanged(
        matterID: String,
        fromVersion: Int,
        toVersion: Int
    ) throws -> Int {
        try store.structuredOutputs.markStaleForChunkerVersion(
            matterID: matterID,
            fromVersion: fromVersion,
            toVersion: toVersion
        )
    }

    @discardableResult
    public func promptBuilderVersionChanged(
        matterID: String,
        fromVersion: String,
        toVersion: String
    ) throws -> Int {
        try store.structuredOutputs.markStaleForPromptBuilderVersion(
            matterID: matterID,
            fromVersion: fromVersion,
            toVersion: toVersion
        )
    }
}
