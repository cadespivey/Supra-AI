import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraDrafting
import SupraDraftingCore
import SupraExports
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

/// Generates a downloadable court/letter draft from a matter + the user's firm
/// profile, on device, via the `SupraDrafting` pipeline + `SupraExports` renderer.
///
/// This is the chat-facing bridge for the drafting engine shipped in 1.5.2: it
/// resolves slots from the matter (caption/parties) and the `AssistantProfile`
/// (firm identity), runs the pipeline, writes the `.docx` into the matter's
/// managed `exports/` directory, records an audit event, and returns the file URL
/// plus any firewall follow-ups (`[cite]` / `[fact?]` flags, missing slots) for the
/// attorney to review. Nothing is invented: if the firm identity is incomplete, or
/// a required caption field is missing, it returns a precise blocking prompt instead
/// of guessing.
@MainActor
public final class MatterDraftingController: ObservableObject {
    public typealias DraftAuditRecorder = (AuditEventRecord) throws -> Void
    public typealias MotionDraftAuditCommitter = (
        AuditEventRecord,
        MotionDraftStoreSnapshot
    ) throws -> Void
    public typealias AsyncDraftCheckpoint = @Sendable () async throws -> Void
    public typealias MotionCompensationCheckpoint = (_ publicURL: URL, _ quarantineURL: URL) throws -> Void
    public typealias DraftCompensationPreUnlinkCheckpoint = (_ quarantineURL: URL) throws -> Void

    public struct DraftArtifact: Sendable, Equatable {
        /// What produced this artifact — a wired catalog kind, or a free-form custom
        /// description. A custom artifact has no `DraftKindID`, so we never fake one.
        public let source: MatterDraftArtifactSource
        /// The on-disk format: a rendered `.docx` filing, or a markdown description/request.
        public let format: DraftArtifactFormat
        public let title: String
        public let fileURL: URL
        public let followUps: [DraftFollowUp]

        /// Advisory/blocking notes the attorney must review before relying on the draft.
        public var reviewNotes: [String] { followUps.map(\.message) }
        public var hasBlocking: Bool { followUps.contains { $0.isBlocking } }
    }

    public struct DraftFollowUp: Sendable, Equatable {
        public let isBlocking: Bool
        public let message: String
    }

    public struct InterruptedDraftRecovery: Sendable, Equatable, Identifiable {
        public let id: String
        public let intentID: String
        public let fileName: String?
        public let fileURL: URL?

        public init(id: String, intentID: String, fileName: String?, fileURL: URL?) {
            self.id = id
            self.intentID = intentID
            self.fileName = fileName
            self.fileURL = fileURL
        }
    }

    public enum DraftError: Error, LocalizedError, Equatable {
        case matterNotFound
        case incompleteFirmProfile(missing: [String])
        case missingCaptionField(String)
        case missingRequiredSlots([String])
        case motionBlocked([String])
        case unsupportedJurisdiction(String)
        case unsupportedKind(DraftKindID)
        case emptyDescription
        case cancelled
        case verificationBlocked([String])
        case renderFailed(String)

        public var errorDescription: String? {
            switch self {
            case .matterNotFound:
                return "The matter to draft for was not found."
            case .emptyDescription:
                return "Describe the work product you want before generating."
            case let .incompleteFirmProfile(missing):
                return "Complete your firm profile in Settings before drafting — still needed: \(missing.joined(separator: ", "))."
            case let .missingCaptionField(field):
                return "This matter is missing its \(field). Add it to the matter before drafting a court filing."
            case let .missingRequiredSlots(slots):
                return "Complete the required drafting fields — still needed: \(slots.joined(separator: ", "))."
            case let .motionBlocked(reasons):
                let detail = reasons.isEmpty ? "The motion inputs or selected sources are not ready." : reasons.joined(separator: " ")
                return "Motion generation was blocked before a file was created. \(detail)"
            case let .unsupportedJurisdiction(jurisdiction):
                return "This court-filing workflow is currently wired for Florida matters only. This matter looks like \(jurisdiction)."
            case let .unsupportedKind(kind):
                return "Drafting for \(kind.rawValue) isn't wired into chat yet."
            case .cancelled:
                return "Draft generation was cancelled before a file was created."
            case let .verificationBlocked(summaries):
                let detail = summaries.isEmpty ? "The content was not fully supported." : summaries.joined(separator: " ")
                return "Draft generation was blocked before a file was created. \(detail)"
            case let .renderFailed(detail):
                return "The draft could not be rendered: \(detail)."
            }
        }
    }

    @Published public private(set) var isGenerating = false
    @Published public var message: String?
    @Published public private(set) var legacyDraftsNeedReviewCount = 0
    @Published public private(set) var interruptedDraftRecoveries: [InterruptedDraftRecovery] = []

    private let store: SupraStore
    private let storage: DocumentStorage
    private let fileWriter: DurableFileWriter
    private let fileStampProvider: @Sendable () -> String
    private let auditRecorder: DraftAuditRecorder
    private let motionAuditCommitter: MotionDraftAuditCommitter
    private let pipelineFactory: @Sendable () -> DraftPipeline
    private let beforeMotionPersistence: AsyncDraftCheckpoint
    private let motionCompensationCheckpoint: MotionCompensationCheckpoint
    private let draftCompensationPreUnlinkCheckpoint: DraftCompensationPreUnlinkCheckpoint
    /// Deterministic test checkpoint for source-snapshot interleavings. The
    /// shipping default is inert; tests use it to prove display/evidence reads
    /// cannot be assembled from different database snapshots.
    var motionAuthoritySourceLoadCheckpoint: () throws -> Void = {}
    var motionFactSourceLoadCheckpoint: () throws -> Void = {}
    /// Present when the app can call the on-device model — required for the LLM-backed
    /// kinds (`letterDemand`). The deterministic notice and supported-motion
    /// paths work without it.
    private let runtimeClient: (any RuntimeClientProtocol)?
    /// The firm's structural style overrides (letterhead/caption/signature/…), or nil to use the
    /// house default. Injected as the raw value type; in the app, `FirmStyleProfileController`
    /// (M2) supplies its `.profile` here. `nil` ⇒ output is byte-for-byte `.defaultFL`.
    private let firmStyleProfile: FirmStyleProfile?

    public init(
        store: SupraStore,
        runtimeClient: (any RuntimeClientProtocol)? = nil,
        storage: DocumentStorage = .makeDefault(),
        fileWriter: DurableFileWriter = DurableFileWriter(),
        fileStampProvider: (@Sendable () -> String)? = nil,
        auditRecorder: DraftAuditRecorder? = nil,
        firmStyleProfile: FirmStyleProfile? = nil,
        pipelineFactory: (@Sendable () -> DraftPipeline)? = nil,
        beforeMotionPersistence: AsyncDraftCheckpoint? = nil,
        motionCompensationCheckpoint: MotionCompensationCheckpoint? = nil,
        draftCompensationPreUnlinkCheckpoint: DraftCompensationPreUnlinkCheckpoint? = nil,
        motionAuditCommitter: MotionDraftAuditCommitter? = nil
    ) {
        self.store = store
        self.runtimeClient = runtimeClient
        self.storage = storage
        self.fileWriter = fileWriter
        self.fileStampProvider = fileStampProvider ?? {
            "\(Self.fileStamp())-\(UUID().uuidString.lowercased())"
        }
        // These injectable closures are observation/fault checkpoints. Store's
        // intent repository owns the actual success audit transaction.
        self.auditRecorder = auditRecorder ?? { _ in }
        self.motionAuditCommitter = motionAuditCommitter ?? { _, _ in }
        self.firmStyleProfile = firmStyleProfile
        // Default: deterministic verifier + the court/letter renderers. Injectable for tests.
        self.pipelineFactory = pipelineFactory ?? { DraftPipeline.makeDefault() }
        self.beforeMotionPersistence = beforeMotionPersistence ?? {}
        self.motionCompensationCheckpoint = motionCompensationCheckpoint ?? { _, _ in }
        self.draftCompensationPreUnlinkCheckpoint = draftCompensationPreUnlinkCheckpoint ?? { _ in }
    }

    public func refreshLegacyDraftReviewState(matterID: String) {
        legacyDraftsNeedReviewCount = ((try? store.remediationRecovery.pendingItems(
            kind: .legacyDraftArtifact,
            matterID: matterID,
            limit: 2_000
        )) ?? []).count
    }

    public func refreshDraftReviewState(matterID: String) {
        refreshLegacyDraftReviewState(matterID: matterID)
        interruptedDraftRecoveries = ((try? store.remediationRecovery.pendingItems(
            kind: .interruptedDraftArtifact,
            matterID: matterID,
            relatedTable: DraftArtifactIntentRecord.databaseTableName,
            limit: 2_000
        )) ?? [])
            .map { item in
                guard let descriptor = try? store.draftArtifacts.recoveryDescriptor(id: item.relatedID),
                      descriptor.matterID == matterID else {
                    return InterruptedDraftRecovery(
                        id: item.id,
                        intentID: item.relatedID,
                        fileName: nil,
                        fileURL: nil
                    )
                }
                let fileURL = storage.exportsDirectory(forMatterID: descriptor.matterID)
                    .appendingPathComponent(descriptor.fileName, isDirectory: false)
                return InterruptedDraftRecovery(
                    id: item.id,
                    intentID: descriptor.intentID,
                    fileName: descriptor.fileName,
                    fileURL: fileURL
                )
            }
    }

    /// Explicitly acknowledges review of legacy file-only artifacts. The files
    /// remain untouched; each content-free recovery item receives an audit event.
    public func confirmLegacyDraftArtifactsReviewed(matterID: String) {
        let items = (try? store.remediationRecovery.pendingItems(
            kind: .legacyDraftArtifact,
            matterID: matterID,
            limit: 2_000
        )) ?? []
        do {
            for item in items {
                try store.remediationRecovery.resolve(
                    id: item.id,
                    resolution: .userReviewed,
                    actor: "user"
                )
            }
            refreshLegacyDraftReviewState(matterID: matterID)
            message = "Legacy draft review recorded. Regenerate any artifact you plan to use."
        } catch {
            message = "Could not record the legacy draft review: \(error.localizedDescription)"
        }
    }

    /// Records the attorney's explicit review decision without moving, opening,
    /// or deleting any artifact. The historical recovery-required intent remains
    /// terminal; the user must regenerate before relying on the prior file.
    public func confirmInterruptedDraftArtifactsReviewed(matterID: String) {
        do {
            for recovery in interruptedDraftRecoveries {
                try store.remediationRecovery.resolve(
                    id: recovery.id,
                    resolution: .userReviewed,
                    actor: "user"
                )
            }
            refreshDraftReviewState(matterID: matterID)
            message = "Interrupted draft review recorded. Regenerate before using any affected file."
        } catch {
            message = "Could not record the interrupted draft review: \(error.localizedDescription)"
        }
    }

