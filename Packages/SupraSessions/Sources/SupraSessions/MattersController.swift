import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraResearch
import SupraRuntimeClient
import SupraStore

/// A view-facing snapshot of a matter (a legal workspace that groups chats,
/// research, authorities, and outputs).
public struct MatterSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var jurisdiction: String
    public var court: String?
    public var practiceArea: String?
    public var clientNames: String?
    public var matterDescription: String?
    public var internalMatterID: String?
    /// LEDES `CLIENT_ID` (e-billing).
    public var clientID: String?
    /// LEDES `CLIENT_MATTER_ID` (e-billing).
    public var clientMatterID: String?
    public var partyPerspective: PartyPerspective
    public var createdAt: Date
    public var updatedAt: Date
    /// Position under the sidebar's manual sort; nil = never manually placed.
    public var sortOrder: Int?
    /// When the matter was pinned to the top of the sidebar; nil = not pinned.
    public var pinnedAt: Date?

    public var isPinned: Bool { pinnedAt != nil }

    init(record: MatterRecord) {
        self.id = record.id
        self.name = record.name
        self.jurisdiction = record.jurisdiction
        self.court = record.court
        self.practiceArea = record.practiceArea
        self.clientNames = record.clientNames
        self.matterDescription = record.matterDescription
        self.internalMatterID = record.internalMatterID
        self.clientID = record.clientID
        self.clientMatterID = record.clientMatterID
        self.partyPerspective = PartyPerspective(rawValue: record.partyPerspective) ?? .neutral
        self.createdAt = record.createdAt
        self.updatedAt = record.updatedAt
        self.sortOrder = record.sortOrder
        self.pinnedAt = record.pinnedAt
    }

    /// Canonical client-group identity, set by the controller from the
    /// ClientDirectory after each load: matters of the same client share this
    /// key even across name spellings or a missing client number, and the label
    /// is the canonical spelling. Empty key = no client info.
    public internal(set) var clientGroupKey: String = ""
    public internal(set) var clientGroupLabel: String?

    /// Canonical practice-area spelling for the group label (the raw field can
    /// be a minority spelling variant). Set by the controller after each load.
    public internal(set) var practiceAreaGroupLabel: String?

    /// What the sidebar shows for the client group: the human name, falling back
    /// to the client number for matters that only carry an ID.
    public var clientDisplayName: String? {
        if let clientNames, !clientNames.isEmpty { return clientNames }
        if let clientID, !clientID.isEmpty { return "Client \(clientID)" }
        return nil
    }

    /// Groups matters of the same practice area across spelling case variants;
    /// empty for matters without one. Locale nil so the key never shifts with
    /// the user's locale.
    public var practiceAreaGroupKey: String {
        guard let practiceArea, !practiceArea.isEmpty else { return "" }
        return practiceArea.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// How the sidebar orders the matter list. Raw values are persisted in
/// UserDefaults, so they must stay stable.
public enum MatterSortMode: String, CaseIterable, Sendable {
    /// Grouped by client, groups ordered by client number (LEDES `CLIENT_ID`),
    /// shown under the client's name.
    case client
    /// Grouped by practice area, groups ordered alphabetically.
    case practiceArea
    case name
    case dateCreated
    case dateModified
    case manual

    public var title: String {
        switch self {
        case .client: return "Client"
        case .practiceArea: return "Practice Area"
        case .name: return "Name"
        case .dateCreated: return "Date Created"
        case .dateModified: return "Date Modified"
        case .manual: return "Manual"
        }
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

/// Exact legal-identity payload owned by the Matter editor. Court identifiers
/// come only from an explicit catalog selection; the legacy strings remain
/// preserved evidence and are never used to infer structured parties.
public struct MatterIdentityEditorSubmission: Sendable, Equatable {
    public let matterID: String
    public let expectedIdentityRevision: Int?
    public var draft: MatterDraft
    public var courtResolutionState: MatterCourtResolutionState
    public var canonicalJurisdictionID: CanonicalJurisdictionID?
    public var canonicalCourtID: CanonicalCourtID?
    public let parties: [MatterPartyIdentity]
    public let representations: [MatterRepresentationIdentity]

    public init(
        matterID: String,
        expectedIdentityRevision: Int?,
        draft: MatterDraft,
        courtResolutionState: MatterCourtResolutionState,
        canonicalJurisdictionID: CanonicalJurisdictionID?,
        canonicalCourtID: CanonicalCourtID?,
        parties: [MatterPartyIdentity],
        representations: [MatterRepresentationIdentity]
    ) {
        self.matterID = matterID
        self.expectedIdentityRevision = expectedIdentityRevision
        self.draft = draft
        self.courtResolutionState = courtResolutionState
        self.canonicalJurisdictionID = canonicalJurisdictionID
        self.canonicalCourtID = canonicalCourtID
        self.parties = parties
        self.representations = representations
    }
}

public enum MatterIdentityEditorError: Error, LocalizedError, Equatable, Sendable {
    case createExpected
    case updateExpected
    case matterUnavailable
    case invalidCourtSelection

    public var errorDescription: String? {
        switch self {
        case .createExpected:
            "This matter already has a saved identity revision. Reopen it in Edit."
        case .updateExpected:
            "The saved matter identity is unavailable. Close and reopen Edit."
        case .matterUnavailable:
            "The matter could not be loaded. Close and reopen the matter, then try again."
        case .invalidCourtSelection:
            "Choose a court from the canonical results, choose a jurisdiction, or mark the court not applicable."
        }
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
    @Published public private(set) var sortMode: MatterSortMode
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
    @Published public private(set) var lastMutationFailure: UserMutationFailure?

    private let store: SupraStore
    private let runtimeClient: any ModelExecutionGateway
    private let defaultSystemPrompt: String?
    private let documentQueue: DocumentProcessingQueue?
    private let isImportReady: (@MainActor () -> Bool)?
    private let defaults: UserDefaults
    private let draftingStorage: DocumentStorage?
    private let beforeMotionPersistence: MatterDraftingController.AsyncDraftCheckpoint?

    private static let sortModeKey = "supra.matterSortMode"

    public init(
        store: SupraStore,
        runtimeClient: any ModelExecutionGateway,
        defaultSystemPrompt: String? = nil,
        documentQueue: DocumentProcessingQueue? = nil,
        isImportReady: (@MainActor () -> Bool)? = nil,
        draftingStorage: DocumentStorage? = nil,
        beforeMotionPersistence: MatterDraftingController.AsyncDraftCheckpoint? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.runtimeClient = runtimeClient
        self.defaultSystemPrompt = defaultSystemPrompt
        self.documentQueue = documentQueue
        self.isImportReady = isImportReady
        self.draftingStorage = draftingStorage
        self.beforeMotionPersistence = beforeMotionPersistence
        self.defaults = defaults
        self.sortMode = defaults.string(forKey: Self.sortModeKey)
            .flatMap(MatterSortMode.init(rawValue:)) ?? .dateModified
    }

    public var selectedMatter: MatterSummary? {
        guard let selectedMatterID else { return nil }
        return matters.first { $0.id == selectedMatterID }
    }

    /// Publishes the matter list (its current value, then every change) for observers
    /// that must stay in lockstep with it — e.g. the ScratchPad `@matter` autocomplete
    /// registry, so a matter created while the app is running is mentionable at once.
    public var mattersPublisher: AnyPublisher<[MatterSummary], Never> {
        $matters.eraseToAnyPublisher()
    }

    /// Starts a create flow with a stable request identity so a visible retry
    /// addresses the same atomic Store command instead of creating a lookalike.
    public func newMatterIdentityEditorSubmission() -> MatterIdentityEditorSubmission {
        MatterIdentityEditorSubmission(
            matterID: UUID().uuidString,
            expectedIdentityRevision: nil,
            draft: MatterDraft(),
            courtResolutionState: .unresolved,
            canonicalJurisdictionID: nil,
            canonicalCourtID: nil,
            parties: [],
            representations: []
        )
    }

    /// Returns the legacy detail fields and the exact structured identity from
    /// one persisted matter. The editor submits only explicit structured graph
    /// edits; clientNames is never parsed into a party or representation.
    public func identityEditorSubmission(
        forMatter id: String
    ) -> MatterIdentityEditorSubmission? {
        guard let record = try? store.matters.fetchMatter(id: id),
              let snapshot = try? store.matterIdentity.fetchSnapshot(matterID: id),
              snapshot.matterID == record.id else { return nil }
        return MatterIdentityEditorSubmission(
            matterID: id,
            expectedIdentityRevision: snapshot.identityRevision,
            draft: MatterDraft(record: record),
            courtResolutionState: snapshot.courtResolutionState,
            canonicalJurisdictionID: snapshot.canonicalJurisdictionID,
            canonicalCourtID: snapshot.canonicalCourtID,
            parties: snapshot.parties,
            representations: snapshot.representations
        )
    }

    /// Shipping presentation boundary for headers, research, and filing gates.
    /// The builder fails closed when IDs, relationship, catalog version, or
    /// digest do not describe one coherent selected court.
    public func courtPresentation(forMatter id: String) -> MatterCourtPresentation? {
        guard let snapshot = try? store.matterIdentity.fetchSnapshot(matterID: id) else {
            return nil
        }
        return MatterCourtPresentationBuilder(catalog: .shared)
            .makePresentation(for: snapshot)
    }

    public func loadMatters() {
        reload()
        if let selectedMatterID, matters.contains(where: { $0.id == selectedMatterID }) {
            if chatController == nil { select(matterID: selectedMatterID) }
        } else {
            select(matterID: matters.first?.id)
        }
    }

    /// Compatibility create for callers that have not adopted the structured
    /// editor payload. The legacy court text is retained as evidence, but the
    /// new matter is explicitly unresolved and is written only through the
    /// canonical aggregate; free text never acquires canonical authority.
    @discardableResult
    public func createMatter(_ draft: MatterDraft) throws -> MatterSummary {
        let result = try createMatter(
            identity: MatterIdentityEditorSubmission(
                matterID: UUID().uuidString,
                expectedIdentityRevision: nil,
                draft: draft,
                courtResolutionState: .unresolved,
                canonicalJurisdictionID: nil,
                canonicalCourtID: nil,
                parties: [],
                representations: []
            )
        )
        lastMutationFailure = nil
        return result
    }

    /// Creates the complete workspace and Store-owned identity graph in one
    /// transaction. A failed command cannot publish a matter missing its chat,
    /// audit receipt, ancillary fields, or starter folders.
    @discardableResult
    public func createMatter(
        identity submission: MatterIdentityEditorSubmission
    ) throws -> MatterSummary {
        guard submission.expectedIdentityRevision == nil else {
            throw MatterIdentityEditorError.createExpected
        }
        try Self.validateCanonicalSelection(submission)
        let normalized = try Self.normalizedIdentityEvidence(submission.draft)
        _ = try store.matterIdentity.createMatter(
            command: MatterIdentityCreateCommand(
                matterID: submission.matterID,
                name: normalized.name,
                legacyJurisdictionText: normalized.jurisdiction,
                legacyCourtText: normalized.court,
                legacyPartyPerspective: submission.draft.partyPerspective,
                legacyClientNames: normalized.clientNames,
                courtResolutionState: submission.courtResolutionState,
                canonicalCatalogVersion: JurisdictionCatalog.shared.catalogVersion,
                canonicalCatalogDigestSHA256: JurisdictionCatalog.shared.identityDigestSHA256,
                canonicalJurisdictionID: submission.canonicalJurisdictionID,
                canonicalCourtID: submission.canonicalCourtID,
                parties: submission.parties,
                representations: submission.representations,
                workspaceDetails: Self.workspaceDetails(
                    draft: submission.draft,
                    normalizedName: normalized.name,
                    starterFolderNames: PracticeAreaFolderTemplates.folders(
                        forPracticeArea: submission.draft.practiceArea
                    )
                )
            )
        )
        reload()
        select(matterID: submission.matterID)
        guard let record = try store.matters.fetchMatter(id: submission.matterID) else {
            throw MatterIdentityEditorError.matterUnavailable
        }
        return MatterSummary(record: record)
    }

    /// User-facing create boundary. A failed aggregate write leaves the draft
    /// with its caller and cannot select or navigate into an uncommitted matter.
    public func attemptCreateMatter(
        _ draft: MatterDraft
    ) -> UserMutationOutcome<MatterSummary> {
        do {
            return .committed(try createMatter(draft))
        } catch {
            return rejectMutation(
                .matterCreate,
                message: "Couldn’t create the matter. \(error.localizedDescription)",
                recoveryActions: error is MatterIdentityEditorError
                    ? [.correctInput] : [.retry, .correctInput]
            )
        }
    }

    /// Canonical editor create boundary. Presentation consumes the committed
    /// matter ID and cannot route into an aggregate that failed to persist.
    public func attemptCreateMatter(
        identity submission: MatterIdentityEditorSubmission
    ) -> UserMutationOutcome<String> {
        do {
            return .committed(try createMatter(identity: submission).id)
        } catch {
            return rejectMutation(
                .matterCreate,
                message: "Couldn’t create the matter. \(error.localizedDescription)",
                recoveryActions: error is MatterIdentityEditorError
                    ? [.correctInput] : [.retry, .correctInput]
            )
        }
    }

    /// Convenience used by callers that only have a name (defaults the required
    /// jurisdiction); the full create flow uses `createMatter(_:)`.
    @discardableResult
    public func createMatter(name: String = "New Matter") throws -> MatterSummary {
        try createMatter(MatterDraft(name: name, jurisdiction: "Unspecified"))
    }

    /// The known clients (numbers + canonical names) aggregated from existing
    /// matters, rebuilt fresh for each matter form so recommendations always
    /// reflect the current data.
    public func clientDirectory() -> ClientDirectory {
        ClientDirectory.build(from: (try? store.matters.fetchClientUsage()) ?? [])
    }

    /// The known practice areas aggregated from existing matters, for the matter
    /// form's suggestions.
    public func practiceAreaDirectory() -> PracticeAreaDirectory {
        PracticeAreaDirectory.build(from: (try? store.matters.fetchPracticeAreaUsage()) ?? [])
    }

    /// Seeds a matter's practice-area starter set through the same idempotent
    /// folder identity used by imports and manual creation. Public for the
    /// direct-store demo fixture path, which intentionally bypasses createMatter.
    public func seedStarterFolders(matterID: String, practiceArea: String) {
        for folderName in PracticeAreaFolderTemplates.folders(forPracticeArea: practiceArea) {
            _ = try? store.documentLibrary.ensureFolder(matterID: matterID, name: folderName)
        }
    }

    /// The editable draft for an existing matter, or nil if it no longer exists.
    public func draft(forMatter id: String) -> MatterDraft? {
        guard let record = try? store.matters.fetchMatter(id: id) else { return nil }
        return MatterDraft(record: record)
    }

    /// Compatibility update retains the existing structured party graph but
    /// explicitly clears court authority. A caller with only free-text fields
    /// cannot silently overwrite or preserve a previously resolved court.
    public func updateMatter(id: String, draft: MatterDraft) throws {
        guard let snapshot = try store.matterIdentity.fetchSnapshot(matterID: id) else {
            throw MatterIdentityEditorError.matterUnavailable
        }
        try updateMatter(
            identity: MatterIdentityEditorSubmission(
                matterID: id,
                expectedIdentityRevision: snapshot.identityRevision,
                draft: draft,
                courtResolutionState: .unresolved,
                canonicalJurisdictionID: nil,
                canonicalCourtID: nil,
                parties: snapshot.parties,
                representations: snapshot.representations
            )
        )
        lastMutationFailure = nil
    }

    /// User-facing edit boundary. The editor dismisses only for `.committed`;
    /// the submitted draft remains owned by the caller on failure.
    public func attemptUpdateMatter(
        id: String,
        draft: MatterDraft
    ) -> UserMutationOutcome<String> {
        do {
            try updateMatter(id: id, draft: draft)
            return .committed(id)
        } catch {
            return rejectMutation(
                .matterEdit,
                message: "Couldn’t save the matter changes. \(error.localizedDescription)",
                recoveryActions: error is MatterIdentityEditorError
                    ? [.correctInput] : [.retry, .correctInput]
            )
        }
    }

    /// Canonical editor update boundary. The submitted identity graph remains
    /// with the sheet until this returns a committed matter ID.
    public func attemptUpdateMatter(
        identity submission: MatterIdentityEditorSubmission
    ) -> UserMutationOutcome<String> {
        do {
            try updateMatter(identity: submission)
            lastMutationFailure = nil
            return .committed(submission.matterID)
        } catch {
            return rejectMutation(
                .matterEdit,
                message: "Couldn’t save the matter changes. \(error.localizedDescription)",
                recoveryActions: error is MatterIdentityEditorError
                    ? [.correctInput] : [.retry, .correctInput]
            )
        }
    }

    /// Soft-deletes a matter. The spec's audit event_type set has no
    /// matter_deleted, so no audit event is written (stays within the contract).
    public func deleteMatter(id: String) {
        _ = attemptDeleteMatter(id: id)
    }

    /// Soft-delete is authoritative before selection changes. A failed write
    /// leaves the visible matter and its controller scope selected.
    public func attemptDeleteMatter(id: String) -> UserMutationOutcome<String> {
        do {
            try store.matters.softDeleteMatter(id: id)
            reload()
            if selectedMatterID == id || !matters.contains(where: { $0.id == selectedMatterID }) {
                select(matterID: matters.first?.id)
            }
            lastMutationFailure = nil
            return .committed(id)
        } catch {
            reload()
            return rejectMutation(
                .matterDelete,
                message: "Couldn’t move the matter to the Recycle Bin. \(error.localizedDescription)"
            )
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
        // documents (chat grounding, outputs, document Q&A), so a single embedding model selection
        // drives them all.
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
        draftingController = MatterDraftingController(
            store: store,
            runtimeClient: runtimeClient,
            storage: draftingStorage ?? .makeDefault(),
            beforeMotionPersistence: beforeMotionPersistence
        )
    }

    /// Pins or unpins a matter; pinned matters float to the top of the sidebar
    /// in every sort mode.
    public func setPinned(matterID: String, pinned: Bool) {
        _ = attemptSetPinned(matterID: matterID, pinned: pinned)
    }

    public func attemptSetPinned(
        matterID: String,
        pinned: Bool
    ) -> UserMutationOutcome<String> {
        do {
            try store.matters.setMatterPinned(id: matterID, pinned: pinned)
            reload()
            lastMutationFailure = nil
            return .committed(matterID)
        } catch {
            reload()
            return rejectMutation(
                .matterPin,
                message: "Couldn’t update the matter’s pinned state. \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Sorting

    /// Switches the sidebar sort and persists the choice. Entering manual mode for
    /// the first time (no matter has ever been placed) bakes in the order the user
    /// is currently looking at, so the list doesn't jump; afterwards the saved
    /// manual order is restored whenever they come back to it.
    public func setSortMode(_ mode: MatterSortMode) {
        _ = attemptSetSortMode(mode)
    }

    /// Retains the selected candidate in the sidebar while committing the
    /// first manual order before persisting that mode as authoritative.
    public func attemptSetSortMode(
        _ mode: MatterSortMode
    ) -> UserMutationOutcome<MatterSortMode> {
        sortMode = mode
        do {
            if mode == .manual, matters.allSatisfy({ $0.sortOrder == nil }) {
                try store.matters.updateMatterSortOrder(orderedIDs: matters.map(\.id))
            }
            defaults.set(mode.rawValue, forKey: Self.sortModeKey)
            reload()
            lastMutationFailure = nil
            return .committed(mode)
        } catch {
            reload()
            return rejectMutation(
                .matterReorder,
                message: "Couldn’t save the matter order. \(error.localizedDescription)"
            )
        }
    }

    /// Replaces court identity and its unchanged party graph in one optimistic
    /// Store command. A stale editor revision is surfaced to the caller.
    public func updateMatter(
        identity submission: MatterIdentityEditorSubmission
    ) throws {
        guard let expectedRevision = submission.expectedIdentityRevision else {
            throw MatterIdentityEditorError.updateExpected
        }
        try Self.validateCanonicalSelection(submission)
        let normalized = try Self.normalizedIdentityEvidence(submission.draft)
        _ = try store.matterIdentity.updateMatter(
            command: MatterIdentityUpdateCommand(
                matterID: submission.matterID,
                expectedIdentityRevision: expectedRevision,
                legacyJurisdictionText: normalized.jurisdiction,
                legacyCourtText: normalized.court,
                legacyPartyPerspective: submission.draft.partyPerspective,
                legacyClientNames: normalized.clientNames,
                courtResolutionState: submission.courtResolutionState,
                canonicalCatalogVersion: JurisdictionCatalog.shared.catalogVersion,
                canonicalCatalogDigestSHA256: JurisdictionCatalog.shared.identityDigestSHA256,
                canonicalJurisdictionID: submission.canonicalJurisdictionID,
                canonicalCourtID: submission.canonicalCourtID,
                parties: submission.parties,
                representations: submission.representations,
                workspaceDetails: Self.workspaceDetails(
                    draft: submission.draft,
                    normalizedName: normalized.name
                )
            )
        )
        reload()
    }

    private struct NormalizedIdentityEvidence {
        let name: String
        let jurisdiction: String
        let court: String?
        let clientNames: String?
    }

    private static func normalizedIdentityEvidence(
        _ draft: MatterDraft
    ) throws -> NormalizedIdentityEvidence {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let jurisdiction = draft.jurisdiction
        guard !name.isEmpty,
              !jurisdiction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MatterIdentityEditorError.invalidCourtSelection
        }
        return NormalizedIdentityEvidence(
            name: name,
            jurisdiction: jurisdiction,
            court: nonemptyEvidence(draft.court),
            clientNames: nonemptyEvidence(draft.clientNames)
        )
    }

    private static func nonemptyEvidence(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : value
    }

    private static func nonemptyTrimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func validateCanonicalSelection(
        _ submission: MatterIdentityEditorSubmission
    ) throws {
        let catalog = JurisdictionCatalog.shared
        switch submission.courtResolutionState {
        case .unresolved, .notApplicable:
            guard submission.canonicalJurisdictionID == nil,
                  submission.canonicalCourtID == nil else {
                throw MatterIdentityEditorError.invalidCourtSelection
            }
        case .jurisdictionOnly:
            guard let jurisdictionID = submission.canonicalJurisdictionID?.rawValue,
                  submission.canonicalCourtID == nil,
                  let selected = catalog.option(id: jurisdictionID),
                  selected.level == .jurisdiction,
                  catalog.canonicalJurisdictionOption(
                    forSelectedOptionID: selected.id
                  )?.id == jurisdictionID else {
                throw MatterIdentityEditorError.invalidCourtSelection
            }
        case .court:
            guard let jurisdictionID = submission.canonicalJurisdictionID?.rawValue,
                  let courtID = submission.canonicalCourtID?.rawValue,
                  let selectedCourt = catalog.option(id: courtID),
                  selectedCourt.level != .jurisdiction,
                  catalog.canonicalJurisdictionOption(
                    forSelectedOptionID: selectedCourt.id
                  )?.id == jurisdictionID else {
                throw MatterIdentityEditorError.invalidCourtSelection
            }
        }
    }

    private static func workspaceDetails(
        draft: MatterDraft,
        normalizedName: String,
        starterFolderNames: [String] = []
    ) -> MatterIdentityWorkspaceDetails {
        MatterIdentityWorkspaceDetails(
            name: normalizedName,
            judge: nonemptyTrimmed(draft.judge),
            docketNumber: nonemptyTrimmed(draft.docketNumber),
            practiceArea: nonemptyTrimmed(draft.practiceArea),
            matterDescription: nonemptyTrimmed(draft.matterDescription),
            internalMatterID: nonemptyTrimmed(draft.internalMatterID),
            clientID: nonemptyTrimmed(draft.clientID),
            clientMatterID: nonemptyTrimmed(draft.clientMatterID),
            notes: nonemptyTrimmed(draft.notes),
            starterFolderNames: starterFolderNames
        )
    }

    /// Drag-to-reorder for manual mode: applies the move to the visible list and
    /// persists the resulting order. Same semantics as SwiftUI's
    /// `move(fromOffsets:toOffset:)` (destination is an offset into the
    /// pre-removal list), reimplemented here because that helper lives in SwiftUI
    /// and this package doesn't link it.
    public func moveMatters(fromOffsets source: IndexSet, toOffset destination: Int) {
        _ = attemptMoveMatters(fromOffsets: source, toOffset: destination)
    }

    public func attemptMoveMatters(
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> UserMutationOutcome<[String]> {
        guard sortMode == .manual else {
            return .committed(matters.map(\.id))
        }
        // Pinned rows always float above the list, so a drag may not cross the
        // pinned/unpinned boundary — otherwise the drop would silently snap
        // back on the re-partition. Pinned rows themselves aren't draggable
        // (`.moveDisabled` in the sidebar); here the drop TARGET is clamped
        // below the pinned block.
        let pinnedCount = matters.prefix(while: \.isPinned).count
        guard source.allSatisfy({ $0 >= pinnedCount }) else {
            return .committed(matters.map(\.id))
        }
        let clampedDestination = max(destination, pinnedCount) - pinnedCount

        // Reorder only the visible unpinned suffix. Pinned rows occupy fixed
        // slots in the latent manual order so unpinning returns them to the
        // position they held before they floated above the list.
        var reorderedUnpinned = matters.filter { !$0.isPinned }
        let unpinnedSource = IndexSet(source.compactMap { visibleIndex in
            let index = visibleIndex - pinnedCount
            return reorderedUnpinned.indices.contains(index) ? index : nil
        })
        guard !unpinnedSource.isEmpty else {
            return .committed(matters.map(\.id))
        }
        let moved = unpinnedSource.sorted(by: >).map { index in
            reorderedUnpinned.remove(at: index)
        }
        let insertion = clampedDestination
            - unpinnedSource.count(where: { $0 < clampedDestination })
        reorderedUnpinned.insert(
            contentsOf: moved.reversed(),
            at: min(insertion, reorderedUnpinned.count)
        )

        var unpinnedIterator = reorderedUnpinned.makeIterator()
        let latentOrder = Self.orderedByMode(matters, .manual).compactMap { matter in
            matter.isPinned ? matter : unpinnedIterator.next()
        }
        do {
            try store.matters.updateMatterSortOrder(orderedIDs: latentOrder.map(\.id))
            reload()
            lastMutationFailure = nil
            return .committed(matters.map(\.id))
        } catch {
            reload()
            return rejectMutation(
                .matterReorder,
                message: "Couldn’t save the matter order. \(error.localizedDescription)"
            )
        }
    }

    private func rejectMutation<Success>(
        _ operation: UserMutationOperation,
        message: String,
        recoveryActions: Set<UserMutationRecoveryAction> = [.retry]
    ) -> UserMutationOutcome<Success> {
        let failure = UserMutationFailure(
            operation: operation,
            userMessage: message,
            recoveryActions: recoveryActions
        )
        lastMutationFailure = failure
        return .failed(failure)
    }

    private func reload() {
        var loaded = (try? store.matters.fetchMatters())?.map(MatterSummary.init) ?? matters
        Self.canonicalizeGroupIdentities(&loaded)
        matters = Self.sorted(loaded, by: sortMode)
    }

    /// Stamps each summary with its canonical client-group key/label and
    /// practice-area label, so the sidebar's grouping (and the client-sort
    /// comparator) agree with the directories about what "the same client" or
    /// "the same practice area" is — folded spellings collapse, and a name-only
    /// matter joins the numbered client it unambiguously matches.
    static func canonicalizeGroupIdentities(_ matters: inout [MatterSummary]) {
        let clientDirectory = ClientDirectory.build(from: matters.map {
            MattersRepository.ClientUsageRow(clientID: $0.clientID, clientNames: $0.clientNames, matterCount: 1, lastUsedAt: $0.updatedAt)
        })
        let practiceAreas = PracticeAreaDirectory.build(from: matters.compactMap { matter in
            matter.practiceArea.map { MattersRepository.PracticeAreaUsageRow(name: $0, matterCount: 1) }
        })
        for index in matters.indices {
            let identity = clientDirectory.groupIdentity(
                clientID: matters[index].clientID,
                clientNames: matters[index].clientNames
            )
            matters[index].clientGroupKey = identity?.key ?? ""
            matters[index].clientGroupLabel = identity?.label
            matters[index].practiceAreaGroupLabel = matters[index].practiceArea
                .flatMap(practiceAreas.canonicalName(for:))
        }
    }

    /// Applies the sort mode, then floats pinned matters to the top. Pinning
    /// only partitions the list — within each half the mode's order holds, so
    /// pinned matters stay predictable across every sort.
    static func sorted(_ matters: [MatterSummary], by mode: MatterSortMode) -> [MatterSummary] {
        let ordered = orderedByMode(matters, mode)
        return ordered.filter(\.isPinned) + ordered.filter { !$0.isPinned }
    }

    private static func orderedByMode(_ matters: [MatterSummary], _ mode: MatterSortMode) -> [MatterSummary] {
        switch mode {
        case .client:
            // Groups ordered by client number (numeric-aware, so client 9 precedes
            // client 10); matters without any client info trail. Within a client,
            // matters read alphabetically. Clients known only by name sort after
            // all numbered clients — the "id:"/"name:" key prefixes encode that
            // deliberately (number-identified clients are the organized ones).
            return matters.sorted { lhs, rhs in
                switch (lhs.clientGroupKey.isEmpty, rhs.clientGroupKey.isEmpty) {
                case (true, false): return false
                case (false, true): return true
                default: break
                }
                if lhs.clientGroupKey != rhs.clientGroupKey {
                    return lhs.clientGroupKey.localizedStandardCompare(rhs.clientGroupKey) == .orderedAscending
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        case .practiceArea:
            // Groups alphabetical by practice area (case-insensitive), matters
            // without one trailing; alphabetical within a group.
            return matters.sorted { lhs, rhs in
                switch (lhs.practiceAreaGroupKey.isEmpty, rhs.practiceAreaGroupKey.isEmpty) {
                case (true, false): return false
                case (false, true): return true
                default: break
                }
                if lhs.practiceAreaGroupKey != rhs.practiceAreaGroupKey {
                    return lhs.practiceAreaGroupKey.localizedStandardCompare(rhs.practiceAreaGroupKey) == .orderedAscending
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        case .name:
            return matters.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .dateCreated:
            return matters.sorted { $0.createdAt > $1.createdAt }
        case .dateModified:
            return matters.sorted { $0.updatedAt > $1.updatedAt }
        case .manual:
            // Never-placed matters (created after the order was set) trail the
            // placed ones, newest first among themselves.
            return matters.sorted { lhs, rhs in
                switch (lhs.sortOrder, rhs.sortOrder) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.updatedAt > rhs.updatedAt
                }
            }
        }
    }
}
