import Combine
import Foundation
import SupraCore
import SupraRuntimeClient
import SupraStore

/// A view-facing snapshot of a matter (a legal workspace that groups chats,
/// research, authorities, and outputs).
public struct MatterSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var jurisdiction: String
    public var court: String?
    public var clientNames: String?
    public var matterDescription: String?
    public var internalMatterID: String?
    /// LEDES `CLIENT_ID` (e-billing).
    public var clientID: String?
    /// LEDES `CLIENT_MATTER_ID` (e-billing).
    public var clientMatterID: String?
    public var partyPerspective: PartyPerspective
    public var updatedAt: Date

    init(record: MatterRecord) {
        self.id = record.id
        self.name = record.name
        self.jurisdiction = record.jurisdiction
        self.court = record.court
        self.clientNames = record.clientNames
        self.matterDescription = record.matterDescription
        self.internalMatterID = record.internalMatterID
        self.clientID = record.clientID
        self.clientMatterID = record.clientMatterID
        self.partyPerspective = PartyPerspective(rawValue: record.partyPerspective) ?? .neutral
        self.updatedAt = record.updatedAt
    }
}

/// Editable matter fields, used by the create/edit form. Keeps the app layer
/// off the GRDB record type.
public struct MatterDraft: Sendable, Equatable {
    public var name: String
    public var jurisdiction: String
    public var partyPerspective: PartyPerspective
    public var court: String
    public var judge: String
    public var docketNumber: String
    public var practiceArea: String
    public var clientNames: String
    public var matterDescription: String
    public var internalMatterID: String
    /// LEDES `CLIENT_ID` — the client's e-billing identifier.
    public var clientID: String
    /// LEDES `CLIENT_MATTER_ID` — the client's matter identifier for e-billing.
    public var clientMatterID: String
    public var notes: String

    public init(
        name: String = "",
        jurisdiction: String = "",
        partyPerspective: PartyPerspective = .neutral,
        court: String = "",
        judge: String = "",
        docketNumber: String = "",
        practiceArea: String = "",
        clientNames: String = "",
        matterDescription: String = "",
        internalMatterID: String = "",
        clientID: String = "",
        clientMatterID: String = "",
        notes: String = ""
    ) {
        self.name = name
        self.jurisdiction = jurisdiction
        self.partyPerspective = partyPerspective
        self.court = court
        self.judge = judge
        self.docketNumber = docketNumber
        self.practiceArea = practiceArea
        self.clientNames = clientNames
        self.matterDescription = matterDescription
        self.internalMatterID = internalMatterID
        self.clientID = clientID
        self.clientMatterID = clientMatterID
        self.notes = notes
    }

    init(record: MatterRecord) {
        self.init(
            name: record.name,
            jurisdiction: record.jurisdiction,
            partyPerspective: PartyPerspective(rawValue: record.partyPerspective) ?? .neutral,
            court: record.court ?? "",
            judge: record.judge ?? "",
            docketNumber: record.docketNumber ?? "",
            practiceArea: record.practiceArea ?? "",
            clientNames: record.clientNames ?? "",
            matterDescription: record.matterDescription ?? "",
            internalMatterID: record.internalMatterID ?? "",
            clientID: record.clientID ?? "",
            clientMatterID: record.clientMatterID ?? "",
            notes: record.notes ?? ""
        )
    }

    /// Required fields per the Milestone 2 spec (§4.1): name + jurisdiction must
    /// be non-empty; party perspective always has a value via the enum.
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !jurisdiction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A view-facing audit-log entry for a matter (decoupled from the GRDB record).
public struct MatterAuditEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let timestamp: Date
    public let eventType: String
    public let actor: String
    public let summary: String
}

