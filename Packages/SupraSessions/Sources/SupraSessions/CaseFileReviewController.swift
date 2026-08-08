import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraStore

public enum CaseFileReviewControllerError: LocalizedError, Equatable {
    case ineligibleSourceRun(String)
    case projectUnavailable(String)
    case noSelectedProject
    case invalidGeneratedValues(String)
    case corruptProjectGraph(String)

    public var errorDescription: String? {
        switch self {
        case .ineligibleSourceRun:
            "This output is not backed by one current, exact exhaustive review run."
        case .projectUnavailable:
            "The selected Review Project is no longer available."
        case .noSelectedProject:
            "Select a Review Project before reviewing a finding."
        case .invalidGeneratedValues:
            "The Review Project contains an unreadable generated-value snapshot."
        case .corruptProjectGraph:
            "The Review Project graph is incomplete or inconsistent."
        }
    }
}

/// Matter-scoped projection of exact exhaustive output into the first native
/// Review Project workbench. The controller never derives review rows from
/// Markdown: eligibility comes from the Store's exact proof boundary, and row,
/// value, review, and evidence state come from the durable Review graph.
@MainActor
public final class CaseFileReviewController: ObservableObject {
    public struct EligibleOutput: Identifiable, Sendable, Equatable {
        public var id: String { outputVersionID }
        public let sourceRunID: String
        public let outputID: String
        public let outputVersionID: String
        public let title: String

        public init(
            sourceRunID: String,
            outputID: String,
            outputVersionID: String,
            title: String
        ) {
            self.sourceRunID = sourceRunID
            self.outputID = outputID
            self.outputVersionID = outputVersionID
            self.title = title
        }
    }

