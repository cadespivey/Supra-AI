import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
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

    /// Questions about the matter's OWN record — who the parties/counsel are, their
    /// contact details, who signed/served/filed. In a matter chat these are answered
    /// from the matter's documents, not the model's memory; this is what makes a bare
    /// "who are the parties?" ground in the file instead of confabulating names.
    /// Deliberately specific (e.g. "email address", not bare "email") so an ordinary
    /// "rewrite this email" doesn't get pulled into document retrieval.
    static let matterEntityPhrases = [
        "who is", "who are", "who's", "who was", "who were", "whose ",
        "the parties", "all parties", "parties in", "parties to", "named parties", "party to",
        "plaintiff", "defendant", "petitioner", "respondent", "movant", "appellant", "appellee",
        "counsel for", "counsel of", "who represents", "who is representing", "attorneys for",
        "attorneys representing", "the attorneys", "law firm", "lead counsel",
        "name of", "names of", "identify the", "list the parties", "list the attorneys",
        "email address", "e-mail address", "their email", "phone number", "telephone number",
        "contact information", "contact info", "address for",
        "who signed", "who served", "who filed", "signatory", "signed by", "served by", "filed by"
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

        // Identity / party / counsel / contact questions are about the matter's own
        // record — ground them in the matter's documents even when they don't name the
        // document collection. An "@" means the message already carries an address.
        let asksAboutMatterEntities = matterEntityPhrases.contains { lower.contains($0) }
            || lower.contains("@")

        guard referencesCollection || asksAboutMatterEntities else { return .none }

        let folderHint = Self.folderHint(in: lower, folderNames: folderNames)

        // Only the "enumerate what exists" phrasing is an inventory listing; an identity
        // question ("who are the parties?") wants the content path (retrieved passages).
        if referencesCollection, inventoryPhrases.contains(where: { lower.contains($0) }) {
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
    /// The packed source passages ([S#]) shown to the model, kept so the controller can
    /// run a post-generation entity-grounding check (catch names absent from the record).
    /// Empty for inventory / no-match contexts, where there is nothing to extract.
    var sourceTexts: [String] = []
    /// Resolvable references behind each `[S#]` passage, so the controller can persist
    /// clickable citations that open the in-app preview at the cited page. Empty for
    /// inventory / no-match contexts.
    var sources: [GroundedSourceRef] = []
    /// Whether every document in the answered scope was fully indexed at retrieval time.
    /// `false` means the answer was produced from a still-indexing scope; the controller
    /// surfaces that as an out-of-band citation-coverage warning rather than relying on a
    /// soft in-prompt note the model may drop.
    var scopeFullyIndexed: Bool = true
    /// Which retrieval tier packed the sources — `.fast` answers are preliminary and
    /// the controller offers "search all documents" (spec §3.2). Inventory/no-match
    /// contexts are `.deep` (there is no deeper tier for them).
    var depth: RetrievalDepth = .deep
}

/// A resolvable pointer behind an inline `[S#]` matter-document citation: enough to
/// open the in-app preview at the right page and highlight the cited passage.
struct GroundedSourceRef: Sendable, Equatable {
    var label: String          // "S1", "S2", …
    var sourceID: String
    var documentID: String
    var documentName: String
    var locator: DocumentSourceLocator
    var excerpt: String
    var supportText: String
    var lowConfidence: Bool
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
    /// Runs the deep tier's LLM rerank (shared `DocumentRerank` machinery). The
    /// grounded answer itself is generated by the caller (the chat controller).
    private let runtimeClient: any RuntimeClientProtocol

    /// How many retrieved passages to pack into a content answer.
    /// Tier packing (spec §3.2.3): the fast tier packs the RRF top directly; the
    /// deep tier retrieves a wide candidate pool (`DocumentRerank.candidatePoolSize`)
    /// and LLM-reranks it down to this packed set — capability parity with the
    /// retired Documents-tab Q&A deep tier, via the same shared machinery.
    private static let fastPackedSourceLimit = 8
    private static let deepPackedSourceLimit = 12

    init(
        store: SupraStore,
        embedder: (any TextEmbedder)?,
        matterID: String,
        defaultSystemPrompt: String?,
        runtimeClient: any RuntimeClientProtocol
    ) {
        self.store = store
        self.matterID = matterID
        self.retrieval = DocumentRetrievalService(store: store, embedder: embedder)
        self.defaultSystemPrompt = defaultSystemPrompt
        self.runtimeClient = runtimeClient
    }

    /// A grounded context for a matter-chat message, or nil when the message is not
    /// about the matter's own documents (the caller then uses its normal path).
    /// `modelID` runs the deep tier's rerank; nil (or a fast pass) never generates.
    func groundedContext(
        forQuestion question: String,
        depth: RetrievalDepth = .fast,
        modelID: ModelID? = nil
    ) async -> GroundedChatContext? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let folders = (try? store.documentLibrary.fetchFolders(matterID: matterID)) ?? []
        switch MatterChatDocumentIntent.classify(trimmed, folderNames: folders.map(\.name)) {
        case .none:
            return nil
        case let .inventory(folderHint):
            return inventoryContext(question: trimmed, folders: folders, folderHint: folderHint)
        case let .content(folderHint):
            return await contentContext(
                question: trimmed, folders: folders, folderHint: folderHint, depth: depth, modelID: modelID
            )
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
        folderHint: String?,
        depth: RetrievalDepth,
        modelID: ModelID?
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
        var effectiveDepth = depth
        // The deep tier retrieves the wide candidate pool the rerank narrows; the
        // fast tier retrieves exactly what it packs.
        var result = try? await retrieval.retrieve(
            matterID: matterID, query: question, scope: scope,
            limit: depth == .fast ? Self.fastPackedSourceLimit : DocumentRerank.candidatePoolSize,
            depth: depth
        )
        // Empty fast packet -> run the deep pass once, silently (spec §8.2), before
        // concluding nothing matches.
        if result?.sources.isEmpty ?? true, depth == .fast {
            effectiveDepth = .deep
            result = try? await retrieval.retrieve(
                matterID: matterID, query: question, scope: scope,
                limit: DocumentRerank.candidatePoolSize, depth: .deep
            )
        }
        var retrieved = result?.sources ?? []
        // Deep tier: LLM-rerank the candidate pool down to the packed set before the
        // answer is generated, so the packet holds the MOST relevant passages rather
        // than the retrieval-ranked top (ported from the Documents-tab Q&A deep tier).
        if effectiveDepth == .deep {
            retrieved = await rerankedDeepSelection(retrieved, question: question, modelID: modelID)
        }
        let sources: [GroundingSource] = retrieved.enumerated().map { index, retrieved in
            let low = retrieved.ocrConfidence.map { $0 < OCRPolicy.lowConfidenceThreshold } ?? false
            return retrieved.groundingSource(
                sourceID: "\(matterID)/\(retrieved.chunkID)",
                label: "S\(index + 1)",
                lowConfidence: low
            )
        }
        let sourceRefs: [GroundedSourceRef] = retrieved.enumerated().map { index, retrieved in
            GroundedSourceRef(
                label: "S\(index + 1)",
                sourceID: "\(matterID)/\(retrieved.chunkID)",
                documentID: retrieved.documentID,
                documentName: retrieved.documentName,
                locator: retrieved.locator,
                excerpt: retrieved.excerpt,
                supportText: sources[index].packedText,
                lowConfidence: sources[index].lowConfidence
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

        // No source excerpts appended to the answer text: the clickable inline `[S#]`
        // markers plus the subtle sources list under the message carry the citations
        // now, so the verbose excerpt block would just duplicate them.
        return GroundedChatContext(
            modelPrompt: prompt, systemPrompt: groundedSystemPrompt(), trailer: nil,
            sourceTexts: sources.map(\.text),
            sources: sourceRefs,
            scopeFullyIndexed: result?.readiness.isFullyReady ?? true,
            depth: effectiveDepth
        )
    }

    /// The deep tier's packed selection: LLM-reranks the wide candidate pool down to
    /// `deepPackedSourceLimit` via the shared `DocumentRerank` machinery. A pool that
    /// already fits the packet skips the rerank (nothing to narrow, no extra
    /// generation); a missing model falls back to retrieval order. Best-effort — the
    /// rerank improves the packet but never blocks the answer.
    private func rerankedDeepSelection(
        _ retrieved: [RetrievedSource],
        question: String,
        modelID: ModelID?
    ) async -> [RetrievedSource] {
        guard retrieved.count > Self.deepPackedSourceLimit else { return retrieved }
        guard let modelID else { return Array(retrieved.prefix(Self.deepPackedSourceLimit)) }
        let candidates = retrieved.enumerated().map { index, item in
            DocumentRerank.Candidate(label: "S\(index + 1)", text: item.text)
        }
        let order = await DocumentRerank.packedOrder(
            question: question,
            candidates: candidates,
            limit: Self.deepPackedSourceLimit,
            runtimeClient: runtimeClient,
            modelID: modelID
        )
        let byLabel = Dictionary(
            zip(candidates.map(\.label), retrieved),
            uniquingKeysWith: { first, _ in first }
        )
        return order.compactMap { byLabel[$0] }
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