/// Manages the list of matters and, for the selected matter, vends a
/// matter-scoped `GlobalChatController` so the same chat UI works inside a matter.
@MainActor
public final class MattersController: ObservableObject {
    @Published public private(set) var matters: [MatterSummary] = []
    @Published public private(set) var selectedMatterID: String?
    @Published public private(set) var chatController: GlobalChatController?
    @Published public private(set) var researchController: ResearchSessionController?
    @Published public private(set) var authoritiesController: AuthoritiesController?
    @Published public private(set) var outputsController: StructuredOutputController?
    @Published public private(set) var documentsController: MatterDocumentsController?
    @Published public private(set) var documentQAController: DocumentQAController?
    @Published public private(set) var documentChronologyController: DocumentChronologyController?
    @Published public private(set) var billingProfileController: BillingProfileController?
    @Published public private(set) var draftingController: MatterDraftingController?

    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private let defaultSystemPrompt: String?
    private let documentQueue: DocumentProcessingQueue?
    private let isImportReady: (@MainActor () -> Bool)?

    public init(
        store: SupraStore,
        runtimeClient: any RuntimeClientProtocol,
        defaultSystemPrompt: String? = nil,
        documentQueue: DocumentProcessingQueue? = nil,
        isImportReady: (@MainActor () -> Bool)? = nil
    ) {
        self.store = store
        self.runtimeClient = runtimeClient
        self.defaultSystemPrompt = defaultSystemPrompt
        self.documentQueue = documentQueue
        self.isImportReady = isImportReady
    }

    public var selectedMatter: MatterSummary? {
        guard let selectedMatterID else { return nil }
        return matters.first { $0.id == selectedMatterID }
    }

    public func loadMatters() {
        reload()
        if let selectedMatterID, matters.contains(where: { $0.id == selectedMatterID }) {
            if chatController == nil { select(matterID: selectedMatterID) }
        } else {
            select(matterID: matters.first?.id)
        }
    }

    /// Creates a matter, its default matter chat, and a `matter_created` audit
    /// event, then selects it (spec §8.3).
    @discardableResult
    public func createMatter(_ draft: MatterDraft) throws -> MatterSummary {
        // Matter + default chat are created atomically by the repository so a
        // matter never exists without its chat (spec §8.3). The audit row stays
        // best-effort: an audit hiccup shouldn't fail matter creation.
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = try store.matters.createMatter(
            name: draft.name,
            jurisdiction: draft.jurisdiction,
            partyPerspective: draft.partyPerspective,
            court: draft.court,
            judge: draft.judge,
            docketNumber: draft.docketNumber,
            practiceArea: draft.practiceArea,
            clientNames: draft.clientNames,
            matterDescription: draft.matterDescription,
            internalMatterID: draft.internalMatterID,
            clientID: draft.clientID,
            clientMatterID: draft.clientMatterID,
            notes: draft.notes,
            defaultChatTitle: "General — \(trimmedName)"
        )
        _ = try? store.auditEvents.recordEvent(
            matterID: record.id,
            eventType: "matter_created",
            actor: "user",
            summary: "Created matter “\(record.name)”"
        )
        reload()
        select(matterID: record.id)
        return MatterSummary(record: record)
    }

    /// Convenience used by callers that only have a name (defaults the required
    /// jurisdiction); the full create flow uses `createMatter(_:)`.
    @discardableResult
    public func createMatter(name: String = "New Matter") throws -> MatterSummary {
        try createMatter(MatterDraft(name: name, jurisdiction: "Unspecified"))
    }

    /// The editable draft for an existing matter, or nil if it no longer exists.
    public func draft(forMatter id: String) -> MatterDraft? {
        guard let record = try? store.matters.fetchMatter(id: id) else { return nil }
        return MatterDraft(record: record)
    }

    public func updateMatter(id: String, draft: MatterDraft) throws {
        try store.matters.updateMatter(
            id: id,
            name: draft.name,
            jurisdiction: draft.jurisdiction,
            partyPerspective: draft.partyPerspective,
            court: draft.court,
            judge: draft.judge,
            docketNumber: draft.docketNumber,
            practiceArea: draft.practiceArea,
            clientNames: draft.clientNames,
            matterDescription: draft.matterDescription,
            internalMatterID: draft.internalMatterID,
            clientID: draft.clientID,
            clientMatterID: draft.clientMatterID,
            notes: draft.notes
        )
        _ = try? store.auditEvents.recordEvent(
            matterID: id,
            eventType: "matter_updated",
            actor: "user",
            summary: "Updated matter details"
        )
        reload()
    }

