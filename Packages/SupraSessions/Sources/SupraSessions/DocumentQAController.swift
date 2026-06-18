import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

/// Generates source-grounded Q&A answers over a matter's documents (plan §8):
/// auto-source or guided retrieval, short or memo answer modes, citation checks,
/// a source appendix, saved as a structured output with a version-scoped source
/// set, and regeneration.
@MainActor
public final class DocumentQAController: ObservableObject {
    @Published public private(set) var isGenerating = false
    @Published public private(set) var message: String?
    @Published public private(set) var lastResult: QAResult?

    public struct QAResult: Sendable, Equatable {
        public var outputID: String
        public var versionID: String
        public var markdown: String
        public var status: String
        public var warnings: [String]
        public var citationLabels: [String]
        public var unsupported: Bool
    }

    public let matterID: String
    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private let retrieval: DocumentRetrievalService
    private let defaultSystemPrompt: String?
    private let lowConfidenceThreshold = OCRPolicy.lowConfidenceThreshold

    public init(
        matterID: String,
        store: SupraStore,
        runtimeClient: any RuntimeClientProtocol,
        embedder: (any TextEmbedder)? = nil,
        defaultSystemPrompt: String? = nil
    ) {
        self.matterID = matterID
        self.store = store
        self.runtimeClient = runtimeClient
        self.retrieval = DocumentRetrievalService(store: store, embedder: embedder)
        self.defaultSystemPrompt = defaultSystemPrompt
    }

    public func scopeReadiness(scope: RetrievalScope) -> ScopeReadiness? {
        try? retrieval.scopeReadiness(matterID: matterID, scope: scope)
    }

    /// Runs a Q&A: retrieves sources (auto or guided), generates a cited answer,
    /// checks citations, and saves it. Returns the result or nil on failure.
    @discardableResult
    public func generate(
        question: String,
        scope: RetrievalScope = .wholeMatter,
        mode: DocumentAnswerMode = .short,
        guidedChunkIDs: [String]? = nil,
        modelID: ModelID?
    ) async -> QAResult? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { message = "Enter a question."; return nil }
        guard let modelID else { message = "Load a chat model in the Models tab to ask questions."; return nil }

        // Block until the selected scope is fully indexed (plan §8.1).
        let readiness = (try? retrieval.scopeReadiness(matterID: matterID, scope: scope)) ?? ScopeReadiness(totalDocuments: 0, readyDocuments: 0, pendingDocuments: 0, requiresSemanticIndex: false, isFullyReady: false)
        guard readiness.isFullyReady else {
            message = "The selected documents are still indexing (\(readiness.readyDocuments)/\(readiness.totalDocuments) ready). Try again once indexing finishes."
            return nil
        }

        isGenerating = true
        message = nil
        defer { isGenerating = false }

