import Combine
import Foundation
import SupraCore
import SupraStore

/// Stable, view-facing identity and presentation facts for one matter document.
/// Persistence-only fields stay behind the Sessions controller boundary.
public struct MatterDocumentSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let matterID: String
    public let parentDocumentID: String?
    public let folderID: String?
    public let displayName: String
    public let status: MatterDocumentStatus?
    public let extractionStatus: DocumentExtractionStatus?
    public let indexStatus: DocumentIndexStatus?
    public let ocrConfidenceSummary: String?
    public let hasUserEditedText: Bool
    public let classificationMetadataJSON: String?

    init(record: MatterDocumentRecord) {
        id = record.id
        matterID = record.matterID
        parentDocumentID = record.parentDocumentID
        folderID = record.folderID
        displayName = record.displayName
        status = MatterDocumentStatus(rawValue: record.status)
        extractionStatus = DocumentExtractionStatus(rawValue: record.extractionStatus)
        indexStatus = DocumentIndexStatus(rawValue: record.indexStatus)
        ocrConfidenceSummary = record.ocrConfidenceSummary
        hasUserEditedText = record.hasUserEditedText
        classificationMetadataJSON = record.classificationMetadataJSON
    }
}

/// Stable, view-facing identity and hierarchy for one document folder.
public struct DocumentFolderSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let parentFolderID: String?
    public let name: String

    init(record: DocumentFolderRecord) {
        id = record.id
        parentFolderID = record.parentFolderID
        name = record.name
    }
}

/// Editable presentation of one persisted billing line.
public struct BillingLineView: Identifiable, Sendable, Equatable {
    public let id: String
    public let seq: Int
    public let clientID: String?
    public let matterID: String?
    public let narrative: String
    public let hours: Double
    public let workDate: String
    public let utbmsTaskCode: String?
    public let utbmsActivityCode: String?
    public let timekeeperID: String?
    public let rate: Double?
    public let confidence: String
    public let codeNote: String?
    public let userEdited: Bool
    public let sourceEntryIDs: [String]

    init(record: BillingLineItemRecord) {
        id = record.id
        seq = record.seq
        clientID = record.clientID
        matterID = record.matterID
        narrative = record.narrative
        hours = record.hours
        workDate = record.workDate
        utbmsTaskCode = record.utbmsTaskCode
        utbmsActivityCode = record.utbmsActivityCode
        timekeeperID = record.timekeeperID
        rate = record.rate
        confidence = record.confidence
        codeNote = record.codeNote
        userEdited = record.userEdited
        sourceEntryIDs = record.sourceEntryIDs
    }
}

/// A Store-independent cross-day ScratchPad search result.
public struct ScratchPadSearchHit: Identifiable, Sendable, Equatable {
    public let id: String
    public let day: String
    public let text: String
    public let mentions: [String]
    public let tags: [String]

    init(hit: ScratchPadRepository.EntryHit) {
        id = hit.entryID
        day = hit.day
        text = hit.text
        mentions = hit.mentions
        tags = hit.tags
    }
}

/// Content-limited diagnostic facts suitable for presentation. Technical details
/// stay in the diagnostics repository rather than becoming UI state.
public struct DiagnosticEventSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let timestamp: Date
    public let severity: String
    public let category: String?
    public let message: String
    public let generationID: String?
    public let modelID: String?

    init(record: DiagnosticEventRecord) {
        id = record.id
        timestamp = record.timestamp
        severity = record.severity
        category = record.category
        message = record.message
        generationID = record.generationID
        modelID = record.modelID
    }
}

/// Owns the diagnostic record-to-view mapping and preserves repository ordering.
@MainActor
public final class DiagnosticsController: ObservableObject {
    @Published public private(set) var events: [DiagnosticEventSummary] = []

    private let store: SupraStore

    public init(store: SupraStore) {
        self.store = store
    }

    public func reload(limit: Int = 100) {
        let records = (try? store.diagnostics.fetchRecentDiagnostics(limit: limit)) ?? []
        events = records.map(DiagnosticEventSummary.init)
    }

    public func performanceEvents(limit: Int = 8) -> [DiagnosticEventSummary] {
        Array(events.lazy.filter { $0.category == "performance" }.prefix(max(0, limit)))
    }
}
