import CryptoKit
import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

/// Classifies imported documents into the approved taxonomy (1.3.2). After text
/// extraction, each document's text is sent to the assigned task model, which
/// returns structured JSON (`DocumentClassification`). The validated result is
/// stored as the document's classification metadata — used for retrieval,
/// filtering, and privilege review, and surfaced as an editable suggestion chip.
///
/// Best-effort by design. Transient failures remain retryable; successful model
/// calls append complete input/model/prompt/sampling/evidence lineage. Uncertain
/// or ungrounded outputs persist as explicit abstentions with no visible primary
/// category instead of silently presenting a guess.
///
/// `@MainActor`: the caller (`DocumentProcessingQueue`) and `ModelLibrary` are both
/// main-actor isolated, so this keeps the model load + store writes on one actor
/// (the long model inference is `await`ed, so the UI stays responsive).
@MainActor
public final class DocumentClassificationService {
    private let store: SupraStore
    private let modelLibrary: ModelLibrary
    private let runtimeClient: any RuntimeClientProtocol
    private let role: ModelRole
    private let abstentionFloor: Double
    private let modelLineageResolver: ((ModelID) -> DocumentGenerationModelLineage?)?

    public static let promptVersion = "document-classification-v2"
    public static let calibrationVersion = "document-classification-calibration-v2"

    public init(
        store: SupraStore,
        modelLibrary: ModelLibrary,
        runtimeClient: any RuntimeClientProtocol,
        role: ModelRole = .drafting,
        abstentionFloor: Double = 0.5,
        modelLineageResolver: ((ModelID) -> DocumentGenerationModelLineage?)? = nil
    ) {
        self.store = store
        self.modelLibrary = modelLibrary
        self.runtimeClient = runtimeClient
        self.role = role
        self.abstentionFloor = min(max(abstentionFloor, 0), 1)
        self.modelLineageResolver = modelLineageResolver
    }

    /// Classifies every not-yet-classified, extracted document in a matter and
    /// returns the number classified. Loads the task model once for the batch; if
    /// none is available the documents are left unclassified for a later pass.
    @discardableResult
    public func classifyMatter(matterID: String) async -> Int {
        let documents = (try? store.documentLibrary.fetchDocuments(matterID: matterID)) ?? []
        let pending = documents.filter(Self.needsClassification)
        guard !pending.isEmpty else { return 0 }

        guard let modelID = await loadTaskModel() else {
            // No assignable/loadable model — leave the documents unclassified so a
            // later import or re-index (once a model is set up) can classify them.
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID, eventType: "document_classification_skipped", actor: "system",
                summary: "Skipped classifying \(pending.count) document(s): no task model is loaded."
            )
            return 0
        }

