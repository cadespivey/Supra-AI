import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

/// One human-readable passage offered by the guided document-Q&A chooser.
/// `chunkID` is retained as the stable selection value, but the UI presents the
/// document name, locator, and excerpt instead of asking users to understand it.
public struct GuidedDocumentSource: Identifiable, Sendable, Equatable {
    public var id: String { chunkID }
    public let chunkID: String
    public let documentID: String
    public let documentName: String
    public let locatorDisplay: String
    public let excerpt: String
    public let revisionID: String?
    public let isReady: Bool
    public let blockingReason: String?

    public init(
        chunkID: String,
        documentID: String,
        documentName: String,
        locatorDisplay: String,
        excerpt: String,
        revisionID: String?,
        isReady: Bool,
        blockingReason: String?
    ) {
        self.chunkID = chunkID
        self.documentID = documentID
        self.documentName = documentName
        self.locatorDisplay = locatorDisplay
        self.excerpt = excerpt
        self.revisionID = revisionID
        self.isReady = isReady
        self.blockingReason = blockingReason
    }
}

/// Readiness of the exact hand-picked set, independent from unselected matter
/// documents. Every selected ID must still resolve to a current ready passage.
public struct GuidedDocumentSelectionReadiness: Sendable, Equatable {
    public let selectedCount: Int
    public let readyCount: Int
    public let blockingReasons: [String]

    public var canGenerate: Bool {
        selectedCount > 0 && readyCount == selectedCount && blockingReasons.isEmpty
    }
}

