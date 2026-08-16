import Foundation
import SupraCore

/// Ordered, typed reasons why a persisted document is not generally ready for
/// grounded semantic work. Consumers may add task-specific blockers, but may
/// not replace or reinterpret this base result.
public enum DocumentReadinessExclusionReason: String, Codable, CaseIterable, Hashable, Sendable {
    case deleted
    case extractionFailed
    case processingFailed
    case reviewRequired
    case extractionIncomplete
    case selectedRevisionIncoherent
    case textIndexFailed
    case staleRevision
    case textIndexIncomplete
    case activeEmbeddingModelMissing
    case selectionInconsistent
    case unverified
    case semanticIndexIncomplete
}

public enum DocumentReadinessReviewCondition: String, Codable, Hashable, Sendable {
    case statusNeedsReview
    case convertedLossyExtraction
}

public struct DocumentReadinessPartBinding: Codable, Equatable, Hashable, Sendable {
    public let partIndex: Int
    public let partID: String
    public let currentRevisionID: String?
    public let currentSelectionID: String?

    public init(
        partIndex: Int,
        partID: String,
        currentRevisionID: String?,
        currentSelectionID: String?
    ) {
        self.partIndex = partIndex
        self.partID = partID
        self.currentRevisionID = currentRevisionID
        self.currentSelectionID = currentSelectionID
    }
}

public struct DocumentReadinessEmbeddingModelIdentity: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let repoID: String
    public let revision: String?
    public let dimension: Int

    public init(id: String, repoID: String, revision: String?, dimension: Int) {
        self.id = id
        self.repoID = repoID
        self.revision = revision
        self.dimension = dimension
    }
}

/// A content-free identity for readiness derived from one database snapshot.
/// It is not persisted: callers must fetch it again at a use boundary.
public struct DocumentReadinessReceipt: Codable, Equatable, Hashable, Sendable {
    public let receiptID: String
    public let documentID: String
    public let matterID: String
    public let isBaseReady: Bool
    public let primaryExclusion: DocumentReadinessExclusionReason?
    public let exclusions: [DocumentReadinessExclusionReason]
    public let extractionStatus: DocumentExtractionStatus?
    public let extractionMethod: String?
    public let reviewConditions: [DocumentReadinessReviewCondition]
    public let partBindings: [DocumentReadinessPartBinding]
    public let selectedRevisionIDs: [String]
    public let selectionIDs: [String]
    public let indexedRevisionIDs: [String]
    public let chunkIDs: [String]
    public let chunkerVersion: Int
    public let activeEmbeddingModelID: String?
    public let activeEmbeddingModelRevision: String?
    public let activeEmbeddingDimension: Int?
    public let activeEmbeddingModel: DocumentReadinessEmbeddingModelIdentity?
    public let selectedEmbeddingModelFlagIDs: [String]
    public let availableEmbeddingModelIDs: [String]
    public let chunkCount: Int
    public let textIndexedChunkCount: Int
    public let semanticIndexedChunkCount: Int

    init(
        receiptID: String,
        documentID: String,
        matterID: String,
        exclusions: [DocumentReadinessExclusionReason],
        extractionStatus: DocumentExtractionStatus?,
        extractionMethod: String?,
        reviewConditions: [DocumentReadinessReviewCondition],
        partBindings: [DocumentReadinessPartBinding],
        selectedRevisionIDs: [String],
        selectionIDs: [String],
        indexedRevisionIDs: [String],
        chunkIDs: [String],
        chunkerVersion: Int,
        activeEmbeddingModelID: String?,
        activeEmbeddingModelRevision: String?,
        activeEmbeddingDimension: Int?,
        activeEmbeddingModel: DocumentReadinessEmbeddingModelIdentity?,
        selectedEmbeddingModelFlagIDs: [String],
        availableEmbeddingModelIDs: [String],
        chunkCount: Int,
        textIndexedChunkCount: Int,
        semanticIndexedChunkCount: Int
    ) {
        self.receiptID = receiptID
        self.documentID = documentID
        self.matterID = matterID
        self.isBaseReady = exclusions.isEmpty
        self.primaryExclusion = exclusions.first
        self.exclusions = exclusions
        self.extractionStatus = extractionStatus
        self.extractionMethod = extractionMethod
        self.reviewConditions = reviewConditions
        self.partBindings = partBindings
        self.selectedRevisionIDs = selectedRevisionIDs
        self.selectionIDs = selectionIDs
        self.indexedRevisionIDs = indexedRevisionIDs
        self.chunkIDs = chunkIDs
        self.chunkerVersion = chunkerVersion
        self.activeEmbeddingModelID = activeEmbeddingModelID
        self.activeEmbeddingModelRevision = activeEmbeddingModelRevision
        self.activeEmbeddingDimension = activeEmbeddingDimension
        self.activeEmbeddingModel = activeEmbeddingModel
        self.selectedEmbeddingModelFlagIDs = selectedEmbeddingModelFlagIDs
        self.availableEmbeddingModelIDs = availableEmbeddingModelIDs
        self.chunkCount = chunkCount
        self.textIndexedChunkCount = textIndexedChunkCount
        self.semanticIndexedChunkCount = semanticIndexedChunkCount
    }
}

public enum DocumentReadinessRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case documentNotFound(String)
    case duplicateDocumentIDs([String])
    case batchScopeMismatch(
        matterID: String,
        missingDocumentIDs: [String],
        foreignDocumentIDs: [String]
    )

    public var errorDescription: String? {
        switch self {
        case .documentNotFound(let documentID):
            "Document \(documentID) does not exist."
        case .duplicateDocumentIDs:
            "A readiness batch cannot contain duplicate document identities."
        case .batchScopeMismatch:
            "The readiness batch contains a missing or cross-matter document identity."
        }
    }
}
