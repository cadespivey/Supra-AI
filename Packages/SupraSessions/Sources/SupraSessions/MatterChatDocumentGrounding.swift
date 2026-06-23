import Foundation
import SupraCore
import SupraDocuments
import SupraStore

/// Classifies whether a matter-chat message is asking about the matter's OWN
/// documents (and, if so, how), so the chat can answer from real data instead of
/// the model's parametric memory.
///
/// The gate is deliberately conservative: a message must reference the matter's
/// document collection — a folder, the user's own files ("my documents", "the
/// documents in …", "uploaded files"), or an explicit count/list of documents.
/// General legal-research questions ("what's the standard for summary judgment in
/// this matter?") are intentionally left to the CourtListener-grounded routes, so
/// the gate returns `.none` for anything that merely mentions "this matter" or a
/// singular "document" without pointing at the stored collection.
enum MatterChatDocumentIntent: Equatable {
    /// "what's in the Research folder", "list my documents", "how many files" —
    /// answerable from a deterministic inventory. `folderHint` is a folder-name
    /// reference (nil = whole matter).
    case inventory(folderHint: String?)
    /// "what do my documents say about X" — answerable from retrieved passages.
    case content(folderHint: String?)
    /// Not about the matter's own documents.
    case none

    /// Phrases that point at the user's OWN stored materials. Kept specific on
    /// purpose: bare "document"/"documents"/"this matter" are excluded because they
    /// appear in ordinary legal questions ("what documents are required to remove a
    /// case?", "the deadline in this matter") that must reach the legal route.
    static let collectionPhrases = [
        "my document", "my file", "my pdf", "my upload",
        "the documents", "these documents", "those documents", "the files",
        "the documents in", "the files in", "in my documents", "in the documents",
        "documents in this matter", "files in this matter", "documents in the matter",
        "documents for this matter", "matter's documents", "matter's files",
        "uploaded", "i uploaded", "attached document", "attached file",
        "case file", "casefile"
    ]

    /// Phrases that mean "enumerate what exists" rather than "tell me what it says".
    static let inventoryPhrases = [
        "list ", "a list of", "list all", "list the", "list every",
        "what document", "what file", "which document", "which file",
        "how many", "show me the", "show all", "contents of", "what's in", "what is in",
        "what are the documents", "what are the files", "enumerate", "name the document",
        "name all", "documents located in", "cases located in", "files located in",
        "what do i have", "everything in", "all documents", "all the files", "all cases located"
    ]

    static func classify(_ message: String, folderNames: [String]) -> MatterChatDocumentIntent {
        let lower = message.lowercased()

        // Collection gate. "folder" is the strongest anchor (folders exist only in
        // the Documents tab). Otherwise require a specific reference to the user's own
        // files, or an explicit count/list of documents/files.
        let mentionsFolderWord = lower.contains("folder")
        let documentNoun = lower.contains("document") || lower.contains("file")
            || lower.contains("pdf") || lower.contains("exhibit")
        let countingInventory = documentNoun
            && (lower.contains("how many") || lower.contains("a list of")
                || lower.contains("list all") || lower.contains("list the")
                || lower.contains("list every") || lower.contains("list my"))
        let referencesCollection = mentionsFolderWord
            || countingInventory
            || collectionPhrases.contains { lower.contains($0) }
        guard referencesCollection else { return .none }

        let folderHint = Self.folderHint(in: lower, folderNames: folderNames)

        if inventoryPhrases.contains(where: { lower.contains($0) }) {
            return .inventory(folderHint: folderHint)
        }
        return .content(folderHint: folderHint)
    }

