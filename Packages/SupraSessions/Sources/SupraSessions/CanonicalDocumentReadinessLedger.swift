import SupraStore

/// The shipping surfaces that consume the Store-owned base readiness receipt.
/// A consumer may add task exclusions, but it cannot derive a competing base state.
public enum DocumentReadinessConsumer: String, CaseIterable, Hashable, Sendable {
    case documents
    case ask
    case chronology
    case drafting
}

/// Typed task policy layered on top of general document readiness. These reasons
/// never alter the receipt identity or Store-owned base exclusion.
public enum DocumentTaskEligibilityExclusion: String, Codable, Hashable, Sendable {
    case outsideSelectedAskScope
    case missingChronologyDateEvidence
    case missingDraftingSourceSelection
}

public struct DocumentReadinessConsumerProjection: Equatable, Hashable, Sendable {
    public let consumer: DocumentReadinessConsumer
    public let baseReceipt: DocumentReadinessReceipt
    public let taskExclusions: [DocumentTaskEligibilityExclusion]

    public var documentID: String { baseReceipt.documentID }
    public var baseReceiptID: String { baseReceipt.receiptID }
    public var isBaseReady: Bool { baseReceipt.isBaseReady }
    public var primaryBaseExclusion: DocumentReadinessExclusionReason? {
        baseReceipt.primaryExclusion
    }
    public var isEligibleForTask: Bool {
        isBaseReady && taskExclusions.isEmpty
    }

    public init(
        consumer: DocumentReadinessConsumer,
        baseReceipt: DocumentReadinessReceipt,
        taskExclusions: [DocumentTaskEligibilityExclusion] = []
    ) {
        self.consumer = consumer
        self.baseReceipt = baseReceipt
        self.taskExclusions = taskExclusions
    }
}

/// One Sessions adapter over the authoritative Store repository. Every consumer
/// projection in a refresh is built from the same batch of derived receipts.
public struct CanonicalDocumentReadinessLedger: Sendable {
    private let store: SupraStore

    public init(store: SupraStore) {
        self.store = store
    }

    public func consumerProjections(
        matterID: String,
        documentIDs: [String],
        taskExclusions: [
            DocumentReadinessConsumer: [String: [DocumentTaskEligibilityExclusion]]
        ] = [:]
    ) throws -> [DocumentReadinessConsumerProjection] {
        let receipts = try store.documentReadiness.fetchReceipts(
            matterID: matterID,
            documentIDs: documentIDs
        )
        return receipts.flatMap { receipt in
            DocumentReadinessConsumer.allCases.map { consumer in
                DocumentReadinessConsumerProjection(
                    consumer: consumer,
                    baseReceipt: receipt,
                    taskExclusions: taskExclusions[consumer]?[receipt.documentID] ?? []
                )
            }
        }
    }
}
