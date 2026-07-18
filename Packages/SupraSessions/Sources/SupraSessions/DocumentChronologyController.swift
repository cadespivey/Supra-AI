import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

/// Generates source-grounded fact chronologies over a selected scope (plan §9):
/// harvests date-bearing chunks + document metadata dates, asks the model for a
/// table or narrative chronology with inline citations and exact/partial date
/// labeling, checks citations, and saves it with a source set. A scope whose
/// table packet whose size estimate fits one context budget runs as a single
/// pass; larger tables and all narratives use batched map passes merged
/// deterministically (WO 42 batched-chronology follow-up), with a
/// narrative synthesized from the merged entries in bounded second-stage passes.
@MainActor
public final class DocumentChronologyController: ObservableObject {
    /// Where a generation currently is, for progress UI. `mapping` counts are
    /// 1-based ("pass 2 of 3").
    public enum Progress: Equatable, Sendable {
        case idle
        case harvesting
        case generating
        case mapping(batch: Int, of: Int)
        case merging
        case synthesizing
        case verifying
        case saving
    }

    @Published public private(set) var isGenerating = false
    /// Neutral completion detail (for example, batch count). Errors and coverage
    /// warnings remain in `message` so the UI can style them distinctly.
    @Published public private(set) var summaryMessage: String?
    @Published public private(set) var message: String?
    @Published public private(set) var lastResult: DocumentQAController.QAResult?
    @Published public private(set) var progress: Progress = .idle
    /// Durable coverage-ledger run backing the most recently accepted chronology
    /// generation. Invalid/re-entrant requests leave this nil or unchanged.
    @Published public private(set) var lastCorpusRunID: String?

    private var generationTask: Task<DocumentQAController.QAResult?, Never>?
    private var activeGenerationID: GenerationID?

    public let matterID: String
    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private let retrieval: DocumentRetrievalService
    private let defaultSystemPrompt: String?
    /// Total safety cap on harvested sources (metadata-date and text-chunk
    /// sources combined) — a guard against pathological scopes, not a tuning
    /// knob. Fitting sources to a model's context is budgeting, and happens
    /// downstream of the harvest.
    private let maxSources: Int

    public init(
        matterID: String,
        store: SupraStore,
        runtimeClient: any RuntimeClientProtocol,
        defaultSystemPrompt: String? = nil,
        maxSources: Int = 1_000
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
        await run(scope: scope, format: format, modelID: modelID, route: route, existingOutputID: nil)
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
        return await run(scope: scope, format: format, modelID: modelID, route: route, existingOutputID: outputID)
    }

