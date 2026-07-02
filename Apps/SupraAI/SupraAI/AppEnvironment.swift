import Combine
import Foundation
import SupraCore
import SupraDocuments
import SupraNetworking
import SupraResearch
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraSessions
import SupraStore

@MainActor
final class AppEnvironment: ObservableObject {
    @Published var runtimeServiceState: RuntimeServiceState = .disconnected
    @Published var runtimeStatusMessage = "Checking runtime"
    /// True when the on-disk store could not be opened and the app fell back to a
    /// throwaway temporary database — surfaced as a warning so the user knows their
    /// data is not being persisted.
    @Published private(set) var usingFallbackStore = false
    /// True on a fresh first launch (no models yet, onboarding never completed) — gates
    /// the first-run model-download flow. Set in `bootstrap()`; cleared once the user
    /// finishes or skips onboarding. Always false under UI tests.
    @Published private(set) var shouldShowOnboarding = false

    /// App-settings key recording when first-run onboarding was completed/skipped.
    private static let onboardingCompletedKey = "onboarding.completedAt"

    let store: SupraStore
    let modelLibrary: ModelLibrary
    let chatController: GlobalChatController
    let modelDownloadController: ModelDownloadController
    let settingsController: SettingsController
    let assistantProfileController: AssistantProfileController
    let sparkleUpdater: SparkleUpdaterController
    let mattersController: MattersController
    let recycleBinController: RecycleBinController
    // Milestone 4: ScratchPad daily notes -> billing.
    let scratchPadController: ScratchPadController
    let billingDraftController: BillingDraftController
    let billingSettingsController: BillingSettingsController
    // Milestone 3: document intelligence setup.
    let documentSetupController: DocumentIntelligenceSetupController
    let embeddingDownloadController: EmbeddingModelDownloadController
    let documentQueue: DocumentProcessingQueue

    private let runtimeStatusController: RuntimeStatusController

    init() {
        let runtimeClient = RuntimeClient()
        let storeResult = AppEnvironment.makeStore()
        let store = storeResult.store
        let systemPrompt = DefaultSystemPrompt.milestone1()
        let appVersion = AppEnvironment.currentAppVersion()
        let modelLibrary = ModelLibrary(store: store, runtimeClient: runtimeClient)
        self.store = store
        self.usingFallbackStore = storeResult.isFallback
        self.runtimeStatusController = RuntimeStatusController(runtimeClient: runtimeClient)
        self.modelLibrary = modelLibrary
        self.chatController = GlobalChatController(
            store: store,
            runtimeClient: runtimeClient,
            defaultSystemPrompt: systemPrompt
        )
        self.modelDownloadController = ModelDownloadController(
            store: store,
            modelLibrary: modelLibrary,
            fetcher: HuggingFaceClient()
        )
        self.settingsController = SettingsController(store: store, appVersion: appVersion)
        self.assistantProfileController = AssistantProfileController(store: store, basePrompt: systemPrompt)
        self.sparkleUpdater = SparkleUpdaterController()
        self.recycleBinController = RecycleBinController(store: store)
        self.scratchPadController = ScratchPadController(store: store)
        // Phase 7: the billing draft controller is seeded from the firm's persisted
        // ScratchPad billing settings (timekeeper, rounding, sensitivity, etc.).
        let billingSettings = BillingSettingsController(store: store)
        self.billingSettingsController = billingSettings
        let billingDraft = BillingDraftController(
            store: store,
            service: BillingDraftService.live(store: store, modelLibrary: modelLibrary, runtimeClient: runtimeClient),
            timekeeper: billingSettings.timekeeper
        )
        billingDraft.applySettings(billingSettings.settings)
        self.billingDraftController = billingDraft

        // Document intelligence controllers must exist before MattersController so
        // it can vend a per-matter Documents controller wired to the queue + gate.
        let documentSetup = DocumentIntelligenceSetupController(store: store, runtimeClient: runtimeClient)
        self.documentSetupController = documentSetup
        self.embeddingDownloadController = EmbeddingModelDownloadController(
            store: store,
            fetcher: HuggingFaceClient()
        )
        // A finished embedding download refreshes the setup controller's model list
        // and auto-verifies the new model, so it appears in "Select for use" and
        // turns green without a manual Re-check or Test Load.
        self.embeddingDownloadController.onModelRegistered = { [weak documentSetup] in
            documentSetup?.handleEmbeddingModelDownloaded()
        }
        let queue = DocumentProcessingQueue(
            store: store,
            importService: DocumentImportService(store: store),
            makeIndexingService: {
                // Build a fresh indexing service per job using the currently
                // selected embedding model (if any).
                let model = try? store.documentSettings.fetchSelectedEmbeddingModel()
                let embedder = model.flatMap { RuntimeTextEmbedder(model: $0, runtimeClient: runtimeClient) }
                return DocumentIndexingService(store: store, embedder: embedder)
            },
            // Suggests a taxonomy category for each imported document using the
            // assigned task model. Self-skips when no model is loadable.
            classificationService: DocumentClassificationService(
                store: store, modelLibrary: modelLibrary, runtimeClient: runtimeClient
            )
        )
        self.documentQueue = queue
        self.mattersController = MattersController(
            store: store,
            runtimeClient: runtimeClient,
            defaultSystemPrompt: systemPrompt,
            documentQueue: queue,
            isImportReady: { documentSetup.isReadyForImport }
        )
        if Self.isUITestMode {
            seedUITestFixturesIfNeeded()
        }
        if Self.isDemoMode {
            seedDemoFixturesIfNeeded()
        }
    }

