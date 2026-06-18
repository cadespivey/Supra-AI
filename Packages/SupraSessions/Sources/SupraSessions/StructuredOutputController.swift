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
        modelID: ModelID?
    ) async -> Bool {
        guard let modelID else {
            message = "Load a model in the Models tab to generate structured outputs."
            return false
        }
        isGenerating = true
        message = nil
        defer { isGenerating = false }

        guard let contract = StructuredOutputContracts.contract(for: type) else {
            message = "Document Q&A and chronologies are generated from the Documents tab."
            return false
        }
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
            let markdown = ReasoningContent.answer(from: try await collect(prompt: prompt, modelID: modelID))
            let analysis = StructuredOutputSections.analyze(
                markdown: markdown, requiredHeadings: contract.requiredHeadings
            )
            let status: StructuredOutputStatus = analysis.missing.isEmpty ? .complete : .needsReview

            let output = try store.structuredOutputs.createOutput(
                matterID: matterID, title: contract.title, outputType: type,
                chatID: chatID, researchSessionID: researchSessionID, status: status
            )
            let version = try store.structuredOutputs.createVersion(
                structuredOutputID: output.id, versionIndex: 1, contentMarkdown: markdown,
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
    public func repairOutput(_ outputID: String, modelID: ModelID?) async -> Bool {
        guard let modelID else {
            message = "Load a model in the Models tab to repair outputs."
            return false
        }
        guard let record = outputRecord(outputID),
              let type = StructuredOutputType(rawValue: record.outputType),
              let active = activeVersion(for: record) else { return false }

        isGenerating = true
        message = nil
        defer { isGenerating = false }

        guard let contract = StructuredOutputContracts.contract(for: type) else { return false }
        do {
            let prompt = try StructuredOutputPromptBuilder.buildRepairPrompt(
                originalOutput: active.contentMarkdown, requiredHeadings: contract.requiredHeadings
            )
            let repaired = ReasoningContent.answer(from: try await collect(prompt: prompt, modelID: modelID))
            let analysis = StructuredOutputSections.analyze(
                markdown: repaired, requiredHeadings: contract.requiredHeadings
            )
            let status: StructuredOutputStatus = analysis.missing.isEmpty ? .complete : .needsReview
            _ = try store.structuredOutputs.createVersion(
                structuredOutputID: outputID, versionIndex: active.versionIndex + 1, contentMarkdown: repaired,
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

    private func collect(prompt: String, modelID: ModelID) async throws -> String {
        let request = GenerateRequest(
            generationID: GenerationID(), modelID: modelID, prompt: prompt,
            // Base prompt only: output is parsed into required sections (with
            // missing-section repair), so the user's free-form profile must not
            // override the contract's structure.
            systemPrompt: defaultSystemPrompt, options: GenerationOptions()
        )
        var output = ""
        for try await event in try runtimeClient.generate(request) {
            if event.type == .token, let token = event.tokenText { output += token }
        }
        return output
    }
}
