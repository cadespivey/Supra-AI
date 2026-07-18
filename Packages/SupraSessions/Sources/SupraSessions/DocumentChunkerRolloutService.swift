import Foundation
import SupraDocuments
import SupraStore

public struct DocumentChunkerRolloutResult: Equatable, Sendable {
    public var previousVersion: Int
    public var targetVersion: Int
    public var matterResults: [DocumentRechunkResult]

    public var scheduledDocuments: Int {
        matterResults.reduce(0) { $0 + $1.scheduledDocuments }
    }

    public var reindexedDocuments: Int {
        matterResults.reduce(0) { $0 + $1.reindexedDocuments }
    }

    public var textIndexedDocuments: Int {
        matterResults.reduce(0) { $0 + $1.textIndexedDocuments }
    }

    public var readyDocuments: Int {
        matterResults.reduce(0) { $0 + $1.readyDocuments }
    }

    public var pendingDocuments: Int {
        matterResults.reduce(0) { $0 + $1.pendingDocuments }
    }
}

public enum DocumentChunkerRolloutError: Error, Equatable, LocalizedError {
    case incompleteMatter(matterID: String, targetVersion: Int, pendingDocuments: Int)

    public var errorDescription: String? {
        switch self {
        case let .incompleteMatter(matterID, targetVersion, pendingDocuments):
            "Matter \(matterID) still has \(pendingDocuments) document(s) pending after the chunker v\(targetVersion) rebuild. The default was not changed."
        }
    }
}

/// Coordinates the D-06 default change across every active matter. Each matter
/// is rebuilt with an explicit chunker, and the persisted default changes only
/// after every eligible document reaches a terminal text-indexed/ready state.
/// A failed or interrupted run therefore remains safely resumable: completed
/// matters no-op on retry and the prior default remains in force.
public actor DocumentChunkerRolloutService {
    public static let approvedDefaultVersion = 2
    static let approvedMigrationCompletionKey = "documents.chunkerVersion.v2MigrationCompletedAt"

    private let store: SupraStore
    private let embedder: (any TextEmbedder)?

    public init(store: SupraStore, embedder: (any TextEmbedder)? = nil) {
        self.store = store
        self.embedder = embedder
    }

    public func switchAllMatters(
        to targetVersion: Int,
        actor: String = "system"
    ) async throws -> DocumentChunkerRolloutResult {
        guard targetVersion == 1 || targetVersion == 2 else {
            throw DocumentRechunkError.unsupportedChunkerVersion(targetVersion)
        }

        let previousVersion = try store.documentSettings.loadSettings().chunkerVersion
        let matters = try store.matters.fetchMatters().sorted { $0.id < $1.id }
        let rechunker = DocumentRechunkService(store: store, embedder: embedder)
        var matterResults: [DocumentRechunkResult] = []

        for matter in matters {
            try Task.checkCancellation()
            let result = try await rechunker.rechunkMatter(
                matterID: matter.id,
                targetVersion: targetVersion
            )
            guard result.pendingDocuments == 0 else {
                throw DocumentChunkerRolloutError.incompleteMatter(
                    matterID: matter.id,
                    targetVersion: targetVersion,
                    pendingDocuments: result.pendingDocuments
                )
            }
            matterResults.append(result)
        }

        try store.documentSettings.updateSettings { settings in
            settings.chunkerVersion = targetVersion
        }

        let result = DocumentChunkerRolloutResult(
            previousVersion: previousVersion,
            targetVersion: targetVersion,
            matterResults: matterResults
        )
        _ = try? store.auditEvents.recordEvent(
            eventType: "document_chunker_default_changed",
            actor: actor,
            summary: "Changed document chunker default from v\(previousVersion) to v\(targetVersion) after rebuilding \(result.reindexedDocuments) document(s) with zero pending"
        )
        return result
    }

    /// Applies the owner-approved v2 default once per store. The completion
    /// marker is written only after the all-matter rebuild and flag update both
    /// succeed. It remains present across a later explicit rollback so launch
    /// bootstrap never silently overrides that operator decision.
    public func promoteApprovedDefaultIfNeeded(
        actor: String = "system"
    ) async throws -> DocumentChunkerRolloutResult? {
        if try store.appSettings.getSetting(
            Self.approvedMigrationCompletionKey,
            as: Date.self
        ) != nil {
            return nil
        }

        let result = try await switchAllMatters(
            to: Self.approvedDefaultVersion,
            actor: actor
        )
        try store.appSettings.setSetting(
            Self.approvedMigrationCompletionKey,
            value: Date()
        )
        _ = try? store.auditEvents.recordEvent(
            eventType: "document_chunker_v2_approved_migration_completed",
            actor: actor,
            summary: "Completed the owner-approved one-time chunker v2 migration with \(result.pendingDocuments) pending document(s)"
        )
        return result
    }
}
