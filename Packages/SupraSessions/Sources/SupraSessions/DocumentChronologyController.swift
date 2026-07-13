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
        modelID: ModelID?,
        route: ModelRoute? = nil
    ) async -> DocumentQAController.QAResult? {
        await produce(scope: scope, format: format, modelID: modelID, route: route, existingOutputID: nil)
    }

    /// Regenerates a saved chronology using its stored scope + format, creating a
    /// new version with a fresh source set (plan §9.1, §10.1).
    @discardableResult
    public func regenerate(outputID: String, modelID: ModelID?, route: ModelRoute? = nil) async -> DocumentQAController.QAResult? {
        guard let output = try? store.structuredOutputs.fetchOutputs(matterID: matterID).first(where: { $0.id == outputID }),
              let activeVersionID = output.activeVersionID,
              let sourceSet = try? store.documentSources.fetchSourceSet(structuredOutputVersionID: activeVersionID) else {
            message = "Could not find the chronology to regenerate."
            return nil
        }
        let scope = (try? JSONDecoder().decode(RetrievalScope.self, from: Data(sourceSet.scopeJSON.utf8))) ?? .wholeMatter
        let format: DocumentChronologyFormat = output.outputType == StructuredOutputType.factChronologyNarrative.rawValue ? .narrative : .table
        return await produce(scope: scope, format: format, modelID: modelID, route: route, existingOutputID: outputID)
    }

    @discardableResult
    private func produce(
        scope: RetrievalScope,
        format: DocumentChronologyFormat,
        modelID: ModelID?,
        route: ModelRoute?,
        existingOutputID: String?
    ) async -> DocumentQAController.QAResult? {
        let effectiveRoute = route ?? ModelRouter().route(forStructuredOutput: format.outputType)
        guard let modelID else {
            message = if let effectiveRoute {
                "Assign a \(effectiveRoute.role.displayName) model in the Models tab to build a chronology."
            } else {
                "Assign a task model in the Models tab to build a chronology."
            }
            return nil
        }
        let readiness = (try? retrieval.scopeReadiness(matterID: matterID, scope: scope)) ?? ScopeReadiness(totalDocuments: 0, readyDocuments: 0, pendingDocuments: 0, requiresSemanticIndex: false, isFullyReady: false)
        guard readiness.isFullyReady else {
            message = "The selected documents are still indexing (\(readiness.readyDocuments)/\(readiness.totalDocuments) ready)."
            return nil
        }

        guard !isGenerating else {
            message = "A chronology is already generating. Wait for it to finish."
            return nil
        }
        isGenerating = true
        message = nil
        defer { isGenerating = false }

        do {
            // Bound the assembled prompt so a large scope can't overflow the model
            // context and silently lose mid-prompt source material (the KV cache
            // evicts the middle when over budget). Reserve roughly half the context
            // for source text (≈4 chars/token), the rest for instructions + answer.
            let contextTokens = effectiveRoute?.options.maxContextTokens ?? 32_768
            let characterBudget = max(8_000, contextTokens * 2)
            let harvest = try harvestSources(scope: scope, characterBudget: characterBudget)
            let prepared = harvest.sources
            guard !prepared.isEmpty else {
                message = "No dated facts were found in the selected documents."
                return nil
            }
            if harvest.droppedCount > 0 {
                message = "Chronology covers \(prepared.count) of \(prepared.count + harvest.droppedCount) dated sources; the rest were omitted to fit the model's context budget. Narrow the scope or date range for full coverage."
            }
            let prompt = DocumentChronologyPromptBuilder.build(sources: prepared.map(\.source), format: format)
            let answer = try await collect(prompt: prompt, modelID: modelID, route: effectiveRoute)
            let verification = try DocumentSupportVerifier.verify(
                answer: answer,
                sources: prepared.map { item in
                    DocumentSupportSource(
                        sourceID: item.source.sourceID,
                        label: item.source.label,
                        locator: item.locatorJSON,
                        text: item.source.packedText,
                        lowConfidence: item.source.lowConfidence
                    )
                },
                scopeFullyIndexed: readiness.isFullyReady && harvest.droppedCount == 0
            )
            let appendix = SourceAppendix(entries: prepared.map {
                SourceAppendix.Entry(label: $0.source.label, documentName: $0.source.documentName, locatorDisplay: $0.source.locatorDisplay, excerpt: $0.source.excerpt, warnings: $0.warnings)
            })
            let markdown = verification.warningMarkdown + answer + "\n" + appendix.markdown()
            let status: StructuredOutputStatus = verification.requiresReview ? .needsReview : .complete

            let outputID: String
            let parentVersionID: String?
            if let existingOutputID {
                outputID = existingOutputID
                let versions = (try? store.structuredOutputs.fetchVersions(structuredOutputID: existingOutputID)) ?? []
                parentVersionID = versions.max(by: { $0.versionIndex < $1.versionIndex })?.id
            } else {
                let output = try store.structuredOutputs.createOutput(
                    matterID: matterID,
                    title: "Chronology (\(format.rawValue))",
                    outputType: format.outputType,
                    status: .draft
                )
                outputID = output.id
                parentVersionID = nil
            }
            let sourceSetID = try prepareSourceSet(prepared: prepared, scope: scope)
            // versionIndex is computed atomically inside createVersion.
            let version = try store.structuredOutputs.createVersion(
                structuredOutputID: outputID, contentMarkdown: markdown,
                requiredSections: [], presentSections: [], missingSections: [], parentVersionID: parentVersionID,
                verificationStatus: verification.verificationStatus,
                verificationVersion: DocumentSupportVerifier.version,
                verificationResults: verification.results,
                sourceSetID: sourceSetID,
                outputStatus: status
            )
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID, eventType: "chronology_generated", actor: "runtime",
                summary: "\(existingOutputID == nil ? "Generated" : "Regenerated") \(format.rawValue) chronology",
                relatedTable: "structured_outputs", relatedID: outputID
            )
            let result = DocumentQAController.QAResult(
                outputID: outputID, versionID: version.id, markdown: markdown, status: status.rawValue,
                warnings: verification.warnings,
                citationLabels: verification.usedLabels,
                unsupported: verification.appearsUnsupported
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

    private func harvestSources(scope: RetrievalScope, characterBudget: Int) throws -> (sources: [PreparedSource], droppedCount: Int) {
        let scopeIDs = try store.documentLibrary.resolveScopeDocumentIDs(
            matterID: matterID, folderIDs: scope.folderIDs, documentIDs: scope.documentIDs,
            tagIDs: scope.tagIDs, dateStart: scope.dateStart, dateEnd: scope.dateEnd
        )
        let documents = try store.documentLibrary.fetchDocuments(matterID: matterID).filter { scopeIDs.contains($0.id) }
        var prepared: [PreparedSource] = []
        var rank = 0
        var usedCharacters = 0
        var droppedCount = 0

        for document in documents {
            // Metadata date (file/email), distinguished from text dates.
            if let metaDate = document.metadataCreatedAt {
                let label = "S\(rank + 1)"
                let iso = ISO8601DateFormatter().string(from: metaDate)
                prepared.append(PreparedSource(
                    source: GroundingSource(
                        sourceID: "\(matterID)/\(document.id)#metadata-date",
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
                if prepared.count >= maxSources || usedCharacters >= characterBudget {
                    droppedCount += 1
                    continue
                }
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
                        sourceID: "\(matterID)/\(chunk.id)",
                        label: label, documentName: document.displayName, locatorDisplay: locator.displayString,
                        text: chunk.normalizedText, excerpt: chunk.displayExcerpt ?? DocumentChunker.excerpt(chunk.normalizedText), lowConfidence: low
                    ),
                    documentID: document.id, chunkID: chunk.id, locatorJSON: locator.encodedJSON(),
                    rank: rank, warnings: low ? ["low OCR confidence"] : []
                ))
                usedCharacters += chunk.normalizedText.count
                rank += 1
            }
        }
        return (prepared, droppedCount)
    }

    /// Leaves the source set pending until `createVersion` attaches it with the
    /// provenance and output status in one transaction.
    private func prepareSourceSet(prepared: [PreparedSource], scope: RetrievalScope) throws -> String {
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
        return sourceSet.id
    }

    private func collect(prompt: String, modelID: ModelID, route: ModelRoute?) async throws -> String {
        let request = GenerateRequest(
            generationID: GenerationID(), modelID: modelID, prompt: prompt,
            // Keep chronology structure isolated from the user's free-form profile
            // while still applying task-specific routing instructions.
            systemPrompt: routedSystemPrompt(route),
            options: route?.options ?? GenerationOptions()
        )
        let output = try await runtimeClient.collectGeneratedText(request)
        return ReasoningContent.answer(from: output)
    }

    private func routedSystemPrompt(_ route: ModelRoute?) -> String? {
        let parts = [defaultSystemPrompt, route?.systemPrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