    /// Soft-deletes a matter. The spec's audit event_type set has no
    /// matter_deleted, so no audit event is written (stays within the contract).
    public func deleteMatter(id: String) {
        try? store.matters.softDeleteMatter(id: id)
        reload()
        if selectedMatterID == id || !matters.contains(where: { $0.id == selectedMatterID }) {
            select(matterID: matters.first?.id)
        }
    }

    public func auditEntries(forMatter id: String) -> [MatterAuditEntry] {
        ((try? store.auditEvents.fetchEvents(matterID: id)) ?? []).map {
            MatterAuditEntry(
                id: $0.id,
                timestamp: $0.timestamp,
                eventType: $0.eventType,
                actor: $0.actor,
                summary: $0.summary
            )
        }
    }

    public func select(matterID: String?) {
        selectedMatterID = matterID
        guard let matterID else {
            chatController = nil
            researchController = nil
            authoritiesController = nil
            outputsController = nil
            documentsController = nil
            documentQAController = nil
            documentChronologyController = nil
            billingProfileController = nil
            draftingController = nil
            return
        }
        // Built once and shared by every controller that retrieves over the matter's
        // documents (chat grounding, outputs, document Q&A), so a single embedding
        // model selection drives them all.
        let embedder = (try? store.documentSettings.fetchSelectedEmbeddingModel())
            .flatMap { RuntimeTextEmbedder(model: $0, runtimeClient: runtimeClient) }

        // Matter chat reads the user's composed soul document fresh at send time
        // (see `SupraStore.composedAssistantPrompt(base:)`), layered OVER the route's
        // task prompt, so profile edits apply without reselecting the matter. The
        // structured-output and document-Q&A workflows layer it over their task base
        // too (the task/grounding contract still leads). The research query-planner
        // and fact chronology stay base-only — their output is machine-parsed into a
        // required structure that a free-form profile must not perturb.
        // The embedder lets matter chat ground answers in the matter's own documents
        // (folder inventories + retrieval) instead of fabricating them.
        let controller = GlobalChatController(
            store: store,
            runtimeClient: runtimeClient,
            defaultSystemPrompt: defaultSystemPrompt,
            scope: .matter(id: matterID),
            embedder: embedder
        )
        controller.loadChats()
        chatController = controller

        let research = ResearchSessionController(
            store: store,
            runtimeClient: runtimeClient,
            matterID: matterID,
            defaultSystemPrompt: defaultSystemPrompt
        )
        research.loadSessions()
        researchController = research

        let authorities = AuthoritiesController(store: store, matterID: matterID, runtimeClient: runtimeClient)
        authorities.load()
        authoritiesController = authorities

        let outputs = StructuredOutputController(
            store: store,
            runtimeClient: runtimeClient,
            matterID: matterID,
            embedder: embedder,
            defaultSystemPrompt: defaultSystemPrompt
        )
        outputs.loadOutputs()
        outputsController = outputs

        if let documentQueue {
            documentsController = MatterDocumentsController(
                matterID: matterID,
                store: store,
                queue: documentQueue,
                isImportReady: isImportReady ?? { true }
            )
        } else {
            documentsController = nil
        }

        documentQAController = DocumentQAController(
            matterID: matterID,
            store: store,
            runtimeClient: runtimeClient,
            embedder: embedder,
            defaultSystemPrompt: defaultSystemPrompt
        )
        documentChronologyController = DocumentChronologyController(
            matterID: matterID,
            store: store,
            runtimeClient: runtimeClient,
            defaultSystemPrompt: defaultSystemPrompt
        )
        billingProfileController = BillingProfileController(
            matterID: matterID,
            store: store,
            queue: documentQueue,
            isImportReady: isImportReady ?? { true }
        )
        draftingController = MatterDraftingController(store: store, runtimeClient: runtimeClient)
    }

    private func reload() {
        matters = (try? store.matters.fetchMatters())?.map(MatterSummary.init) ?? matters
    }
}
