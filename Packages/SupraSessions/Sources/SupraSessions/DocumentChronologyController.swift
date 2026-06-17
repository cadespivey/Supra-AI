import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

/// Generates one-shot, source-grounded fact chronologies over a selected scope
/// (plan §9): harvests date-bearing chunks + document metadata dates, asks the
/// model for a table or narrative chronology with inline citations and exact/
/// partial date labeling, checks citations, and saves it with a source set.
@MainActor
public final class DocumentChronologyController: ObservableObject {
    @Published public private(set) var isGenerating = false
    @Published public private(set) var message: String?
    @Published public private(set) var lastResult: DocumentQAController.QAResult?

    public let matterID: String
    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private let retrieval: DocumentRetrievalService
    private let defaultSystemPrompt: String?
    private let maxSources: Int

    public init(
        matterID: String,
        store: SupraStore,
        runtimeClient: any RuntimeClientProtocol,
        defaultSystemPrompt: String? = nil,
        maxSources: Int = 30
    ) {
        self.matterID = matterID
        self.store = store
        self.runtimeClient = runtimeClient
        // Chronology harvests dated chunks deterministically; text indexing is
        // sufficient, so readiness does not require a semantic index here.
        self.retrieval = DocumentRetrievalService(store: store, embedder: nil)
        self.defaultSystemPrompt = defaultSystemPrompt
        self.maxSources = maxSources
    }

    public func scopeReadiness(scope: RetrievalScope) -> ScopeReadiness? {
        try? retrieval.scopeReadiness(matterID: matterID, scope: scope)
    }

