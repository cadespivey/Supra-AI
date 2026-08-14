import Foundation
import SupraStore

public struct QuickAttachmentMatterHandoffCompletion: Sendable, Equatable {
    public let attachmentID: String
    public let matterID: String
    public let documentID: String
    public let importBatchID: String
    public let readinessReceipt: DocumentReadinessReceipt

    public init(
        attachmentID: String,
        matterID: String,
        documentID: String,
        importBatchID: String,
        readinessReceipt: DocumentReadinessReceipt
    ) {
        self.attachmentID = attachmentID
        self.matterID = matterID
        self.documentID = documentID
        self.importBatchID = importBatchID
        self.readinessReceipt = readinessReceipt
    }
}

public struct QuickAttachmentMatterHandoffFailure: Error, LocalizedError, Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable {
        case sourceUnavailable
        case importFailed
        case indexingFailed
        case readinessFailed
    }

    public let stage: Stage
    public let message: String

    public var errorDescription: String? { message }
}

public enum QuickAttachmentMatterHandoffOutcome: Sendable, Equatable {
    case completed(QuickAttachmentMatterHandoffCompletion)
    case awaitingReadiness(documentID: String, receipt: DocumentReadinessReceipt)
    case failed(QuickAttachmentMatterHandoffFailure)
}

/// Promotes a quick attachment through the ordinary matter-document pipeline.
/// This is intentionally not a flag change on the session context: import owns
/// the durable file and document rows, indexing owns text/semantic projections,
/// and only the Store's freshly derived canonical receipt may report completion.
public struct QuickAttachmentMatterHandoff: Sendable {
    private let store: SupraStore
    private let importService: DocumentImportService
    private let indexingService: DocumentIndexingService

    public init(
        store: SupraStore,
        importService: DocumentImportService,
        indexingService: DocumentIndexingService
    ) {
        self.store = store
        self.importService = importService
        self.indexingService = indexingService
    }

    public func addToMatter(
        attachment: ChatAttachmentContext,
        matterID: String
    ) async -> QuickAttachmentMatterHandoffOutcome {
        guard let sourceURL = attachment.sourceURL else {
            return .failed(
                QuickAttachmentMatterHandoffFailure(
                    stage: .sourceUnavailable,
                    message: "This quick attachment is no longer available. Choose the file again to add it to the matter."
                )
            )
        }

        let importOutcome: DocumentImportService.ImportOutcome
        do {
            importOutcome = try await importService.importSources(
                [sourceURL],
                matterID: matterID
            )
        } catch {
            return .failed(
                QuickAttachmentMatterHandoffFailure(
                    stage: .importFailed,
                    message: "The file could not be imported into the matter: \(error.localizedDescription)"
                )
            )
        }

        guard let documentID = importOutcome.report.items.first(where: {
            $0.parentDocumentID == nil && $0.documentID != nil
        })?.documentID else {
            let reason = importOutcome.report.items.compactMap(\.reason).first
                ?? "The import did not create a matter document."
            return .failed(
                QuickAttachmentMatterHandoffFailure(
                    stage: .importFailed,
                    message: reason
                )
            )
        }

        do {
            _ = try await indexingService.indexDocument(documentID: documentID)
        } catch {
            return .failed(
                QuickAttachmentMatterHandoffFailure(
                    stage: .indexingFailed,
                    message: "The imported document could not be indexed: \(error.localizedDescription)"
                )
            )
        }

        let receipt: DocumentReadinessReceipt
        do {
            receipt = try store.documentReadiness.fetchReceipt(documentID: documentID)
        } catch {
            return .failed(
                QuickAttachmentMatterHandoffFailure(
                    stage: .readinessFailed,
                    message: "Document readiness could not be confirmed: \(error.localizedDescription)"
                )
            )
        }

        guard receipt.isBaseReady else {
            return .awaitingReadiness(documentID: documentID, receipt: receipt)
        }
        return .completed(
            QuickAttachmentMatterHandoffCompletion(
                attachmentID: attachment.id,
                matterID: matterID,
                documentID: documentID,
                importBatchID: importOutcome.batchID,
                readinessReceipt: receipt
            )
        )
    }
}