    /// The folder a message refers to, if any. Matches only explicit folder syntax
    /// ("<name> folder", "folder named <name>") so a short or word-prefix folder name
    /// ("Re", "A") can't false-match mid-word ("in regards", "in a deposition"). A
    /// missed hint just falls back to a whole-matter inventory, which is still
    /// complete and truthful — so precision here is a convenience, not correctness.
    /// Longest names win so "Research Memos" beats "Research".
    static func folderHint(in lower: String, folderNames: [String]) -> String? {
        for name in folderNames.sorted(by: { $0.count > $1.count }) {
            let n = name.lowercased()
            guard !n.isEmpty else { continue }
            if lower.contains("\(n) folder") || lower.contains("folder \(n)")
                || lower.contains("folder named \(n)") || lower.contains("folder called \(n)") {
                return name
            }
        }
        // The app auto-creates a "Research" bucket for authorities imported from the
        // Research tab, so "research folder" maps to it even if no folder matched
        // above. Literal (not MatterDocumentsController.researchFolderName) to keep
        // this a pure, nonisolated function; it mirrors that @MainActor constant.
        if lower.contains("research folder") { return "Research" }
        return nil
    }
}

/// The grounded prompt + system prompt the matter chat should send instead of the
/// raw user turn, plus an optional trailer appended to the streamed answer (e.g. a
/// source key so inline `[S#]` citations resolve for the reader).
struct GroundedChatContext: Sendable, Equatable {
    var modelPrompt: String
    var systemPrompt: String?
    var trailer: String?
}

/// Grounds a matter chat in the matter's OWN documents. Inventory questions ("what's
/// in folder X") are answered from a deterministic database listing — the model never
/// gets to invent a document. Content questions ("what do my documents say about Y")
/// reuse the Documents-tab retrieval pipeline (`DocumentRetrievalService` +
/// `DocumentQAPromptBuilder`) so the answer is cited and bounded to real passages.
///
/// Used only for `.matter` chat scope; global chats have no document collection.
@MainActor
final class MatterChatDocumentGrounding {
    private let store: SupraStore
    private let matterID: String
    private let retrieval: DocumentRetrievalService
    private let defaultSystemPrompt: String?

    /// How many retrieved passages to pack into a content answer.
    private static let packedSourceLimit = 8

    init(
        store: SupraStore,
        embedder: (any TextEmbedder)?,
        matterID: String,
        defaultSystemPrompt: String?
    ) {
        self.store = store
        self.matterID = matterID
        self.retrieval = DocumentRetrievalService(store: store, embedder: embedder)
        self.defaultSystemPrompt = defaultSystemPrompt
    }

