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
/// Best-effort by design. A document the model can't classify — no model loaded,
/// too little text, an unparseable answer, or a generation error — is left
/// *unclassified* (metadata stays nil) so a later pass can retry it, and the
/// surrounding import never fails. Only a successful classification is persisted.
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

    public init(
        store: SupraStore,
        modelLibrary: ModelLibrary,
        runtimeClient: any RuntimeClientProtocol,
        role: ModelRole = .drafting
    ) {
        self.store = store
        self.modelLibrary = modelLibrary
        self.runtimeClient = runtimeClient
        self.role = role
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
    func classifyDocument(_ document: MatterDocumentRecord, modelID: ModelID) async -> Bool {
        let text = combinedText(documentID: document.id)
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

        let truncated = text.count > Self.maxClassificationCharacters
        let request = GenerateRequest(
            generationID: GenerationID(),
            modelID: modelID,
            prompt: DocumentClassificationPrompt.userContent(
                fileName: document.displayName, text: text, maxCharacters: Self.maxClassificationCharacters
            ),
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
            var classification = decoded.normalized()
            if truncated {
                classification.warnings.append("Only the first \(Self.maxClassificationCharacters) characters were classified; the document is longer.")
            }
            return store(classification, for: document)
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

    /// Persists a classification as the document's metadata. Returns false (and
    /// logs) if encoding or the write fails, so callers don't over-report success.
    @discardableResult
    private func store(_ classification: DocumentClassification, for document: MatterDocumentRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(classification),
              let json = String(data: data, encoding: .utf8)
        else { return false }
        do {
            try store.documentLibrary.updateClassification(documentID: document.id, classificationMetadataJSON: json)
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

    private func combinedText(documentID: String) -> String {
        let parts = (try? store.documentIndex.fetchParts(documentID: documentID)) ?? []
        return parts.map(\.normalizedText).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