    /// Loads persisted state and refreshes runtime status on launch.
    func bootstrap() async {
        // Reconcile any validation run abandoned by a previous quit/crash so it
        // surfaces as cancelled rather than lingering as in-progress.
        try? store.validation.markUnfinishedRunsCancelled()
        modelLibrary.refresh()
        // First-run onboarding: a truly fresh launch (no models yet, never completed)
        // shows the guided model-download flow. UI tests skip it entirely.
        let onboarded = (try? store.appSettings.getSetting(Self.onboardingCompletedKey, as: Date.self)) != nil
        shouldShowOnboarding = !Self.isUITestMode && !Self.isDemoMode && !onboarded && modelLibrary.models.isEmpty
        chatController.loadChats()
        // Each launch opens the global chat fresh — a blank new chat with example
        // prompts — rather than reopening the last conversation. The prior chats
        // stay one click away in the history sidebar.
        chatController.startNewChat()
        // Seed UI-test data before any runtime/status refresh that may take time on
        // a machine without the helper service running; the shell can render matters
        // immediately while the rest of bootstrap finishes.
        if Self.isUITestMode { seedUITestFixturesIfNeeded() }
        if Self.isDemoMode { seedDemoFixturesIfNeeded() }
        await refreshRuntimeStatus()
        // If the runtime already holds a model from a previous session, re-enable
        // chat without forcing the user to re-load it (the chat gate keys on
        // ModelLibrary.loadState, which otherwise starts idle each launch).
        modelLibrary.reconcileLoadedModel(runtimeStatusController.loadedModelID)
        autoLoadStartupModelIfNeeded()
        await documentSetupController.refreshAll()
        // Reconcile any document job interrupted by a previous quit (plan §5.4).
        documentQueue.bootstrap()
        // Auto-purge documents and chats soft-deleted past the retention window
        // (plan §12.2). Matters are never auto-purged — only manually from the Recycle Bin.
        let maintenance = DocumentMaintenance(store: store)
        maintenance.purgeExpired()
        maintenance.purgeExpiredChats()
        // Start Sparkle: scheduled background checks + silent download, surfacing a
        // single "Install and Relaunch" prompt. Skipped in UI tests.
        if !Self.isUITestMode, !Self.isDemoMode { sparkleUpdater.start() }
    }

    /// Records that first-run onboarding was completed or skipped and dismisses it.
    /// Persisted so it never reappears; downloads started during onboarding continue
    /// because the download controllers live here, not on the dismissed view.
    func markOnboardingComplete() {
        try? store.appSettings.setSetting(Self.onboardingCompletedKey, value: Date())
        shouldShowOnboarding = false
    }

    /// Auto-loads the startup model into the runtime on launch for manual runtime
    /// workflows. Prefers the best available reasoning model (see
    /// `ModelLibrary.startupModelID`) so the app opens ready for complex reasoning
    /// rather than the lighter drafting/instruct model. Routed chat tasks still load
    /// their assigned role model before generation. Skipped when a model is already
    /// loaded or in UI tests.
    private func autoLoadStartupModelIfNeeded() {
        guard !Self.isUITestMode,
              case .idle = modelLibrary.loadState,
              let startupModelID = modelLibrary.startupModelID() else { return }
        Task {
            await modelLibrary.activateAndLoad(modelID: startupModelID)
            // bootstrap()'s refreshAll() likely ran while the model was still
            // loading and cached chatModelLoaded = false. Re-query once the
            // background load settles so the Settings checklist reflects the
            // now-loaded model without a manual Re-check.
            await documentSetupController.refreshChatModelStatus()
        }
    }

