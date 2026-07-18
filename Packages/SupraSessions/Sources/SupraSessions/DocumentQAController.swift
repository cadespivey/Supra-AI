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
    public static let promptBuilderVersion = "document-qa-v1"
    @Published public private(set) var isGenerating = false
    @Published public private(set) var message: String?
    @Published public private(set) var lastResult: QAResult?
    @Published public private(set) var lastPackingReport: TokenPackingReport?
    private var sourceSetPackingReport: DocumentPackingReport?

    public struct QAResult: Sendable, Equatable {
        public var outputID: String
        public var versionID: String
        public var markdown: String
        public var status: String
        public var warnings: [String]
        public var citationLabels: [String]
        public var unsupported: Bool
        /// Which retrieval tier grounded this answer — `.fast` answers are
        /// preliminary and the UI offers "search all documents" (spec §3.2).
        public var depth: RetrievalDepth = .deep
        public var assuranceState: OutputAssuranceState? = nil
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
    ///
    /// Fast-by-default (spec §3.2): the preliminary pass skips the rerank; when it
    /// finds nothing usable the controller auto-escalates to `.deep` once, silently
    /// (§8.2). The UI offers "search all documents" on `.fast` results.
    @discardableResult
    public func generate(
        question: String,
        scope: RetrievalScope = .wholeMatter,
        mode: DocumentAnswerMode = .short,
        guidedChunkIDs: [String]? = nil,
        modelID: ModelID?,
        modelLineage: DocumentGenerationModelLineage? = nil,
        route: ModelRoute? = nil,
        depth: RetrievalDepth = .fast
    ) async -> QAResult? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { message = "Enter a question."; return nil }
        let effectiveRoute = route ?? ModelRouter().route(forStructuredOutput: mode.outputType)
        guard let modelID else {
            message = if let effectiveRoute {
                "Assign a \(effectiveRoute.role.displayName) model in the Models tab to ask questions."
            } else {
                "Assign a task model in the Models tab to ask questions."
            }
            return nil
        }
        guard let resolvedModelLineage = modelLineage ?? DocumentGenerationModelLineage.resolve(
            modelID: modelID,
            store: store
        ) else {
            message = DocumentGenerationLineageError.stableModelIdentityUnavailable.localizedDescription
            return nil
        }

        // Block until the selected scope is fully indexed (plan §8.1).
        let readiness = (try? retrieval.scopeReadiness(matterID: matterID, scope: scope)) ?? ScopeReadiness(totalDocuments: 0, readyDocuments: 0, pendingDocuments: 0, requiresSemanticIndex: false, isFullyReady: false)
        guard readiness.isFullyReady else {
            message = "The selected documents are still indexing (\(readiness.readyDocuments)/\(readiness.totalDocuments) ready). Try again once indexing finishes."
            return nil
        }
        guard !isGenerating else {
            message = "A question is already being answered. Wait for it to finish."
            return nil
        }

        isGenerating = true
        message = nil
        lastPackingReport = nil
        sourceSetPackingReport = nil
        defer { isGenerating = false }

        let isGuided = (guidedChunkIDs?.isEmpty == false)
        do {
            var effectiveDepth = depth
            var prepared = try await prepareSources(question: trimmed, scope: scope, guidedChunkIDs: guidedChunkIDs, modelID: modelID, route: effectiveRoute, depth: effectiveDepth)
            // Empty fast packet → run the deep pass once, silently (§8.2). Never
            // auto-escalate merely on low confidence — the fast tier stays predictable.
            if prepared.isEmpty, effectiveDepth == .fast {
                effectiveDepth = .deep
                prepared = try await prepareSources(question: trimmed, scope: scope, guidedChunkIDs: guidedChunkIDs, modelID: modelID, route: effectiveRoute, depth: .deep)
            }
            guard !prepared.isEmpty else {
                message = "No matching sources were found in the selected scope."
                return nil
            }
            let budgeted = try await collectBudgetedAnswer(
                question: trimmed,
                mode: mode,
                prepared: prepared,
                modelID: modelID,
                route: effectiveRoute
            )
            prepared = budgeted.prepared
            let answer = budgeted.answer

            let verification = try verify(
                answer: answer,
                prepared: prepared,
                scopeFullyIndexed: readiness.isFullyReady
            )
            let appendix = makeAppendix(prepared)
            let markdown = verification.warningMarkdown + answer + "\n" + appendix.markdown()
            let status: StructuredOutputStatus = effectiveDepth == .fast || verification.requiresReview
                ? .needsReview
                : .complete

            let result = try persist(
                question: trimmed, scope: scope, mode: mode, markdown: markdown,
                prepared: prepared, status: status, verification: verification,
                sourceMode: isGuided ? .guided : .autoSource, depth: effectiveDepth,
                modelID: modelID, modelLineage: resolvedModelLineage, route: effectiveRoute,
                prompt: budgeted.prompt
            )
            lastResult = result
            return result
        } catch {
            message = "Q&A generation failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Regenerates an output using its saved scope + question, creating a new
    /// version with a fresh source set (plan §10.1). Defaults to `.deep`: an
    /// explicit regenerate (or "search all documents" on a preliminary answer) is a
    /// request for the full pass. The prior version is retained, so a preliminary
    /// answer is never silently discarded (spec §5).
    @discardableResult
    public func regenerate(
        outputID: String,
        modelID: ModelID?,
        modelLineage: DocumentGenerationModelLineage? = nil,
        route: ModelRoute? = nil,
        depth: RetrievalDepth = .deep
    ) async -> QAResult? {
        guard let output = try? store.structuredOutputs.fetchOutputs(matterID: matterID).first(where: { $0.id == outputID }),
              let activeVersionID = output.activeVersionID,
              let sourceSet = try? store.documentSources.fetchSourceSet(structuredOutputVersionID: activeVersionID) else {
            message = "Could not find the output to regenerate."
            return nil
        }
        let scope = (try? JSONDecoder().decode(RetrievalScope.self, from: Data((sourceSet.scopeJSON).utf8))) ?? .wholeMatter
        let question = sourceSet.retrievalQuery ?? output.title
        let mode: DocumentAnswerMode = output.outputType == StructuredOutputType.documentQAMemo.rawValue ? .memo : .short
        // Preserve a hand-picked (guided) selection on regenerate instead of
        // silently falling back to auto-retrieval, which would change which
        // sources the answer is grounded in without the user knowing.
        var guidedChunkIDs: [String]?
        if sourceSet.mode == DocumentSourceSetMode.guided.rawValue {
            let priorChunkIDs = ((try? store.documentSources.fetchSources(structuredOutputVersionID: activeVersionID)) ?? [])
                .sorted { $0.rank < $1.rank }
                .compactMap(\.chunkID)
            guidedChunkIDs = priorChunkIDs.isEmpty ? nil : priorChunkIDs
        }
        return await regenerateExisting(
            outputID: outputID,
            question: question,
            scope: scope,
            mode: mode,
            guidedChunkIDs: guidedChunkIDs,
            modelID: modelID,
            modelLineage: modelLineage,
            route: route ?? ModelRouter().route(forStructuredOutput: mode.outputType),
            depth: depth
        )
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

    /// Tier tuning (spec §3.1). Deep: wider candidate pool, LLM-reranked down to the
    /// packed set (the shared `DocumentRerank` pool — 40 keeps the rerank prompt
    /// inside small local-model contexts). Fast: small pool, no rerank, packs the
    /// RRF top — a preliminary answer in seconds.
    static let candidatePoolSize = DocumentRerank.candidatePoolSize
    static let packedSourceLimit = 10
    static let fastCandidatePoolSize = 12
    static let fastPackedSourceLimit = 8

    private func prepareSources(question: String, scope: RetrievalScope, guidedChunkIDs: [String]?, modelID: ModelID?, route: ModelRoute?, depth: RetrievalDepth) async throws -> [PreparedSource] {
        if let guidedChunkIDs, !guidedChunkIDs.isEmpty {
            return prepareGuided(chunkIDs: guidedChunkIDs)
        }
        let pool = depth == .fast ? Self.fastCandidatePoolSize : Self.candidatePoolSize
        let result = try await retrieval.retrieve(matterID: matterID, query: question, scope: scope, limit: pool, depth: depth)
        let candidates = result.sources.enumerated().map { index, retrieved -> PreparedSource in
            let low = (retrieved.ocrConfidence.map { $0 < lowConfidenceThreshold } ?? false)
            return PreparedSource(
                source: retrieved.groundingSource(
                    sourceID: "\(matterID)/\(retrieved.chunkID)",
                    label: "S\(index + 1)",
                    lowConfidence: low
                ),
                documentID: retrieved.documentID, chunkID: retrieved.chunkID,
                locatorJSON: retrieved.locator.encodedJSON(), rank: index,
                warnings: low ? ["low OCR confidence"] : []
            )
        }
        // Fast tier: pack the RRF top directly — the rerank IS the slow part.
        if depth == .fast {
            return relabeled(Array(candidates.prefix(Self.fastPackedSourceLimit)))
        }
        guard let modelID else { return relabeled(Array(candidates.prefix(Self.packedSourceLimit))) }
        return await rerankSources(candidates, question: question, modelID: modelID, route: route)
    }

    /// Per-candidate snippet length shown to the reranker (see
    /// `DocumentRerank.snippetChars`).
    static let rerankSnippetChars = DocumentRerank.snippetChars

    /// LLM-reranks the candidate pool to the most relevant `packedSourceLimit`,
    /// re-labeling them S1…SN in the new order. Delegates to the shared
    /// `DocumentRerank` machinery (also used by the matter-chat grounded deep pass).
    /// Best-effort: a model failure, or one that returns too few valid labels, falls
    /// back to retrieval order.
    private func rerankSources(_ candidates: [PreparedSource], question: String, modelID: ModelID, route: ModelRoute?) async -> [PreparedSource] {
        guard candidates.count > Self.packedSourceLimit else { return relabeled(candidates) }
        let order = await DocumentRerank.packedOrder(
            question: question,
            candidates: candidates.map { DocumentRerank.Candidate(label: $0.source.label, text: $0.source.text) },
            limit: Self.packedSourceLimit,
            runtimeClient: runtimeClient,
            modelID: modelID
        )
        let byLabel = Dictionary(candidates.map { ($0.source.label, $0) }, uniquingKeysWith: { first, _ in first })
        return relabeled(order.compactMap { byLabel[$0] })
    }

    private func relabeled(_ sources: [PreparedSource]) -> [PreparedSource] {
        sources.enumerated().map { index, item in
            var copy = item
            copy.source.label = "S\(index + 1)"
            copy.rank = index
            return copy
        }
    }

    /// Final source order (see `DocumentRerank.rerankOrder`). Kept as a stable seam
    /// for existing callers/tests; the implementation lives in the shared machinery.
    nonisolated static func rerankOrder(retrievalLabels: [String], preferred: [String], limit: Int) -> [String] {
        DocumentRerank.rerankOrder(retrievalLabels: retrievalLabels, preferred: preferred, limit: limit)
    }

    /// Extracts S-style source labels from a reranker's free-text reply (see
    /// `DocumentRerank.parsePacketLabels`). Kept as a stable seam for existing
    /// callers/tests; the implementation lives in the shared machinery.
    nonisolated static func parsePacketLabels(_ text: String) -> [String] {
        DocumentRerank.parsePacketLabels(text)
    }

    private func prepareGuided(chunkIDs: [String]) -> [PreparedSource] {
        let nameByID = Dictionary((try? store.documentLibrary.fetchDocuments(matterID: matterID))?.map { ($0.id, $0.displayName) } ?? [], uniquingKeysWith: { a, _ in a })
        // Matter-scope the hand-picked chunks: only chunks belonging to documents
        // in THIS matter may be used, so a stray/other-matter chunk id can never
        // leak another matter's content into this answer.
        let chunks = ((try? store.documentIndex.fetchChunks(ids: chunkIDs)) ?? [])
            .filter { nameByID[$0.documentID] != nil }
        // `chunkIDs` is caller-supplied (guided generation / regenerate), so it isn't
        // guaranteed unique the way a primary-key fetch is — dedupe keys to keep the
        // ordering map from trapping on a repeated id.
        let order = Dictionary(chunkIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
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
                let structureContext = chunk.chunkerVersion == 2
                    ? chunk.nodeID.flatMap { try? store.documentStructure.retrievalContext(nodeID: $0) }
                    : nil
                return PreparedSource(
                    source: GroundingSource(
                        sourceID: "\(matterID)/\(chunk.id)",
                        label: "S\(index + 1)", documentName: nameByID[chunk.documentID] ?? "Document",
                        locatorDisplay: locator.displayString, text: chunk.normalizedText,
                        excerpt: chunk.displayExcerpt ?? DocumentChunker.excerpt(chunk.normalizedText),
                        lowConfidence: low,
                        unitKind: chunk.chunkerVersion == 2 ? (chunk.unitKind ?? structureContext?.unitKind) : nil,
                        hiddenDerived: structureContext?.hiddenDerived ?? false
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
        prepared: [PreparedSource], status: StructuredOutputStatus, verification: DocumentSupportReport,
        sourceMode: DocumentSourceSetMode, depth: RetrievalDepth,
        modelID: ModelID, modelLineage: DocumentGenerationModelLineage,
        route: ModelRoute?, prompt: String
    ) throws -> QAResult {
        let title = "Q&A: \(question.prefix(60))"
        let output = try store.structuredOutputs.createOutput(
            matterID: matterID,
            title: String(title),
            outputType: mode.outputType,
            status: .draft
        )
        let sourceSetID = try prepareSourceSet(
            prepared: prepared,
            scope: scope,
            question: question,
            mode: sourceMode,
            depth: depth
        )
        let generation = try createGenerationSession(
            modelID: modelID,
            lineage: modelLineage,
            prompt: prompt,
            route: route
        )
        let version = try store.structuredOutputs.createVersion(
            structuredOutputID: output.id, contentMarkdown: markdown,
            requiredSections: [], presentSections: [], missingSections: [],
            generationSessionID: generation.id,
            verificationStatus: verification.verificationStatus,
            verificationVersion: DocumentSupportVerifier.version,
            verificationResults: verification.results,
            verificationDimensions: VerificationDimensionsMapper.dimensions(for: verification),
            sourceSetID: sourceSetID,
            promptBuilderVersion: Self.promptBuilderVersion,
            assuranceState: depth == .fast ? .preliminary : nil,
            outputStatus: status
        )
        _ = try? store.auditEvents.recordEvent(
            matterID: matterID, eventType: "qa_generated", actor: "runtime",
            summary: "Generated document Q&A", relatedTable: "structured_outputs", relatedID: output.id
        )
        return QAResult(
            outputID: output.id, versionID: version.id, markdown: markdown, status: status.rawValue,
            warnings: verification.warnings,
            citationLabels: verification.usedLabels,
            unsupported: verification.appearsUnsupported,
            depth: depth,
            assuranceState: version.assuranceState.flatMap(OutputAssuranceState.init(rawValue:))
        )
    }

    private func regenerateExisting(
        outputID: String,
        question: String,
        scope: RetrievalScope,
        mode: DocumentAnswerMode,
        guidedChunkIDs: [String]?,
        modelID: ModelID?,
        modelLineage: DocumentGenerationModelLineage?,
        route: ModelRoute?,
        depth: RetrievalDepth = .deep
    ) async -> QAResult? {
        let effectiveRoute = route ?? ModelRouter().route(forStructuredOutput: mode.outputType)
        guard let modelID else {
            message = if let effectiveRoute {
                "Assign a \(effectiveRoute.role.displayName) model in the Models tab to regenerate."
            } else {
                "Assign a task model in the Models tab to regenerate."
            }
            return nil
        }
        guard let resolvedModelLineage = modelLineage ?? DocumentGenerationModelLineage.resolve(
            modelID: modelID,
            store: store
        ) else {
            message = DocumentGenerationLineageError.stableModelIdentityUnavailable.localizedDescription
            return nil
        }
        guard !isGenerating else {
            message = "A question is already being answered. Wait for it to finish."
            return nil
        }
        isGenerating = true
        message = nil
        lastPackingReport = nil
        sourceSetPackingReport = nil
        defer { isGenerating = false }
        let isGuided = (guidedChunkIDs?.isEmpty == false)
        do {
            let readiness = (try? retrieval.scopeReadiness(matterID: matterID, scope: scope)) ?? ScopeReadiness(totalDocuments: 0, readyDocuments: 0, pendingDocuments: 0, requiresSemanticIndex: false, isFullyReady: false)
            var prepared = try await prepareSources(question: question, scope: scope, guidedChunkIDs: guidedChunkIDs, modelID: modelID, route: effectiveRoute, depth: depth)
            guard !prepared.isEmpty else { message = "No matching sources were found."; return nil }
            let budgeted = try await collectBudgetedAnswer(
                question: question,
                mode: mode,
                prepared: prepared,
                modelID: modelID,
                route: effectiveRoute
            )
            prepared = budgeted.prepared
            let answer = budgeted.answer
            let verification = try verify(
                answer: answer,
                prepared: prepared,
                scopeFullyIndexed: readiness.isFullyReady
            )
            let markdown = verification.warningMarkdown + answer + "\n" + makeAppendix(prepared).markdown()
            let status: StructuredOutputStatus = depth == .fast || verification.requiresReview
                ? .needsReview
                : .complete

            let existingVersions = (try? store.structuredOutputs.fetchVersions(structuredOutputID: outputID)) ?? []
            let parentVersionID = existingVersions.max(by: { $0.versionIndex < $1.versionIndex })?.id
            let sourceSetID = try prepareSourceSet(
                prepared: prepared,
                scope: scope,
                question: question,
                mode: isGuided ? .guided : .autoSource,
                depth: depth
            )
            let generation = try createGenerationSession(
                modelID: modelID,
                lineage: resolvedModelLineage,
                prompt: budgeted.prompt,
                route: effectiveRoute
            )
            let version = try store.structuredOutputs.createVersion(
                structuredOutputID: outputID, contentMarkdown: markdown,
                requiredSections: [], presentSections: [], missingSections: [],
                parentVersionID: parentVersionID,
                generationSessionID: generation.id,
                verificationStatus: verification.verificationStatus,
                verificationVersion: DocumentSupportVerifier.version,
                verificationResults: verification.results,
                verificationDimensions: VerificationDimensionsMapper.dimensions(for: verification),
                sourceSetID: sourceSetID,
                promptBuilderVersion: Self.promptBuilderVersion,
                assuranceState: depth == .fast ? .preliminary : nil,
                outputStatus: status
            )
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID, eventType: "qa_generated", actor: "runtime",
                summary: "Regenerated document Q&A", relatedTable: "structured_outputs", relatedID: outputID
            )
            let result = QAResult(
                outputID: outputID,
                versionID: version.id,
                markdown: markdown,
                status: status.rawValue,
                warnings: verification.warnings,
                citationLabels: verification.usedLabels,
                unsupported: verification.appearsUnsupported,
                depth: depth,
                assuranceState: version.assuranceState.flatMap(OutputAssuranceState.init(rawValue:))
            )
            lastResult = result
            return result
        } catch {
            message = "Regeneration failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func verify(
        answer: String,
        prepared: [PreparedSource],
        scopeFullyIndexed: Bool
    ) throws -> DocumentSupportReport {
        try DocumentSupportVerifier.verify(
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
            scopeFullyIndexed: scopeFullyIndexed
        )
    }

    /// Creates a pending, matter-scoped source set. `createVersion` attaches it
    /// together with provenance, active version, and output status in one database
    /// transaction.
    private func prepareSourceSet(prepared: [PreparedSource], scope: RetrievalScope, question: String, mode: DocumentSourceSetMode, depth: RetrievalDepth) throws -> String {
        let scopeJSON = (try? JSONEncoder().encode(scope)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let report = sourceSetPackingReport ?? DocumentSourceLineageBuilder.report(
            summary: lastPackingReport,
            candidates: prepared.map { item in
                .init(
                    sourceID: item.source.sourceID,
                    label: item.source.label,
                    rank: item.rank,
                    originalText: item.source.text,
                    packedText: item.source.packedText
                )
            }
        )
        let isGuided = mode == .guided
        let configuration = DocumentRetrievalConfiguration(
            mode: mode.rawValue,
            depth: depth.rawValue,
            candidateLimit: isGuided ? prepared.count : (depth == .fast ? Self.fastCandidatePoolSize : Self.candidatePoolSize),
            packedLimit: isGuided ? prepared.count : (depth == .fast ? Self.fastPackedSourceLimit : Self.packedSourceLimit),
            maxPerDocument: isGuided ? nil : DocumentRetrievalService.defaultMaxPerDocument,
            semanticFloor: isGuided ? nil : (depth == .fast
                ? DocumentRetrievalService.fastMinSemanticSimilarity
                : DocumentRetrievalService.defaultMinSemanticSimilarity),
            rrfK: isGuided ? nil : DocumentRetrievalService.rrfK
        )
        let lineage = try DocumentSourceLineageBuilder.make(
            store: store,
            matterID: matterID,
            scope: scope,
            configuration: configuration,
            packingReport: report
        )
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matterID, mode: mode, scopeJSON: scopeJSON, retrievalQuery: question,
            retrievalDepth: depth.rawValue,
            packingReportJSON: lineage.packingReportJSON,
            embeddingModelID: lineage.embeddingModelID,
            embeddingModelRevision: lineage.embeddingModelRevision,
            chunkerVersion: lineage.chunkerVersion,
            retrievalConfigJSON: lineage.retrievalConfigJSON,
            corpusSnapshotHash: lineage.corpusSnapshotHash
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
        return sourceSet.id
    }

    private func collect(prompt: String, modelID: ModelID, route: ModelRoute?) async throws -> String {
        let request = GenerateRequest(
            generationID: GenerationID(), modelID: modelID, prompt: prompt,
            // The grounding contract (answer only from sources, [S#] citations, exact
            // refusal string) leads in the base prompt + user-turn prompt, so layering
            // the user's profile on top personalizes citation style / jurisdiction /
            // voice without loosening the grounding discipline.
            systemPrompt: routedSystemPrompt(route),
            options: route?.options ?? GenerationOptions()
        )
        let output = try await runtimeClient.collectGeneratedText(request)
        return ReasoningContent.answer(from: output)
    }

    private struct BudgetedAnswer {
        var answer: String
        var prepared: [PreparedSource]
        var prompt: String
    }

    private enum QABudgetError: LocalizedError {
        case requiredPacketTooLarge

        var errorDescription: String? {
            "The grounded question and its first source cannot fit the selected model's context window."
        }
    }

    /// Counts the actual serialized cumulative source prefixes, packs the
    /// largest safe prefix, and permits exactly one source-boundary retry when
    /// the runtime tokenizer still reports overflow.
    private func collectBudgetedAnswer(
        question: String,
        mode: DocumentAnswerMode,
        prepared: [PreparedSource],
        modelID: ModelID,
        route: ModelRoute?
    ) async throws -> BudgetedAnswer {
        let systemPrompt = routedSystemPrompt(route)
        let packetPrompts = prepared.indices.map { upperBound in
            DocumentQAPromptBuilder.buildQAPrompt(
                question: question,
                sources: Array(prepared.prefix(upperBound + 1)).map(\.source),
                mode: mode
            )
        }
        var report = await RuntimeTokenBudgeting.report(
            serializedPackets: packetPrompts.map {
                RuntimeTokenBudgeting.serializedPacket(systemPrompt: systemPrompt, prompt: $0)
            },
            modelID: modelID,
            options: route?.options ?? GenerationOptions(),
            runtimeClient: runtimeClient
        )
        lastPackingReport = report
        guard report.canPack else { throw QABudgetError.requiredPacketTooLarge }

        var selected = Array(prepared.prefix(report.packedItemCount))
        var prompt = DocumentQAPromptBuilder.buildQAPrompt(
            question: question,
            sources: selected.map(\.source),
            mode: mode
        )
        do {
            sourceSetPackingReport = DocumentSourceLineageBuilder.report(
                summary: report,
                candidates: prepared.map { item in
                    .init(
                        sourceID: item.source.sourceID,
                        label: item.source.label,
                        rank: item.rank,
                        originalText: item.source.text,
                        packedText: item.source.packedText
                    )
                }
            )
            return BudgetedAnswer(
                answer: try await collect(prompt: prompt, modelID: modelID, route: route),
                prepared: selected,
                prompt: prompt
            )
        } catch let error as GenerationStreamError where error == .contextOverflowed {
            guard selected.count > 1 else { throw error }
        }

        selected.removeLast()
        prompt = DocumentQAPromptBuilder.buildQAPrompt(
            question: question,
            sources: selected.map(\.source),
            mode: mode
        )
        let retryReport = await RuntimeTokenBudgeting.report(
            serializedPackets: [
                RuntimeTokenBudgeting.serializedPacket(systemPrompt: systemPrompt, prompt: prompt)
            ],
            modelID: modelID,
            options: route?.options ?? GenerationOptions(),
            runtimeClient: runtimeClient
        )
        report.countMethod = retryReport.countMethod
        report.selectedInputTokens = retryReport.selectedInputTokens
        report.packedItemCount = selected.count
        report.omittedItemCount = report.consideredItemCount - selected.count
        report.omissionReason = "context_overflow_retry"
        report.overflowRetryCount = 1
        report.cumulativeInputTokenCounts = retryReport.cumulativeInputTokenCounts
        lastPackingReport = report
        sourceSetPackingReport = DocumentSourceLineageBuilder.report(
            summary: report,
            candidates: prepared.map { item in
                .init(
                    sourceID: item.source.sourceID,
                    label: item.source.label,
                    rank: item.rank,
                    originalText: item.source.text,
                    packedText: item.source.packedText
                )
            }
        )

        return BudgetedAnswer(
            answer: try await collect(prompt: prompt, modelID: modelID, route: route),
            prepared: selected,
            prompt: prompt
        )
    }

    private func createGenerationSession(
        modelID: ModelID,
        lineage: DocumentGenerationModelLineage,
        prompt: String,
        route: ModelRoute?
    ) throws -> GenerationSessionRecord {
        try store.generation.createDocumentGenerationSession(
            modelID: modelID.rawValue.uuidString,
            modelRepository: lineage.modelRepository,
            modelRevision: lineage.modelRevision,
            promptBuilderVersion: Self.promptBuilderVersion,
            prompt: prompt,
            systemPrompt: routedSystemPrompt(route),
            options: route?.options ?? GenerationOptions()
        )
    }

    private func routedSystemPrompt(_ route: ModelRoute?) -> String? {
        let base = [defaultSystemPrompt, route?.systemPrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        // Document Q&A is strictly grounded in the matter's sources — exclude the
        // user's writing-style excerpts so the model can't treat them as facts.
        return store.composedAssistantPrompt(base: base.isEmpty ? nil : base, includeWritingSamples: false)
    }
}