    /// A grounded context for a matter-chat message, or nil when the message is not
    /// about the matter's own documents (the caller then uses its normal path).
    func groundedContext(forQuestion question: String) async -> GroundedChatContext? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let folders = (try? store.documentLibrary.fetchFolders(matterID: matterID)) ?? []
        switch MatterChatDocumentIntent.classify(trimmed, folderNames: folders.map(\.name)) {
        case .none:
            return nil
        case let .inventory(folderHint):
            return inventoryContext(question: trimmed, folders: folders, folderHint: folderHint)
        case let .content(folderHint):
            return await contentContext(question: trimmed, folders: folders, folderHint: folderHint)
        }
    }

    // MARK: - Inventory

    private func inventoryContext(
        question: String,
        folders: [DocumentFolderRecord],
        folderHint: String?
    ) -> GroundedChatContext {
        let inventory = scopeInventory(folders: folders, folderHint: folderHint)
        let count = inventory.documents.count
        let prompt = """
        The user is asking about the documents stored in \(inventory.scopeLabel) in this app. \
        Below is the COMPLETE and AUTHORITATIVE inventory of those documents (including any sub-folders), \
        taken directly from the app's database.

        DOCUMENT INVENTORY — \(inventory.scopeLabel) (\(count) document\(count == 1 ? "" : "s")):
        \(inventory.text)

        Answer the user's question using ONLY this inventory. Do not invent, add, rename, guess, or infer \
        any document, case, or file that is not listed above. If the inventory is empty, tell the user there \
        are no documents in \(inventory.scopeLabel). Do not claim to have searched, opened, or reviewed \
        anything — you are simply reading the list above.

        QUESTION: \(question)

        ANSWER:
        """
        return GroundedChatContext(modelPrompt: prompt, systemPrompt: groundedSystemPrompt(), trailer: nil)
    }

    // MARK: - Content (retrieval-augmented)

    private func contentContext(
        question: String,
        folders: [DocumentFolderRecord],
        folderHint: String?
    ) async -> GroundedChatContext {
        let folder = resolveFolder(folders: folders, folderHint: folderHint)

        // No documents at all → answer from the (empty) inventory so the model says so
        // instead of fabricating contents.
        let rootDocs = (try? store.documentLibrary.fetchDocuments(matterID: matterID))?
            .filter { $0.parentDocumentID == nil } ?? []
        guard !rootDocs.isEmpty else {
            return inventoryContext(question: question, folders: folders, folderHint: folderHint)
        }

        // A folder hint covers that folder AND its sub-folders, matching how the
        // inventory is built — so "what do the Discovery docs say" doesn't silently
        // skip Discovery/Depositions.
        let scope: RetrievalScope = folder
            .map { RetrievalScope(folderIDs: folderAndDescendantIDs(of: $0, in: folders)) }
            ?? .wholeMatter
        let result = try? await retrieval.retrieve(
            matterID: matterID, query: question, scope: scope, limit: Self.packedSourceLimit
        )
        let sources: [GroundingSource] = (result?.sources ?? []).enumerated().map { index, retrieved in
            let low = retrieved.ocrConfidence.map { $0 < OCRPolicy.lowConfidenceThreshold } ?? false
            return GroundingSource(
                label: "S\(index + 1)",
                documentName: retrieved.documentName,
                locatorDisplay: retrieved.locator.displayString,
                text: retrieved.text,
                excerpt: retrieved.excerpt,
                lowConfidence: low,
                metadata: retrieved.metadata
            )
        }

        // Nothing relevant indexed → tell the user, and show what exists, rather than
        // letting the model answer from outside knowledge.
        guard !sources.isEmpty else {
            return noMatchContext(
                question: question, folders: folders, folderHint: folderHint, readiness: result?.readiness
            )
        }

        var prompt = DocumentQAPromptBuilder.buildQAPrompt(question: question, sources: sources, mode: .short)
        if let readiness = result?.readiness, !readiness.isFullyReady {
            prompt = "(Note: only \(readiness.readyDocuments) of \(readiness.totalDocuments) documents in scope are "
                + "indexed so far; content from the rest may be missing.)\n\n" + prompt
        }

        let appendix = SourceAppendix(entries: sources.map {
            SourceAppendix.Entry(
                label: $0.label, documentName: $0.documentName,
                locatorDisplay: $0.locatorDisplay, excerpt: $0.excerpt,
                warnings: $0.lowConfidence ? ["low OCR confidence"] : []
            )
        })
        return GroundedChatContext(
            modelPrompt: prompt, systemPrompt: groundedSystemPrompt(), trailer: "\n" + appendix.markdown()
        )
    }

    private func noMatchContext(
        question: String,
        folders: [DocumentFolderRecord],
        folderHint: String?,
        readiness: ScopeReadiness?
    ) -> GroundedChatContext {
        let inventory = scopeInventory(folders: folders, folderHint: folderHint)
        // Distinguish "nothing is indexed yet" from "indexed, but nothing relevant" —
        // reporting the wrong one misleads the user.
        let stillIndexing = (readiness?.readyDocuments ?? 0) == 0 && !inventory.documents.isEmpty
        let lead = stillIndexing
            ? "The user asked about the CONTENTS of the documents in \(inventory.scopeLabel), but those "
                + "documents have not finished indexing yet, so their text is not searchable. Tell the user "
                + "their documents are still being indexed and to try again shortly. Do NOT answer from outside "
                + "knowledge or invent document contents."
            : "The user asked about the CONTENTS of the documents in \(inventory.scopeLabel), but a search of "
                + "the indexed text found no passages relevant to the question. Do NOT answer from outside "
                + "knowledge and do NOT invent document contents. Tell the user that no relevant passages were "
                + "found in their documents for this question; you may name which documents exist (listed below) "
                + "and suggest they rephrase or open the Documents tab."
        let prompt = """
        \(lead)

        DOCUMENTS IN \(inventory.scopeLabel):
        \(inventory.text)

        QUESTION: \(question)

        ANSWER:
        """
        return GroundedChatContext(modelPrompt: prompt, systemPrompt: groundedSystemPrompt(), trailer: nil)
    }

    // MARK: - Helpers

    private struct ScopeInventory {
        var scopeLabel: String
        var documents: [MatterDocumentRecord]
        var text: String
    }

    private func resolveFolder(folders: [DocumentFolderRecord], folderHint: String?) -> DocumentFolderRecord? {
        guard let folderHint else { return nil }
        return folders.first { $0.name.caseInsensitiveCompare(folderHint) == .orderedSame }
    }

    /// A folder plus all of its descendant folders, so "the X folder" means everything
    /// filed under X (folders are hierarchical via `parentFolderID`).
    private func folderAndDescendantIDs(
        of folder: DocumentFolderRecord, in folders: [DocumentFolderRecord]
    ) -> [String] {
        var result = [folder.id]
        var frontier = Set([folder.id])
        while !frontier.isEmpty {
            let children = folders.filter { $0.parentFolderID.map(frontier.contains) ?? false }.map(\.id)
            let fresh = children.filter { !result.contains($0) }
            result.append(contentsOf: fresh)
            frontier = Set(fresh)
        }
        return result
    }

    /// The root documents for a folder hint (nil = whole matter), including sub-folders,
    /// formatted as a numbered list with type/date and a folder label when the scope
    /// spans more than one folder.
    private func scopeInventory(folders: [DocumentFolderRecord], folderHint: String?) -> ScopeInventory {
        let folder = resolveFolder(folders: folders, folderHint: folderHint)
        let scopeLabel: String
        if let folder {
            scopeLabel = "the “\(folder.name)” folder"
        } else if let folderHint {
            scopeLabel = "the “\(folderHint)” folder"
        } else {
            scopeLabel = "this matter"
        }

        // A hint that named a non-existent folder scopes to nothing (truthfully empty).
        let documents: [MatterDocumentRecord]
        if folderHint != nil, folder == nil {
            documents = []
        } else if let folder {
            let scopeIDs = Set(folderAndDescendantIDs(of: folder, in: folders))
            documents = ((try? store.documentLibrary.fetchDocuments(matterID: matterID)) ?? [])
                .filter { $0.parentDocumentID == nil && ($0.folderID.map(scopeIDs.contains) ?? false) }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } else {
            documents = ((try? store.documentLibrary.fetchDocuments(matterID: matterID)) ?? [])
                .filter { $0.parentDocumentID == nil }
        }

        // Label folders even when they're soft-deleted, so a stray folder reference
        // isn't silently relabeled "(none)".
        let folderNameByID = Dictionary(
            uniqueKeysWithValues: ((try? store.documentLibrary.fetchFolders(matterID: matterID, includeDeleted: true)) ?? folders)
                .map { ($0.id, $0.name) }
        )
        let distinctFolders = Set(documents.compactMap(\.folderID))
        let showFolderLabel = folder == nil || distinctFolders.count > 1

        let lines: [String]
        if documents.isEmpty {
            lines = ["(no documents)"]
        } else {
            lines = documents.enumerated().map { index, doc in
                var row = "\(index + 1). \(doc.displayName)"
                var suffix: [String] = []
                if let meta = DocumentRetrievalService.contextMetadata(for: doc) { suffix.append(meta) }
                if showFolderLabel {
                    let folderLabel = doc.folderID.flatMap { folderNameByID[$0] }
                    suffix.append("Folder: \(folderLabel ?? "(none)")")
                }
                if !suffix.isEmpty { row += " — " + suffix.joined(separator: " · ") }
                return row
            }
        }
        return ScopeInventory(scopeLabel: scopeLabel, documents: documents, text: lines.joined(separator: "\n"))
    }

    /// The grounded base prompt (strict "use only the sources" contract) layered with
    /// the user's profile — minus writing-style excerpts, which must never enter a
    /// grounded context where the model could mine them as facts.
    private func groundedSystemPrompt() -> String? {
        let base = [defaultSystemPrompt, LegalPromptTemplates.documentGroundedSystemPrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return store.composedAssistantPrompt(base: base.isEmpty ? nil : base, includeWritingSamples: false)
    }
}
