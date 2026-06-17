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

    /// The active version's missing required sections, or all-required when there
    /// is no active version yet.
    func missingSections(forOutput outputID: String) -> [String] {
        guard let record = (try? store.structuredOutputs.fetchOutputs(matterID: matterID))?
            .first(where: { $0.id == outputID }) else { return [] }
        return missingSectionList(for: record)
    }

    private func missingCount(for record: StructuredOutputRecord) -> Int {
        missingSectionList(for: record).count
    }

    private func missingSectionList(for record: StructuredOutputRecord) -> [String] {
        let versions = (try? store.structuredOutputs.fetchVersions(structuredOutputID: record.id)) ?? []
        let active = versions.first { $0.id == record.activeVersionID }
            ?? versions.max(by: { $0.versionIndex < $1.versionIndex })
        guard let json = active?.missingSectionsJSON,
              let decoded = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
        return decoded
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
