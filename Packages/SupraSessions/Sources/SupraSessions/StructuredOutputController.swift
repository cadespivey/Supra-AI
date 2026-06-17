import Combine
import Foundation
import SupraCore
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
        public let updatedAt: Date
    }

    @Published public private(set) var outputs: [OutputItem] = []
    @Published public private(set) var isGenerating = false
    @Published public private(set) var message: String?

    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private let defaultSystemPrompt: String?
    public let matterID: String

    public init(
        store: SupraStore,
        runtimeClient: any RuntimeClientProtocol,
        matterID: String,
        defaultSystemPrompt: String? = nil
    ) {
        self.store = store
        self.runtimeClient = runtimeClient
        self.matterID = matterID
        self.defaultSystemPrompt = defaultSystemPrompt
    }

    public func loadOutputs() {
        outputs = ((try? store.structuredOutputs.fetchOutputs(matterID: matterID)) ?? []).map { record in
            OutputItem(
                id: record.id,
                title: record.title,
                outputType: record.outputType,
                status: record.status,
                missingCount: missingCount(for: record),
                updatedAt: record.updatedAt
            )
        }
    }

    /// Generates an output: prompt → local model → section detection → persist.
    /// Status is `complete` only when no required section is missing (§12.4).
    @discardableResult
    public func createOutput(
        type: StructuredOutputType,
        context: String,
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

        let contract = StructuredOutputContracts.contract(for: type)
        do {
            let prompt = try StructuredOutputPromptBuilder.buildPrompt(for: contract, context: context)
            let markdown = ReasoningContent.answer(from: try await collect(prompt: prompt, modelID: modelID))
            let analysis = StructuredOutputSections.analyze(
                markdown: markdown, requiredHeadings: contract.requiredHeadings
            )
            let status: StructuredOutputStatus = analysis.missing.isEmpty ? .complete : .needsReview

            let output = try store.structuredOutputs.createOutput(
                matterID: matterID, title: contract.title, outputType: type,
                chatID: chatID, researchSessionID: researchSessionID, status: status
            )
            _ = try store.structuredOutputs.createVersion(
                structuredOutputID: output.id, versionIndex: 1, contentMarkdown: markdown,
                requiredSections: contract.requiredHeadings,
                presentSections: analysis.present, missingSections: analysis.missing
            )
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID, eventType: "structured_output_created", actor: "runtime",
                summary: "Created \(contract.title)", relatedTable: "structured_outputs", relatedID: output.id
            )
            loadOutputs()
            return true
        } catch {
            message = "Output generation failed: \(error.localizedDescription)"
            return false
        }
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

        let contract = StructuredOutputContracts.contract(for: type)
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
            systemPrompt: defaultSystemPrompt, options: GenerationOptions()
        )
        var output = ""
        for try await event in try runtimeClient.generate(request) {
            if event.type == .token, let token = event.tokenText { output += token }
        }
        return output
    }
}