        var classified = 0
        for document in pending {
            if await classifyDocument(document, modelID: modelID) { classified += 1 }
        }
        if classified > 0 {
            _ = try? store.auditEvents.recordEvent(
                matterID: matterID, eventType: "document_classification_completed", actor: "system",
                summary: "Classified \(classified) document(s)"
            )
        }
        return classified
    }

    /// Classifies a single document and persists the result on success. Returns
    /// true only when a classification was stored. Transient/unusable cases leave
    /// the document unclassified (nil) so a later pass can retry. Swallows its own
    /// errors so it is safe to call in a loop.
    @discardableResult
    func classifyDocument(
        _ document: MatterDocumentRecord,
        modelID: ModelID,
        modelLineage: DocumentGenerationModelLineage? = nil,
        classificationKey: String = "classification:\(UUID().uuidString)"
    ) async -> Bool {
        let revisions = currentRevisions(documentID: document.id)
        let text = revisions.map(\.text).joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minimumTextLength else {
            // Too little usable text to classify — leave unclassified (retryable if
            // OCR or an edit later adds text) rather than storing a sticky result.
            _ = try? store.auditEvents.recordEvent(
                eventType: "document_classification_skipped", actor: "system",
                summary: "Skipped \(document.displayName): too little extractable text to classify.",
                relatedTable: "matter_documents", relatedID: document.id
            )
            return false
        }

        guard let stableLineage = modelLineage
                ?? modelLineageResolver?(modelID)
                ?? modelLibrary.generationLineage(for: modelID) else {
            _ = try? store.auditEvents.recordEvent(
                eventType: "document_classification_failed", actor: "system",
                summary: "Could not classify \(document.displayName): stable model repository and revision are unavailable.",
                relatedTable: "matter_documents", relatedID: document.id
            )
            return false
        }

        let samples = DocumentClassificationSampler.samples(
            revisions: revisions,
            structureNodes: (try? store.documentStructure.fetchNodes(documentID: document.id)) ?? [],
            characterBudget: Self.maxClassificationCharacters
        )
        guard !samples.isEmpty else { return false }

        let request = GenerateRequest(
            generationID: GenerationID(),
            modelID: modelID,
            prompt: DocumentClassificationPrompt.userContent(fileName: document.displayName, samples: samples),
            systemPrompt: DocumentClassificationPrompt.system(),
            options: GenerationOptions(
                preset: .extractive,
                temperature: 0.0,
                topP: 1.0,
                maxOutputTokens: 1200,
                thinkingBudget: .off
            )
        )

        do {
            let raw = try await runtimeClient.collectGeneratedText(request)
            let answer = ReasoningContent.answer(from: raw)
            guard let json = Self.extractJSONObject(from: answer),
                  let decoded = try? JSONDecoder().decode(DocumentClassification.self, from: Data(json.utf8))
            else {
                // Unparseable answer — leave unclassified so a later pass (perhaps a
                // different/updated model) can retry, rather than sticking it.
                _ = try? store.auditEvents.recordEvent(
                    eventType: "document_classification_failed", actor: "system",
                    summary: "Could not parse a classification for \(document.displayName).",
                    relatedTable: "matter_documents", relatedID: document.id
                )
                return false
            }
            return persist(
                decoded,
                for: document,
                revisions: revisions,
                modelLineage: stableLineage,
                classificationKey: classificationKey
            )
        } catch {
            // A runtime/generation failure is non-fatal — leave the document
            // unclassified (retryable) and log the reason.
            _ = try? store.auditEvents.recordEvent(
                eventType: "document_classification_failed", actor: "system",
                summary: "Classification failed for \(document.displayName): \(error.localizedDescription)",
                relatedTable: "matter_documents", relatedID: document.id
            )
            return false
        }
    }

    // MARK: - Persistence

    /// Validates evidence and calibration, then atomically appends the lineage row
    /// and updates the compatible latest-value JSON projection.
    @discardableResult
    private func persist(
        _ rawClassification: DocumentClassification,
        for document: MatterDocumentRecord,
        revisions: [DocumentPartRevisionRecord],
        modelLineage: DocumentGenerationModelLineage,
        classificationKey: String
    ) -> Bool {
        let rawSuggestedCategory = rawClassification.primaryTag
        let confidence = DocumentClassificationConfidence(
            rawConfidence: rawClassification.confidence,
            abstentionFloor: abstentionFloor,
            rawSuggestedPrimaryCategory: rawSuggestedCategory
        )
        let validEvidence = validatedEvidence(rawClassification.evidenceSpans, revisions: revisions)
        var classification = rawClassification.normalized()
        var abstentionReason: String?
        if !(0...1).contains(rawClassification.confidence) {
            abstentionReason = "The model returned confidence outside the required 0...1 range."
        } else if DocumentCategory.from(rawTag: rawSuggestedCategory) == nil {
            abstentionReason = "The model returned a primary category outside the approved taxonomy."
        } else if rawClassification.confidence < abstentionFloor {
            abstentionReason = "Raw confidence \(Self.render(rawClassification.confidence)) is below the calibrated abstention floor \(Self.render(abstentionFloor))."
        } else if validEvidence == nil || rawClassification.evidenceSpans.isEmpty {
            abstentionReason = "The model did not provide exact revision-bound evidence for the suggested category."
        }
        let abstained = abstentionReason != nil
        let persistedEvidence = validEvidence ?? []
        if let abstentionReason {
            classification.abstained = true
            classification.primaryTag = ""
            classification.secondaryTags = []
            classification.evidenceSpans = persistedEvidence
            if !classification.warnings.contains(abstentionReason) {
                classification.warnings.append(abstentionReason)
            }
        } else {
            classification.abstained = false
            classification.evidenceSpans = persistedEvidence
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let projectionData = try? encoder.encode(classification),
              let projectionJSON = String(data: projectionData, encoding: .utf8),
              let revisionIDsJSON = Self.encodeJSON(revisions.map(\.id)),
              let secondaryJSON = Self.encodeJSON(abstained ? [] : classification.secondaryCategories.map(\.rawValue)),
              let confidenceJSON = Self.encodeJSON(confidence),
              let evidenceJSON = Self.encodeJSON(persistedEvidence),
              let warningsJSON = Self.encodeJSON(classification.warnings)
        else { return false }

        let record = DocumentClassificationRecord(
            matterID: document.matterID,
            documentID: document.id,
            classificationKey: classificationKey,
            inputRevisionIDsJSON: revisionIDsJSON,
            inputChecksum: Self.inputChecksum(revisions),
            modelRepository: modelLineage.modelRepository,
            modelRevision: modelLineage.modelRevision,
            promptVersion: Self.promptVersion,
            samplingStrategy: DocumentClassificationSampler.strategy,
            samplingVersion: DocumentClassificationSampler.version,
            primaryCategory: abstained ? nil : classification.primaryCategory.rawValue,
            secondaryCategoriesJSON: secondaryJSON,
            confidenceJSON: confidenceJSON,
            calibrationVersion: Self.calibrationVersion,
            abstained: abstained,
            abstentionReason: abstentionReason,
            evidenceSpansJSON: evidenceJSON,
            warningsJSON: warningsJSON
        )
        do {
            try store.documentClassifications.appendAndProjectLegacy(
                record,
                legacyProjectionJSON: projectionJSON
            )
            return true
        } catch {
            _ = try? store.auditEvents.recordEvent(
                eventType: "document_classification_failed", actor: "system",
                summary: "Could not persist classification for \(document.displayName): \(error.localizedDescription)",
                relatedTable: "matter_documents", relatedID: document.id
            )
            return false
        }
    }

    // MARK: - Helpers

    private func loadTaskModel() async -> ModelID? {
        switch await modelLibrary.ensureLoadedRoutedModelID(for: role) {
        case .success(let modelID): return modelID
        case .failure: return nil
        }
    }

    private func currentRevisions(documentID: String) -> [DocumentPartRevisionRecord] {
        guard let parts = try? store.documentIndex.fetchParts(documentID: documentID) else { return [] }
        var revisions: [DocumentPartRevisionRecord] = []
        for part in parts.sorted(by: { $0.partIndex < $1.partIndex }) {
            guard let revisionID = part.currentRevisionID,
                  let revision = try? store.documentRevisions.fetchRevision(id: revisionID),
                  revision.documentID == documentID,
                  revision.partIndex == part.partIndex else {
                return []
            }
            revisions.append(revision)
        }
        return revisions
    }

    private func validatedEvidence(
        _ spans: [DocumentClassificationEvidenceSpan],
        revisions: [DocumentPartRevisionRecord]
    ) -> [DocumentClassificationEvidenceSpan]? {
        let byID = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
        for span in spans {
            guard let revision = byID[span.revisionID],
                  span.charStart >= 0,
                  span.charEnd > span.charStart,
                  span.charEnd <= revision.text.count else { return nil }
            let start = revision.text.index(revision.text.startIndex, offsetBy: span.charStart)
            let end = revision.text.index(revision.text.startIndex, offsetBy: span.charEnd)
            guard String(revision.text[start..<end]) == span.excerpt else { return nil }
        }
        return spans
    }

    nonisolated private static func inputChecksum(_ revisions: [DocumentPartRevisionRecord]) -> String {
        var hasher = SHA256()
        for revision in revisions {
            hasher.update(data: Data(revision.id.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(revision.partIndex).utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(revision.text.utf8))
            hasher.update(data: Data([0xff]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    nonisolated private static func render(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Whether a document is eligible for (re)classification: extracted / OCR-complete /
    /// edited, not yet classified, and not deleted. `nonisolated` so the queue and the
    /// standing-guard tests can evaluate it without main-actor isolation (mirrors
    /// `extractJSONObject`).
    nonisolated static func needsClassification(_ document: MatterDocumentRecord) -> Bool {
        guard document.deletedAt == nil, document.classificationMetadataJSON == nil else { return false }
        return document.extractionStatus == DocumentExtractionStatus.extracted.rawValue
            || document.extractionStatus == DocumentExtractionStatus.ocrComplete.rawValue
            || document.extractionStatus == DocumentExtractionStatus.edited.rawValue
    }

    /// Extracts the first balanced JSON object from model output that may be
    /// wrapped in prose or ```json fences. `nonisolated` so it is usable as a pure
    /// helper (and from tests) without main-actor isolation.
    nonisolated static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                if character == "\"" { inString = true }
                else if character == "{" { depth += 1 }
                else if character == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static let minimumTextLength = 40
    private static let maxClassificationCharacters = 12_000
}