    /// Wraps `produce` in a stored task so `cancel()` has something to cancel;
    /// the public generate/regenerate signatures and their awaited results are
    /// unchanged.
    private func run(
        scope: RetrievalScope,
        format: DocumentChronologyFormat,
        modelID: ModelID?,
        route: ModelRoute?,
        existingOutputID: String?
    ) async -> DocumentQAController.QAResult? {
        // Claim cancellation ownership before creating the child task. A
        // re-entrant Generate/Regenerate call must not overwrite the handle for
        // the run that is already streaming.
        guard generationTask == nil else { return nil }
        let task = Task {
            await self.produce(scope: scope, format: format, modelID: modelID, route: route, existingOutputID: existingOutputID)
        }
        generationTask = task
        defer { generationTask = nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in
                self?.cancelActiveRuntimeGeneration()
            }
        }
    }

    /// Cancels the in-flight chronology run: the produce task (checked between
    /// batches) and the active runtime generation, mirroring the chat
    /// controller's cancel path. Cancellation before the final saving stage
    /// persists nothing; saving is the explicit point of no return.
    public func cancel() {
        generationTask?.cancel()
        cancelActiveRuntimeGeneration()
    }

    private func cancelActiveRuntimeGeneration() {
        guard let activeGenerationID else { return }
        let runtimeClient = runtimeClient
        Task { _ = try? await runtimeClient.cancelGeneration(activeGenerationID) }
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
        summaryMessage = nil
        lastCorpusRunID = nil
        defer {
            isGenerating = false
            progress = .idle
        }

        var chronologyLedger: ChronologyLedgerSession?
        do {
            progress = .harvesting
            await Task.yield()
            // The harvest is bounded only by the maxSources safety cap; the
            // batch planner below is the budgeting authority.
            let harvest = try await harvestSources(scope: scope)
            let prepared = harvest.sources
            guard !prepared.isEmpty else {
                message = "No dated facts were found in the selected documents."
                return nil
            }
            let ledger = try makeChronologyLedger(
                harvest: harvest,
                scope: scope,
                modelID: modelID
            )
            chronologyLedger = ledger
            lastCorpusRunID = ledger.runID
            if harvest.droppedCount > 0 {
                let named = harvest.omittedDocuments.prefix(5)
                var namesClause = named.joined(separator: ", ")
                let remaining = harvest.omittedDocuments.count - named.count
                if remaining > 0 { namesClause += " and \(remaining) more" }
                message = "Chronology covers \(prepared.count) of \(prepared.count + harvest.droppedCount) dated sources; omitted to fit the model's budget: \(namesClause). Narrow the scope or date range for full coverage."
            }

            let supportSources = prepared.map { item in
                DocumentSupportSource(
                    sourceID: item.source.sourceID,
                    label: item.source.label,
                    locator: item.locatorJSON,
                    text: item.source.packedText,
                    lowConfidence: item.source.lowConfidence
                )
            }

            let outcome = try await generateAnswer(
                prepared: prepared,
                supportSources: supportSources,
                format: format,
                modelID: modelID,
                route: effectiveRoute,
                ledger: ledger
            )
            let answer = outcome.answer

            try Task.checkCancellation()
            progress = .verifying
            await Task.yield()
            let scopeFullyIndexed = readiness.isFullyReady && harvest.droppedCount == 0
            // Proposition verification is pure but can be substantial for a
            // large chronology. Keep it off the MainActor so progress and Cancel
            // remain responsive; cancellation is checked before any persistence.
            let verificationTask = Task.detached(priority: .userInitiated) {
                try DocumentSupportVerifier.verify(
                    answer: answer,
                    sources: supportSources,
                    scopeFullyIndexed: scopeFullyIndexed
                )
            }
            let verification = try await withTaskCancellationHandler {
                try await verificationTask.value
            } onCancel: {
                verificationTask.cancel()
            }
            try Task.checkCancellation()
            let finalNarrativeCitationFailures = if format == .narrative {
                try await unsupportedFinalNarrativeCitations(
                    propositions: verification.propositions,
                    allowedSources: supportSources
                )
            } else {
                [PropositionSupportResult]()
            }
            let appendix = SourceAppendix(entries: prepared.map {
                SourceAppendix.Entry(label: $0.source.label, documentName: $0.source.documentName, locatorDisplay: $0.source.locatorDisplay, excerpt: $0.source.excerpt, warnings: $0.warnings)
            })

            var supplementalWarnings: [String] = []
            if outcome.unparsedRowCount > 0 {
                supplementalWarnings.append("\(outcome.unparsedRowCount) intermediate chronology lines could not be parsed and were omitted.")
            }
            if outcome.emptyMapPassCount > 0 {
                supplementalWarnings.append("\(outcome.emptyMapPassCount) of \(outcome.mapPassCount) extraction passes produced no usable rows; their sources may be uncovered.")
            }
            if outcome.mapCoverageGap {
                supplementalWarnings.append("One or more extraction passes omitted source labels; their dated facts may be uncovered.")
            }
            if outcome.outOfBatchCitationCount > 0 {
                supplementalWarnings.append("\(outcome.outOfBatchCitationCount) intermediate citation(s) referred to a source outside its assigned source packet; review the affected rows.")
            }
            if outcome.unsupportedMapCitationCount > 0 {
                supplementalWarnings.append("\(outcome.unsupportedMapCitationCount) chronology citation(s) could not be verified against their sources; review the affected rows.")
            }
            if outcome.narrativeOmittedEntryCount > 0 {
                supplementalWarnings.append("The narrative omits \(outcome.narrativeOmittedEntryCount) of \(outcome.narrativeEntryCount) chronology entries; regenerate or use the table format.")
            }
            if !finalNarrativeCitationFailures.isEmpty {
                supplementalWarnings.append("\(finalNarrativeCitationFailures.count) final narrative citation(s) could not be verified independently against their sources; review the affected sentences.")
            }

            let supplementalWarningMarkdown = supplementalWarnings.isEmpty
                ? ""
                : "> ⚠️ **CHRONOLOGY NEEDS REVIEW — DO NOT RELY.** \(supplementalWarnings.joined(separator: " "))\n\n"
            var markdown = verification.warningMarkdown + supplementalWarningMarkdown + answer + "\n"
            markdown += appendix.markdown()
            let requiresReview = verification.requiresReview || !supplementalWarnings.isEmpty
            let status: StructuredOutputStatus = requiresReview ? .needsReview : .complete
            let persistedVerificationStatus: OutputVerificationStatus = requiresReview
                ? .needsReview
                : verification.verificationStatus
            var resultWarnings = verification.warnings
            for warning in supplementalWarnings where !resultWarnings.contains(warning) {
                resultWarnings.append(warning)
            }

            try Task.checkCancellation()
            progress = .saving
            // Saving is the point of no return. Yield once so the UI can remove
            // the Cancel affordance, then honor any click that raced that UI
            // update before beginning the atomic persistence commit.
            await Task.yield()
            try Task.checkCancellation()
            try ledger.finalize(harvest: harvest, outcome: outcome)
            let persisted = try persistChronology(
                existingOutputID: existingOutputID,
                format: format,
                prepared: prepared,
                scope: scope,
                markdown: markdown,
                status: status,
                verificationStatus: persistedVerificationStatus,
                verificationResults: verification.results + finalNarrativeCitationFailures,
                corpusAnalysisRunID: ledger.runID
            )
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID, eventType: "chronology_generated", actor: "runtime",
                summary: "\(existingOutputID == nil ? "Generated" : "Regenerated") \(format.rawValue) chronology",
                relatedTable: "structured_outputs", relatedID: persisted.outputID
            )
            // The harvest-coverage message (set above when sources were dropped)
            // outranks the pass-count note — coverage gaps matter more.
            if outcome.mapPassCount > 1, message == nil {
                summaryMessage = "Built from \(prepared.count) sources in \(outcome.mapPassCount) passes."
            }
            let result = DocumentQAController.QAResult(
                outputID: persisted.outputID, versionID: persisted.version.id, markdown: markdown, status: status.rawValue,
                warnings: resultWarnings,
                citationLabels: verification.usedLabels,
                unsupported: verification.appearsUnsupported
            )
            lastResult = result
            return result
        } catch {
            // A user cancel can surface as CancellationError (the between-batch
            // check), GenerationStreamError.cancelled (the runtime's cancelled
            // event), or another stream error thrown after the task was
            // cancelled (a cancelled runtime may finish the stream without a
            // completion event, which collects as .interrupted) — treat all of
            // them as the user action, not a failure. Pre-save cancellation
            // persists nothing; saving itself is the point of no return.
            if error is CancellationError || (error as? GenerationStreamError) == .cancelled || Task.isCancelled {
                try? chronologyLedger?.cancel()
                message = "Chronology generation was cancelled."
            } else {
                try? chronologyLedger?.fail(error)
                message = "Chronology generation failed: \(error.localizedDescription)"
            }
            return nil
        }
    }

    private struct GenerationOutcome {
        var answer: String
        var unparsedRowCount = 0
        var emptyMapPassCount = 0
        var mapCoverageGap = false
        var outOfBatchCitationCount = 0
        var unsupportedMapCitationCount = 0
        var narrativeOmittedEntryCount = 0
        var narrativeEntryCount = 0
        var mapPassCount = 0
    }

    private struct MapAudit {
        var entries: [ChronologyEntry]
        var unparsedRowCount: Int
        var isEmpty: Bool
        var coverageGap: Bool
        var outOfBatchCitationCount: Int
        var unsupportedCitationCount: Int
    }

    /// Tables may keep a one-request generation when the serialized preflight
    /// fits, but their output still crosses the same strict parse and per-label
    /// support gates as a map pass. Narratives always map to deterministic entries
    /// first so the synthesis stage has an auditable completeness contract.
    private func generateAnswer(
        prepared: [PreparedSource],
        supportSources: [DocumentSupportSource],
        format: DocumentChronologyFormat,
        modelID: ModelID,
        route: ModelRoute?,
        ledger: ChronologyLedgerSession
    ) async throws -> GenerationOutcome {
        if format == .table {
            let oneShotPrompt = DocumentChronologyPromptBuilder.build(
                sources: prepared.map(\.source),
                format: format
            )
            if requestFitsPromptBudget(oneShotPrompt, route: route) {
                try Task.checkCancellation()
                progress = .generating
                await Task.yield()
                do {
                    let sourceIndices = Array(prepared.indices)
                    try ledger.beginPass(sourceIndices: sourceIndices)
                    let rawAnswer = try await collect(prompt: oneShotPrompt, modelID: modelID, route: route)
                    let allowedLabels = Set(prepared.map { $0.source.label })
                    let audit = try await auditMapAnswer(
                        rawAnswer,
                        allowedLabels: allowedLabels,
                        allowedSources: supportSources
                    )
                    try ledger.completePass(
                        sourceIndices: sourceIndices,
                        sourceLabels: sourceIndices.map { prepared[$0].source.label },
                        audit: audit
                    )
                    var outcome = GenerationOutcome(answer: ChronologyMerge.renderTable(audit.entries))
                    outcome.unparsedRowCount = audit.unparsedRowCount
                    outcome.emptyMapPassCount = audit.isEmpty ? 1 : 0
                    outcome.mapCoverageGap = audit.coverageGap
                    outcome.outOfBatchCitationCount = audit.outOfBatchCitationCount
                    outcome.unsupportedMapCitationCount = audit.unsupportedCitationCount
                    outcome.mapPassCount = 1
                    return outcome
                } catch let error as GenerationStreamError where error == .contextOverflowed {
                    // The byte estimate is only a preflight. The runtime's actual
                    // tokenizer is authoritative; discard overflow output and retry
                    // through source-boundary map passes.
                }
            }
        }
        return try await generateMapReduce(
            prepared: prepared,
            supportSources: supportSources,
            format: format,
            modelID: modelID,
            route: route,
            ledger: ledger
        )
    }

    private func generateMapReduce(
        prepared: [PreparedSource],
        supportSources: [DocumentSupportSource],
        format: DocumentChronologyFormat,
        modelID: ModelID,
        route: ModelRoute?,
        ledger: ChronologyLedgerSession
    ) async throws -> GenerationOutcome {
        let planned = try planMapBatches(prepared: prepared, route: route)
        var pending = planned.map(\.sourceIndices)
        var completedPassCount = 0
        var batchEntries: [[ChronologyEntry]] = []
        var outcome = GenerationOutcome(answer: "")

        while !pending.isEmpty {
            try Task.checkCancellation()
            let sourceIndices = pending.removeFirst()
            let displayedTotal = completedPassCount + 1 + pending.count
            progress = .mapping(batch: completedPassCount + 1, of: displayedTotal)
            await Task.yield()
            let mapPrompt = DocumentChronologyPromptBuilder.buildMapPass(
                sources: sourceIndices.map { prepared[$0].source }
            )
            guard requestFitsPromptBudget(mapPrompt, route: route) else {
                throw ChronologyGenerationError.promptTooLarge(stage: "map pass")
            }

            let mapAnswer: String
            do {
                try ledger.beginPass(sourceIndices: sourceIndices)
                mapAnswer = try await collect(prompt: mapPrompt, modelID: modelID, route: route)
            } catch let error as GenerationStreamError where error == .contextOverflowed {
                guard sourceIndices.count > 1 else {
                    throw ChronologyGenerationError.promptTooLarge(stage: "single-source map pass")
                }
                let midpoint = sourceIndices.count / 2
                let first = Array(sourceIndices[..<midpoint])
                let second = Array(sourceIndices[midpoint...])
                pending.insert(second, at: 0)
                pending.insert(first, at: 0)
                continue
            }

            let allowedLabels = Set(sourceIndices.map { prepared[$0].source.label })
            let allowedSources = supportSources.filter { allowedLabels.contains($0.label) }
            let audit = try await auditMapAnswer(
                mapAnswer,
                allowedLabels: allowedLabels,
                allowedSources: allowedSources
            )
            try ledger.completePass(
                sourceIndices: sourceIndices,
                sourceLabels: sourceIndices.map { prepared[$0].source.label },
                audit: audit
            )
            outcome.unparsedRowCount += audit.unparsedRowCount
            if audit.isEmpty { outcome.emptyMapPassCount += 1 }
            outcome.mapCoverageGap = outcome.mapCoverageGap || audit.coverageGap
            outcome.outOfBatchCitationCount += audit.outOfBatchCitationCount
            outcome.unsupportedMapCitationCount += audit.unsupportedCitationCount
            batchEntries.append(audit.entries)
            completedPassCount += 1
        }

        try Task.checkCancellation()
        progress = .merging
        await Task.yield()
        let merged = ChronologyMerge.merge(batchEntries)
        outcome.mapPassCount = completedPassCount
        if format == .table {
            outcome.answer = ChronologyMerge.renderTable(merged)
        } else {
            progress = .synthesizing
            await Task.yield()
            outcome.narrativeEntryCount = merged.count
            outcome.answer = try await synthesizeNarrative(
                entries: merged,
                modelID: modelID,
                route: route
            )
            outcome.narrativeOmittedEntryCount = ChronologyNarrativeCoverage
                .omittedEntries(from: merged, in: outcome.answer)
                .count
        }
        return outcome
    }

    private func auditMapAnswer(
        _ answer: String,
        allowedLabels: Set<String>,
        allowedSources: [DocumentSupportSource]
    ) async throws -> MapAudit {
        let parsed = ChronologyTableParser.parse(answer)
        let representedLabels = Set(parsed.entries.flatMap(\.labels))
        let outOfBatchCount = parsed.entries.reduce(0) { count, entry in
            count + entry.labels.filter { !allowedLabels.contains($0) }.count
        }
        let unsupportedCount = try await unsupportedCitationCount(
            entries: parsed.entries,
            allowedSources: allowedSources
        )
        return MapAudit(
            entries: parsed.entries,
            unparsedRowCount: parsed.unparsedRowCount,
            isEmpty: parsed.entries.isEmpty,
            coverageGap: !allowedLabels.isSubset(of: representedLabels),
            outOfBatchCitationCount: outOfBatchCount,
            unsupportedCitationCount: unsupportedCount
        )
    }

    // MARK: - Harvesting

    private struct PreparedSource {
        var source: GroundingSource
        var documentID: String
        var chunkID: String?
        var revisionID: String?
        var locatorJSON: String
        var rank: Int
        var warnings: [String]
        /// The owning document's metadata date, falling back to the document's
        /// creation date, used to order map passes chronologically.
        var documentOrderDate: Date
    }

    private struct ChronologyHarvestDocument {
        var documentID: String
        var displayName: String
        var indexState: String
        var revisionIDs: [String]
        var includedSourceIndices: [Int]
        var droppedSourceCount: Int
    }

    private struct ChronologyHarvest {
        var sources: [PreparedSource]
        var omittedDocuments: [String]
        var droppedCount: Int
        var documents: [ChronologyHarvestDocument]
    }

    /// Harvests every date-bearing source in the scope, bounded only by the
    /// `maxSources` safety cap. Metadata-date sources pass through the same cap
    /// as text chunks so many metadata-dated documents cannot starve the dated
    /// text chunks out of the packet. `omittedDocuments` lists the display name
    /// of each document that lost at least one source to the cap (once per
    /// name, in document order).
    private func harvestSources(scope: RetrievalScope) async throws -> ChronologyHarvest {
        let scopeIDs = try store.documentLibrary.resolveScopeDocumentIDs(
            matterID: matterID, folderIDs: scope.folderIDs, documentIDs: scope.documentIDs,
            tagIDs: scope.tagIDs, dateStart: scope.dateStart, dateEnd: scope.dateEnd
        )
        let documents = try store.documentLibrary.fetchDocuments(matterID: matterID).filter { scopeIDs.contains($0.id) }
        var prepared: [PreparedSource] = []
        var omittedDocuments: [String] = []
        var harvestDocuments: [ChronologyHarvestDocument] = []
        var rank = 0
        var droppedCount = 0

        for (documentIndex, document) in documents.enumerated() {
            if documentIndex.isMultiple(of: 25) {
                try Task.checkCancellation()
                await Task.yield()
            }
            var documentHadDrop = false
            let sourceStart = prepared.count
            var documentDroppedCount = 0
            let chunks = try store.documentIndex.fetchChunks(documentID: document.id)
            let revisionIDs = Array(Set(chunks.compactMap(\.revisionID))).sorted()

            // Metadata date (file/email), distinguished from text dates.
            if let metaDate = document.metadataCreatedAt {
                if prepared.count >= maxSources {
                    droppedCount += 1
                    documentDroppedCount += 1
                    documentHadDrop = true
                } else {
                    let label = "S\(rank + 1)"
                    let iso = ISO8601DateFormatter().string(from: metaDate)
                    prepared.append(PreparedSource(
                        source: GroundingSource(
                            sourceID: "\(matterID)/\(document.id)#metadata-date",
                            label: label, documentName: document.displayName, locatorDisplay: "metadata date",
                            text: "Document metadata date: \(iso) (metadata date)", excerpt: iso, lowConfidence: false
                        ),
                        documentID: document.id, chunkID: nil, revisionID: nil,
                        locatorJSON: DocumentSourceLocator(sourceKind: .convertedDocument).encodedJSON(),
                        rank: rank, warnings: [],
                        documentOrderDate: document.metadataCreatedAt ?? document.createdAt
                    ))
                    rank += 1
                }
            }

            // Date-bearing chunks (text dates).
            for (chunkIndex, chunk) in chunks.enumerated() {
                if chunkIndex.isMultiple(of: 100) {
                    try Task.checkCancellation()
                    await Task.yield()
                }
                guard DateExtraction.containsDate(chunk.normalizedText) else { continue }
                if prepared.count >= maxSources {
                    droppedCount += 1
                    documentDroppedCount += 1
                    documentHadDrop = true
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
                let structureContext = chunk.chunkerVersion == 2
                    ? chunk.nodeID.flatMap { try? store.documentStructure.retrievalContext(nodeID: $0) }
                    : nil
                prepared.append(PreparedSource(
                    source: GroundingSource(
                        sourceID: "\(matterID)/\(chunk.id)",
                        label: label, documentName: document.displayName, locatorDisplay: locator.displayString,
                        text: chunk.normalizedText,
                        excerpt: chunk.displayExcerpt ?? DocumentChunker.excerpt(chunk.normalizedText),
                        lowConfidence: low,
                        unitKind: chunk.chunkerVersion == 2 ? (chunk.unitKind ?? structureContext?.unitKind) : nil,
                        hiddenDerived: structureContext?.hiddenDerived ?? false
                    ),
                    documentID: document.id, chunkID: chunk.id, revisionID: chunk.revisionID,
                    locatorJSON: locator.encodedJSON(),
                    rank: rank, warnings: low ? ["low OCR confidence"] : [],
                    documentOrderDate: document.metadataCreatedAt ?? document.createdAt
                ))
                rank += 1
            }

            if documentHadDrop, !omittedDocuments.contains(document.displayName) {
                omittedDocuments.append(document.displayName)
            }
            harvestDocuments.append(ChronologyHarvestDocument(
                documentID: document.id,
                displayName: document.displayName,
                indexState: document.indexStatus,
                revisionIDs: revisionIDs,
                includedSourceIndices: Array(sourceStart..<prepared.count),
                droppedSourceCount: documentDroppedCount
            ))
        }
        return ChronologyHarvest(
            sources: prepared,
            omittedDocuments: omittedDocuments,
            droppedCount: droppedCount,
            documents: harvestDocuments
        )
    }

    private func makeChronologyLedger(
        harvest: ChronologyHarvest,
        scope: RetrievalScope,
        modelID _: ModelID
    ) throws -> ChronologyLedgerSession {
        let snapshot = CorpusAnalysisSnapshot(members: harvest.documents.map { document in
            let included = !document.includedSourceIndices.isEmpty
            return CorpusAnalysisSnapshotMember(
                memberKey: document.documentID,
                documentID: document.documentID,
                displayName: document.displayName,
                revisionIDs: document.revisionIDs,
                indexState: document.indexState,
                disposition: included ? .eligible : .excluded,
                reason: included
                    ? nil
                    : (document.droppedSourceCount > 0 ? "max_sources_cap" : "no_dated_sources")
            )
        })
        let run = try store.corpusAnalysis.createOrFetchRun(CorpusAnalysisRunRecord(
            runKey: "chronology:\(UUID().uuidString)",
            matterID: matterID,
            taskKind: CorpusAnalysisTaskKind.chronology.rawValue,
            scopeJSON: try Self.canonicalJSON(scope),
            corpusSnapshotJSON: try Self.canonicalJSON(snapshot),
            partitionStrategy: "chronology_document_v1",
            partitionStrategyVersion: 1,
            status: CorpusAnalysisRunStatus.planning.rawValue
        ))
        let eligible = harvest.documents.filter { !$0.includedSourceIndices.isEmpty }
        let partitions = try eligible.enumerated().map { index, document in
            CorpusAnalysisPartitionRecord(
                runID: run.id,
                partitionKey: String(format: "document-%06d", index + 1),
                inputRevisionIDsJSON: try Self.canonicalJSON(document.revisionIDs)
            )
        }
        try store.corpusAnalysis.createPartitions(
            matterID: matterID,
            runID: run.id,
            partitions: partitions
        )
        _ = try store.corpusAnalysis.updateStatus(
            matterID: matterID,
            runID: run.id,
            to: .running
        )
        return ChronologyLedgerSession(
            store: store,
            matterID: matterID,
            runID: run.id,
            documents: eligible,
            partitions: partitions,
            sources: harvest.sources
        )
    }

    @MainActor
    private final class ChronologyLedgerSession {
        let runID: String

        private let store: SupraStore
        private let matterID: String
        private let partitionIDByDocumentID: [String: String]
        private let documentIDBySourceIndex: [Int: String]
        private let expectedSourceIndicesByDocumentID: [String: Set<Int>]
        private var completedSourceIndices: Set<Int> = []
        private var begunDocumentIDs: Set<String> = []
        private var completedDocumentIDs: Set<String> = []
        private var passes: [ChronologyPassAuditRecord] = []
        private var isFinalized = false

        init(
            store: SupraStore,
            matterID: String,
            runID: String,
            documents: [ChronologyHarvestDocument],
            partitions: [CorpusAnalysisPartitionRecord],
            sources: [PreparedSource]
        ) {
            self.store = store
            self.matterID = matterID
            self.runID = runID
            partitionIDByDocumentID = Dictionary(uniqueKeysWithValues: zip(documents, partitions).map {
                ($0.0.documentID, $0.1.id)
            })
            documentIDBySourceIndex = Dictionary(uniqueKeysWithValues: sources.indices.map {
                ($0, sources[$0].documentID)
            })
            expectedSourceIndicesByDocumentID = Dictionary(uniqueKeysWithValues: documents.map {
                ($0.documentID, Set($0.includedSourceIndices))
            })
        }

        func beginPass(sourceIndices: [Int]) throws {
            for documentID in documentIDs(for: sourceIndices)
                where !begunDocumentIDs.contains(documentID)
                    && !completedDocumentIDs.contains(documentID) {
                guard let partitionID = partitionIDByDocumentID[documentID] else { continue }
                _ = try store.corpusAnalysis.beginAttempt(
                    matterID: matterID,
                    runID: runID,
                    partitionID: partitionID
                )
                begunDocumentIDs.insert(documentID)
            }
        }

        func completePass(
            sourceIndices: [Int],
            sourceLabels: [String],
            audit: MapAudit
        ) throws {
            completedSourceIndices.formUnion(sourceIndices)
            passes.append(ChronologyPassAuditRecord(
                passNumber: passes.count + 1,
                sourceLabels: sourceLabels,
                unparsedRowCount: audit.unparsedRowCount,
                empty: audit.isEmpty,
                coverageGap: audit.coverageGap,
                outOfBatchCitationCount: audit.outOfBatchCitationCount,
                unsupportedCitationCount: audit.unsupportedCitationCount
            ))
            for documentID in documentIDs(for: sourceIndices)
                where !completedDocumentIDs.contains(documentID) {
                guard let expected = expectedSourceIndicesByDocumentID[documentID],
                      expected.isSubset(of: completedSourceIndices),
                      let partitionID = partitionIDByDocumentID[documentID] else { continue }
                if !begunDocumentIDs.contains(documentID) {
                    _ = try store.corpusAnalysis.beginAttempt(
                        matterID: matterID,
                        runID: runID,
                        partitionID: partitionID
                    )
                    begunDocumentIDs.insert(documentID)
                }
                try store.corpusAnalysis.completeAttemptSucceeded(
                    matterID: matterID,
                    runID: runID,
                    partitionID: partitionID,
                    findingsJSON: "[]"
                )
                completedDocumentIDs.insert(documentID)
            }
        }

        func finalize(harvest: ChronologyHarvest, outcome: GenerationOutcome) throws {
            _ = try store.corpusAnalysis.updateStatus(
                matterID: matterID,
                runID: runID,
                to: .reconciling
            )
            let reconciliation = ChronologyLedgerReconciliationRecord(
                droppedCount: harvest.droppedCount,
                omittedDocumentNames: harvest.omittedDocuments,
                mapPassCount: outcome.mapPassCount,
                passes: passes
            )
            let validation = ChronologyLedgerValidationRecord(
                unparsedRowCount: outcome.unparsedRowCount,
                emptyMapPassCount: outcome.emptyMapPassCount,
                mapCoverageGap: outcome.mapCoverageGap,
                outOfBatchCitationCount: outcome.outOfBatchCitationCount,
                unsupportedMapCitationCount: outcome.unsupportedMapCitationCount,
                narrativeOmittedEntryCount: outcome.narrativeOmittedEntryCount
            )
            _ = try store.corpusAnalysis.saveReconciliation(
                matterID: matterID,
                runID: runID,
                reconciliationJSON: try DocumentChronologyController.canonicalJSON(reconciliation),
                validationResultsJSON: try DocumentChronologyController.canonicalJSON(validation)
            )
            _ = try store.corpusAnalysis.updateStatus(
                matterID: matterID,
                runID: runID,
                to: .verifying
            )

            var reasons: [String] = []
            if harvest.droppedCount > 0 {
                reasons.append("\(harvest.droppedCount) dated source(s) were omitted by the chronology safety cap.")
            }
            if outcome.mapCoverageGap {
                reasons.append("One or more chronology passes omitted source labels.")
            }
            if outcome.unparsedRowCount > 0 || outcome.emptyMapPassCount > 0 {
                reasons.append("One or more chronology passes produced incomplete parse coverage.")
            }
            if outcome.outOfBatchCitationCount > 0 || outcome.unsupportedMapCitationCount > 0 {
                reasons.append("One or more chronology pass citations failed validation.")
            }
            if outcome.narrativeOmittedEntryCount > 0 {
                reasons.append("Narrative synthesis omitted reconciled chronology entries.")
            }
            _ = try store.corpusAnalysis.finalizeRun(
                matterID: matterID,
                runID: runID,
                assuranceState: reasons.isEmpty ? .corpusComplete : .corpusIncomplete,
                assuranceReasons: reasons,
                exclusionsDisclosed: true
            )
            isFinalized = true
        }

        func cancel() throws {
            guard !isFinalized else { return }
            for documentID in begunDocumentIDs.subtracting(completedDocumentIDs) {
                guard let partitionID = partitionIDByDocumentID[documentID] else { continue }
                try store.corpusAnalysis.completeAttemptCancelled(
                    matterID: matterID,
                    runID: runID,
                    partitionID: partitionID
                )
            }
            _ = try store.corpusAnalysis.cancelRun(matterID: matterID, runID: runID)
            isFinalized = true
        }

        func fail(_ error: Error) throws {
            guard !isFinalized else { return }
            for (documentID, partitionID) in partitionIDByDocumentID
                where !completedDocumentIDs.contains(documentID) {
                if begunDocumentIDs.contains(documentID) {
                    _ = try store.corpusAnalysis.completeAttemptFailed(
                        matterID: matterID,
                        runID: runID,
                        partitionID: partitionID,
                        retryable: false,
                        errorSummary: error.localizedDescription,
                        maximumRetryCount: 0,
                        dispositionReason: "chronology_failed"
                    )
                } else {
                    try store.corpusAnalysis.setDisposition(
                        matterID: matterID,
                        runID: runID,
                        partitionID: partitionID,
                        disposition: .failed,
                        dispositionReason: "chronology_failed",
                        errorSummary: error.localizedDescription
                    )
                }
            }
            _ = try store.corpusAnalysis.coverage(matterID: matterID, runID: runID)
            _ = try store.corpusAnalysis.updateStatus(matterID: matterID, runID: runID, to: .failed)
            isFinalized = true
        }

        private func documentIDs(for sourceIndices: [Int]) -> [String] {
            var seen = Set<String>()
            return sourceIndices.compactMap { documentIDBySourceIndex[$0] }.filter {
                seen.insert($0).inserted
            }
        }
    }

    private struct ChronologyPassAuditRecord: Codable {
        var passNumber: Int
        var sourceLabels: [String]
        var unparsedRowCount: Int
        var empty: Bool
        var coverageGap: Bool
        var outOfBatchCitationCount: Int
        var unsupportedCitationCount: Int

        private enum CodingKeys: String, CodingKey {
            case passNumber = "pass_number"
            case sourceLabels = "source_labels"
            case unparsedRowCount = "unparsed_row_count"
            case empty
            case coverageGap = "coverage_gap"
            case outOfBatchCitationCount = "out_of_batch_citation_count"
            case unsupportedCitationCount = "unsupported_citation_count"
        }
    }

    private struct ChronologyLedgerReconciliationRecord: Codable {
        var schemaVersion = 1
        var droppedCount: Int
        var omittedDocumentNames: [String]
        var mapPassCount: Int
        var passes: [ChronologyPassAuditRecord]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case droppedCount = "dropped_count"
            case omittedDocumentNames = "omitted_document_names"
            case mapPassCount = "map_pass_count"
            case passes
        }
    }

    private struct ChronologyLedgerValidationRecord: Codable {
        var schemaVersion = 1
        var unparsedRowCount: Int
        var emptyMapPassCount: Int
        var mapCoverageGap: Bool
        var outOfBatchCitationCount: Int
        var unsupportedMapCitationCount: Int
        var narrativeOmittedEntryCount: Int

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case unparsedRowCount = "unparsed_row_count"
            case emptyMapPassCount = "empty_map_pass_count"
            case mapCoverageGap = "map_coverage_gap"
            case outOfBatchCitationCount = "out_of_batch_citation_count"
            case unsupportedMapCitationCount = "unsupported_map_citation_count"
            case narrativeOmittedEntryCount = "narrative_omitted_entry_count"
        }
    }

    /// Builds the source-set records in memory so the repository can insert the
    /// output, source packet, and version in one transaction.
    private func makeSourceSet(
        prepared: [PreparedSource],
        scope: RetrievalScope
    ) -> (set: DocumentSourceSetRecord, sources: [DocumentOutputSourceRecord]) {
        let scopeJSON = (try? JSONEncoder().encode(scope)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let sourceSet = DocumentSourceSetRecord(
            matterID: matterID,
            mode: DocumentSourceSetMode.chronology.rawValue,
            scopeJSON: scopeJSON
        )
        let rows = prepared.map { source in
            DocumentOutputSourceRecord(
                sourceSetID: sourceSet.id, documentID: source.documentID, chunkID: source.chunkID,
                revisionID: source.revisionID,
                citationLabel: source.source.label, locatorJSON: source.locatorJSON,
                excerpt: source.source.excerpt, rank: source.rank,
                warningsJSON: source.warnings.isEmpty ? nil : (try? JSONEncoder.encodeToString(source.warnings))
            )
        }
        return (sourceSet, rows)
    }

    /// Atomically persists the optional new output, source set/rows, version,
    /// source attachment, and active-output update.
    private func persistChronology(
        existingOutputID: String?,
        format: DocumentChronologyFormat,
        prepared: [PreparedSource],
        scope: RetrievalScope,
        markdown: String,
        status: StructuredOutputStatus,
        verificationStatus: OutputVerificationStatus,
        verificationResults: [PropositionSupportResult],
        corpusAnalysisRunID: String
    ) throws -> (outputID: String, version: StructuredOutputVersionRecord) {
        let outputID = existingOutputID ?? UUID().uuidString
        let newOutput = existingOutputID == nil
            ? StructuredOutputRecord(
                id: outputID,
                matterID: matterID,
                title: "Chronology (\(format.rawValue))",
                outputType: format.outputType.rawValue,
                status: StructuredOutputStatus.draft.rawValue
            )
            : nil
        let sourceSet = makeSourceSet(prepared: prepared, scope: scope)
        let version = try store.structuredOutputs.createVersionWithSourceSetAtomically(
            structuredOutputID: outputID,
            newOutput: newOutput,
            sourceSet: sourceSet.set,
            outputSources: sourceSet.sources,
            contentMarkdown: markdown,
            verificationStatus: verificationStatus,
            verificationVersion: DocumentSupportVerifier.version,
            verificationResults: verificationResults,
            outputStatus: status,
            corpusAnalysisRunID: corpusAnalysisRunID
        )
        return (outputID, version)
    }

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: - Budgeting and map/reduce verification

    private enum ChronologyGenerationError: LocalizedError {
        case promptTooLarge(stage: String)

        var errorDescription: String? {
            switch self {
            case let .promptTooLarge(stage):
                "The \(stage) prompt cannot fit the selected model's context window. Narrow the chronology scope or select a model with a larger context window."
            }
        }
    }

    /// Uses the same clamped context/output limits as the runtime and estimates
    /// four UTF-8 bytes per prompt token. The routed system prompt is part of the
    /// serialized request even though it is sent separately from `prompt`. This
    /// is a preflight only; runtime tokenizer overflow triggers split-and-retry.
    private func serializedPromptByteBudget(route: ModelRoute?) -> Int {
        let options = (route?.options ?? GenerationOptions()).clampedForRuntime()
        return PromptBudget.promptTokenBudget(
            maxContextTokens: options.maxContextTokens,
            maxOutputTokens: options.maxOutputTokens
        ) * 4
    }

    private func requestFitsPromptBudget(_ prompt: String, route: ModelRoute?) -> Bool {
        let systemBytes = routedSystemPrompt(route)?.utf8.count ?? 0
        return prompt.utf8.count + systemBytes <= serializedPromptByteBudget(route: route)
    }

    /// Plans with the actual JSON-serialized envelope cost rather than only the
    /// source text. Each incremental cost includes a comma reserve for joining
    /// JSON objects, making the estimate conservative; every completed prompt is
    /// checked again against the true request size before generation.
    private func planMapBatches(
        prepared: [PreparedSource],
        route: ModelRoute?
    ) throws -> [ChronologyBatch] {
        let emptyPromptBytes = DocumentChronologyPromptBuilder.buildMapPass(sources: []).utf8.count
        let systemBytes = routedSystemPrompt(route)?.utf8.count ?? 0
        let sourceByteBudget = serializedPromptByteBudget(route: route) - systemBytes - emptyPromptBytes
        guard sourceByteBudget > 0 else {
            throw ChronologyGenerationError.promptTooLarge(stage: "map-pass instruction")
        }

        let items = prepared.map { item in
            let singletonBytes = DocumentChronologyPromptBuilder
                .buildMapPass(sources: [item.source])
                .utf8.count
            return ChronologyBatchPlanner.Item(
                documentKey: item.documentID,
                // The combined JSON array adds one comma between objects. Adding
                // one to every item is a safe overestimate for the first object.
                charCount: max(1, singletonBytes - emptyPromptBytes + 1),
                orderDate: item.documentOrderDate
            )
        }
        let batches = ChronologyBatchPlanner.plan(items: items, characterBudget: sourceByteBudget)
        guard !batches.isEmpty else {
            throw ChronologyGenerationError.promptTooLarge(stage: "map pass")
        }
        for (index, batch) in batches.enumerated() {
            let prompt = DocumentChronologyPromptBuilder.buildMapPass(
                sources: batch.sourceIndices.map { prepared[$0].source }
            )
            guard requestFitsPromptBudget(prompt, route: route) else {
                throw ChronologyGenerationError.promptTooLarge(stage: "map pass \(index + 1)")
            }
        }
        return batches
    }

    /// Verifies every intermediate citation against its own cited source. The
    /// aggregate verifier intentionally accepts support from any citation on a
    /// proposition, which is useful for final answers but would otherwise let a
    /// valid label launder an invented extra label during map/merge.
    private func unsupportedCitationCount(
        entries: [ChronologyEntry],
        allowedSources: [DocumentSupportSource]
    ) async throws -> Int {
        let sourcesByLabel = Dictionary(
            allowedSources.map { ($0.label, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var unsupportedCount = 0
        var checkedCitationCount = 0
        for entry in entries {
            for label in entry.labels {
                if checkedCitationCount.isMultiple(of: 25) {
                    try Task.checkCancellation()
                    await Task.yield()
                }
                checkedCitationCount += 1
                guard let source = sourcesByLabel[label] else { continue }
                var isolatedEntry = entry
                isolatedEntry.labels = [label]
                let report = try DocumentSupportVerifier.verify(
                    answer: ChronologyMerge.renderTable([isolatedEntry]),
                    sources: [source],
                    scopeFullyIndexed: true
                )
                if report.requiresReview { unsupportedCount += 1 }
            }
        }
        return unsupportedCount
    }

    /// Audits every final narrative citation independently. The aggregate
    /// verifier intentionally accepts a proposition once any cited source
    /// supports it; synthesis needs the stronger contract that no extra label
    /// can borrow support from a neighboring valid citation.
    private func unsupportedFinalNarrativeCitations(
        propositions: [CitedProposition],
        allowedSources: [DocumentSupportSource]
    ) async throws -> [PropositionSupportResult] {
        let sourcesByLabel = Dictionary(
            allowedSources.map { ($0.label, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var failures: [PropositionSupportResult] = []
        var checkedCitationCount = 0
        for proposition in propositions {
            for label in proposition.citationLabels {
                if checkedCitationCount.isMultiple(of: 25) {
                    try Task.checkCancellation()
                    await Task.yield()
                }
                checkedCitationCount += 1
                guard let source = sourcesByLabel[label] else {
                    // The aggregate verifier already records unresolved labels.
                    continue
                }
                let isolatedAnswer = "\(proposition.text) [\(label)]"
                let report = try DocumentSupportVerifier.verify(
                    answer: isolatedAnswer,
                    sources: [source],
                    scopeFullyIndexed: true
                )
                guard let result = report.results.first, result.status != .supported else { continue }
                failures.append(try PropositionSupportResult(
                    propositionID: "\(proposition.id)-\(label)",
                    status: result.status,
                    reasons: result.reasons,
                    evidence: result.evidence,
                    timestamp: result.timestamp
                ))
            }
        }
        return failures
    }

    /// Synthesizes sequential entry ranges whose actual prompt and conservative
    /// output proxy both fit the selected route. Splitting only at entry
    /// boundaries keeps every dated fact and its labels together.
    private func synthesizeNarrative(
        entries: [ChronologyEntry],
        modelID: ModelID,
        route: ModelRoute?
    ) async throws -> String {
        guard !entries.isEmpty else { return "" }
        let options = (route?.options ?? GenerationOptions()).clampedForRuntime()
        let outputByteBudget = options.maxOutputTokens * 4
        var chunks: [[ChronologyEntry]] = []
        var current: [ChronologyEntry] = []

        func fits(_ candidate: [ChronologyEntry]) -> Bool {
            let prompt = DocumentChronologyPromptBuilder.buildSynthesis(entries: candidate)
            let outputProxy = ChronologyMerge.renderTable(candidate)
            return requestFitsPromptBudget(prompt, route: route)
                && outputProxy.utf8.count <= outputByteBudget
        }

        for entry in entries {
            let candidate = current + [entry]
            if fits(candidate) {
                current = candidate
                continue
            }
            guard !current.isEmpty else {
                throw ChronologyGenerationError.promptTooLarge(stage: "narrative synthesis")
            }
            chunks.append(current)
            current = [entry]
            guard fits(current) else {
                throw ChronologyGenerationError.promptTooLarge(stage: "narrative synthesis")
            }
        }
        if !current.isEmpty { chunks.append(current) }

        var narratives: [String] = []
        var pending = chunks
        while !pending.isEmpty {
            try Task.checkCancellation()
            let chunk = pending.removeFirst()
            let prompt = DocumentChronologyPromptBuilder.buildSynthesis(entries: chunk)
            do {
                narratives.append(try await collect(prompt: prompt, modelID: modelID, route: route))
            } catch let error as GenerationStreamError where error == .contextOverflowed {
                guard chunk.count > 1 else {
                    throw ChronologyGenerationError.promptTooLarge(stage: "single-entry narrative synthesis")
                }
                let midpoint = chunk.count / 2
                let first = Array(chunk[..<midpoint])
                let second = Array(chunk[midpoint...])
                pending.insert(second, at: 0)
                pending.insert(first, at: 0)
            }
        }
        return narratives.joined(separator: "\n\n")
    }

    private func collect(prompt: String, modelID: ModelID, route: ModelRoute?) async throws -> String {
        let request = GenerateRequest(
            generationID: GenerationID(), modelID: modelID, prompt: prompt,
            // Keep chronology structure isolated from the user's free-form profile
            // while still applying task-specific routing instructions.
            systemPrompt: routedSystemPrompt(route),
            options: route?.options ?? GenerationOptions()
        )
        // Track the in-flight generation so cancel() can stop the runtime, not
        // just this task.
        activeGenerationID = request.generationID
        defer { activeGenerationID = nil }
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
