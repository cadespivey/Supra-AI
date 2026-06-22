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
        let effectiveRoute = route ?? ModelRouter().route(forStructuredOutput: type)
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
            return true
        } catch {
            message = "Output generation failed: \(error.localizedDescription)"
            return false
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
        status: StructuredOutputStatus
    ) -> (markdown: String, status: StructuredOutputStatus) {
        let citations = LegalCitationVerifier.extractCitationLikeStrings(from: markdown)
        guard !citations.isEmpty || type.assertsLegalAuthority else { return (markdown, status) }
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
              let active = activeVersion(for: record) else { return false }
        guard let contract = StructuredOutputContracts.contract(for: type) else { return false }
        let effectiveRoute = route ?? ModelRouter().repairRoute(forStructuredOutput: type)
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

        do {
            let prompt = try StructuredOutputPromptBuilder.buildRepairPrompt(
                originalOutput: active.contentMarkdown, requiredHeadings: contract.requiredHeadings
            )
            let rawRepaired = ReasoningContent.answer(from: try await collect(prompt: prompt, modelID: modelID, route: effectiveRoute))
            let analysis = StructuredOutputSections.analyze(
                markdown: rawRepaired, requiredHeadings: contract.requiredHeadings
            )
            let (repaired, status) = Self.guardUnverifiedCitations(
                in: rawRepaired,
                type: type,
                status: analysis.missing.isEmpty ? .complete : .needsReview
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
            return true
        } catch {
            message = "Structure repair failed: \(error.localizedDescription)"
            return false
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