/// A persisted source rendered beneath a Q&A result. It is loaded from the saved
/// version, not reconstructed from the current chooser state.
public struct DocumentQASourceReference: Identifiable, Sendable, Equatable {
    public let id: String
    /// Live chunk IDs are intentionally optional: reindexing deletes and
    /// recreates chunks, and the historical citation FK is `ON DELETE SET NULL`.
    public let chunkID: String?
    public let documentName: String
    public let citationLabel: String
    public let locatorDisplay: String
    public let excerpt: String
    public let canPreview: Bool
}

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
        /// Whether the answer came from automatic retrieval or an explicit saved
        /// source packet. Fast guided results must never advertise a scope-wide
        /// "Search All Documents" action that regeneration will not perform.
        public var sourceMode: DocumentSourceSetMode = .autoSource
        /// Which retrieval tier grounded this answer — `.fast` answers are
        /// preliminary and the UI offers "search all documents" (spec §3.2).
        public var depth: RetrievalDepth = .deep
        public var assuranceState: OutputAssuranceState? = nil
    }

    public let matterID: String
    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private let retrieval: DocumentRetrievalService
    private let previewLoader: DocumentPreviewLoader
    private let requiresSemanticIndex: Bool
    private let defaultSystemPrompt: String?
    private let lowConfidenceThreshold = OCRPolicy.lowConfidenceThreshold
    private var activeGenerationID: GenerationID?

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
        self.previewLoader = DocumentPreviewLoader(store: store)
        self.requiresSemanticIndex = embedder != nil
        self.defaultSystemPrompt = defaultSystemPrompt
    }

    public func scopeReadiness(scope: RetrievalScope) -> ScopeReadiness? {
        try? retrieval.scopeReadiness(matterID: matterID, scope: scope)
    }

    /// Builds the chooser catalog from the current matter scope. A document with
    /// stale/failed/review-required state remains visible but disabled; a ready
    /// chunk is selectable only when it binds the part's current immutable
    /// revision. Documents without a current chunk get one named disabled row so
    /// an omitted source never disappears silently from readiness UI.
    public func guidedSources(scope: RetrievalScope = .wholeMatter) -> [GuidedDocumentSource] {
        guard let scopedIDs = try? store.documentLibrary.resolveScopeDocumentIDs(
            matterID: matterID,
            folderIDs: scope.folderIDs,
            documentIDs: scope.documentIDs,
            tagIDs: scope.tagIDs,
            dateStart: scope.dateStart,
            dateEnd: scope.dateEnd
        ) else { return [] }
        let allowed = Set(scopedIDs)
        let documents = ((try? store.documentLibrary.fetchDocuments(matterID: matterID)) ?? [])
            .filter { allowed.contains($0.id) }
            .sorted {
                let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }

        return documents.flatMap { document -> [GuidedDocumentSource] in
            let documentBlocker = guidedDocumentBlocker(document)
            let parts = (try? store.documentIndex.fetchParts(documentID: document.id)) ?? []
            let currentRevisionByPartID = Dictionary(
                uniqueKeysWithValues: parts.compactMap { part in
                    part.currentRevisionID.map { (part.id, $0) }
                }
            )
            let chunks = (try? store.documentIndex.fetchChunks(documentID: document.id)) ?? []
            guard !chunks.isEmpty else {
                return [GuidedDocumentSource(
                    chunkID: "unavailable-document:\(document.id)",
                    documentID: document.id,
                    documentName: document.displayName,
                    locatorDisplay: "No indexed passages",
                    excerpt: "Reprocess this document before selecting it.",
                    revisionID: nil,
                    isReady: false,
                    blockingReason: documentBlocker ?? "\(document.displayName): no indexed passages are available"
                )]
            }
            return chunks.map { chunk in
                let locator = Self.locator(for: chunk)
                let revisionBlocker: String? = if chunk.revisionID == nil {
                    "\(document.displayName): passage has no current revision binding"
                } else if chunk.pagePartID == nil {
                    "\(document.displayName): passage has no current part binding"
                } else if let partID = chunk.pagePartID,
                          currentRevisionByPartID[partID] != chunk.revisionID {
                    "\(document.displayName): passage belongs to an older revision"
                } else {
                    nil
                }
                let blocker = documentBlocker ?? revisionBlocker
                return GuidedDocumentSource(
                    chunkID: chunk.id,
                    documentID: document.id,
                    documentName: document.displayName,
                    locatorDisplay: locator.displayString,
                    excerpt: chunk.displayExcerpt ?? DocumentChunker.excerpt(chunk.normalizedText),
                    revisionID: chunk.revisionID,
                    isReady: blocker == nil,
                    blockingReason: blocker
                )
            }
        }
    }

    /// Re-resolves each selected ID so deletion, reprocessing, or review state
    /// changes between opening the sheet and pressing Generate fail closed.
    public func guidedSelectionReadiness(
        chunkIDs: [String],
        scope: RetrievalScope = .wholeMatter
    ) -> GuidedDocumentSelectionReadiness {
        let uniqueIDs = chunkIDs.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard !uniqueIDs.isEmpty else {
            return GuidedDocumentSelectionReadiness(
                selectedCount: 0,
                readyCount: 0,
                blockingReasons: ["Choose at least one ready source."]
            )
        }
        let byID = Dictionary(
            guidedSources(scope: scope).map { ($0.chunkID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var readyCount = 0
        var blockers: [String] = []
        for id in uniqueIDs {
            guard let source = byID[id] else {
                blockers.append("A selected source is no longer available. Refresh the source list and choose again.")
                continue
            }
            if source.isReady {
                readyCount += 1
            } else {
                blockers.append(source.blockingReason ?? "\(source.documentName): source is unavailable")
            }
        }
        return GuidedDocumentSelectionReadiness(
            selectedCount: uniqueIDs.count,
            readyCount: readyCount,
            blockingReasons: Array(NSOrderedSet(array: blockers)) as? [String] ?? blockers
        )
    }

    /// Loads the immutable source rows attached to one saved answer version.
    public func sourceReferences(versionID: String) -> [DocumentQASourceReference] {
        guard let sourceSet = try? store.documentSources.fetchSourceSet(
            structuredOutputVersionID: versionID
        ), sourceSet.matterID == matterID else { return [] }
        let names = Dictionary(
            ((try? store.documentLibrary.fetchDocuments(matterID: matterID)) ?? []).map {
                ($0.id, $0.displayName)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return ((try? store.documentSources.fetchSources(sourceSetID: sourceSet.id)) ?? [])
            .map { row in
                let locator = (try? JSONDecoder().decode(
                    DocumentSourceLocator.self,
                    from: Data(row.locatorJSON.utf8)
                )) ?? DocumentSourceLocator(sourceKind: .text)
                return DocumentQASourceReference(
                    id: row.id,
                    chunkID: row.chunkID,
                    documentName: row.documentID.flatMap { names[$0] } ?? "Document",
                    citationLabel: row.citationLabel,
                    locatorDisplay: locator.displayString,
                    excerpt: row.excerpt,
                    canPreview: row.documentID != nil || !row.excerpt.isEmpty
                )
            }
    }

    /// Loads a saved source row rather than refetching its mutable live chunk.
    /// The preview loader resolves the row's exact revision + denormalized
    /// locator/excerpt, so old answers stay inspectable after reindexing.
    public func preview(sourceID: String) -> DocumentPreviewModel? {
        guard let source = try? store.documentSources.fetchSource(id: sourceID),
              let sourceSet = try? store.documentSources.fetchSourceSet(id: source.sourceSetID),
              sourceSet.matterID == matterID else { return nil }
        return previewLoader.load(outputSource: source)
    }

    /// Chooser previews are intentionally live; result previews use
    /// `preview(sourceID:)` above.
    public func preview(chunkID: String) -> DocumentPreviewModel? {
        guard let chunk = try? store.documentIndex.fetchChunk(id: chunkID),
              let document = try? store.documentLibrary.fetchDocument(id: chunk.documentID),
              document.matterID == matterID else { return nil }
        return previewLoader.load(
            documentID: chunk.documentID,
            locator: Self.locator(for: chunk),
            matchText: chunk.normalizedText
        )
    }

    /// Stops the active runtime request. The sheet also cancels its awaiting Task,
    /// and the generation path checks cancellation before any persistence boundary.
    public func cancel() {
        guard let activeGenerationID else { return }
        let runtimeClient = runtimeClient
        Task { _ = try? await runtimeClient.cancelGeneration(activeGenerationID) }
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

        let isGuided = guidedChunkIDs != nil
        // Auto preserves its historical whole-scope readiness contract. Guided
        // mode validates the exact selected passages, so an unrelated unselected
        // document cannot expand or block the user's explicit source set.
        let readiness: ScopeReadiness
        if let guidedChunkIDs {
            let selected = guidedSelectionReadiness(chunkIDs: guidedChunkIDs, scope: scope)
            guard selected.canGenerate else {
                message = selected.blockingReasons.first ?? "Choose at least one ready source."
                return nil
            }
            readiness = ScopeReadiness(
                totalDocuments: selected.selectedCount,
                readyDocuments: selected.readyCount,
                pendingDocuments: 0,
                requiresSemanticIndex: requiresSemanticIndex,
                isFullyReady: true
            )
        } else {
            readiness = (try? retrieval.scopeReadiness(matterID: matterID, scope: scope))
                ?? ScopeReadiness(totalDocuments: 0, readyDocuments: 0, pendingDocuments: 0, requiresSemanticIndex: false, isFullyReady: false)
        }
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

        do {
            try Task.checkCancellation()
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
            if let guidedChunkIDs,
               Set(prepared.map(\.chunkID)) != Set(guidedChunkIDs) {
                message = "A selected source is no longer available. Refresh the source list and choose again."
                return nil
            }
            try Task.checkCancellation()
            let budgeted = try await collectBudgetedAnswer(
                question: trimmed,
                mode: mode,
                prepared: prepared,
                modelID: modelID,
                route: effectiveRoute,
                requiresExactSourceSet: isGuided
            )
            prepared = budgeted.prepared
            let answer = budgeted.answer
            try Task.checkCancellation()

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
        } catch is CancellationError {
            message = "Generation cancelled."
            return nil
        } catch let error as GenerationStreamError where error == .cancelled {
            message = "Generation cancelled."
            return nil
        } catch {
            message = Task.isCancelled
                ? "Generation cancelled."
                : "Q&A generation failed: \(error.localizedDescription)"
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
            guard let priorRows = try? store.documentSources.fetchSources(
                structuredOutputVersionID: activeVersionID
            ), let resolved = rehydratePersistedGuidedChunkIDs(priorRows) else {
                message = "A selected source is no longer available. The saved source set was not changed."
                return nil
            }
            guidedChunkIDs = resolved
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

    /// Reindexing deletes/reinserts live chunks, which correctly nulls historical
    /// `chunk_id` foreign keys. A guided regeneration may recover a nil binding
    /// only by finding one exact current chunk with the saved document, immutable
    /// revision, locator, and excerpt. Any missing/ambiguous row rejects the whole
    /// packet; it is never legal to `compactMap` into a smaller selection.
    private func rehydratePersistedGuidedChunkIDs(
        _ rows: [DocumentOutputSourceRecord]
    ) -> [String]? {
        let orderedRows = rows.sorted {
            $0.rank == $1.rank ? $0.id < $1.id : $0.rank < $1.rank
        }
        guard !orderedRows.isEmpty else { return nil }
        var resolved: [String] = []
        resolved.reserveCapacity(orderedRows.count)

        for row in orderedRows {
            guard let documentID = row.documentID,
                  let revisionID = row.revisionID,
                  let locator = try? JSONDecoder().decode(
                      DocumentSourceLocator.self,
                      from: Data(row.locatorJSON.utf8)
                  ) else { return nil }

            func matchesSavedProvenance(_ chunk: DocumentChunkRecord) -> Bool {
                chunk.documentID == documentID
                    && chunk.revisionID == revisionID
                    && Self.locator(for: chunk) == locator
                    && (chunk.displayExcerpt ?? DocumentChunker.excerpt(chunk.normalizedText)) == row.excerpt
            }

            if let chunkID = row.chunkID {
                guard let chunk = try? store.documentIndex.fetchChunk(id: chunkID),
                      matchesSavedProvenance(chunk) else { return nil }
                resolved.append(chunkID)
                continue
            }
            let matches = ((try? store.documentIndex.fetchChunks(documentID: documentID)) ?? [])
                .filter(matchesSavedProvenance)
            guard matches.count == 1 else { return nil }
            resolved.append(matches[0].id)
        }

        guard Set(resolved).count == orderedRows.count else { return nil }
        return resolved
    }

    // MARK: - Internals

    private struct PreparedSource {
        var source: GroundingSource
        var documentID: String
        var chunkID: String
        var revisionID: String?
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
        if let guidedChunkIDs {
            return prepareGuided(chunkIDs: guidedChunkIDs, scope: scope)
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
                documentID: retrieved.documentID,
                chunkID: retrieved.chunkID,
                revisionID: retrieved.revisionID,
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

    private func prepareGuided(
        chunkIDs: [String],
        scope: RetrievalScope
    ) -> [PreparedSource] {
        let readySourcesByID = Dictionary(
            guidedSources(scope: scope)
                .filter(\.isReady)
                .map { ($0.chunkID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Re-resolve readiness at the packing boundary as well as submission.
        // Only exact ready passages in this matter/scope may reach the prompt.
        let chunks = ((try? store.documentIndex.fetchChunks(ids: chunkIDs)) ?? [])
            .filter { chunk in
                readySourcesByID[chunk.id]?.documentID == chunk.documentID
            }
        // `chunkIDs` is caller-supplied (guided generation / regenerate), so it isn't
        // guaranteed unique the way a primary-key fetch is — dedupe keys to keep the
        // ordering map from trapping on a repeated id.
        let order = Dictionary(chunkIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return chunks
            .sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
            .enumerated().map { index, chunk in
                let locator = Self.locator(for: chunk)
                let low = (chunk.ocrConfidence.map { $0 < lowConfidenceThreshold } ?? false)
                let structureContext = chunk.chunkerVersion == 2
                    ? chunk.nodeID.flatMap { try? store.documentStructure.retrievalContext(nodeID: $0) }
                    : nil
                return PreparedSource(
                    source: GroundingSource(
                        sourceID: "\(matterID)/\(chunk.id)",
                        label: "S\(index + 1)",
                        documentName: readySourcesByID[chunk.id]?.documentName ?? "Document",
                        locatorDisplay: locator.displayString, text: chunk.normalizedText,
                        excerpt: chunk.displayExcerpt ?? DocumentChunker.excerpt(chunk.normalizedText),
                        lowConfidence: low,
                        unitKind: chunk.chunkerVersion == 2 ? (chunk.unitKind ?? structureContext?.unitKind) : nil,
                        hiddenDerived: structureContext?.hiddenDerived ?? false
                    ),
                    documentID: chunk.documentID,
                    chunkID: chunk.id,
                    revisionID: chunk.revisionID,
                    locatorJSON: locator.encodedJSON(), rank: index, warnings: low ? ["low OCR confidence"] : []
                )
            }
    }

    private func guidedDocumentBlocker(_ document: MatterDocumentRecord) -> String? {
        if document.extractionStatus == DocumentExtractionStatus.failed.rawValue
            || document.status == MatterDocumentStatus.failed.rawValue {
            return "\(document.displayName): failed processing"
        }
        if document.status == MatterDocumentStatus.needsReview.rawValue {
            return "\(document.displayName): needs review"
        }
        if document.indexStatus == DocumentIndexStatus.stale.rawValue {
            return "\(document.displayName): index is stale"
        }
        let textReady = document.indexStatus == DocumentIndexStatus.ready.rawValue
            || (!requiresSemanticIndex && document.indexStatus == DocumentIndexStatus.textIndexed.rawValue)
        if !textReady || document.status != MatterDocumentStatus.ready.rawValue {
            return "\(document.displayName): indexing is incomplete"
        }
        if document.extractionMethod?.hasPrefix("converted_lossy@toolchain:") == true {
            return "\(document.displayName): converted text requires review"
        }
        return nil
    }

    private static func locator(for chunk: DocumentChunkRecord) -> DocumentSourceLocator {
        DocumentSourceLocator(
            sourceKind: DocumentSourceKind(rawValue: chunk.sourceKind) ?? .text,
            pageIndex: chunk.pageIndex,
            pageLabel: chunk.pageLabel,
            sheetName: chunk.sheetName,
            cellRange: chunk.cellRange,
            emailPartPath: chunk.emailPartPath,
            charStart: chunk.charStart,
            charEnd: chunk.charEnd,
            boundingBoxesJSON: chunk.boundingBoxesJSON
        )
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
        let output = StructuredOutputRecord(
            matterID: matterID,
            title: String(title),
            outputType: mode.outputType.rawValue,
            status: StructuredOutputStatus.draft.rawValue
        )
        let preparedSourceSet = try makeSourceSet(
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
        let version = try store.structuredOutputs.createVersionWithSourceSetAtomically(
            structuredOutputID: output.id,
            newOutput: output,
            sourceSet: preparedSourceSet.sourceSet,
            outputSources: preparedSourceSet.sources,
            contentMarkdown: markdown,
            verificationStatus: verification.verificationStatus,
            verificationVersion: DocumentSupportVerifier.version,
            verificationResults: verification.results,
            verificationDimensions: VerificationDimensionsMapper.dimensions(for: verification),
            outputStatus: status,
            generationSessionID: generation.id,
            promptBuilderVersion: Self.promptBuilderVersion,
            assuranceState: depth == .fast ? .preliminary : nil
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
            sourceMode: sourceMode,
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
        let isGuided = guidedChunkIDs != nil
        do {
            let readiness: ScopeReadiness
            if let guidedChunkIDs {
                let selected = guidedSelectionReadiness(chunkIDs: guidedChunkIDs, scope: scope)
                guard selected.canGenerate else {
                    message = selected.blockingReasons.first ?? "Choose at least one ready source."
                    return nil
                }
                readiness = ScopeReadiness(
                    totalDocuments: selected.selectedCount,
                    readyDocuments: selected.readyCount,
                    pendingDocuments: 0,
                    requiresSemanticIndex: requiresSemanticIndex,
                    isFullyReady: true
                )
            } else {
                readiness = (try? retrieval.scopeReadiness(matterID: matterID, scope: scope))
                    ?? ScopeReadiness(totalDocuments: 0, readyDocuments: 0, pendingDocuments: 0, requiresSemanticIndex: false, isFullyReady: false)
            }
            try Task.checkCancellation()
            var prepared = try await prepareSources(question: question, scope: scope, guidedChunkIDs: guidedChunkIDs, modelID: modelID, route: effectiveRoute, depth: depth)
            guard !prepared.isEmpty else { message = "No matching sources were found."; return nil }
            if let guidedChunkIDs,
               Set(prepared.map(\.chunkID)) != Set(guidedChunkIDs) {
                message = "A selected source is no longer available. Refresh the source list and choose again."
                return nil
            }
            let budgeted = try await collectBudgetedAnswer(
                question: question,
                mode: mode,
                prepared: prepared,
                modelID: modelID,
                route: effectiveRoute,
                requiresExactSourceSet: isGuided
            )
            prepared = budgeted.prepared
            let answer = budgeted.answer
            try Task.checkCancellation()
            let verification = try verify(
                answer: answer,
                prepared: prepared,
                scopeFullyIndexed: readiness.isFullyReady
            )
            let markdown = verification.warningMarkdown + answer + "\n" + makeAppendix(prepared).markdown()
            let status: StructuredOutputStatus = depth == .fast || verification.requiresReview
                ? .needsReview
                : .complete

            let preparedSourceSet = try makeSourceSet(
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
            let version = try store.structuredOutputs.createVersionWithSourceSetAtomically(
                structuredOutputID: outputID,
                newOutput: nil,
                sourceSet: preparedSourceSet.sourceSet,
                outputSources: preparedSourceSet.sources,
                contentMarkdown: markdown,
                verificationStatus: verification.verificationStatus,
                verificationVersion: DocumentSupportVerifier.version,
                verificationResults: verification.results,
                verificationDimensions: VerificationDimensionsMapper.dimensions(for: verification),
                outputStatus: status,
                generationSessionID: generation.id,
                promptBuilderVersion: Self.promptBuilderVersion,
                assuranceState: depth == .fast ? .preliminary : nil
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
                sourceMode: isGuided ? .guided : .autoSource,
                depth: depth,
                assuranceState: version.assuranceState.flatMap(OutputAssuranceState.init(rawValue:))
            )
            lastResult = result
            return result
        } catch is CancellationError {
            message = "Generation cancelled."
            return nil
        } catch let error as GenerationStreamError where error == .cancelled {
            message = "Generation cancelled."
            return nil
        } catch {
            message = Task.isCancelled
                ? "Generation cancelled."
                : "Regeneration failed: \(error.localizedDescription)"
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

    private struct PreparedSourceSet {
        var sourceSet: DocumentSourceSetRecord
        var sources: [DocumentOutputSourceRecord]
    }

    /// Builds pending provenance records in memory. The structured-output
    /// repository inserts these records together with the output/version and
    /// attaches them inside one transaction, so a failed source FK can never
    /// strand a draft output or pending source set.
    private func makeSourceSet(
        prepared: [PreparedSource],
        scope: RetrievalScope,
        question: String,
        mode: DocumentSourceSetMode,
        depth: RetrievalDepth
    ) throws -> PreparedSourceSet {
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
        let sourceSet = DocumentSourceSetRecord(
            matterID: matterID,
            mode: mode.rawValue,
            scopeJSON: scopeJSON,
            retrievalQuery: question,
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
                sourceSetID: sourceSet.id,
                documentID: source.documentID,
                chunkID: source.chunkID,
                revisionID: source.revisionID,
                citationLabel: source.source.label, locatorJSON: source.locatorJSON,
                excerpt: source.source.excerpt, rank: source.rank,
                warningsJSON: source.warnings.isEmpty ? nil : (try? JSONEncoder.encodeToString(source.warnings))
            )
        }
        return PreparedSourceSet(sourceSet: sourceSet, sources: rows)
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
        activeGenerationID = request.generationID
        defer { activeGenerationID = nil }
        let output = try await runtimeClient.collectGeneratedText(request)
        try Task.checkCancellation()
        return ReasoningContent.answer(from: output)
    }

    private struct BudgetedAnswer {
        var answer: String
        var prepared: [PreparedSource]
        var prompt: String
    }

    private enum QABudgetError: LocalizedError {
        case requiredPacketTooLarge
        case explicitSourcesTooLarge

        var errorDescription: String? {
            switch self {
            case .requiredPacketTooLarge:
                "The grounded question and its first source cannot fit the selected model's context window."
            case .explicitSourcesTooLarge:
                "The selected sources do not all fit the assigned model's context window. Choose fewer sources or assign a model with a larger context window."
            }
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
        route: ModelRoute?,
        requiresExactSourceSet: Bool = false
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
        guard report.canPack else {
            throw requiresExactSourceSet
                ? QABudgetError.explicitSourcesTooLarge
                : QABudgetError.requiredPacketTooLarge
        }
        if requiresExactSourceSet, report.packedItemCount != prepared.count {
            throw QABudgetError.explicitSourcesTooLarge
        }

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
            if requiresExactSourceSet { throw QABudgetError.explicitSourcesTooLarge }
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