    func refreshRuntimeStatus() async {
        await runtimeStatusController.refresh()
        runtimeServiceState = runtimeStatusController.serviceState
        runtimeStatusMessage = runtimeStatusController.statusMessage
    }

    /// True when launched by the XCUITest harness (passes `-uiTestMode`). Drives a
    /// hermetic throwaway store + a seeded matter so UI tests never touch real data.
    static var isUITestMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestMode")
    }

    /// True when launched with `-demoMode`: the same hermetic throwaway store as UI
    /// tests, seeded with entirely FICTITIOUS demo data (fictional parties, clients,
    /// and documents; only the case law is real) for marketing screenshots. Never
    /// touches the user's real database.
    static var isDemoMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-demoMode")
    }

    /// Seeds a deterministic matter for UI tests if none exists yet.
    private func seedUITestFixturesIfNeeded() {
        mattersController.loadMatters()
        if mattersController.matters.isEmpty {
            _ = try? mattersController.createMatter(name: "McKernon Motors v. Liberty Rail")
            mattersController.loadMatters()
        }
        seedUITestCitationsChatIfNeeded()
    }

    /// Seeds a global chat whose assistant answer carries clickable `[A1]` (authority)
    /// and `[S1]` (document source) citations, plus a small text document so the
    /// `[S1]` preview resolves to real content. Lets UI tests exercise the sources
    /// block / inline-citation / export features without a model or network.
    private func seedUITestCitationsChatIfNeeded() {
        let existing = (try? store.chats.fetchGlobalChats()) ?? []
        guard !existing.contains(where: { $0.title == "Citations Demo" }) else { return }
        do {
            // A text document so the [S1] citation opens a real preview.
            var documentID: String?
            if let matterID = mattersController.matters.first?.id {
                let blob = try store.documentLibrary.upsertBlob(
                    DocumentBlobRecord(
                        sha256: "uitest-agreement-sha",
                        byteSize: 0,
                        originalExtension: "pdf",
                        managedRelativePath: "uitest/agreement.pdf"
                    )
                ).blob
                let document = try store.documentLibrary.insertDocument(
                    MatterDocumentRecord(
                        matterID: matterID,
                        blobID: blob.id,
                        displayName: "agreement.pdf",
                        status: MatterDocumentStatus.ready.rawValue
                    )
                )
                try store.documentIndex.replaceParts(documentID: document.id, parts: [
                    DocumentPagePartRecord(
                        documentID: document.id,
                        partIndex: 0,
                        sourceKind: DocumentSourceKind.text.rawValue,
                        normalizedText: "SECTION 3. The term of this Agreement is two (2) years from the Effective Date.",
                        charCount: 76
                    )
                ])
                documentID = document.id
            }

            let chat = try store.chats.createGlobalChat(title: "Citations Demo")
            _ = try store.chats.appendUserMessage(
                chatID: chat.id,
                content: "Summarize the controlling authority and the contract term."
            )
            let assistant = try store.chats.createAssistantMessageShell(chatID: chat.id)
            let variant = try store.chats.createVariant(messageID: assistant.id, generationSessionID: nil)
            let answer = "The Ninth Circuit recognized the claim [A1]. Your agreement confirms a two-year term [S1]."
            try store.chats.appendToken(to: variant.id, token: answer)
            try store.chats.completeVariant(variant.id)

            let locator = DocumentSourceLocator(sourceKind: .text, charStart: 0, charEnd: 9)
            try store.chats.replaceCitations(messageID: assistant.id, [
                MessageCitationRecord(
                    messageID: assistant.id, label: "A1", kind: "authority",
                    url: "https://www.courtlistener.com/opinion/1/foo-v-bar/",
                    displayName: "Foo v. Bar, 1 F.4th 1", rank: 0
                ),
                MessageCitationRecord(
                    messageID: assistant.id, label: "S1", kind: "source",
                    documentID: documentID, locatorJSON: locator.encodedJSON(),
                    displayName: "agreement.pdf", matchText: "SECTION 3", rank: 1
                )
            ])
        } catch {
            // Best-effort fixture seeding — a failure just means the demo chat is absent.
        }
    }

    // MARK: - Demo mode (marketing screenshots)

    /// Seeds entirely FICTITIOUS demo data for `-demoMode` screenshots: fictional
    /// parties, clients, documents, and deponents. Only the case law is real
    /// (public-domain opinions). Runs against the hermetic throwaway store only.
    private func seedDemoFixturesIfNeeded() {
        mattersController.loadMatters()
        guard mattersController.matters.isEmpty else { return }
        do {
            let matter = try store.matters.createMatter(
                name: "Meridian Fabrication v. Northgate Logistics",
                jurisdiction: "Florida",
                partyPerspective: .plaintiff,
                court: "U.S. District Court, Southern District of Florida",
                docketNumber: "9:26-cv-81452",
                practiceArea: "Commercial Litigation",
                clientNames: "Meridian Fabrication, Inc."
            )

            // Fictitious documents with real (fictional) contract text so previews work.
            let msaText = """
            SECTION 9. INDEMNIFICATION. Carrier shall defend, indemnify, and hold harmless \
            Meridian Fabrication, Inc. and its officers, directors, and employees from and \
            against any third-party claims, damages, and expenses (including reasonable \
            attorneys' fees) arising out of Carrier's negligent performance of the Services. \
            SECTION 10. INSURANCE. Carrier shall maintain commercial general liability \
            insurance with limits of not less than $2,000,000 per occurrence, naming \
            Meridian Fabrication, Inc. as an additional insured, and shall furnish \
            certificates of insurance upon request.
            """
            let depoText = """
            Q. Mr. Calloway, who was responsible for securing the load on the morning of \
            March 14? A. That would have been our dock crew. Q. And were the tie-down \
            procedures in the driver handbook followed that morning? A. Not to my knowledge, \
            no. The straps were not doubled as the handbook requires.
            """
            let coverageText = """
            Re: Claim No. NGL-2026-0417 — Meridian Fabrication, Inc. v. Northgate Logistics. \
            Dear Counsel: We acknowledge tender of the above-referenced claim under policy \
            CGL-88214. Coverage is accepted subject to a full reservation of rights, \
            including with respect to timeliness of notice under Condition 4(b).
            """
            let msaID = try seedDemoDocument(
                matterID: matter.id, name: "Master Services Agreement (2024).pdf",
                sha: "demo-msa", text: msaText
            )
            let depoID = try seedDemoDocument(
                matterID: matter.id, name: "Deposition Tr. — R. Calloway (Vol. I).pdf",
                sha: "demo-depo", text: depoText
            )
            let coverageID = try seedDemoDocument(
                matterID: matter.id, name: "Insurance Coverage Letter.docx",
                sha: "demo-coverage", text: coverageText
            )
            let contractsTag = try store.documentLibrary.createTag(matterID: matter.id, name: "Contracts")
            let depositionsTag = try store.documentLibrary.createTag(matterID: matter.id, name: "Depositions")
            let insuranceTag = try store.documentLibrary.createTag(matterID: matter.id, name: "Insurance")
            try store.documentLibrary.assignTag(tagID: contractsTag.id, documentID: msaID)
            try store.documentLibrary.assignTag(tagID: depositionsTag.id, documentID: depoID)
            try store.documentLibrary.assignTag(tagID: insuranceTag.id, documentID: coverageID)
            try store.documentLibrary.assignTag(tagID: insuranceTag.id, documentID: msaID)

            // A grounded matter-chat answer with clickable [S#] document citations.
            let docChat = try store.chats.createMatterChat(matterID: matter.id, title: "Indemnification coverage")
            _ = try store.chats.appendUserMessage(
                chatID: docChat.id,
                content: "What do my documents say about indemnification and insurance coverage?"
            )
            let docAssistant = try store.chats.createAssistantMessageShell(chatID: docChat.id)
            let docVariant = try store.chats.createVariant(messageID: docAssistant.id, generationSessionID: nil)
            let docAnswer = """
            Under the Master Services Agreement, Northgate must defend and indemnify Meridian \
            against third-party claims arising from Northgate's negligent performance of the \
            carrier services [S1]. That indemnity is backed by an insurance covenant: Northgate \
            is required to maintain commercial general liability coverage of at least $2,000,000 \
            per occurrence and to name Meridian as an additional insured [S1].

            The insurer has acknowledged tender of the claim, but coverage was accepted subject \
            to a full reservation of rights on the late-notice issue under Condition 4(b) [S2]. \
            The deposition testimony supports the underlying negligence theory: the dock crew did \
            not follow the handbook's tie-down procedures on the morning of the incident [S3].
            """
            try store.chats.appendToken(to: docVariant.id, token: docAnswer)
            try store.chats.completeVariant(docVariant.id)
            try store.chats.replaceCitations(messageID: docAssistant.id, [
                MessageCitationRecord(
                    messageID: docAssistant.id, label: "S1", kind: "source",
                    documentID: msaID,
                    locatorJSON: DocumentSourceLocator(sourceKind: .text, charStart: 0, charEnd: 320).encodedJSON(),
                    displayName: "Master Services Agreement (2024).pdf",
                    matchText: "SECTION 9. INDEMNIFICATION", rank: 0
                ),
                MessageCitationRecord(
                    messageID: docAssistant.id, label: "S2", kind: "source",
                    documentID: coverageID,
                    locatorJSON: DocumentSourceLocator(sourceKind: .text, charStart: 0, charEnd: 200).encodedJSON(),
                    displayName: "Insurance Coverage Letter.docx",
                    matchText: "reservation of rights", rank: 1
                ),
                MessageCitationRecord(
                    messageID: docAssistant.id, label: "S3", kind: "source",
                    documentID: depoID,
                    locatorJSON: DocumentSourceLocator(sourceKind: .text, charStart: 0, charEnd: 220).encodedJSON(),
                    displayName: "Deposition Tr. — R. Calloway (Vol. I).pdf",
                    matchText: "tie-down procedures", rank: 2
                )
            ])

            // A saved authority with REAL case law (public domain) so the in-app
            // opinion reader has offline text: Winter v. NRDC, 555 U.S. 7 (2008).
            let session = try store.research.createSession(
                matterID: matter.id, title: "Preliminary injunction standard",
                issueText: "Standard for granting a preliminary injunction", jurisdiction: "Federal",
                status: .complete
            )
            let query = try store.research.createQuery(
                researchSessionID: session.id, queryText: "\"preliminary injunction\" standard",
                queryIndex: 0, status: .approved
            )
            let result = try store.research.insertResult(ResearchResultRecord(
                researchQueryID: query.id,
                caseName: "Winter v. Natural Resources Defense Council, Inc.",
                citationJSON: #"["555 U.S. 7"]"#,
                preferredCitation: "555 U.S. 7",
                court: "Supreme Court of the United States",
                reviewState: ResearchResultReviewState.saved.rawValue
            ))
            let winterText = """
            A preliminary injunction is an extraordinary remedy never awarded as of right. \
            In each case, courts must balance the competing claims of injury and must consider \
            the effect on each party of the granting or withholding of the requested relief.

            A plaintiff seeking a preliminary injunction must establish that he is likely to \
            succeed on the merits, that he is likely to suffer irreparable harm in the absence \
            of preliminary relief, that the balance of equities tips in his favor, and that an \
            injunction is in the public interest.

            Issuing a preliminary injunction based only on a possibility of irreparable harm \
            is inconsistent with our characterization of injunctive relief as an extraordinary \
            remedy that may only be awarded upon a clear showing that the plaintiff is entitled \
            to such relief.
            """
            _ = try store.authorities.insertAuthority(AuthorityRecord(
                matterID: matter.id,
                researchSessionID: session.id,
                researchResultID: result.id,
                opinionID: "demo-winter",
                caseName: "Winter v. Natural Resources Defense Council, Inc.",
                citationJSON: #"["555 U.S. 7"]"#,
                preferredCitation: "555 U.S. 7",
                court: "Supreme Court of the United States",
                courtID: "scotus",
                absoluteURL: "/opinion/145917/winter-v-natural-resources-defense-council/",
                reviewState: ResearchResultReviewState.saved.rawValue,
                useStatus: AuthorityUseStatus.retrievedFromCourtListener.rawValue,
                opinionText: winterText
            ))

            // A local-first research answer with a clickable [A1] that opens the
            // in-app reader offline (via the saved authority's persisted text).
            let researchChat = try store.chats.createMatterChat(matterID: matter.id, title: "Preliminary injunction standard")
            _ = try store.chats.appendUserMessage(
                chatID: researchChat.id,
                content: "/research What must we show to obtain a preliminary injunction?"
            )
            let researchAssistant = try store.chats.createAssistantMessageShell(chatID: researchChat.id)
            let researchVariant = try store.chats.createVariant(messageID: researchAssistant.id, generationSessionID: nil)
            let researchAnswer = """
            To obtain a preliminary injunction, Meridian must establish four elements: (1) a \
            likelihood of success on the merits; (2) a likelihood of irreparable harm absent \
            preliminary relief; (3) that the balance of equities tips in its favor; and (4) that \
            an injunction serves the public interest [A1]. Irreparable harm must be likely — a \
            mere possibility is not enough, because injunctive relief is an extraordinary remedy \
            requiring a clear showing of entitlement [A1].

            _Preliminary — answered from this matter's saved authorities. Use “Search \
            CourtListener” below for a wider search._
            """
            try store.chats.appendToken(to: researchVariant.id, token: researchAnswer)
            try store.chats.completeVariant(researchVariant.id)
            let winterRef = AuthorityCitationRef(
                opinionID: "demo-winter",
                citation: "555 U.S. 7",
                court: "Supreme Court of the United States",
                dateFiled: "2008-11-12"
            )
            let winterRefJSON = (try? JSONEncoder().encode(winterRef)).flatMap { String(data: $0, encoding: .utf8) }
            try store.chats.replaceCitations(messageID: researchAssistant.id, [
                MessageCitationRecord(
                    messageID: researchAssistant.id, label: "A1", kind: "authority",
                    url: "https://www.courtlistener.com/opinion/145917/winter-v-natural-resources-defense-council/",
                    locatorJSON: winterRefJSON,
                    displayName: "Winter v. Natural Resources Defense Council, Inc.",
                    matchText: "A plaintiff seeking a preliminary injunction must establish that he is likely to succeed on the merits, that he is likely to suffer irreparable harm",
                    rank: 0
                )
            ])

            mattersController.loadMatters()
        } catch {
            // Best-effort — a seeding failure just means an emptier demo.
        }
    }

    /// One fictitious, fully-indexed demo document (ready status, previewable text).
    private func seedDemoDocument(matterID: String, name: String, sha: String, text: String) throws -> String {
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                sha256: sha, byteSize: 0,
                originalExtension: (name as NSString).pathExtension,
                managedRelativePath: "demo/\(sha)"
            )
        ).blob
        let document = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                matterID: matterID, blobID: blob.id, displayName: name,
                status: MatterDocumentStatus.ready.rawValue
            )
        )
        try store.documentIndex.replaceParts(documentID: document.id, parts: [
            DocumentPagePartRecord(
                documentID: document.id, partIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: text, charCount: text.count
            )
        ])
        return document.id
    }

    /// Opens the on-disk store, falling back to a temporary store so the app still
    /// launches if the Application Support database cannot be created. `isFallback`
    /// is true for that degraded last-resort store (not for the UI-test store).
    private static func makeStore() -> (store: SupraStore, isFallback: Bool) {
        if isUITestMode || isDemoMode {
            // Fresh, throwaway store per launch so UI tests / demo screenshots are
            // deterministic and isolated from the user's real Application Support
            // database.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("SupraAI-UITest-\(UUID().uuidString).sqlite")
            if let store = try? SupraStore(url: url) { return (store, false) }
        }
        if let store = try? SupraStore.openAppSupportStore() {
            return (store, false)
        }
        // Unique-named on-disk fallback so a corrupt/locked leftover fallback file
        // from a previous crash can't doom every subsequent launch. Prune stale
        // fallback files first since nothing persists across launches in this path.
        cleanupStaleFallbackStores()
        let fallbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraAI-fallback-\(UUID().uuidString).sqlite")
        if let store = try? SupraStore(url: fallbackURL) {
            return (store, true)
        }
        // Absolute last resort: an in-memory store so the app still launches
        // (degraded — nothing persists) instead of crashing on a broken disk.
        if let store = try? SupraStore.inMemory() {
            return (store, true)
        }
        return (unavailableStore(), true)
    }

    /// Removes leftover fallback databases (and their -wal/-shm sidecars) from the
    /// temp directory so failed launches don't accumulate stale files.
    private static func cleanupStaleFallbackStores() {
        let tempDir = FileManager.default.temporaryDirectory
        let entries = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
        for url in entries where url.lastPathComponent.hasPrefix("SupraAI-fallback-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func unavailableStore() -> SupraStore {
        fatalError("Unable to open any Supra AI store.")
    }

    private static func currentAppVersion() -> AppVersion {
        let info = Bundle.main.infoDictionary
        return AppVersion(
            marketingVersion: info?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            buildNumber: info?["CFBundleVersion"] as? String ?? "0"
        )
    }
}