    public struct Project: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let sourceRunID: String
        public let status: String
        public let staleReason: String?
        public let updatedAt: Date
    }

    public enum ReviewState: String, Sendable, Equatable {
        case needsReview = "needs_review"
        case reviewed
    }

    public struct Row: Identifiable, Sendable, Equatable {
        public var id: String { cellID }
        public let cellID: String
        public let finding: String
        public let generatedValues: [String]
        public let supportingSourceCount: Int
        public let contrarySourceCount: Int
        public let reviewState: ReviewState
        public let valueState: String
        public let supportState: String
        public let reviewedBy: String?
        public let reviewedAt: Date?

        public var sourceCount: Int {
            supportingSourceCount + contrarySourceCount
        }
    }

    public enum EvidenceKind: String, Sendable, Equatable {
        case supporting
        case contrary
    }

    public struct Evidence: Identifiable, Sendable, Equatable {
        public let id: String
        public let kind: EvidenceKind
        public let citationLabel: String
        public let documentName: String
        public let excerpt: String
        public let locatorJSON: String
        public let availability: String
        public let unavailableReason: String?

        let frozenOutputSourceID: String
        let frozenDocumentID: String
        let frozenRevisionID: String
        let liveOutputSourceID: String?
        let liveDocumentID: String?

        public var isAvailable: Bool { availability == "available" }
    }

    @Published public private(set) var eligibleOutputs: [EligibleOutput] = []
    @Published public private(set) var projects: [Project] = []
    @Published public private(set) var rows: [Row] = []
    @Published public private(set) var selectedProjectID: String?
    @Published public private(set) var selectedCellID: String?
    @Published public private(set) var selectedEvidence: [Evidence] = []
    @Published public private(set) var message: String?

    public let matterID: String

    private let store: SupraStore
    private let previewLoader: DocumentPreviewLoader

    public init(
        matterID: String,
        store: SupraStore,
        previewStorage: DocumentStorage = .makeDefault()
    ) {
        self.matterID = matterID
        self.store = store
        self.previewLoader = DocumentPreviewLoader(store: store, storage: previewStorage)
    }

    public func load() {
        let priorProjectID = selectedProjectID
        let priorCellID = selectedCellID
        do {
            eligibleOutputs = try fetchEligibleOutputs()
            let records = try store.caseFileReviews.fetchProjects(matterID: matterID)
            projects = records.map(Self.project)

            let projectID = priorProjectID.flatMap { candidate in
                records.contains { $0.id == candidate } ? candidate : nil
            } ?? records.first?.id
            try loadProject(projectID: projectID, preservingCellID: priorCellID)
            message = nil
        } catch {
            projects = []
            rows = []
            selectedProjectID = nil
            clearSelection()
            message = error.localizedDescription
        }
    }

    public func selectProject(_ projectID: String?) {
        do {
            try loadProject(projectID: projectID, preservingCellID: nil)
            message = nil
        } catch {
            rows = []
            selectedProjectID = nil
            clearSelection()
            message = error.localizedDescription
        }
    }

    public func openReview(
        sourceRunID: String,
        title: String,
        actor: String? = nil,
        at: Date = Date()
    ) throws {
        guard eligibleOutputs.contains(where: { $0.sourceRunID == sourceRunID }) else {
            throw CaseFileReviewControllerError.ineligibleSourceRun(sourceRunID)
        }
        let graph = try store.caseFileReviews.createOrFetchProject(
            matterID: matterID,
            sourceRunID: sourceRunID,
            title: title,
            actor: reviewActor(explicit: actor),
            at: at
        )
        eligibleOutputs = try fetchEligibleOutputs()
        projects = try store.caseFileReviews.fetchProjects(matterID: matterID).map(Self.project)
        try apply(graph: graph, preservingCellID: nil)
        message = nil
    }

    public func selectCell(_ cellID: String) {
        guard rows.contains(where: { $0.cellID == cellID }),
              let selectedProjectID else {
            clearSelection()
            return
        }
        do {
            selectedCellID = cellID
            selectedEvidence = try evidence(
                store.caseFileReviews.fetchCurrentEvidence(
                    matterID: matterID,
                    projectID: selectedProjectID,
                    cellID: cellID
                )
            )
            message = nil
        } catch {
            clearSelection()
            message = error.localizedDescription
        }
    }

    public func clearSelection() {
        selectedCellID = nil
        selectedEvidence = []
    }

    public func markReviewed(
        cellID: String,
        reviewedBy: String? = nil,
        reviewedAt: Date = Date()
    ) throws {
        guard let selectedProjectID else {
            throw CaseFileReviewControllerError.noSelectedProject
        }
        _ = try store.caseFileReviews.markCellReviewed(
            matterID: matterID,
            projectID: selectedProjectID,
            cellID: cellID,
            reviewedBy: reviewActor(explicit: reviewedBy),
            reviewedAt: reviewedAt
        )
        guard let graph = try store.caseFileReviews.fetchProjectGraph(
            matterID: matterID,
            projectID: selectedProjectID
        ) else {
            throw CaseFileReviewControllerError.projectUnavailable(selectedProjectID)
        }
        projects = try store.caseFileReviews.fetchProjects(matterID: matterID).map(Self.project)
        try apply(graph: graph, preservingCellID: selectedCellID)
        message = nil
    }

    public func preview(evidenceID: String) -> DocumentPreviewModel? {
        guard let item = selectedEvidence.first(where: { $0.id == evidenceID }) else {
            return nil
        }
        if let sourceID = item.liveOutputSourceID,
           let source = try? store.documentSources.fetchSource(id: sourceID) {
            return previewLoader.load(outputSource: source)
        }

        let locator = Self.locator(for: item)
        if item.isAvailable, let documentID = item.liveDocumentID {
            return previewLoader.load(
                documentID: documentID,
                locator: locator,
                matchText: item.excerpt
            )
        }

        return DocumentPreviewModel(
            documentName: item.documentName,
            locatorDisplay: locator.displayString,
            warnings: [],
            revisionID: item.frozenRevisionID,
            revisionNotice: "Frozen Review Project source",
            kind: .unavailable(
                reason: item.unavailableReason ?? "The original source is no longer available.",
                fallbackText: item.excerpt
            )
        )
    }

    private func fetchEligibleOutputs() throws -> [EligibleOutput] {
        var eligible: [EligibleOutput] = []
        for output in try store.structuredOutputs.fetchOutputs(matterID: matterID) {
            guard output.outputType == StructuredOutputType.documentExhaustiveList.rawValue,
                  let versionID = output.activeVersionID,
                  let run = try store.corpusAnalysis.fetchExactReviewRun(
                    matterID: matterID,
                    structuredOutputVersionID: versionID
                  ),
                  let reconciliationJSON = run.reconciliationJSON,
                  let snapshot = try? JSONDecoder().decode(
                    ExhaustiveListReviewSnapshot.self,
                    from: Data(reconciliationJSON.utf8)
                  ),
                  snapshot.schemaVersion == 1 else {
                continue
            }
            eligible.append(EligibleOutput(
                sourceRunID: run.id,
                outputID: output.id,
                outputVersionID: versionID,
                title: output.title
            ))
        }
        return eligible
    }

    private func loadProject(projectID: String?, preservingCellID: String?) throws {
        guard let projectID else {
            selectedProjectID = nil
            rows = []
            clearSelection()
            return
        }
        guard let graph = try store.caseFileReviews.fetchProjectGraph(
            matterID: matterID,
            projectID: projectID
        ) else {
            throw CaseFileReviewControllerError.projectUnavailable(projectID)
        }
        try apply(graph: graph, preservingCellID: preservingCellID)
    }

    private func apply(
        graph: CaseFileReviewProjectGraph,
        preservingCellID: String?
    ) throws {
        let generatedValueColumnID = graph.columns
            .first { $0.columnKey == "generated_value" }?.id
        var projectedRows: [Row] = []
        for row in graph.rows.sorted(by: { $0.ordinal < $1.ordinal }) {
            guard let generatedValueColumnID,
                  let cell = graph.cells.first(where: {
                    $0.rowID == row.id && $0.columnID == generatedValueColumnID
                  }),
                  let generationID = cell.currentGenerationID,
                  let generation = graph.generations.first(where: {
                      $0.id == generationID && $0.cellID == cell.id
                  }) else {
                throw CaseFileReviewControllerError.corruptProjectGraph(graph.project.id)
            }
            let generatedValues: [String]
            do {
                generatedValues = try JSONDecoder().decode(
                    [String].self,
                    from: Data(generation.generatedValuesJSON.utf8)
                )
            } catch {
                throw CaseFileReviewControllerError.invalidGeneratedValues(cell.id)
            }
            let edges = try store.caseFileReviews.fetchCurrentEvidence(
                matterID: matterID,
                projectID: graph.project.id,
                cellID: cell.id
            )
            projectedRows.append(Row(
                cellID: cell.id,
                finding: row.rowKey,
                generatedValues: generatedValues,
                supportingSourceCount: edges.count { $0.kind == EvidenceKind.supporting.rawValue },
                contrarySourceCount: edges.count { $0.kind == EvidenceKind.contrary.rawValue },
                reviewState: ReviewState(rawValue: cell.reviewState) ?? .needsReview,
                valueState: cell.valueState,
                supportState: cell.supportState,
                reviewedBy: cell.reviewedBy,
                reviewedAt: cell.reviewedAt
            ))
        }

        selectedProjectID = graph.project.id
        rows = projectedRows
        if let preservingCellID,
           projectedRows.contains(where: { $0.cellID == preservingCellID }) {
            selectCell(preservingCellID)
        } else {
            clearSelection()
        }
    }

    private func evidence(_ records: [CaseFileReviewEvidenceEdgeRecord]) -> [Evidence] {
        records.compactMap { record in
            guard let kind = EvidenceKind(rawValue: record.kind) else { return nil }
            return Evidence(
                id: record.id,
                kind: kind,
                citationLabel: record.citationLabel,
                documentName: record.frozenDocumentName,
                excerpt: record.excerpt,
                locatorJSON: record.locatorJSON,
                availability: record.availability,
                unavailableReason: record.unavailableReason,
                frozenOutputSourceID: record.frozenOutputSourceID,
                frozenDocumentID: record.frozenDocumentID,
                frozenRevisionID: record.frozenRevisionID,
                liveOutputSourceID: record.liveOutputSourceID,
                liveDocumentID: record.liveDocumentID
            )
        }
    }

    private static func project(_ record: CaseFileReviewProjectRecord) -> Project {
        Project(
            id: record.id,
            title: record.title,
            sourceRunID: record.sourceRunID,
            status: record.status,
            staleReason: record.staleReason,
            updatedAt: record.updatedAt
        )
    }

    private func reviewActor(explicit: String?) -> String {
        if let explicit {
            let normalized = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { return normalized }
        }
        let profile: AssistantProfile = (
            try? store.appSettings.getSetting(AssistantProfile.profileKey, as: AssistantProfile.self)
        ) ?? .empty
        let name = profile.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Local user" : name
    }

    private static func locator(for evidence: Evidence) -> DocumentSourceLocator {
        (try? JSONDecoder().decode(
            DocumentSourceLocator.self,
            from: Data(evidence.locatorJSON.utf8)
        )) ?? DocumentSourceLocator(
            sourceKind: .text,
            charStart: nil,
            charEnd: nil
        )
    }
}
