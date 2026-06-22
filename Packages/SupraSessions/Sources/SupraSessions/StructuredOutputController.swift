import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraResearch
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

/// Generates structured legal outputs for a matter (spec §12.4): builds the
/// type's prompt, runs it through the local model, detects present/missing
/// sections deterministically, and stores the output + version 1 + audit.
/// Structure repair (WO 29) and the Outputs tab UI (WO 30) build on this.
@MainActor
public final class StructuredOutputController: ObservableObject {
    public struct OutputItem: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let outputType: String
        public let status: String
        public let missingCount: Int
        public let createdAt: Date
        public let updatedAt: Date
        public let researchSessionID: String?
    }

    /// A version of a structured output for the detail view's version picker.
    public struct VersionItem: Identifiable, Sendable, Equatable {
        public let id: String
        public let index: Int
        public let isActive: Bool
        public let markdown: String
        public let missingSections: [String]
        public let repairReason: String?
    }

    @Published public private(set) var outputs: [OutputItem] = []
    @Published public private(set) var isGenerating = false
    @Published public private(set) var message: String?

    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private let retrieval: DocumentRetrievalService
    private let defaultSystemPrompt: String?
    public let matterID: String

    public init(
        store: SupraStore,
        runtimeClient: any RuntimeClientProtocol,
        matterID: String,
        embedder: (any TextEmbedder)? = nil,
        defaultSystemPrompt: String? = nil
    ) {
        self.store = store
        self.runtimeClient = runtimeClient
        self.retrieval = DocumentRetrievalService(store: store, embedder: embedder)
        self.matterID = matterID
        self.defaultSystemPrompt = defaultSystemPrompt
    }

    // MARK: - Document grounding (spec §12.4)

    /// A document the user can scope an output to (top-level documents only;
    /// attachments are retrieved with their parent).
    public struct DocumentChoice: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
    }

    /// One grounding source attached to an output version, for the detail view.
    public struct SourceItem: Identifiable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let documentName: String
        public let locatorDisplay: String
        public let excerpt: String
    }

    /// The matter's documents available to scope an output to.
    public func documentChoices() -> [DocumentChoice] {
        ((try? store.documentLibrary.fetchDocuments(matterID: matterID)) ?? [])
            .filter { $0.parentDocumentID == nil }
            .map { DocumentChoice(id: $0.id, name: $0.displayName) }
    }

    /// Readiness of a chosen scope (so the sheet can show "X/Y indexed" and block
    /// generation until indexing finishes, like Document Q&A).
    public func scopeReadiness(scope: RetrievalScope) -> ScopeReadiness? {
        try? retrieval.scopeReadiness(matterID: matterID, scope: scope)
    }

    /// The grounding sources attached to a given output version.
    public func sources(forVersion versionID: String) -> [SourceItem] {
        let rows = (try? store.documentSources.fetchSources(structuredOutputVersionID: versionID)) ?? []
        guard !rows.isEmpty else { return [] }
        let nameByID = Dictionary(
            ((try? store.documentLibrary.fetchDocuments(matterID: matterID)) ?? []).map { ($0.id, $0.displayName) },
            uniquingKeysWith: { a, _ in a }
        )
        return rows.sorted { $0.rank < $1.rank }.map { row in
            let locator = try? JSONDecoder().decode(DocumentSourceLocator.self, from: Data(row.locatorJSON.utf8))
            return SourceItem(
                id: row.id,
                label: row.citationLabel,
                documentName: row.documentID.flatMap { nameByID[$0] } ?? "Document",
                locatorDisplay: locator?.displayString ?? "",
                excerpt: row.excerpt
            )
        }
    }

    /// Exports an output's active version to the given format, returning the
    /// written file URL (plan §10.2). Applies to document Q&A/chronology outputs
    /// and any structured output.
    public func exportOutput(outputID: String, format: DocumentExportFormat) -> URL? {
        do {
            return try DocumentExportService(store: store).export(matterID: matterID, structuredOutputID: outputID, format: format)
        } catch {
            message = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    public func loadOutputs() {
        outputs = ((try? store.structuredOutputs.fetchOutputs(matterID: matterID)) ?? []).map { record in
            OutputItem(
                id: record.id,
                title: record.title,
                outputType: record.outputType,
                status: record.status,
                missingCount: missingCount(for: record),
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                researchSessionID: record.researchSessionID
            )
        }
    }

    /// The output's versions (oldest first) for the detail view's picker.
    public func versions(forOutput outputID: String) -> [VersionItem] {
        guard let record = outputRecord(outputID) else { return [] }
        return ((try? store.structuredOutputs.fetchVersions(structuredOutputID: outputID)) ?? [])
            .sorted { $0.versionIndex < $1.versionIndex }
            .map { version in
                VersionItem(
                    id: version.id,
                    index: version.versionIndex,
                    isActive: version.id == record.activeVersionID,
                    markdown: version.contentMarkdown,
                    missingSections: (try? JSONDecoder().decode([String].self, from: Data(version.missingSectionsJSON.utf8))) ?? [],
                    repairReason: version.repairReason
                )
            }
    }

    /// Generates an output: prompt → local model → section detection → persist.
    /// Status is `complete` only when no required section is missing (§12.4).
    @discardableResult
    public func createOutput(
        type: StructuredOutputType,
        context: String,
        scope: RetrievalScope? = nil,
        chatID: String? = nil,
        researchSessionID: String? = nil,
        modelID: ModelID?,
        route: ModelRoute? = nil
    ) async -> Bool {
        guard let contract = StructuredOutputContracts.contract(for: type) else {
            message = "Document Q&A and chronologies are generated from the Documents tab."
            return false
        }
        var effectiveRoute = route ?? ModelRouter().route(forStructuredOutput: type)
        // Multi-section contracts (8–11 headings) need output room; raise the budget so
        // a long memo isn't truncated mid-structure (which previously read as "missing
        // sections" — a length problem misclassified as a structure problem).
        if let current = effectiveRoute?.options.maxOutputTokens {
            effectiveRoute?.options.maxOutputTokens = max(current, Self.structuredOutputMinOutputTokens)
        }
        guard let modelID else {
            message = if let effectiveRoute {
                "Assign a \(effectiveRoute.role.displayName) model in the Models tab to generate \(contract.title)."
            } else {
                "Assign a task model in the Models tab to generate structured outputs."
            }
            return false
        }
        // Re-entrancy guard: claim the flag synchronously (no await before this)
        // so a second concurrent call cannot start a parallel generation.
        guard !isGenerating else {
            message = "An output is already generating. Wait for it to finish."
            return false
        }
        isGenerating = true
        message = nil
        defer { isGenerating = false }

        do {
            // When the output is scoped to documents, retrieve the most relevant
            // passages and prepend them as cited grounding (mirrors Document Q&A).
            var groundedContext = context
            var prepared: [PreparedDocSource] = []
            let retrievalQuery = context.trimmingCharacters(in: .whitespacesAndNewlines)
            if let scope {
                let readiness = scopeReadiness(scope: scope)
                    ?? ScopeReadiness(totalDocuments: 0, readyDocuments: 0, pendingDocuments: 0, requiresSemanticIndex: false, isFullyReady: false)
                guard readiness.isFullyReady else {
                    message = "The selected documents are still indexing (\(readiness.readyDocuments)/\(readiness.totalDocuments) ready). Try again once indexing finishes."
                    return false
                }
                let result = try await retrieval.retrieve(matterID: matterID, query: retrievalQuery, scope: scope, limit: 10)
                prepared = result.sources.map { PreparedDocSource(label: "S\($0.rank + 1)", source: $0) }
                guard !prepared.isEmpty else {
                    message = "No matching content was found in the selected documents."
                    return false
                }
                groundedContext = Self.groundingBlock(prepared) + "\n\n---\n\nADDITIONAL CONTEXT:\n" + context
            }

            let prompt = try StructuredOutputPromptBuilder.buildPrompt(for: contract, context: groundedContext)
            let rawMarkdown = ReasoningContent.answer(from: try await collect(prompt: prompt, modelID: modelID, route: effectiveRoute))
            let analysis = StructuredOutputSections.analyze(
                markdown: rawMarkdown, requiredHeadings: contract.requiredHeadings
            )
            // Cardinal-sin guard: this controller never retrieves or verifies legal
            // authority, so any reporter/case/statute citation the model emits is
            // ungrounded. Force review and flag it so it can never read as verified
            // good law. ([S1]-style document labels are not legal citations and are
            // not affected.)
            let (markdown, status) = Self.guardUnverifiedCitations(
                in: rawMarkdown,
                type: type,
                status: analysis.missing.isEmpty ? .complete : .needsReview
            )

            let output = try store.structuredOutputs.createOutput(
                matterID: matterID, title: contract.title, outputType: type,
                chatID: chatID, researchSessionID: researchSessionID, status: status
            )
            let version = try store.structuredOutputs.createVersion(
                structuredOutputID: output.id, contentMarkdown: markdown,
                requiredSections: contract.requiredHeadings,
                presentSections: analysis.present, missingSections: analysis.missing
            )
            if let scope, !prepared.isEmpty {
                try? attachDocumentSources(prepared, scope: scope, query: retrievalQuery, versionID: version.id)
            }
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID, eventType: "structured_output_created", actor: "runtime",
                summary: "Created \(contract.title)\(scope == nil ? "" : " grounded in \(prepared.count) document source(s)")",
                relatedTable: "structured_outputs", relatedID: output.id
            )
            loadOutputs()
            // Auto-repair missing required sections (up to N passes) so a complete,
            // fully-structured output is the common case rather than a manual step. A
            // pass that doesn't reduce the missing set is discarded and stops the loop.
            await autoRepairIfNeeded(outputID: output.id, missing: analysis.missing, modelID: modelID)
            return true
        } catch {
            message = "Output generation failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Output-token budget floor for multi-section structured outputs, so a long memo
    /// isn't truncated mid-structure.
    static let structuredOutputMinOutputTokens = 8000
    /// Automatic structure-repair passes after generation before leaving an output as
    /// needs-review.
    static let maxAutoRepairPasses = 2

    private func autoRepairIfNeeded(outputID: String, missing: [String], modelID: ModelID) async {
        var remaining = missing
        var pass = 0
        while !remaining.isEmpty, pass < Self.maxAutoRepairPasses {
            pass += 1
            // route: nil → performRepair uses the dedicated repair (critique) route.
            guard let result = await performRepair(
                outputID: outputID, modelID: modelID, route: nil, commitOnlyIfImproved: true, previousMissingCount: remaining.count
            ), result.committed else { break }
            if result.missing.count >= remaining.count { break } // no progress → stop
            remaining = result.missing
        }
    }

    /// Detects ungrounded legal citations in a generated structured output and, for
    /// authority-asserting types, always flags it. These outputs are scaffolds built
    /// from notes/documents, not from retrieved+verified legal authority, so their
    /// citations must never present as verified good law. The banner fires when a
    /// citation in a recognized format is present, OR unconditionally for a type
    /// whose contract asserts authority (so an unrecognized citation format can't
    /// slip a fabricated authority through as a "complete" output).
    static func guardUnverifiedCitations(
        in markdown: String,
        type: StructuredOutputType,
        status: StructuredOutputStatus,
        forceFlag: Bool = false
    ) -> (markdown: String, status: StructuredOutputStatus) {
        let citations = LegalCitationVerifier.extractCitationLikeStrings(from: markdown)
        // `forceFlag` keeps the guard monotonic across repair passes: once an output
        // was flagged for ungrounded citations, a later pass that merely restates the
        // citation in a regex-missed form must not silently clear the banner.
        guard forceFlag || !citations.isEmpty || type.assertsLegalAuthority else { return (markdown, status) }
        let detail = citations.isEmpty
            ? "Independently verify every legal authority cited in this output before use."
            : "Independently verify every citation before use: \(citations.prefix(8).joined(separator: "; "))."
        let banner = """
        > ⚠️ **UNVERIFIED CITATIONS — DO NOT RELY.** This output was drafted from your notes/documents without retrieving or verifying legal authority. \(detail)

        """
        return (banner + markdown, .needsReview)
    }

    private struct PreparedDocSource {
        let label: String
        let source: RetrievedSource
    }

    /// Formats retrieved passages as a cited grounding block for the prompt.
    private static func groundingBlock(_ prepared: [PreparedDocSource]) -> String {
        var lines = ["SOURCE DOCUMENTS — ground your analysis in these and cite them inline as [S1], [S2], … wherever you rely on them:", ""]
        for item in prepared {
            lines.append("[\(item.label)] \(item.source.documentName) — \(item.source.locator.displayString)")
            lines.append(item.source.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Persists the grounding sources as a version-scoped source set (mirrors
    /// DocumentQAController.attachSources), so the output records what it cited.
    private func attachDocumentSources(_ prepared: [PreparedDocSource], scope: RetrievalScope, query: String, versionID: String) throws {
        let scopeJSON = (try? JSONEncoder().encode(scope)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let sourceSet = try store.documentSources.createSourceSet(
            matterID: matterID, mode: .autoSource, scopeJSON: scopeJSON, retrievalQuery: query
        )
        let rows = prepared.map { item in
            DocumentOutputSourceRecord(
                sourceSetID: sourceSet.id, documentID: item.source.documentID, chunkID: item.source.chunkID,
                citationLabel: item.label, locatorJSON: item.source.locator.encodedJSON(),
                excerpt: item.source.excerpt, rank: item.source.rank, warningsJSON: nil
            )
        }
        try store.documentSources.addOutputSources(rows)
        try store.documentSources.attachSourceSet(id: sourceSet.id, structuredOutputVersionID: versionID)
    }

    /// Re-runs the structure-repair prompt for an output: preserves the prior
    /// version, links the repaired one to it as parent, makes it active, re-runs
    /// detection, and audits it (spec §12.5).
    @discardableResult
    public func repairOutput(_ outputID: String, modelID: ModelID?, route: ModelRoute? = nil) async -> Bool {
        guard let record = outputRecord(outputID),
              let type = StructuredOutputType(rawValue: record.outputType),
              activeVersion(for: record) != nil,
              StructuredOutputContracts.contract(for: type) != nil else { return false }
        var effectiveRoute = route ?? ModelRouter().repairRoute(forStructuredOutput: type)
        if let current = effectiveRoute?.options.maxOutputTokens {
            effectiveRoute?.options.maxOutputTokens = max(current, Self.structuredOutputMinOutputTokens)
        }
        guard let modelID else {
            message = if let effectiveRoute {
                "Assign a \(effectiveRoute.role.displayName) model in the Models tab to repair \(record.title)."
            } else {
                "Assign a task model in the Models tab to repair outputs."
            }
            return false
        }

        guard !isGenerating else {
            message = "An output is already generating. Wait for it to finish."
            return false
        }
        isGenerating = true
        message = nil
        defer { isGenerating = false }

        // Manual repair is preserve-or-improve too: a worse/no-op sample must not
        // replace the active version (and overwrite its status) just because the user
        // clicked Repair. It still ran, so return true, but message on a no-op.
        guard let result = await performRepair(
            outputID: outputID, modelID: modelID, route: effectiveRoute,
            commitOnlyIfImproved: true, previousMissingCount: nil
        ) else { return false }
        if !result.committed {
            message = "Repair did not improve the structure — kept the previous version."
        }
        return true
    }

    /// Generates one structure-repair pass for an output's active version. Returns the
    /// repaired version's missing sections, or nil on failure. When
    /// `commitOnlyIfImproved` is set and the pass does not reduce the missing set, no
    /// version is saved (the no-op is discarded) and the prior missing set is returned.
    private func performRepair(
        outputID: String,
        modelID: ModelID,
        route: ModelRoute?,
        commitOnlyIfImproved: Bool,
        previousMissingCount: Int?
    ) async -> (missing: [String], committed: Bool)? {
        guard let record = outputRecord(outputID),
              let type = StructuredOutputType(rawValue: record.outputType),
              let active = activeVersion(for: record),
              let contract = StructuredOutputContracts.contract(for: type) else { return nil }
        do {
            let prompt = try StructuredOutputPromptBuilder.buildRepairPrompt(
                originalOutput: active.contentMarkdown, requiredHeadings: contract.requiredHeadings
            )
            var resolvedRoute = route ?? ModelRouter().repairRoute(forStructuredOutput: type)
            if let current = resolvedRoute?.options.maxOutputTokens {
                resolvedRoute?.options.maxOutputTokens = max(current, Self.structuredOutputMinOutputTokens)
            }
            let rawRepaired = ReasoningContent.answer(from: try await collect(prompt: prompt, modelID: modelID, route: resolvedRoute))
            let analysis = StructuredOutputSections.analyze(
                markdown: rawRepaired, requiredHeadings: contract.requiredHeadings
            )
            // Preserve-or-improve: never replace the active version with one that has
            // the same or more missing sections (a regression on a local model's bad
            // sample, or an auto-repair no-op).
            let priorMissingCount = previousMissingCount
                ?? (try? JSONDecoder().decode([String].self, from: Data(active.missingSectionsJSON.utf8)))?.count
                ?? .max
            if commitOnlyIfImproved, analysis.missing.count >= priorMissingCount {
                return (analysis.missing, committed: false)
            }
            // Monotonic citation guard: if the prior version was flagged for ungrounded
            // citations, keep it flagged even if this pass's citation evades the regex.
            let priorWasCitationFlagged = active.contentMarkdown.contains("UNVERIFIED CITATIONS")
            let (repaired, status) = Self.guardUnverifiedCitations(
                in: rawRepaired, type: type,
                status: analysis.missing.isEmpty ? .complete : .needsReview,
                forceFlag: priorWasCitationFlagged
            )
            _ = try store.structuredOutputs.createVersion(
                structuredOutputID: outputID, contentMarkdown: repaired,
                requiredSections: contract.requiredHeadings, presentSections: analysis.present,
                missingSections: analysis.missing, parentVersionID: active.id,
                repairReason: "missing_required_sections", makeActive: true
            )
            try? store.structuredOutputs.updateStatus(outputID: outputID, status: status)
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID, eventType: "structured_output_repaired", actor: "runtime",
                summary: "Repaired \(record.title)", relatedTable: "structured_outputs", relatedID: outputID
            )
            loadOutputs()
            return (analysis.missing, committed: true)
        } catch {
            message = "Structure repair failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// The active version's missing required sections.
    public func missingSections(forOutput outputID: String) -> [String] {
        guard let record = outputRecord(outputID), let active = activeVersion(for: record) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(active.missingSectionsJSON.utf8))) ?? []
    }

    private func outputRecord(_ outputID: String) -> StructuredOutputRecord? {
        (try? store.structuredOutputs.fetchOutputs(matterID: matterID))?.first { $0.id == outputID }
    }

    private func activeVersion(for record: StructuredOutputRecord) -> StructuredOutputVersionRecord? {
        let versions = (try? store.structuredOutputs.fetchVersions(structuredOutputID: record.id)) ?? []
        return versions.first { $0.id == record.activeVersionID }
            ?? versions.max(by: { $0.versionIndex < $1.versionIndex })
    }

    private func missingCount(for record: StructuredOutputRecord) -> Int {
        guard let active = activeVersion(for: record) else { return 0 }
        return (try? JSONDecoder().decode([String].self, from: Data(active.missingSectionsJSON.utf8)))?.count ?? 0
    }

    private func collect(prompt: String, modelID: ModelID, route: ModelRoute?) async throws -> String {
        let request = GenerateRequest(
            generationID: GenerationID(), modelID: modelID, prompt: prompt,
            // The task base (default + route prompt) leads and the required-heading
            // contract lives in the user-turn template, so layering the user's
            // profile on top personalizes citation style / jurisdiction / voice
            // without overriding the output structure.
            systemPrompt: structuredSystemPrompt(route),
            options: route?.options ?? GenerationOptions()
        )
        return try await runtimeClient.collectGeneratedText(request)
    }

    private func structuredSystemPrompt(_ route: ModelRoute?) -> String? {
        let base = [defaultSystemPrompt, route?.systemPrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return store.composedAssistantPrompt(base: base.isEmpty ? nil : base)
    }
}