    @discardableResult
    public func generate(
        scope: RetrievalScope = .wholeMatter,
        format: DocumentChronologyFormat = .table,
        modelID: ModelID?
    ) async -> DocumentQAController.QAResult? {
        guard let modelID else { message = "Load a chat model in the Models tab to build a chronology."; return nil }
        let readiness = (try? retrieval.scopeReadiness(matterID: matterID, scope: scope)) ?? ScopeReadiness(totalDocuments: 0, readyDocuments: 0, pendingDocuments: 0, requiresSemanticIndex: false, isFullyReady: false)
        guard readiness.isFullyReady else {
            message = "The selected documents are still indexing (\(readiness.readyDocuments)/\(readiness.totalDocuments) ready)."
            return nil
        }

        isGenerating = true
        message = nil
        defer { isGenerating = false }

        do {
            let prepared = try harvestSources(scope: scope)
            guard !prepared.isEmpty else {
                message = "No dated facts were found in the selected documents."
                return nil
            }
            let prompt = DocumentChronologyPromptBuilder.build(sources: prepared.map(\.source), format: format)
            let answer = try await collect(prompt: prompt, modelID: modelID)
            let check = CitationCoverage.check(
                answer: answer, availableLabels: prepared.map(\.source.label),
                lowConfidenceLabels: Set(prepared.filter { $0.source.lowConfidence }.map(\.source.label)),
                scopeFullyIndexed: readiness.isFullyReady
            )
            let appendix = SourceAppendix(entries: prepared.map {
                SourceAppendix.Entry(label: $0.source.label, documentName: $0.source.documentName, locatorDisplay: $0.source.locatorDisplay, excerpt: $0.source.excerpt, warnings: $0.warnings)
            })
            let markdown = answer + "\n" + appendix.markdown()
            let status: StructuredOutputStatus = check.requiresReview ? .needsReview : .complete

            let title = "Chronology (\(format.rawValue))"
            let output = try store.structuredOutputs.createOutput(matterID: matterID, title: title, outputType: format.outputType, status: status)
            let version = try store.structuredOutputs.createVersion(
                structuredOutputID: output.id, versionIndex: 1, contentMarkdown: markdown,
                requiredSections: [], presentSections: [], missingSections: []
            )
            try attachSources(prepared: prepared, scope: scope, versionID: version.id)
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID, eventType: "chronology_generated", actor: "runtime",
                summary: "Generated \(format.rawValue) chronology", relatedTable: "structured_outputs", relatedID: output.id
            )
            let result = DocumentQAController.QAResult(
                outputID: output.id, versionID: version.id, markdown: markdown, status: status.rawValue,
                warnings: check.warnings, citationLabels: check.usedLabels, unsupported: check.appearsUnsupported
            )
            lastResult = result
            return result
        } catch {
            message = "Chronology generation failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Harvesting

    private struct PreparedSource {
        var source: GroundingSource
        var documentID: String
        var chunkID: String?
        var locatorJSON: String
        var rank: Int
        var warnings: [String]
    }

    private func harvestSources(scope: RetrievalScope) throws -> [PreparedSource] {
        let scopeIDs = try store.documentLibrary.resolveScopeDocumentIDs(
            matterID: matterID, folderIDs: scope.folderIDs, documentIDs: scope.documentIDs,
            tagIDs: scope.tagIDs, dateStart: scope.dateStart, dateEnd: scope.dateEnd
        )
        let documents = try store.documentLibrary.fetchDocuments(matterID: matterID).filter { scopeIDs.contains($0.id) }
        var prepared: [PreparedSource] = []
        var rank = 0

        for document in documents {
            // Metadata date (file/email), distinguished from text dates.
            if let metaDate = document.metadataCreatedAt {
                let label = "S\(rank + 1)"
                let iso = ISO8601DateFormatter().string(from: metaDate)
                prepared.append(PreparedSource(
                    source: GroundingSource(
                        label: label, documentName: document.displayName, locatorDisplay: "metadata date",
                        text: "Document metadata date: \(iso) (metadata date)", excerpt: iso, lowConfidence: false
                    ),
                    documentID: document.id, chunkID: nil,
                    locatorJSON: DocumentSourceLocator(sourceKind: .convertedDocument).encodedJSON(),
                    rank: rank, warnings: []
                ))
                rank += 1
            }

            // Date-bearing chunks (text dates).
            let chunks = (try? store.documentIndex.fetchChunks(documentID: document.id)) ?? []
            for chunk in chunks where DateExtraction.containsDate(chunk.normalizedText) {
                if prepared.count >= maxSources { break }
                let label = "S\(rank + 1)"
                let locator = DocumentSourceLocator(
                    sourceKind: DocumentSourceKind(rawValue: chunk.sourceKind) ?? .text,
                    pageIndex: chunk.pageIndex, pageLabel: chunk.pageLabel, sheetName: chunk.sheetName,
                    cellRange: chunk.cellRange, emailPartPath: chunk.emailPartPath,
                    charStart: chunk.charStart, charEnd: chunk.charEnd
                )
                let low = (chunk.ocrConfidence.map { $0 < OCRPolicy.lowConfidenceThreshold } ?? false)
                prepared.append(PreparedSource(
                    source: GroundingSource(
                        label: label, documentName: document.displayName, locatorDisplay: locator.displayString,
                        text: chunk.normalizedText, excerpt: chunk.displayExcerpt ?? DocumentChunker.excerpt(chunk.normalizedText), lowConfidence: low
                    ),
                    documentID: document.id, chunkID: chunk.id, locatorJSON: locator.encodedJSON(),
                    rank: rank, warnings: low ? ["low OCR confidence"] : []
                ))
                rank += 1
            }
            if prepared.count >= maxSources { break }
        }
        return prepared
    }

    private func attachSources(prepared: [PreparedSource], scope: RetrievalScope, versionID: String) throws {
        let scopeJSON = (try? JSONEncoder().encode(scope)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let sourceSet = try store.documentSources.createSourceSet(matterID: matterID, mode: .chronology, scopeJSON: scopeJSON, retrievalQuery: nil)
        let rows = prepared.map { source in
            DocumentOutputSourceRecord(
                sourceSetID: sourceSet.id, documentID: source.documentID, chunkID: source.chunkID,
                citationLabel: source.source.label, locatorJSON: source.locatorJSON,
                excerpt: source.source.excerpt, rank: source.rank,
                warningsJSON: source.warnings.isEmpty ? nil : (try? JSONEncoder.encodeToString(source.warnings))
            )
        }
        try store.documentSources.addOutputSources(rows)
        try store.documentSources.attachSourceSet(id: sourceSet.id, structuredOutputVersionID: versionID)
    }

    private func collect(prompt: String, modelID: ModelID) async throws -> String {
        let request = GenerateRequest(
            generationID: GenerationID(), modelID: modelID, prompt: prompt,
            systemPrompt: defaultSystemPrompt, options: GenerationOptions()
        )
        var output = ""
        for try await event in try runtimeClient.generate(request) {
            if event.type == .token, let token = event.tokenText { output += token }
        }
        return ReasoningContent.answer(from: output)
    }
}