    /// The effective house style sheet for this matter's drafts: the firm's overrides resolved
    /// over `.defaultFL`, then clamped to the Fla. R. Jud. Admin. 2.520(a) floor so a firm can
    /// never push below 12 pt / 1" margins. `internal` (reachable via `@testable`), not `private`.
    ///
    /// Precedence: an injected `firmStyleProfile` (tests / explicit override) wins; otherwise the
    /// profile persisted by `FirmStyleProfileController` is read FRESH from the store — the same
    /// read-at-draft-time pattern `AssistantProfile` uses — so a Settings edit applies to the very
    /// next draft. With neither present, this is exactly `.defaultFL` (invariant 5).
    func effectiveStyle() -> HouseStyleSheet {
        let stored = try? store.appSettings.getSetting(FirmStyleProfile.profileKey, as: FirmStyleProfile.self)
        return (firmStyleProfile ?? stored ?? FirmStyleProfile()).resolved(over: .defaultFL).clampedToFloor()
    }

    // MARK: - Public entry point

    /// Drafts a Notice of Appearance for a matter, writing a `.docx` to managed
    /// storage and returning its URL + review notes. The deterministic, no-LLM kind
    /// — the first kind wired into chat.
    public func draftNoticeOfAppearance(
        matterID: String,
        parties: [PartyLine],
        partyRepresented: String,
        representedPartyName: String,
        recipients: [ServiceRecipient],
        serviceDate: DateOnly = DateOnly.today
    ) async -> Result<DraftArtifact, DraftError> {
        guard !isGenerating else {
            message = "A draft is already generating. Wait for it to finish."
            return .failure(.renderFailed("already generating"))
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        isGenerating = true
        message = nil
        defer { isGenerating = false }

        guard let matter = try? store.matters.fetchMatter(id: matterID) else {
            return .failure(.matterNotFound)
        }
        let profile = (try? store.appSettings.getSetting(AssistantProfile.profileKey, as: AssistantProfile.self)) ?? .empty
        guard profile.hasDraftingIdentity else {
            return .failure(.incompleteFirmProfile(missing: profile.missingDraftingIdentityFields))
        }
        guard let caseNumber = matter.docketNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !caseNumber.isEmpty else {
            return .failure(.missingCaptionField("case/docket number"))
        }
        let courtHeader = Self.courtHeader(for: matter)
        guard !courtHeader.isEmpty, courtHeader.caseInsensitiveCompare("Unspecified") != .orderedSame else {
            return .failure(.missingCaptionField("court"))
        }
        guard Self.isSupportedNoticeJurisdiction(matter: matter, courtHeader: courtHeader) else {
            return .failure(.unsupportedJurisdiction(courtHeader))
        }

        // Match the bar admission to the filing's court (court text first, then the
        // matter's jurisdiction); falls back to the primary license.
        let firm = Self.firmProfile(from: profile, jurisdiction: matter.court ?? matter.jurisdiction)
        let inputs = NoticeAppearance.Inputs(
            courtHeader: courtHeader,
            parties: Self.normalizedParties(parties),
            partyRepresented: partyRepresented.trimmingCharacters(in: .whitespacesAndNewlines),
            representedPartyName: representedPartyName.trimmingCharacters(in: .whitespacesAndNewlines),
            caseNumber: caseNumber,
            division: matter.judge?.trimmingCharacters(in: .whitespacesAndNewlines),   // division/judge line; nil-safe
            serviceDate: serviceDate,
            recipients: Self.normalizedRecipients(recipients)
        )
        let missingSlots = NoticeAppearanceInputValidator.validate(inputs: inputs, profile: firm)
        guard missingSlots.isEmpty else {
            return .failure(.missingRequiredSlots(missingSlots))
        }

        let pipeline = pipelineFactory()
        let result: DraftResult
        do {
            result = try await pipeline.runNotice(inputs, profile: firm, style: effectiveStyle())
            try Task.checkCancellation()
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as SupraDraftingCore.DraftError {
            return .failure(Task.isCancelled ? .cancelled : Self.mapCoreDraftError(error))
        } catch {
            return .failure(Task.isCancelled ? .cancelled : .renderFailed(error.localizedDescription))
        }

        do {
            try Task.checkCancellation()
            let url = try persist(
                data: result.docx,
                matterID: matterID,
                title: NoticeAppearance.title,
                format: .docx,
                artifactKind: .noticeAppearance
            )
            let followUps = result.followUps.map { DraftFollowUp(isBlocking: $0.severity == .blocking, message: $0.message) }
            return .success(DraftArtifact(source: .kind(.noticeAppearance), format: .docx, title: NoticeAppearance.title, fileURL: url, followUps: followUps))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(Task.isCancelled ? .cancelled : .renderFailed(error.localizedDescription))
        }
    }

    // MARK: - Request layer (multi-kind + custom)

    /// The kinds the app can actually generate, with display titles and a reason for
    /// any that are present in the catalog but not yet wired into the app. `isEnabled`
    /// is keyed off the controller's wired generation paths — NOT registry membership,
    /// since registry membership alone does not prove an end-to-end app path.
    public func availableDraftKinds() -> [DraftKindAvailability] {
        let wired = wiredKinds
        return DraftKindID.allCases.map { kind in
            DraftKindAvailability(
                id: kind,
                title: Self.displayTitle(for: kind),
                isEnabled: wired.contains(kind),
                disabledReason: wired.contains(kind)
                    ? nil
                    : "\(Self.displayTitle(for: kind)) drafting isn't wired into the app yet — use “Custom” to describe it for now."
            )
        }
    }

    /// Single entry point for the Draft Workspace. Dispatches a typed request to the
    /// matching generation path. Notice and supported-motion paths render `.docx`;
    /// the custom path writes a clearly labeled markdown work-product description.
    public func draft(_ request: MatterDraftRequest, matterID: String) async -> Result<DraftArtifact, DraftError> {
        switch request {
        case let .noticeAppearance(input):
            return await draftNoticeOfAppearance(
                matterID: matterID,
                parties: input.parties,
                partyRepresented: input.partyRepresented,
                representedPartyName: input.representedPartyName,
                recipients: input.recipients,
                serviceDate: input.serviceDate
            )
        case let .motionToDismiss(input):
            return await draftMotionToDismiss(matterID: matterID, input: input)
        case let .customDescription(input):
            return await draftCustomDescription(matterID: matterID, input: input)
        }
    }

    /// Writes the user's free-form work-product description to a markdown file in the
    /// matter's exports. No model and no rendering: the output is the attorney's own
    /// words plus matter context, labeled as a drafting brief, so nothing is invented.
    public func draftCustomDescription(matterID: String, input: CustomDraftDescriptionInput) async -> Result<DraftArtifact, DraftError> {
        guard !isGenerating else {
            message = "A draft is already generating. Wait for it to finish."
            return .failure(.renderFailed("already generating"))
        }
        isGenerating = true
        message = nil
        defer { isGenerating = false }

        guard let matter = try? store.matters.fetchMatter(id: matterID) else {
            return .failure(.matterNotFound)
        }
        let description = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            return .failure(.emptyDescription)
        }
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Work-Product Description"
        let markdown = Self.customDescriptionMarkdown(
            title: title,
            description: description,
            instructions: input.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            matter: matter
        )
        do {
            let url = try persist(
                data: Data(markdown.utf8),
                matterID: matterID,
                title: title,
                format: .markdown,
                artifactKind: .customDescription
            )
            let note = DraftFollowUp(
                isBlocking: false,
                message: "This is a work-product description in your own words — not a court-ready or model-generated filing. Use it as a drafting brief or starting point."
            )
            return .success(DraftArtifact(source: .customDescription, format: .markdown, title: title, fileURL: url, followUps: [note]))
        } catch {
            return .failure(.renderFailed(error.localizedDescription))
        }
    }

    /// Generates a Demand Letter (the `letterDemand` kind) with the on-device drafting model.
    /// The user's structured inputs are the ONLY fact source; the model writes the body, then
    /// the deterministic letter pipeline (verifier + pre-file gate + letterhead renderer)
    /// produces the `.docx`. The caller must resolve/load the drafting model first.
    public func draftLetterDemand(
        matterID: String,
        input: LetterDraftInput,
        modelID: ModelID,
        route: ModelRoute
    ) async -> Result<DraftArtifact, DraftError> {
        guard !isGenerating else {
            message = "A draft is already generating. Wait for it to finish."
            return .failure(.renderFailed("already generating"))
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard let runtimeClient else {
            return .failure(.unsupportedKind(.letterDemand))
        }
        isGenerating = true
        message = nil
        defer { isGenerating = false }

        guard let matter = try? store.matters.fetchMatter(id: matterID) else {
            return .failure(.matterNotFound)
        }
        let profile = (try? store.appSettings.getSetting(AssistantProfile.profileKey, as: AssistantProfile.self)) ?? .empty
        guard profile.hasDraftingIdentity else {
            return .failure(.incompleteFirmProfile(missing: profile.missingDraftingIdentityFields))
        }
        let claim = input.claimSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !claim.isEmpty else {
            return .failure(.missingRequiredSlots(["the claim or dispute the letter is about"]))
        }

        let firm = Self.firmProfile(from: profile, jurisdiction: matter.court ?? matter.jurisdiction)
        let facts = Self.letterFacts(from: input, claim: claim)
        let voice = AssistantVoiceProfile(registerNotes: Self.voiceRegister(tone: input.tone, profile: profile))
        let parts = LetterDemand.promptParts(facts: facts, profile: voice)
        let inputs = Self.letterInputs(from: input)

        let generator = RuntimeLetterGenerator(runtimeClient: runtimeClient, modelID: modelID, route: route)
        let generated: GeneratedLetter
        do {
            try Task.checkCancellation()
            generated = try await generator.generateLetter(parts)
            try Task.checkCancellation()
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as GenerationStreamError where error == .cancelled {
            return .failure(.cancelled)
        } catch let error as SupraDraftingCore.DraftError {
            return .failure(Task.isCancelled ? .cancelled : Self.mapCoreDraftError(error))
        } catch {
            return .failure(Task.isCancelled ? .cancelled : .renderFailed(error.localizedDescription))
        }
        guard !generated.paragraphs.isEmpty else {
            return .failure(.verificationBlocked(["The drafting model returned no verified letter body."]))
        }

        let result: DraftResult
        do {
            try Task.checkCancellation()
            result = try await pipelineFactory().runLetter(
                inputs,
                generated: generated,
                facts: facts,
                profile: firm,
                style: effectiveStyle()
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as SupraDraftingCore.DraftError {
            return .failure(Task.isCancelled ? .cancelled : Self.mapCoreDraftError(error))
        } catch {
            return .failure(Task.isCancelled ? .cancelled : .renderFailed(error.localizedDescription))
        }

        do {
            try Task.checkCancellation()
            let title = "Demand Letter"
            let url = try persist(
                data: result.docx,
                matterID: matterID,
                title: title,
                format: .docx,
                artifactKind: .letterDemand
            )
            let followUps = result.followUps.map { DraftFollowUp(isBlocking: $0.severity == .blocking, message: $0.message) }
            return .success(DraftArtifact(source: .kind(.letterDemand), format: .docx, title: title, fileURL: url, followUps: followUps))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(Task.isCancelled ? .cancelled : .renderFailed(error.localizedDescription))
        }
    }

    /// The kinds this controller can actually generate. `letterDemand` is LLM-backed, so it
    /// is only wired when a runtime is available; notice and motion are deterministic.
    private var wiredKinds: Set<DraftKindID> {
        runtimeClient == nil
            ? [.noticeAppearance, .motionToDismiss]
            : [.noticeAppearance, .motionToDismiss, .letterDemand]
    }

    // MARK: - Supported Florida Motion to Dismiss

    /// Current, revision-bound fact excerpts that can be selected for the motion.
    /// Ineligible rows remain visible with a concrete reason so a missing source is
    /// never silently treated as grounded evidence.
    public func motionFactSources(matterID: String) -> [MotionDraftFactSource] {
        do {
            return try loadMotionFactSources(matterID: matterID)
        } catch {
            message = "Could not load motion fact sources: \(error.localizedDescription)"
            return []
        }
    }

    /// Saved authorities for this matter, annotated with the first motion
    /// vertical's review, citation-shape, and proposition-support requirements.
    public func motionAuthoritySources(matterID: String) -> [MotionDraftAuthoritySource] {
        do {
            return try loadMotionAuthoritySources(matterID: matterID)
        } catch {
            message = "Could not load motion authorities: \(error.localizedDescription)"
            return []
        }
    }

    /// Store-backed readiness used at the generation boundary. Every selected
    /// source is refreshed immediately before snapshot capture, so cached UI
    /// state cannot authorize stale or deleted evidence.
    public func motionReadiness(input: MotionToDismissDraftInput, matterID: String) -> MotionDraftReadiness {
        let factSources = try? loadMotionFactSources(matterID: matterID)
        let authoritySources = try? loadMotionAuthoritySources(matterID: matterID)
        return evaluateMotionReadiness(
            input: input,
            matterID: matterID,
            factSources: factSources,
            authoritySources: authoritySources
        )
    }

    /// Interactive readiness over source rows already loaded and displayed by
    /// the form. Keystrokes and SwiftUI body recomputation must not rescan the
    /// document and authority libraries.
    public func motionReadiness(
        input: MotionToDismissDraftInput,
        matterID: String,
        factSources: [MotionDraftFactSource],
        authoritySources: [MotionDraftAuthoritySource]
    ) -> MotionDraftReadiness {
        evaluateMotionReadiness(
            input: input,
            matterID: matterID,
            factSources: factSources,
            authoritySources: authoritySources
        )
    }

    private func evaluateMotionReadiness(
        input: MotionToDismissDraftInput,
        matterID: String,
        factSources: [MotionDraftFactSource]?,
        authoritySources: [MotionDraftAuthoritySource]?
    ) -> MotionDraftReadiness {
        var reasons: [String] = []
        let selectedFacts = Self.uniqueMotionFactSelections(input.selectedFacts)
        let selectedFactIDs = selectedFacts.map(\.chunkID)
        let selectedAuthorities = Self.uniqueMotionAuthoritySelections(input.selectedAuthorities)

        let matter: MatterRecord?
        do {
            matter = try store.matters.fetchMatter(id: matterID)
        } catch {
            matter = nil
            reasons.append("The matter could not be loaded.")
        }

        if let matter {
            let profile: AssistantProfile
            do {
                profile = try store.appSettings.getSetting(AssistantProfile.profileKey, as: AssistantProfile.self) ?? .empty
            } catch {
                profile = .empty
                reasons.append("The firm profile could not be loaded.")
            }
            let courtHeader = Self.explicitCourtHeader(for: matter)
            if courtHeader.isEmpty {
                reasons.append("The matter is missing an explicit court.")
            } else if !FloridaMotionToDismissContract.isSupportedFilingCourt(courtHeader) {
                reasons.append(FloridaMotionToDismissContract.filingCourtRequirement)
            }
            let noticeInputs = NoticeAppearance.Inputs(
                courtHeader: courtHeader,
                parties: Self.normalizedParties(input.parties),
                partyRepresented: input.partyRepresented.trimmingCharacters(in: .whitespacesAndNewlines),
                representedPartyName: input.representedPartyName.trimmingCharacters(in: .whitespacesAndNewlines),
                caseNumber: matter.docketNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                division: nil,
                serviceDate: input.serviceDate,
                recipients: Self.normalizedRecipients(input.recipients)
            )
            let firm = Self.firmProfile(from: profile, jurisdiction: courtHeader)
            reasons.append(contentsOf: NoticeAppearanceInputValidator.validate(inputs: noticeInputs, profile: firm)
                .map { "Missing or invalid \($0)." })
        } else if !reasons.contains("The matter could not be loaded.") {
            reasons.append("The matter was not found.")
        }

        if input.respondingTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append("Identify the pleading the motion responds to.")
        }
        if input.reliefSought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append("State the relief sought.")
        }
        let composedSlots = [
            ("responding pleading", input.respondingTo),
            ("requested relief", input.reliefSought),
            ("represented party name", input.representedPartyName),
            ("represented party role", input.partyRepresented),
        ]
        for (label, value) in composedSlots
            where MotionCitationShapeDetector.containsCitationShape(in: value) {
            reasons.append(
                "Remove citation-shaped text from the \(label). Legal citations must come from a selected fact excerpt or reviewed authority."
            )
        }
        if input.grounds.count != 1 {
            reasons.append("Select exactly one supported ground.")
        }
        if !input.grounds.isEmpty {
            for ground in input.grounds {
                do {
                    let spec = try MotionGroundSpec.knownGround(for: ground)
                    if spec.key != MotionGroundSpec.failureToStateClaim.key {
                        reasons.append("Unsupported ground “\(ground)”. This workflow supports failure to state a claim.")
                    }
                } catch {
                    let label = ground.trimmingCharacters(in: .whitespacesAndNewlines)
                    reasons.append("Unsupported ground “\(label.isEmpty ? "blank" : label)”. This workflow supports failure to state a claim.")
                }
            }
        }

        if selectedFacts.count != input.selectedFacts.count {
            reasons.append("Fact-source selections must contain unique, nonblank revision and excerpt bindings.")
        }
        if selectedFactIDs.isEmpty {
            reasons.append("Select at least one current fact excerpt.")
        }
        if let factSources {
            let availableFacts = Dictionary(
                uniqueKeysWithValues: factSources.map { ($0.chunkID, $0) }
            )
            for selection in selectedFacts {
                guard let source = availableFacts[selection.chunkID] else {
                    reasons.append("Selected fact source \(selection.chunkID) is unavailable in this matter.")
                    continue
                }
                if !source.isReady {
                    reasons.append("Fact source “\(source.documentName)” is unavailable: \(source.blockingReason ?? "it is not current and ready").")
                } else if source.documentRevisionID != selection.expectedRevisionID
                    || source.excerptSHA256 != selection.expectedExcerptSHA256 {
                    reasons.append("Fact source “\(source.documentName)” changed after it was selected. Reload and select it again.")
                }
            }
        } else {
            reasons.append("Selected fact sources could not be verified.")
        }

        if selectedAuthorities.count != input.selectedAuthorities.count {
            reasons.append("Authority selections must contain unique, nonblank IDs.")
        }
        if selectedAuthorities.isEmpty {
            reasons.append("Select at least one reviewed authority.")
        }
        if let authoritySources {
            let availableAuthorities = Dictionary(
                uniqueKeysWithValues: authoritySources.map { ($0.authorityID, $0) }
            )
            for selection in selectedAuthorities {
                guard let source = availableAuthorities[selection.authorityID] else {
                    reasons.append("Selected authority \(selection.authorityID) is unavailable in this matter.")
                    continue
                }
                if !source.isReady {
                    reasons.append("Authority “\(source.caseName)” is unavailable: \(source.blockingReason ?? "it is not reviewed and supported").")
                } else if source.bindingSHA256 != selection.expectedBindingSHA256 {
                    reasons.append("Authority “\(source.caseName)” changed after it was selected. Reload and select it again.")
                }
            }
        } else {
            reasons.append("Selected authorities could not be verified.")
        }

        let uniqueReasons = Self.uniqueStrings(reasons)
        return MotionDraftReadiness(
            selectedFactCount: selectedFactIDs.count,
            selectedAuthorityCount: selectedAuthorities.count,
            blockingReasons: uniqueReasons
        )
    }

    public func draftMotionToDismiss(
        matterID: String,
        input: MotionToDismissDraftInput
    ) async -> Result<DraftArtifact, DraftError> {
        guard !isGenerating else {
            message = "A draft is already generating. Wait for it to finish."
            return .failure(.renderFailed("already generating"))
        }
        isGenerating = true
        message = nil
        defer { isGenerating = false }

        do {
            try Task.checkCancellation()
            let readiness = motionReadiness(input: input, matterID: matterID)
            guard readiness.canGenerate else {
                return .failure(.motionBlocked(readiness.blockingReasons))
            }

            let selectedFacts = Self.uniqueMotionFactSelections(input.selectedFacts)
            let selectedFactIDs = selectedFacts.map(\.chunkID)
            let selectedAuthorities = Self.uniqueMotionAuthoritySelections(input.selectedAuthorities)
            let selectedAuthorityIDs = selectedAuthorities.map(\.authorityID)
            let groundSpecs = try Self.motionGroundSpecs(input.grounds)
            let snapshotRequest = MotionDraftSnapshotRequest(
                matterID: matterID,
                factSelections: selectedFacts.map {
                    MotionDraftFactSelection(
                        chunkID: $0.chunkID,
                        expectedRevisionID: $0.expectedRevisionID,
                        expectedExcerptSHA256: $0.expectedExcerptSHA256
                    )
                },
                authoritySelections: selectedAuthorities.map {
                    MotionDraftAuthoritySelection(
                        authorityID: $0.authorityID,
                        groundKey: .failureToStateClaim,
                        expectedBindingSHA256: $0.expectedBindingSHA256
                    )
                },
                assistantProfileSettingKey: AssistantProfile.profileKey,
                firmStyleProfileSettingKey: FirmStyleProfile.profileKey
            )
            let snapshot = try store.draftingSources.captureMotionSnapshot(snapshotRequest)
            let matter = snapshot.matter
            let profile: AssistantProfile = try Self.decodeMotionSetting(
                snapshot.assistantProfile,
                defaultValue: .empty
            )
            guard profile.hasDraftingIdentity else {
                return .failure(.incompleteFirmProfile(missing: profile.missingDraftingIdentityFields))
            }
            let courtHeader = Self.explicitCourtHeader(for: matter)
            guard !courtHeader.isEmpty else {
                return .failure(.missingCaptionField("court"))
            }
            guard FloridaMotionToDismissContract.isSupportedFilingCourt(courtHeader) else {
                return .failure(.motionBlocked([FloridaMotionToDismissContract.filingCourtRequirement]))
            }
            guard let caseNumber = matter.docketNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !caseNumber.isEmpty else {
                return .failure(.missingCaptionField("case/docket number"))
            }

            let parties = Self.normalizedParties(input.parties)
            let recipients = Self.normalizedRecipients(input.recipients)
            let representedName = input.representedPartyName.trimmingCharacters(in: .whitespacesAndNewlines)
            let representedRole = input.partyRepresented.trimmingCharacters(in: .whitespacesAndNewlines)
            let respondingTo = input.respondingTo.trimmingCharacters(in: .whitespacesAndNewlines)
            let relief = input.reliefSought.trimmingCharacters(in: .whitespacesAndNewlines)
            let firm = Self.firmProfile(from: profile, jurisdiction: courtHeader)
            let noticeInputs = NoticeAppearance.Inputs(
                courtHeader: courtHeader,
                parties: parties,
                partyRepresented: representedRole,
                representedPartyName: representedName,
                caseNumber: caseNumber,
                division: nil,
                serviceDate: input.serviceDate,
                recipients: recipients
            )
            let invalidSlots = NoticeAppearanceInputValidator.validate(inputs: noticeInputs, profile: firm)
            guard invalidSlots.isEmpty else {
                return .failure(.missingRequiredSlots(invalidSlots))
            }
            var shell = NoticeAppearance.assemble(noticeInputs, profile: firm)
            shell.caption.judge = matter.judge?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            guard var signature = shell.signature, var certificate = shell.certificate else {
                return .failure(.verificationBlocked(["The required signature or certificate shell was unavailable."]))
            }
            signature.respectfullySubmitted = input.serviceDate
            let title = MotionToDismiss.title(
                party: representedName,
                partyRole: representedRole,
                pleading: respondingTo
            )
            certificate.documentTitle = title

            let introductionText =
                "\(representedRole), \(representedName), moves to dismiss \(respondingTo) for failure to state a claim. This motion is assembled from the factual excerpts and reviewed authorities selected by counsel."
            let introduction = [BodyBlock.paragraph(introductionText)]
            let packet = Self.motionPacket(snapshot: snapshot, groundSpecs: groundSpecs)
            guard packet.authorities.allSatisfy({
                FloridaMotionToDismissContract.isSupportedAuthorityCitation($0.citation)
            }) else {
                return .failure(.motionBlocked(["Every selected authority must have a supported Florida state citation."]))
            }
            let argumentHeading = "THE \(respondingTo.uppercased()) FAILS TO STATE A CLAIM."
            let conclusion = "WHEREFORE, \(representedName) respectfully requests \(relief)."
            let evidence = MotionVerificationEvidence(
                facts: packet.facts.map {
                    MotionFactEvidence(
                        factID: $0.chunkID,
                        text: $0.text,
                        sourceID: $0.revisionID,
                        locator: $0.locator
                    )
                },
                authorities: zip(packet.authorities, snapshot.authorities).map { authority, source in
                    MotionAuthorityEvidence(
                        authorityID: authority.authorityID,
                        citation: authority.citation,
                        reviewedExcerpt: authority.snippet,
                        groundKey: source.groundKey.rawValue
                    )
                },
                bodyContract: MotionBodyContract(
                    introduction: introductionText,
                    argumentHeading: argumentHeading,
                    conclusion: conclusion
                )
            )
            let authorityParagraphs = evidence.authorities.map { authority in
                BodyBlock.paragraph(authority.canonicalParagraph)
            }
            let selectedFactReviewParagraphs = evidence.canonicalSelectedFactReviewParagraphs.map(BodyBlock.paragraph)
            let argument = MotionToDismiss.ArgumentPoint(
                heading: argumentHeading,
                body: authorityParagraphs + selectedFactReviewParagraphs
            )
            let model = MotionToDismiss.assemble(
                caption: shell.caption,
                title: title,
                introduction: introduction,
                numberedFacts: packet.facts.map(\.text),
                argumentPoints: [argument],
                conclusion: conclusion,
                signature: signature,
                certificate: certificate
            )
            let effectiveMotionStyle = try motionStyle(from: snapshot)

            try Task.checkCancellation()
            let result = try await pipelineFactory().runMotion(
                model: model,
                evidence: evidence,
                style: effectiveMotionStyle
            )
            try Task.checkCancellation()
            try await beforeMotionPersistence()
            try Task.checkCancellation()

            let auditInput = MotionDraftAuditInput(
                canonicalRequest: try Self.motionRequestData(
                    matterID: matterID,
                    parties: parties,
                    representedRole: representedRole,
                    representedName: representedName,
                    recipients: recipients,
                    serviceDate: input.serviceDate,
                    respondingTo: respondingTo,
                    relief: relief,
                    groundKeys: groundSpecs.map(\.key),
                    factIDs: selectedFactIDs,
                    authorityIDs: selectedAuthorityIDs
                ),
                canonicalCaption: try Self.captionData(shell.caption),
                canonicalEffectiveStyle: try Self.canonicalData(effectiveMotionStyle),
                groundContractIdentity: Self.storeIdentity(MotionGroundSpec.contractIdentity),
                assemblerIdentity: Self.storeIdentity(MotionToDismiss.assemblerIdentity),
                verificationReceipt: MotionDraftVerificationReceiptInput(
                    status: .passed,
                    scope: .motionSelectedSourceReproductionAndStructure,
                    supportedPropositionIDs: result.verificationReceipt.supportedPropositionIDs,
                    verifierIdentity: Self.storeIdentity(result.verificationReceipt.verifierIdentity),
                    gateIdentity: Self.storeIdentity(result.verificationReceipt.gateIdentity),
                    rendererIdentity: Self.storeIdentity(result.verificationReceipt.rendererIdentity)
                )
            )
            guard result.verificationReceipt.scope == .motionSelectedSourceReproductionAndStructure else {
                return .failure(.verificationBlocked([
                    "The verification receipt did not cover exact selected-source reproduction and structure."
                ]))
            }
            let url = try persistMotion(
                data: result.docx,
                matterID: matterID,
                title: "Motion to Dismiss",
                snapshot: snapshot,
                auditInput: auditInput
            )
            let followUps = result.followUps.map {
                DraftFollowUp(isBlocking: $0.severity == .blocking, message: $0.message)
            }
            return .success(DraftArtifact(
                source: .kind(.motionToDismiss),
                format: .docx,
                title: title,
                fileURL: url,
                followUps: followUps
            ))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as DraftError {
            return .failure(error)
        } catch let error as SupraDraftingCore.DraftError {
            return .failure(Self.mapCoreDraftError(error))
        } catch let error as MotionDraftSnapshotError {
            return .failure(.motionBlocked([Self.motionSnapshotFailureMessage(error)]))
        } catch {
            return .failure(.renderFailed(error.localizedDescription))
        }
    }

    private struct MotionRequestFingerprint: Encodable {
        let matterID: String
        let parties: [PartyLine]
        let representedRole: String
        let representedName: String
        let recipients: [ServiceRecipient]
        let serviceDate: DateOnly
        let respondingTo: String
        let relief: String
        let groundKeys: [String]
        let factIDs: [String]
        let authorityIDs: [String]
    }

    private struct MotionCaptionFingerprint: Encodable {
        let courtHeader: String
        let parties: [PartyLine]
        let caseNumber: String
        let division: String?
        let judge: String?
    }

    nonisolated private static func motionGroundSpecs(_ grounds: [String]) throws -> [MotionGroundSpec] {
        guard grounds.count == 1 else {
            throw DraftError.motionBlocked(["Select exactly one supported ground."])
        }
        let spec: MotionGroundSpec
        do {
            spec = try MotionGroundSpec.knownGround(for: grounds[0])
        } catch {
            throw DraftError.motionBlocked(["This workflow supports only failure to state a claim."])
        }
        guard spec.key == MotionGroundSpec.failureToStateClaim.key else {
            throw DraftError.motionBlocked(["This workflow supports only failure to state a claim."])
        }
        return [spec]
    }

    nonisolated private static func decodeMotionSetting<Value: Decodable>(
        _ setting: MotionDraftSettingSnapshot,
        defaultValue: @autoclosure () -> Value
    ) throws -> Value {
        guard let json = setting.valueJSON else { return defaultValue() }
        return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }

    private func motionStyle(from snapshot: MotionDraftStoreSnapshot) throws -> HouseStyleSheet {
        let stored: FirmStyleProfile = try Self.decodeMotionSetting(
            snapshot.firmStyleProfile,
            defaultValue: FirmStyleProfile()
        )
        return (firmStyleProfile ?? stored).resolved(over: .defaultFL).clampedToFloor()
    }

    /// Exact selected-only packet derived from the single Store snapshot used for
    /// generation and audit. There is intentionally no independent-read variant.
    nonisolated static func motionPacket(
        snapshot: MotionDraftStoreSnapshot,
        groundSpecs: [MotionGroundSpec]
    ) -> MotionDraftPacket {
        let facts = snapshot.facts.map { source in
            let sourceKind = DocumentSourceKind(rawValue: source.sourceKind) ?? .text
            let locator = DocumentSourceLocator(
                sourceKind: sourceKind,
                pageIndex: source.pageIndex,
                pageLabel: source.pageLabel,
                sheetName: source.sheetName,
                cellRange: source.cellRange,
                emailPartPath: source.emailPartPath,
                charStart: source.charStart,
                charEnd: source.charEnd
            ).displayString
            return MotionDraftPacket.Fact(
                chunkID: source.chunkID,
                documentID: source.documentID,
                revisionID: source.revisionID,
                documentName: source.documentName,
                locator: locator,
                text: source.text
            )
        }
        let authorities = snapshot.authorities.map { source in
            MotionDraftPacket.Authority(
                authorityID: source.authorityID,
                caseName: source.caseName,
                citation: source.citation,
                snippet: source.excerpt
            )
        }
        return MotionDraftPacket(
            facts: facts,
            authorities: authorities,
            groundSpecs: groundSpecs
        )
    }

    nonisolated private static func motionRequestData(
        matterID: String,
        parties: [PartyLine],
        representedRole: String,
        representedName: String,
        recipients: [ServiceRecipient],
        serviceDate: DateOnly,
        respondingTo: String,
        relief: String,
        groundKeys: [String],
        factIDs: [String],
        authorityIDs: [String]
    ) throws -> Data {
        try canonicalData(MotionRequestFingerprint(
            matterID: matterID,
            parties: parties,
            representedRole: representedRole,
            representedName: representedName,
            recipients: recipients,
            serviceDate: serviceDate,
            respondingTo: respondingTo,
            relief: relief,
            groundKeys: groundKeys,
            factIDs: factIDs,
            authorityIDs: authorityIDs
        ))
    }

    nonisolated private static func captionData(_ caption: CaptionModel) throws -> Data {
        try canonicalData(MotionCaptionFingerprint(
            courtHeader: caption.courtHeader,
            parties: caption.parties,
            caseNumber: caption.caseNumber,
            division: caption.division,
            judge: caption.judge
        ))
    }

    nonisolated private static func canonicalData<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    nonisolated private static func storeIdentity(
        _ identity: DraftComponentIdentity
    ) -> MotionDraftAuditComponentIdentity {
        MotionDraftAuditComponentIdentity(id: identity.id, version: identity.version)
    }

    nonisolated private static func motionSnapshotFailureMessage(
        _ error: MotionDraftSnapshotError
    ) -> String {
        switch error {
        case .matterNotFound:
            return "The matter changed or was removed before motion generation."
        case .sourceSnapshotStale:
            return "A selected source or drafting setting changed before the audit could be committed."
        case .emptyFactSelection, .emptyAuthoritySelection:
            return "Select at least one current fact excerpt and one reviewed authority."
        case .authorityPropositionUnavailable:
            return "A selected authority no longer has current reviewed proposition evidence."
        default:
            return "The selected motion sources could not be captured as one current, verified snapshot."
        }
    }

    private func loadMotionFactSources(matterID: String) throws -> [MotionDraftFactSource] {
        try motionFactSourceLoadCheckpoint()
        return try store.draftingSources.fetchMotionFactSources(matterID: matterID).map { record in
            let document = record.document
            let chunk = record.chunk
            var blockers: [String] = []
            if document.status != MatterDocumentStatus.ready.rawValue {
                blockers.append("the document is not ready")
            }
            if ![DocumentExtractionStatus.extracted.rawValue, DocumentExtractionStatus.ocrComplete.rawValue, DocumentExtractionStatus.edited.rawValue]
                .contains(document.extractionStatus) {
                blockers.append("text extraction is not ready")
            }
            if ![DocumentIndexStatus.textIndexed.rawValue, DocumentIndexStatus.ready.rawValue]
                .contains(document.indexStatus) {
                blockers.append("the text index is not current")
            }
            let revisionID = chunk.revisionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if revisionID.isEmpty {
                blockers.append("the excerpt has no immutable revision")
            }
            if chunk.pagePartID != nil, let part = record.part {
                if part.currentRevisionID != chunk.revisionID {
                    blockers.append("the excerpt is stale relative to the current revision")
                }
            } else {
                blockers.append("the excerpt is not bound to a current document part")
            }
            let text = chunk.normalizedText
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blockers.append("the excerpt is empty")
            }
            if InstructionShapeDetector.isBlocking(text) {
                blockers.append("the excerpt contains instruction-shaped text")
            }
            let sourceKind = DocumentSourceKind(rawValue: chunk.sourceKind) ?? .text
            let locator = DocumentSourceLocator(
                sourceKind: sourceKind,
                pageIndex: chunk.pageIndex,
                pageLabel: chunk.pageLabel,
                sheetName: chunk.sheetName,
                cellRange: chunk.cellRange,
                emailPartPath: chunk.emailPartPath,
                charStart: chunk.charStart,
                charEnd: chunk.charEnd,
                boundingBoxesJSON: chunk.boundingBoxesJSON
            ).displayString
            return MotionDraftFactSource(
                chunkID: chunk.id,
                documentID: document.id,
                documentRevisionID: revisionID,
                excerptSHA256: DocumentStorage.sha256Hex(of: Data(text.utf8)),
                documentName: document.displayName,
                locator: locator,
                text: text,
                isReady: blockers.isEmpty,
                blockingReason: blockers.isEmpty ? nil : blockers.joined(separator: ", ")
            )
        }
    }

    private func loadMotionAuthoritySources(matterID: String) throws -> [MotionDraftAuthoritySource] {
        try motionAuthoritySourceLoadCheckpoint()
        return try store.draftingSources.fetchMotionAuthoritySources(
            matterID: matterID,
            groundKey: .failureToStateClaim
        ).map { record in
            let authority = record.authority
            let citation = Self.motionCitation(from: authority)
            var blockers: [String] = []
            let snippet: String
            let bindingSHA256: String?
            switch record.propositionState {
            case let .ready(reviewed):
                snippet = reviewed.excerpt
                bindingSHA256 = reviewed.bindingSHA256
            case .notReviewed:
                snippet = ""
                bindingSHA256 = nil
                blockers.append("the failure-to-state-a-claim proposition has not been reviewed")
            case let .blocked(reason):
                snippet = ""
                bindingSHA256 = nil
                blockers.append("the reviewed proposition evidence is unavailable (\(reason.rawValue))")
            }
            if !FloridaMotionToDismissContract.isSupportedAuthorityCitation(citation) {
                blockers.append("the citation is missing or unsupported")
            }
            if snippet.isEmpty {
                blockers.append("no supporting proposition text is saved")
            }
            if InstructionShapeDetector.isBlocking(snippet) {
                blockers.append("the saved text contains instruction-shaped content")
            }
            return MotionDraftAuthoritySource(
                authorityID: authority.id,
                caseName: authority.caseName,
                citation: citation,
                snippet: snippet,
                bindingSHA256: bindingSHA256,
                isReady: blockers.isEmpty,
                blockingReason: blockers.isEmpty ? nil : blockers.joined(separator: ", ")
            )
        }
    }

    nonisolated private static func motionCitation(from authority: AuthorityRecord) -> String {
        if let preferred = authority.preferredCitation?.trimmingCharacters(in: .whitespacesAndNewlines), !preferred.isEmpty {
            return preferred
        }
        guard let data = authority.citationJSON.data(using: .utf8),
              let citations = try? JSONDecoder().decode([String].self, from: data) else {
            return ""
        }
        return citations.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated private static func uniqueMotionFactSelections(
        _ values: [MotionDraftFactSourceSelection]
    ) -> [MotionDraftFactSourceSelection] {
        var seen = Set<String>()
        return values.compactMap { selection in
            let chunkID = selection.chunkID.trimmingCharacters(in: .whitespacesAndNewlines)
            let revisionID = selection.expectedRevisionID.trimmingCharacters(in: .whitespacesAndNewlines)
            let excerptSHA256 = selection.expectedExcerptSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunkID.isEmpty,
                  !revisionID.isEmpty,
                  excerptSHA256.utf8.count == 64,
                  excerptSHA256.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (97...102).contains(byte)
                  }),
                  seen.insert(chunkID).inserted else { return nil }
            return MotionDraftFactSourceSelection(
                chunkID: chunkID,
                expectedRevisionID: revisionID,
                expectedExcerptSHA256: excerptSHA256
            )
        }
    }

    nonisolated private static func uniqueMotionAuthoritySelections(
        _ values: [MotionDraftAuthoritySourceSelection]
    ) -> [MotionDraftAuthoritySourceSelection] {
        var seen = Set<String>()
        return values.compactMap { selection in
            let authorityID = selection.authorityID.trimmingCharacters(in: .whitespacesAndNewlines)
            let binding = selection.expectedBindingSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !authorityID.isEmpty,
                  !binding.isEmpty,
                  seen.insert(authorityID).inserted else { return nil }
            return MotionDraftAuthoritySourceSelection(
                authorityID: authorityID,
                expectedBindingSHA256: binding
            )
        }
    }

    nonisolated private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    nonisolated private static func letterFacts(from input: LetterDraftInput, claim: String) -> [GroundedFact] {
        var facts = [GroundedFact(text: claim, label: "claim", docId: "user-input", locator: "claim")]
        let amount = input.demandAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        if !amount.isEmpty {
            facts.append(GroundedFact(text: amount, label: "demandAmount", docId: "user-input", locator: "demandAmount"))
        }
        let deadline = input.responseDeadline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !deadline.isEmpty {
            facts.append(GroundedFact(text: deadline, label: "responseDeadline", docId: "user-input", locator: "responseDeadline"))
        }
        return facts
    }

    nonisolated private static func toneRegister(_ tone: String) -> String {
        switch tone.lowercased() {
        case "final": return "firm, final, and unequivocal — a last demand before suit"
        case "measured": return "professional and measured, leaving room to resolve"
        default: return "firm but professional"
        }
    }

    nonisolated private static func mapCoreDraftError(_ error: SupraDraftingCore.DraftError) -> DraftError {
        switch error {
        case let .verificationBlocked(summaries):
            return .verificationBlocked(summaries)
        default:
            return .renderFailed(String(describing: error))
        }
    }

    /// The letter's tone/register cue, enriched from the attorney's saved writing-style surface
    /// (SPEC §8, Track B). Prose voice ONLY — never facts, never structure; the enrichment rides
    /// the same "match the register only" prompt line the canned phrase does. An unconfigured
    /// profile (balanced formality/length, no notes) yields exactly the canned tone phrase, so
    /// existing prompts are byte-for-byte unchanged (prompt parity). `internal` for @testable.
    nonisolated static func voiceRegister(tone: String, profile: AssistantProfile) -> String {
        var parts = [toneRegister(tone)]
        switch profile.formality {
        case .formal: parts.append("formal register")
        case .plainSpoken: parts.append("plain-spoken, minimal legalese")
        case .balanced: break
        }
        switch profile.length {
        case .concise: parts.append("concise — no filler")
        case .thorough: parts.append("thorough and complete")
        case .balanced: break
        }
        let notes = profile.voiceNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            parts.append("the attorney's style notes: \(notes)")
        }
        return parts.joined(separator: "; ")
    }

    nonisolated private static func letterInputs(from input: LetterDraftInput) -> LetterDemand.Inputs {
        let name = input.recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = AddressBlock(
            name: name,
            title: nil,
            firm: input.recipientFirm.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            street: input.recipientStreet.trimmingCharacters(in: .whitespacesAndNewlines),
            city: input.recipientCity.trimmingCharacters(in: .whitespacesAndNewlines),
            state: input.recipientState.trimmingCharacters(in: .whitespacesAndNewlines),
            zip: input.recipientZip.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let salutation = input.salutation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Dear \(name.isEmpty ? "Sir or Madam" : name):"
        return LetterDemand.Inputs(
            recipient: recipient,
            reSubject: input.reSubject.trimmingCharacters(in: .whitespacesAndNewlines),
            salutation: salutation,
            date: .today,
            deliveryNotation: input.deliveryNotation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            enclosures: [],
            cc: []
        )
    }

    private static func displayTitle(for kind: DraftKindID) -> String {
        switch kind {
        case .noticeAppearance: return "Notice of Appearance"
        case .motionToDismiss: return "Motion to Dismiss"
        case .letterDemand: return "Demand Letter"
        }
    }

    nonisolated private static func customDescriptionMarkdown(
        title: String,
        description: String,
        instructions: String,
        matter: MatterRecord
    ) -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("> Work-product description — drafted by the user, not a court-ready filing or model output.")
        lines.append("")
        lines.append("**Matter:** \(matter.name)")
        if let court = matter.court?.trimmingCharacters(in: .whitespacesAndNewlines), !court.isEmpty {
            lines.append("**Court:** \(court)")
        }
        if let docket = matter.docketNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !docket.isEmpty {
            lines.append("**Case no.:** \(docket)")
        }
        lines.append("")
        lines.append("## Requested work product")
        lines.append("")
        lines.append(description)
        if !instructions.isEmpty {
            lines.append("")
            lines.append("## Instructions / notes")
            lines.append("")
            lines.append(instructions)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Profile → FirmProfile (slot-only identity)

    /// Projects the user's `AssistantProfile` onto the drafting `FirmProfile`. Pure
    /// and `nonisolated` so it can be unit-tested without the MainActor controller.
    /// `jurisdiction` (a filing's court/jurisdiction text) selects which bar admission
    /// prints; an empty value falls back to the primary license.
    nonisolated public static func firmProfile(
        from profile: AssistantProfile,
        jurisdiction: String = ""
    ) -> FirmProfile {
        let license = profile.resolvedBarLicense(forJurisdiction: jurisdiction)
        let barLabel = BarJurisdictionCatalog.jurisdiction(id: license?.jurisdictionID)?.barLabel ?? "Bar No."
        return FirmProfile(
            firmName: profile.organization.trimmingCharacters(in: .whitespacesAndNewlines),
            signingAttorney: profile.fullName.trimmingCharacters(in: .whitespacesAndNewlines),
            barNumber: license?.barNumber.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            barLabel: barLabel,
            office: OfficeBlock(
                street: profile.officeStreet.trimmingCharacters(in: .whitespacesAndNewlines),
                suite: profile.officeSuite.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                city: profile.officeCity.trimmingCharacters(in: .whitespacesAndNewlines),
                state: profile.officeState.trimmingCharacters(in: .whitespacesAndNewlines),
                zip: profile.officeZip.trimmingCharacters(in: .whitespacesAndNewlines),
                phone: profile.officePhone.trimmingCharacters(in: .whitespacesAndNewlines),
                fax: profile.officeFax.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ),
            primaryEmail: profile.primaryEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            secondaryEmails: profile.secondaryEmails
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    nonisolated private static func courtHeader(for matter: MatterRecord) -> String {
        if let court = matter.court?.trimmingCharacters(in: .whitespacesAndNewlines), !court.isEmpty {
            return court
        }
        return matter.jurisdiction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Motions are filing documents: a broad jurisdiction label is not a court
    /// caption and must never be substituted for one.
    nonisolated private static func explicitCourtHeader(for matter: MatterRecord) -> String {
        matter.court?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated private static func isSupportedNoticeJurisdiction(matter: MatterRecord, courtHeader: String) -> Bool {
        [matter.court, matter.jurisdiction, courtHeader]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { candidate in
                BarJurisdictionCatalog.match(candidate)?.id == "fl"
                    || candidate.localizedCaseInsensitiveContains("florida")
            }
    }

    nonisolated private static func normalizedParties(_ parties: [PartyLine]) -> [PartyLine] {
        parties.map {
            PartyLine(
                name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                designation: $0.designation.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    nonisolated private static func normalizedRecipients(_ recipients: [ServiceRecipient]) -> [ServiceRecipient] {
        recipients.map { recipient in
            ServiceRecipient(
                name: recipient.name.trimmingCharacters(in: .whitespacesAndNewlines),
                firm: recipient.firm.trimmingCharacters(in: .whitespacesAndNewlines),
                address: OfficeBlock(
                    street: recipient.address.street.trimmingCharacters(in: .whitespacesAndNewlines),
                    suite: recipient.address.suite?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    city: recipient.address.city.trimmingCharacters(in: .whitespacesAndNewlines),
                    state: recipient.address.state.trimmingCharacters(in: .whitespacesAndNewlines),
                    zip: recipient.address.zip.trimmingCharacters(in: .whitespacesAndNewlines),
                    phone: recipient.address.phone.trimmingCharacters(in: .whitespacesAndNewlines),
                    fax: recipient.address.fax?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ),
                emails: recipient.emails
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                role: recipient.role.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    // MARK: - Persistence

    private enum PersistenceError: Error, LocalizedError {
        case auditFailed(String)
        case partialFailure(audit: String, compensation: String)
        case rollbackSynchronizationUncertain(String)
        case postInstallStateUncertain(String)
        case temporaryCleanupUncertain(name: String, detail: String)
        case filenameAllocationFailed

        var errorDescription: String? {
            switch self {
            case let .auditFailed(detail):
                "The draft audit failed and the file change was rolled back: \(detail)"
            case let .partialFailure(audit, compensation):
                "The draft was installed, but auditing failed (\(audit)) and rollback also failed (\(compensation))."
            case let .rollbackSynchronizationUncertain(detail):
                "The draft install failed and rollback directory synchronization also failed; recovery is required: \(detail)"
            case let .postInstallStateUncertain(detail):
                "The draft install reached an uncertain final publication state; recovery is required: \(detail)"
            case let .temporaryCleanupUncertain(name, detail):
                "Managed temporary cleanup for \(name) could not be verified; recovery is required: \(detail)"
            case .filenameAllocationFailed:
                "A unique draft filename could not be allocated."
            }
        }
    }

    private func persist(
        data: Data,
        matterID: String,
        title: String,
        format: DocumentExportFormat,
        artifactKind: DraftArtifactIntentKind
    ) throws -> URL {
        let directory = storage.exportsDirectory(forMatterID: matterID)
        let rawStamp = sanitize(fileStampProvider())
        let stamp = rawStamp.isEmpty ? UUID().uuidString.lowercased() : rawStamp
        let basename = sanitize(title)

        for attempt in 1...100 {
            let collisionSuffix = attempt == 1 ? "" : "-\(attempt)"
            let fileName = "\(basename)-\(stamp)\(collisionSuffix).\(format.fileExtension)"
            let url = directory.appendingPathComponent(fileName)
            let intentFormat: DraftArtifactIntentFormat = format == .docx ? .docx : .markdown
            let intent: DraftArtifactIntentRecord
            do {
                intent = try store.draftArtifacts.prepareGenericIntent(
                    matterID: matterID,
                    artifactKind: artifactKind,
                    format: intentFormat,
                    fileName: fileName,
                    output: data
                )
            } catch DraftArtifactIntentError.fileNameReserved {
                continue
            }
            let installedIdentity: DurableFileWriter.InstalledFileIdentity
            do {
                installedIdentity = try fileWriter.writeNewOwned(
                    data,
                    to: url,
                    containedIn: storage.root
                ) { temporaryData in
                    try DocumentExportValidator.validate(temporaryData, as: format)
                }
            } catch DurableFileWriter.WriterError.destinationExists {
                try? store.draftArtifacts.abortIntent(id: intent.id)
                continue
            } catch let DurableFileWriter.WriterError.createOnlyRollbackSynchronizationFailed(detail) {
                try? store.draftArtifacts.markRecoveryRequired(id: intent.id)
                throw PersistenceError.rollbackSynchronizationUncertain(detail)
            } catch let DurableFileWriter.WriterError.postInstallStateUncertain(detail) {
                try? store.draftArtifacts.markRecoveryRequired(id: intent.id)
                throw PersistenceError.postInstallStateUncertain(detail)
            } catch let DurableFileWriter.WriterError.managedTemporaryCleanupUncertain(name, detail) {
                try? store.draftArtifacts.markRecoveryRequired(id: intent.id)
                throw PersistenceError.temporaryCleanupUncertain(name: name, detail: detail)
            } catch {
                try? store.draftArtifacts.abortIntent(id: intent.id)
                throw error
            }

            do {
                let event = try store.draftArtifacts.auditEventPreview(intentID: intent.id)
                try auditRecorder(event)
                let installed = try finalInstalledOutput(
                    at: url,
                    format: format,
                    expectedIdentity: installedIdentity,
                    intent: intent
                )
                try store.draftArtifacts.finalizeIntent(
                    id: intent.id,
                    installedOutput: installed
                )
            } catch {
                let auditDescription = error.localizedDescription
                do {
                    try removeNewDraftFile(
                        at: url,
                        expectedIdentity: installedIdentity,
                        expectedByteCount: intent.outputByteSize,
                        expectedSHA256: intent.outputSHA256
                    )
                    try store.draftArtifacts.abortIntent(id: intent.id)
                } catch {
                    try? store.draftArtifacts.markRecoveryRequired(id: intent.id)
                    throw PersistenceError.partialFailure(
                        audit: auditDescription,
                        compensation: error.localizedDescription
                    )
                }
                throw PersistenceError.auditFailed(auditDescription)
            }
            return url
        }
        throw PersistenceError.filenameAllocationFailed
    }

    /// Motion persistence is create-only. A collision chooses a distinct name;
    /// no reviewed artifact is ever replaced. The source snapshot is revalidated
    /// in the same Store transaction that appends the success audit.
    private func persistMotion(
        data: Data,
        matterID: String,
        title: String,
        snapshot: MotionDraftStoreSnapshot,
        auditInput: MotionDraftAuditInput
    ) throws -> URL {
        let directory = storage.exportsDirectory(forMatterID: matterID)
        let rawStamp = sanitize(fileStampProvider())
        let stamp = rawStamp.isEmpty ? UUID().uuidString.lowercased() : rawStamp
        let basename = sanitize(title)

        for attempt in 1...100 {
            try Task.checkCancellation()
            let collisionSuffix = attempt == 1 ? "" : "-\(attempt)"
            let fileName = "\(basename)-\(stamp)\(collisionSuffix).docx"
            let url = directory.appendingPathComponent(fileName)
            let intent: DraftArtifactIntentRecord
            do {
                intent = try store.draftArtifacts.prepareMotionIntent(
                    snapshot: snapshot,
                    fileName: fileName,
                    output: data,
                    auditInput: auditInput
                )
            } catch DraftArtifactIntentError.fileNameReserved {
                continue
            }
            let installedIdentity: DurableFileWriter.InstalledFileIdentity
            do {
                installedIdentity = try fileWriter.writeNewOwned(
                    data,
                    to: url,
                    containedIn: storage.root
                ) { temporaryData in
                    try DocumentExportValidator.validate(temporaryData, as: .docx)
                }
            } catch DurableFileWriter.WriterError.destinationExists {
                try? store.draftArtifacts.abortIntent(id: intent.id)
                continue
            } catch let DurableFileWriter.WriterError.createOnlyRollbackSynchronizationFailed(detail) {
                try? store.draftArtifacts.markRecoveryRequired(id: intent.id)
                throw PersistenceError.rollbackSynchronizationUncertain(detail)
            } catch let DurableFileWriter.WriterError.postInstallStateUncertain(detail) {
                try? store.draftArtifacts.markRecoveryRequired(id: intent.id)
                throw PersistenceError.postInstallStateUncertain(detail)
            } catch let DurableFileWriter.WriterError.managedTemporaryCleanupUncertain(name, detail) {
                try? store.draftArtifacts.markRecoveryRequired(id: intent.id)
                throw PersistenceError.temporaryCleanupUncertain(name: name, detail: detail)
            } catch {
                try? store.draftArtifacts.abortIntent(id: intent.id)
                throw error
            }
            do {
                let event = try store.draftArtifacts.auditEventPreview(intentID: intent.id)
                try motionAuditCommitter(event, snapshot)
                let installed = try finalInstalledOutput(
                    at: url,
                    format: .docx,
                    expectedIdentity: installedIdentity,
                    intent: intent
                )
                try store.draftArtifacts.finalizeIntent(
                    id: intent.id,
                    installedOutput: installed
                )
            } catch {
                let auditDescription = error.localizedDescription
                do {
                    try removeNewDraftFile(
                        at: url,
                        expectedIdentity: installedIdentity,
                        expectedByteCount: intent.outputByteSize,
                        expectedSHA256: intent.outputSHA256,
                        checkpoint: motionCompensationCheckpoint
                    )
                    try store.draftArtifacts.abortIntent(id: intent.id)
                } catch {
                    try? store.draftArtifacts.markRecoveryRequired(id: intent.id)
                    throw PersistenceError.partialFailure(
                        audit: auditDescription,
                        compensation: error.localizedDescription
                    )
                }
                throw PersistenceError.auditFailed(auditDescription)
            }
            return url
        }
        throw PersistenceError.filenameAllocationFailed
    }

    /// Reopens the public name through the retained managed-directory capability
    /// after the process-boundary observer. The writer binds format/content
    /// validation and two stable reads to the exact installed descriptor, then
    /// returns those bytes immediately before transactional finalize.
    private func finalInstalledOutput(
        at url: URL,
        format: DocumentExportFormat,
        expectedIdentity: DurableFileWriter.InstalledFileIdentity,
        intent: DraftArtifactIntentRecord
    ) throws -> Data {
        try fileWriter.validatedInstalledFileData(
            matching: expectedIdentity,
            at: url,
            containedIn: storage.root,
            expectedByteCount: intent.outputByteSize
        ) { installed in
            guard installed.count == intent.outputByteSize,
                  DocumentStorage.sha256Hex(of: installed) == intent.outputSHA256 else {
                throw DraftCompensationError.destinationChanged
            }
            try DocumentExportValidator.validate(installed, as: format)
        }
    }

    private enum DraftCompensationError: Error, LocalizedError {
        case quarantineFailed(Int32)
        case quarantineNameExhausted
        case destinationChanged
        case destinationChangedAndQuarantined(String, Int32)
        case inspectionFailed(String)
        case inspectionFailedAndQuarantined(String, Int32)
        case checkpointFailed(String)
        case checkpointFailedAndQuarantined(String, Int32)
        case deletionIdentityChanged(String)
        case deletionFailed(String, String)
        case directorySynchronizationFailed(String)
        case publicDestinationStillLinked(String)
        case publicDestinationStillLinkedWithoutRetainedQuarantine
        case publicDestinationStillLinkedAfterRemoval
        case quarantinePathChanged(String)
        case sourceNameReappeared(String)
        case retainedManagedFileChanged(String)
        case exactFileHasRemainingLinks(String, UInt64)
        case exactFileLinkStateUncertain(String, String)
        case removalCouldNotBeVerified

        var errorDescription: String? {
            switch self {
            case let .quarantineFailed(code):
                return "The new draft could not be quarantined for rollback (errno \(code))."
            case .quarantineNameExhausted:
                return "A unique same-directory draft rollback quarantine could not be allocated."
            case .destinationChanged:
                return "The new draft path changed before rollback; the changed file was restored and left untouched."
            case let .destinationChangedAndQuarantined(name, code):
                return "The new draft path changed before rollback; the concurrent destination was left untouched and the changed file remains preserved as \(name) (restore errno \(code))."
            case let .inspectionFailed(detail):
                return "The quarantined draft could not be inspected and was restored: \(detail)."
            case let .inspectionFailedAndQuarantined(name, code):
                return "The quarantined draft could not be inspected; the destination was left untouched and the file remains preserved as \(name) (restore errno \(code))."
            case let .checkpointFailed(detail):
                return "Draft rollback stopped before deletion and the file was restored: \(detail)."
            case let .checkpointFailedAndQuarantined(name, code):
                return "Draft rollback stopped before deletion; the destination was left untouched and the file remains preserved as \(name) (restore errno \(code))."
            case let .deletionIdentityChanged(name):
                return "The verified rollback quarantine changed before unlink and remains preserved as \(name)."
            case let .deletionFailed(name, detail):
                return "The verified rollback quarantine \(name) could not be removed: \(detail)."
            case let .directorySynchronizationFailed(detail):
                return "The draft rollback was removed, but its directory synchronization failed: \(detail)."
            case let .publicDestinationStillLinked(name):
                return "The exact installed draft remains at the public destination and rollback material remains preserved as \(name)."
            case .publicDestinationStillLinkedWithoutRetainedQuarantine:
                return "The exact installed draft remains at the public destination, but no exact rollback quarantine could be verified at the retained name; recovery is required."
            case .publicDestinationStillLinkedAfterRemoval:
                return "The exact installed draft reappeared at the public destination after quarantine removal; recovery is required."
            case let .quarantinePathChanged(name):
                return "The rollback quarantine path changed before deletion; nothing at \(name) was removed and recovery is required."
            case let .sourceNameReappeared(name):
                return "The removed rollback source name \(name) reappeared after directory synchronization; recovery is required."
            case let .retainedManagedFileChanged(name):
                return "The exact rollback file \(name) changed before deletion and remains preserved; recovery is required."
            case let .exactFileHasRemainingLinks(name, count):
                return "The exact rollback file \(name) still has \(count) filesystem link(s) after known-name removal; recovery is required."
            case let .exactFileLinkStateUncertain(name, detail):
                return "The exact rollback file \(name) link state could not be verified (\(detail)); recovery is required."
            case .removalCouldNotBeVerified:
                return "Draft rollback could not verify removal of the exact installed file; recovery is required."
            }
        }
    }

    private func removeNewDraftFile(
        at url: URL,
        expectedIdentity: DurableFileWriter.InstalledFileIdentity,
        expectedByteCount: Int,
        expectedSHA256: String,
        checkpoint: MotionCompensationCheckpoint = { _, _ in }
    ) throws {
        do {
            let removed = try fileWriter.removeInstalledFile(
                matching: expectedIdentity,
                at: url,
                containedIn: storage.root,
                expectedByteCount: expectedByteCount,
                missingIsSuccess: true,
                quarantineCheckpoint: { publicURL, quarantineURL in
                    do {
                        try checkpoint(publicURL, quarantineURL)
                    } catch {
                        throw DraftCompensationError.checkpointFailed(
                            error.localizedDescription
                        )
                    }
                },
                contentValidator: { data in
                    guard DocumentStorage.sha256Hex(of: data) == expectedSHA256 else {
                        throw DraftCompensationError.destinationChanged
                    }
                },
                preRemovalCheckpoint: { quarantineURL in
                    do {
                        try draftCompensationPreUnlinkCheckpoint(quarantineURL)
                    } catch {
                        throw DraftCompensationError.checkpointFailed(
                            error.localizedDescription
                        )
                    }
                }
            )
            guard removed else {
                throw DraftCompensationError.removalCouldNotBeVerified
            }
        } catch let error as DraftCompensationError {
            throw error
        } catch let DurableFileWriter.WriterError.createOnlyRollbackConflict(name, code) {
            throw DraftCompensationError.destinationChangedAndQuarantined(name, code)
        } catch let DurableFileWriter.WriterError.publicDestinationStillLinked(name) {
            throw DraftCompensationError.publicDestinationStillLinked(name)
        } catch DurableFileWriter.WriterError.publicDestinationStillLinkedWithoutRetainedQuarantine {
            throw DraftCompensationError.publicDestinationStillLinkedWithoutRetainedQuarantine
        } catch DurableFileWriter.WriterError.publicDestinationStillLinkedAfterRemoval {
            throw DraftCompensationError.publicDestinationStillLinkedAfterRemoval
        } catch let DurableFileWriter.WriterError.quarantinePathChanged(name) {
            throw DraftCompensationError.quarantinePathChanged(name)
        } catch let DurableFileWriter.WriterError.sourceNameReappeared(name) {
            throw DraftCompensationError.sourceNameReappeared(name)
        } catch let DurableFileWriter.WriterError.retainedManagedFileChanged(name) {
            throw DraftCompensationError.retainedManagedFileChanged(name)
        } catch let DurableFileWriter.WriterError.exactFileHasRemainingLinks(name, count) {
            throw DraftCompensationError.exactFileHasRemainingLinks(name, count)
        } catch let DurableFileWriter.WriterError.exactFileLinkStateUncertain(name, detail) {
            throw DraftCompensationError.exactFileLinkStateUncertain(name, detail)
        } catch let DurableFileWriter.WriterError.retainedQuarantineChanged(name) {
            throw DraftCompensationError.deletionIdentityChanged(name)
        } catch let DurableFileWriter.WriterError.anchoredParentDirectorySynchronizationFailed(detail) {
            throw DraftCompensationError.directorySynchronizationFailed(detail)
        } catch let DurableFileWriter.WriterError.createOnlyRollbackFailed(code) {
            throw DraftCompensationError.quarantineFailed(code)
        } catch {
            throw DraftCompensationError.deletionFailed(
                url.lastPathComponent,
                error.localizedDescription
            )
        }
    }

    private func sanitize(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-").prefix(60).description
    }

    nonisolated private static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Request layer value types

/// What produced a `DraftArtifact`. Keeps custom artifacts out of `DraftKindID` so we
/// never introduce a fake `.custom` kind the registry/renderer don't support.
public enum MatterDraftArtifactSource: Sendable, Equatable {
    case kind(DraftKindID)
    case customDescription
}

public enum DraftArtifactFormat: String, Sendable, Equatable {
    case docx
    case markdown
}

/// A catalog kind plus whether the app can generate it right now and why not.
public struct DraftKindAvailability: Sendable, Equatable, Identifiable {
    public var id: DraftKindID
    public var title: String
    public var isEnabled: Bool
    public var disabledReason: String?

    public init(id: DraftKindID, title: String, isEnabled: Bool, disabledReason: String? = nil) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
    }
}

/// The structured inputs for a Notice of Appearance, bundled so the Draft Workspace can
/// dispatch them through the shared `draft(_:matterID:)` entry point.
public struct NoticeAppearanceDraftInput: Sendable, Equatable {
    public var parties: [PartyLine]
    public var partyRepresented: String
    public var representedPartyName: String
    public var recipients: [ServiceRecipient]
    public var serviceDate: DateOnly

    public init(
        parties: [PartyLine],
        partyRepresented: String,
        representedPartyName: String,
        recipients: [ServiceRecipient],
        serviceDate: DateOnly = .today
    ) {
        self.parties = parties
        self.partyRepresented = partyRepresented
        self.representedPartyName = representedPartyName
        self.recipients = recipients
        self.serviceDate = serviceDate
    }
}

/// Attorney-supplied slots plus explicit, immutable source selections for the
/// first supported Florida motion vertical. No notice defaults are smuggled into
/// this request; the form must supply every caption/service value deliberately.
public struct MotionToDismissDraftInput: Sendable, Equatable {
    public var parties: [PartyLine]
    public var partyRepresented: String
    public var representedPartyName: String
    public var recipients: [ServiceRecipient]
    public var serviceDate: DateOnly
    public var respondingTo: String
    public var grounds: [String]
    public var reliefSought: String
    public var selectedFacts: [MotionDraftFactSourceSelection]
    public var selectedAuthorities: [MotionDraftAuthoritySourceSelection]

    public init(
        parties: [PartyLine],
        partyRepresented: String,
        representedPartyName: String,
        recipients: [ServiceRecipient],
        serviceDate: DateOnly = .today,
        respondingTo: String,
        grounds: [String],
        reliefSought: String,
        selectedFacts: [MotionDraftFactSourceSelection],
        selectedAuthorities: [MotionDraftAuthoritySourceSelection]
    ) {
        self.parties = parties
        self.partyRepresented = partyRepresented
        self.representedPartyName = representedPartyName
        self.recipients = recipients
        self.serviceDate = serviceDate
        self.respondingTo = respondingTo
        self.grounds = grounds
        self.reliefSought = reliefSought
        self.selectedFacts = selectedFacts
        self.selectedAuthorities = selectedAuthorities
    }

    public var selectedFactChunkIDs: [String] { selectedFacts.map(\.chunkID) }
}

/// The exact revision and excerpt bytes displayed when counsel selected a fact.
/// A chunk identifier alone is insufficient because reindexing can reuse it for
/// different persisted text.
public struct MotionDraftFactSourceSelection: Sendable, Equatable, Hashable {
    public let chunkID: String
    public let expectedRevisionID: String
    public let expectedExcerptSHA256: String

    public init(
        chunkID: String,
        expectedRevisionID: String,
        expectedExcerptSHA256: String
    ) {
        self.chunkID = chunkID
        self.expectedRevisionID = expectedRevisionID
        self.expectedExcerptSHA256 = expectedExcerptSHA256
    }
}

/// The exact reviewed authority evidence the user selected from the displayed
/// source row. Reusing only the authority ID would allow a later review envelope
/// to be substituted silently before snapshot capture.
public struct MotionDraftAuthoritySourceSelection: Sendable, Equatable, Hashable {
    public let authorityID: String
    public let expectedBindingSHA256: String

    public init(authorityID: String, expectedBindingSHA256: String) {
        self.authorityID = authorityID
        self.expectedBindingSHA256 = expectedBindingSHA256
    }
}

public struct MotionDraftFactSource: Sendable, Equatable, Identifiable {
    public var id: String { chunkID }
    public let chunkID: String
    public let documentID: String
    public let documentRevisionID: String
    public let excerptSHA256: String
    public let documentName: String
    public let locator: String
    public let text: String
    public let isReady: Bool
    public let blockingReason: String?

    public var displayExcerpt: String { String(text.prefix(240)) }

    public init(
        chunkID: String,
        documentID: String,
        documentRevisionID: String,
        excerptSHA256: String,
        documentName: String,
        locator: String,
        text: String,
        isReady: Bool,
        blockingReason: String?
    ) {
        self.chunkID = chunkID
        self.documentID = documentID
        self.documentRevisionID = documentRevisionID
        self.excerptSHA256 = excerptSHA256
        self.documentName = documentName
        self.locator = locator
        self.text = text
        self.isReady = isReady
        self.blockingReason = blockingReason
    }
}

public struct MotionDraftAuthoritySource: Sendable, Equatable, Identifiable {
    public var id: String { authorityID }
    public let authorityID: String
    public let caseName: String
    public let citation: String
    public let snippet: String
    public let bindingSHA256: String?
    public let isReady: Bool
    public let blockingReason: String?

    public var displayExcerpt: String { String(snippet.prefix(240)) }

    public init(
        authorityID: String,
        caseName: String,
        citation: String,
        snippet: String,
        bindingSHA256: String?,
        isReady: Bool,
        blockingReason: String?
    ) {
        self.authorityID = authorityID
        self.caseName = caseName
        self.citation = citation
        self.snippet = snippet
        self.bindingSHA256 = bindingSHA256
        self.isReady = isReady
        self.blockingReason = blockingReason
    }
}

public struct MotionDraftReadiness: Sendable, Equatable {
    public let selectedFactCount: Int
    public let selectedAuthorityCount: Int
    public let blockingReasons: [String]

    public var canGenerate: Bool { blockingReasons.isEmpty }

    public init(selectedFactCount: Int, selectedAuthorityCount: Int, blockingReasons: [String]) {
        self.selectedFactCount = selectedFactCount
        self.selectedAuthorityCount = selectedAuthorityCount
        self.blockingReasons = blockingReasons
    }
}

struct MotionDraftPacket: Sendable, Equatable {
    struct Fact: Sendable, Equatable {
        let chunkID: String
        let documentID: String
        let revisionID: String
        let documentName: String
        let locator: String
        let text: String
    }

    struct Authority: Sendable, Equatable {
        let authorityID: String
        let caseName: String
        let citation: String
        let snippet: String
    }

    let facts: [Fact]
    let authorities: [Authority]
    let groundSpecs: [MotionGroundSpec]
}

/// Stored on the required `draft_generated` audit row. Raw source/profile text
/// is excluded; immutable row identities and canonical hashes retain the exact
/// assembly, verification, and output lineage.
@available(*, deprecated, message: "Use the Store-built MotionDraftAuditLineage")
public struct LegacyMotionDraftAuditLineage: Codable, Sendable, Equatable {
    public struct Fact: Codable, Sendable, Equatable {
        public let chunkID: String
        public let documentID: String
        public let partID: String
        public let revisionID: String
        public let nodeID: String?
        public let unitKind: String?
        public let chunkerVersion: Int
        public let charStart: Int
        public let charEnd: Int
        public let ocrConfidence: Double?
        public let boundingBoxesSHA256: String?
        public let relatedStructureEdges: [MotionDraftStructureEdgeSnapshot]
        public let revisionSHA256: String
        public let excerptSHA256: String

        public init(_ source: MotionDraftFactSnapshot) {
            chunkID = source.chunkID
            documentID = source.documentID
            partID = source.partID
            revisionID = source.revisionID
            nodeID = source.nodeID
            unitKind = source.unitKind
            chunkerVersion = source.chunkerVersion
            charStart = source.charStart
            charEnd = source.charEnd
            ocrConfidence = source.ocrConfidence
            boundingBoxesSHA256 = source.boundingBoxesSHA256
            relatedStructureEdges = source.relatedStructureEdges
            revisionSHA256 = source.revisionSHA256
            excerptSHA256 = source.excerptSHA256
        }
    }

    public struct Authority: Codable, Sendable, Equatable {
        public let authorityID: String
        public let groundKey: String
        public let evidenceSchemaVersion: Int
        public let excerptByteStart: Int
        public let excerptByteLength: Int
        public let opinionSHA256: String
        public let excerptSHA256: String
        public let effectiveCitationSHA256: String
        public let courtSHA256: String
        public let bindingSHA256: String

        public init(_ source: MotionDraftAuthoritySnapshot) {
            authorityID = source.authorityID
            groundKey = source.groundKey.rawValue
            evidenceSchemaVersion = source.evidenceSchemaVersion
            excerptByteStart = source.excerptByteStart
            excerptByteLength = source.excerptByteLength
            opinionSHA256 = source.opinionSHA256
            excerptSHA256 = source.excerptSHA256
            effectiveCitationSHA256 = source.effectiveCitationSHA256
            courtSHA256 = source.courtSHA256
            bindingSHA256 = source.bindingSHA256
        }
    }

    public let schemaVersion: Int
    public let kindID: String
    public let sourceSnapshotSHA256: String
    public let facts: [Fact]
    public let authorities: [Authority]
    public let groundKeys: [String]
    public let requestSHA256: String
    public let captionSHA256: String
    public let assistantProfileSHA256: String
    public let effectiveStyleSHA256: String
    public let groundContractIdentity: DraftComponentIdentity
    public let assemblerIdentity: DraftComponentIdentity
    public let verifierIdentity: DraftComponentIdentity
    public let gateIdentity: DraftComponentIdentity
    public let rendererIdentity: DraftComponentIdentity
    public let verificationReceiptSHA256: String
    public let verificationStatus: DraftVerificationStatus
    public var outputFileName: String
    public let outputSHA256: String
    public let outputByteSize: Int

    public init(
        schemaVersion: Int,
        kindID: String,
        sourceSnapshotSHA256: String,
        facts: [Fact],
        authorities: [Authority],
        groundKeys: [String],
        requestSHA256: String,
        captionSHA256: String,
        assistantProfileSHA256: String,
        effectiveStyleSHA256: String,
        groundContractIdentity: DraftComponentIdentity,
        assemblerIdentity: DraftComponentIdentity,
        verifierIdentity: DraftComponentIdentity,
        gateIdentity: DraftComponentIdentity,
        rendererIdentity: DraftComponentIdentity,
        verificationReceiptSHA256: String,
        verificationStatus: DraftVerificationStatus,
        outputFileName: String,
        outputSHA256: String,
        outputByteSize: Int
    ) {
        self.schemaVersion = schemaVersion
        self.kindID = kindID
        self.sourceSnapshotSHA256 = sourceSnapshotSHA256
        self.facts = facts
        self.authorities = authorities
        self.groundKeys = groundKeys
        self.requestSHA256 = requestSHA256
        self.captionSHA256 = captionSHA256
        self.assistantProfileSHA256 = assistantProfileSHA256
        self.effectiveStyleSHA256 = effectiveStyleSHA256
        self.groundContractIdentity = groundContractIdentity
        self.assemblerIdentity = assemblerIdentity
        self.verifierIdentity = verifierIdentity
        self.gateIdentity = gateIdentity
        self.rendererIdentity = rendererIdentity
        self.verificationReceiptSHA256 = verificationReceiptSHA256
        self.verificationStatus = verificationStatus
        self.outputFileName = outputFileName
        self.outputSHA256 = outputSHA256
        self.outputByteSize = outputByteSize
    }
}

/// The user-facing inputs for a Demand Letter. The claim/amount/deadline become the
/// grounded facts the model may use; the rest fill the deterministic letter scaffold.
public struct LetterDraftInput: Sendable, Equatable {
    public var recipientName: String
    public var recipientFirm: String
    public var recipientStreet: String
    public var recipientCity: String
    public var recipientState: String
    public var recipientZip: String
    public var reSubject: String
    public var salutation: String
    public var claimSummary: String
    public var demandAmount: String
    public var responseDeadline: String
    public var tone: String
    public var deliveryNotation: String

    public init(
        recipientName: String = "",
        recipientFirm: String = "",
        recipientStreet: String = "",
        recipientCity: String = "",
        recipientState: String = "",
        recipientZip: String = "",
        reSubject: String = "",
        salutation: String = "",
        claimSummary: String = "",
        demandAmount: String = "",
        responseDeadline: String = "",
        tone: String = "firm",
        deliveryNotation: String = ""
    ) {
        self.recipientName = recipientName
        self.recipientFirm = recipientFirm
        self.recipientStreet = recipientStreet
        self.recipientCity = recipientCity
        self.recipientState = recipientState
        self.recipientZip = recipientZip
        self.reSubject = reSubject
        self.salutation = salutation
        self.claimSummary = claimSummary
        self.demandAmount = demandAmount
        self.responseDeadline = responseDeadline
        self.tone = tone
        self.deliveryNotation = deliveryNotation
    }
}

/// A free-form work-product description for kinds the app can't render yet.
public struct CustomDraftDescriptionInput: Sendable, Equatable {
    public var title: String
    public var description: String
    public var instructions: String

    public init(title: String, description: String, instructions: String = "") {
        self.title = title
        self.description = description
        self.instructions = instructions
    }
}

/// A typed drafting request dispatched by the Draft Workspace.
public enum MatterDraftRequest: Sendable, Equatable {
    case noticeAppearance(NoticeAppearanceDraftInput)
    case motionToDismiss(MotionToDismissDraftInput)
    case customDescription(CustomDraftDescriptionInput)
}

// MARK: - Convenience factory

extension DraftPipeline {
    /// The default chat pipeline: deterministic verifier + the court/letter renderer.
    /// The renderer dispatches on `RenderInput`, so one instance serves both shells.
    public static func makeDefault() -> DraftPipeline {
        DraftPipeline(verifier: DraftVerifier(), renderer: CompositeRenderer())
    }
}