        do {
            let prepared = try await prepareSources(question: trimmed, scope: scope, guidedChunkIDs: guidedChunkIDs)
            guard !prepared.isEmpty else {
                message = "No matching sources were found in the selected scope."
                return nil
            }
            let groundingSources = prepared.map(\.source)
            let prompt = DocumentQAPromptBuilder.buildQAPrompt(question: trimmed, sources: groundingSources, mode: mode)
            let answer = try await collect(prompt: prompt, modelID: modelID)

            let lowConfidence = Set(prepared.filter { $0.source.lowConfidence }.map(\.source.label))
            let check = CitationCoverage.check(
                answer: answer,
                availableLabels: groundingSources.map(\.label),
                lowConfidenceLabels: lowConfidence,
                scopeFullyIndexed: readiness.isFullyReady
            )
            let appendix = makeAppendix(prepared)
            let markdown = answer + "\n" + appendix.markdown()
            let status: StructuredOutputStatus = check.requiresReview ? .needsReview : .complete

            let result = try persist(
                question: trimmed, scope: scope, mode: mode, markdown: markdown,
                prepared: prepared, status: status, check: check
            )
            lastResult = result
            return result
        } catch {
            message = "Q&A generation failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Regenerates an output using its saved scope + question, creating a new
    /// version with a fresh source set (plan §10.1).
    @discardableResult
    public func regenerate(outputID: String, modelID: ModelID?) async -> QAResult? {
        guard let output = try? store.structuredOutputs.fetchOutputs(matterID: matterID).first(where: { $0.id == outputID }),
              let activeVersionID = output.activeVersionID,
              let sourceSet = try? store.documentSources.fetchSourceSet(structuredOutputVersionID: activeVersionID) else {
            message = "Could not find the output to regenerate."
            return nil
        }
        let scope = (try? JSONDecoder().decode(RetrievalScope.self, from: Data((sourceSet.scopeJSON).utf8))) ?? .wholeMatter
        let question = sourceSet.retrievalQuery ?? output.title
        let mode: DocumentAnswerMode = output.outputType == StructuredOutputType.documentQAMemo.rawValue ? .memo : .short
        return await regenerateExisting(outputID: outputID, question: question, scope: scope, mode: mode, modelID: modelID)
    }

    // MARK: - Internals

    private struct PreparedSource {
        var source: GroundingSource
        var documentID: String
        var chunkID: String
        var locatorJSON: String
        var rank: Int
        var warnings: [String]
    }

    private func prepareSources(question: String, scope: RetrievalScope, guidedChunkIDs: [String]?) async throws -> [PreparedSource] {
        if let guidedChunkIDs, !guidedChunkIDs.isEmpty {
            return prepareGuided(chunkIDs: guidedChunkIDs)
        }
        let result = try await retrieval.retrieve(matterID: matterID, query: question, scope: scope, limit: 10)
        return result.sources.enumerated().map { index, retrieved in
            let label = "S\(index + 1)"
            let low = (retrieved.ocrConfidence.map { $0 < lowConfidenceThreshold } ?? false)
            return PreparedSource(
                source: GroundingSource(
                    label: label, documentName: retrieved.documentName,
                    locatorDisplay: retrieved.locator.displayString, text: retrieved.text,
                    excerpt: retrieved.excerpt, lowConfidence: low
                ),
                documentID: retrieved.documentID, chunkID: retrieved.chunkID,
                locatorJSON: retrieved.locator.encodedJSON(), rank: index,
                warnings: low ? ["low OCR confidence"] : []
            )
        }
    }

    private func prepareGuided(chunkIDs: [String]) -> [PreparedSource] {
        let chunks = (try? store.documentIndex.fetchChunks(ids: chunkIDs)) ?? []
        let order = Dictionary(uniqueKeysWithValues: chunkIDs.enumerated().map { ($1, $0) })
        let nameByID = Dictionary((try? store.documentLibrary.fetchDocuments(matterID: matterID))?.map { ($0.id, $0.displayName) } ?? [], uniquingKeysWith: { a, _ in a })
        return chunks
            .sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
            .enumerated().map { index, chunk in
                let locator = DocumentSourceLocator(
                    sourceKind: DocumentSourceKind(rawValue: chunk.sourceKind) ?? .text,
                    pageIndex: chunk.pageIndex, pageLabel: chunk.pageLabel, sheetName: chunk.sheetName,
                    cellRange: chunk.cellRange, emailPartPath: chunk.emailPartPath,
                    charStart: chunk.charStart, charEnd: chunk.charEnd
                )
                let low = (chunk.ocrConfidence.map { $0 < lowConfidenceThreshold } ?? false)
                return PreparedSource(
                    source: GroundingSource(
                        label: "S\(index + 1)", documentName: nameByID[chunk.documentID] ?? "Document",
                        locatorDisplay: locator.displayString, text: chunk.normalizedText,
                        excerpt: chunk.displayExcerpt ?? DocumentChunker.excerpt(chunk.normalizedText), lowConfidence: low
                    ),
                    documentID: chunk.documentID, chunkID: chunk.id,
                    locatorJSON: locator.encodedJSON(), rank: index, warnings: low ? ["low OCR confidence"] : []
                )
            }
    }

    private func makeAppendix(_ prepared: [PreparedSource]) -> SourceAppendix {
        SourceAppendix(entries: prepared.map { source in
            SourceAppendix.Entry(
                label: source.source.label, documentName: source.source.documentName,
                locatorDisplay: source.source.locatorDisplay, excerpt: source.source.excerpt,
                warnings: source.warnings
            )
        })
    }

    private func persist(
        question: String, scope: RetrievalScope, mode: DocumentAnswerMode, markdown: String,
        prepared: [PreparedSource], status: StructuredOutputStatus, check: CitationCheckResult
    ) throws -> QAResult {
        let title = "Q&A: \(question.prefix(60))"
        let output = try store.structuredOutputs.createOutput(matterID: matterID, title: String(title), outputType: mode.outputType, status: status)
        let version = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id, versionIndex: 1, contentMarkdown: markdown,
            requiredSections: [], presentSections: [], missingSections: []
        )
        try attachSources(prepared: prepared, scope: scope, question: question, mode: mode, versionID: version.id)
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID, eventType: "qa_generated", actor: "runtime",
            summary: "Generated document Q&A", relatedTable: "structured_outputs", relatedID: output.id
        )
        return QAResult(
            outputID: output.id, versionID: version.id, markdown: markdown, status: status.rawValue,
            warnings: check.warnings, citationLabels: check.usedLabels, unsupported: check.appearsUnsupported
        )
    }

    private func regenerateExisting(outputID: String, question: String, scope: RetrievalScope, mode: DocumentAnswerMode, modelID: ModelID?) async -> QAResult? {
        guard let modelID else { message = "Load a chat model to regenerate."; return nil }
        isGenerating = true
        message = nil
        defer { isGenerating = false }
        do {
            let readiness = (try? retrieval.scopeReadiness(matterID: matterID, scope: scope)) ?? ScopeReadiness(totalDocuments: 0, readyDocuments: 0, pendingDocuments: 0, requiresSemanticIndex: false, isFullyReady: false)
            let prepared = try await prepareSources(question: question, scope: scope, guidedChunkIDs: nil)
            guard !prepared.isEmpty else { message = "No matching sources were found."; return nil }
            let prompt = DocumentQAPromptBuilder.buildQAPrompt(question: question, sources: prepared.map(\.source), mode: mode)
            let answer = try await collect(prompt: prompt, modelID: modelID)
            let lowConfidence = Set(prepared.filter { $0.source.lowConfidence }.map(\.source.label))
            let check = CitationCoverage.check(answer: answer, availableLabels: prepared.map(\.source.label), lowConfidenceLabels: lowConfidence, scopeFullyIndexed: readiness.isFullyReady)
            let markdown = answer + "\n" + makeAppendix(prepared).markdown()
            let status: StructuredOutputStatus = check.requiresReview ? .needsReview : .complete

            let existingVersions = (try? store.structuredOutputs.fetchVersions(structuredOutputID: outputID)) ?? []
            let nextIndex = (existingVersions.map(\.versionIndex).max() ?? 0) + 1
            let version = try store.structuredOutputs.createVersion(
                structuredOutputID: outputID, versionIndex: nextIndex, contentMarkdown: markdown,
                requiredSections: [], presentSections: [], missingSections: [],
                parentVersionID: existingVersions.first(where: { $0.versionIndex == nextIndex - 1 })?.id
            )
            try? store.structuredOutputs.updateStatus(outputID: outputID, status: status)
            try attachSources(prepared: prepared, scope: scope, question: question, mode: mode, versionID: version.id)
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID, eventType: "qa_generated", actor: "runtime",
                summary: "Regenerated document Q&A", relatedTable: "structured_outputs", relatedID: outputID
            )
            let result = QAResult(outputID: outputID, versionID: version.id, markdown: markdown, status: status.rawValue, warnings: check.warnings, citationLabels: check.usedLabels, unsupported: check.appearsUnsupported)
            lastResult = result
            return result
        } catch {
            message = "Regeneration failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func attachSources(prepared: [PreparedSource], scope: RetrievalScope, question: String, mode: DocumentAnswerMode, versionID: String) throws {
        let scopeJSON = (try? JSONEncoder().encode(scope)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matterID, mode: .autoSource, scopeJSON: scopeJSON, retrievalQuery: question
        )
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
            // Base prompt only: the answer is machine-checked for citation coverage
            // against the grounding sources, so the user's free-form profile must
            // not degrade the required citation structure.
            systemPrompt: defaultSystemPrompt, options: GenerationOptions()
        )
        var output = ""
        for try await event in try runtimeClient.generate(request) {
            if event.type == .token, let token = event.tokenText { output += token }
        }
        return ReasoningContent.answer(from: output)
    }
}
