import AppKit
import Combine
import CryptoKit
import Foundation
import SupraCore
import SupraDocuments
import SupraDraftingCore
import SupraNetworking
import SupraResearch
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraSessions
import SupraStore

struct DatabaseRecoveryState: Sendable {
    enum Failure: Sendable {
        case snapshot
        case migration
        case restore
    }

    let failure: Failure
    let recoveryItemURL: URL?

    var title: String {
        switch failure {
        case .snapshot: "Database upgrade paused"
        case .migration: "Database recovery required"
        case .restore: "Restore recovery required"
        }
    }

    var message: String {
        switch failure {
        case .snapshot:
            "Supra AI could not create and verify the required pre-upgrade snapshot. Your existing database was not changed. Check available disk space and Application Support permissions, then quit and relaunch."
        case .migration:
            "Supra AI could not complete the database upgrade. New work is disabled so it cannot be written to temporary storage. Your existing database and the verified pre-upgrade snapshot remain available for recovery."
        case .restore:
            "Supra AI could not activate the staged restore or return the live database to its verified pre-restore state. Normal work is disabled. Quit the app and preserve the entire safety folder, including its recovery database and managed-document blobs, before attempting manual recovery."
        }
    }

    var recoveryActionTitle: String {
        switch failure {
        case .restore: "Show Recovery Safety Copy"
        case .snapshot, .migration: "Show Recovery Snapshot"
        }
    }

    var recoveryActionHint: String {
        switch failure {
        case .restore:
            "Opens Finder with the complete verified safety folder selected."
        case .snapshot, .migration:
            "Opens Finder with the verified recovery database selected."
        }
    }
}

@MainActor
final class AppEnvironment: ObservableObject {
    @Published var runtimeServiceState: RuntimeServiceState = .disconnected
    @Published var runtimeStatusMessage = "Checking runtime"
    /// True when the on-disk store could not be opened and the app fell back to a
    /// throwaway temporary database — surfaced as a warning so the user knows their
    /// data is not being persisted.
    @Published private(set) var usingFallbackStore = false
    /// A migration-specific open failure is blocking, not a silent temporary-store
    /// degradation. RootView replaces the entire working shell with recovery choices
    /// while this value is present, so durable-looking work cannot be created in the
    /// fallback store.
    @Published private(set) var databaseRecoveryState: DatabaseRecoveryState?
    /// True on a fresh first launch (no models yet, onboarding never completed) — gates
    /// the first-run model-download flow. Set in `bootstrap()`; cleared once the user
    /// finishes or skips onboarding. Always false under UI tests.
    @Published private(set) var shouldShowOnboarding = false
    /// Drives the launch splash. Shown once per process launch: starts true and is
    /// set false when the timed splash dismissal fires. Because AppEnvironment is a
    /// `@StateObject` on the App scene it outlives any single window, so closing the
    /// window (red X) and reopening from the Dock — the app never quit — goes straight
    /// to the shell instead of replaying the splash. Only a true cold launch (a new
    /// process, hence a new AppEnvironment) shows it again.
    @Published var isShowingSplash = true
    /// Content-free counts created by v057. Individual controllers own the
    /// corresponding recovery actions; RootView uses this only for the one-time
    /// post-upgrade notice.
    @Published private(set) var remediationRecoverySummary = RemediationRecoverySummary(
        pendingCount: 0,
        pendingByKind: [:]
    )
    /// D-06's persisted internal flag, exposed in Diagnostics for the required
    /// operational rollback/rebuild drill.
    @Published private(set) var documentChunkerVersion = DocumentChunkerRolloutService.approvedDefaultVersion
    @Published private(set) var documentChunkerStatusMessage = "Chunker v2 is the approved default."
    @Published private(set) var isChangingDocumentChunker = false

    /// App-settings key recording when first-run onboarding was completed/skipped.
    private static let onboardingCompletedKey = "onboarding.completedAt"

    let store: SupraStore
    let modelLibrary: ModelLibrary
    let chatController: GlobalChatController
    let modelDownloadController: ModelDownloadController
    let settingsController: SettingsController
    let backupController: BackupController
    let assistantProfileController: AssistantProfileController
    /// Firm structural style (Track A): letterhead/caption/signature wording + geometry.
    let firmStyleProfileController: FirmStyleProfileController
    /// Resolves/loads the drafting model, then parses a firm-style exemplar document into a
    /// candidate profile for the Settings review pane (M3). Fails soft with a message when no
    /// drafting model is available.
    let parseFirmStyleExemplar: @MainActor (ExemplarKind, URL) async -> ExemplarParseOutcome
    let sparkleUpdater: SparkleUpdaterController
    let mattersController: MattersController
    let recycleBinController: RecycleBinController
    // Milestone 4: ScratchPad daily notes -> billing.
    let scratchPadController: ScratchPadController
    /// Key-less government-data searches (SEC EDGAR, CFPB, NLRB).
    let publicRecordsController: PublicRecordsController
    let billingDraftController: BillingDraftController
    let billingSettingsController: BillingSettingsController
    // Milestone 3: document intelligence setup.
    let documentSetupController: DocumentIntelligenceSetupController
    let embeddingDownloadController: EmbeddingModelDownloadController
    let documentQueue: DocumentProcessingQueue
    private let draftArtifactStorage: DocumentStorage
    private let draftArtifactReconciler: DraftArtifactReconciliationService
    private let interruptedDraftRecoveryUITestRoot: URL?

    private let runtimeStatusController: RuntimeStatusController
    private let runtimeClient: ExclusiveRuntimeClient
    /// Non-nil only for the explicitly authorized guided-Q&A XCUITest launch.
    /// The synthetic model fixture is confined to this throwaway root.
    private let guidedQAUITestModelRoot: URL?
    /// Non-nil only for the hermetic Guided Review creation fixture. It gives
    /// managed-model pinning a tiny signed synthetic install without consulting
    /// the user's model library.
    private let reviewCreationUITestModelRoot: URL?
    /// Fires a classification-only pass for the selected matter whenever a model
    /// finishes loading, so documents imported while no model was available get
    /// classified once one is ready (the queue de-dupes and no-ops when nothing is
    /// pending).
    private var classifyOnModelLoadCancellable: AnyCancellable?

    init() {
        let coldStartRestore = AppEnvironment.prepareColdStartRestore()
        let restoreActivation = coldStartRestore?.activation
        let guidedQAUITestAuthorized = Self.isUITestMode && ProcessInfo.processInfo.arguments.contains("-uiTestGuidedQA")
        let reviewCreationUITestAuthorized = Self.isUITestMode
            && ProcessInfo.processInfo.arguments.contains("-uiTestReviewCreation")
        let reviewCreationUITestScenario = Self.reviewCreationUITestScenario
        let interruptedDraftRecoveryUITestRoot = Self.interruptedDraftRecoveryUITestRoot()
        let baseRuntimeClient: any RuntimeClientProtocol = guidedQAUITestAuthorized
            ? GuidedQAUITestRuntimeClient()
            : RuntimeClient()
        let runtimeClient = ExclusiveRuntimeClient(base: baseRuntimeClient)
        let guidedQAUITestModelRoot = guidedQAUITestAuthorized
            ? Optional(FileManager.default.temporaryDirectory.appendingPathComponent(
                "SupraAI-UITest-GuidedQA-\(UUID().uuidString)",
                isDirectory: true
            ))
            : nil
        let reviewCreationUITestModelRoot = reviewCreationUITestAuthorized
            ? Optional(FileManager.default.temporaryDirectory.appendingPathComponent(
                "SupraAI-UITest-ReviewCreationModel-\(UUID().uuidString)",
                isDirectory: true
            ))
            : nil
        let guidedQAUITestManagedRoots = guidedQAUITestModelRoot.map { [$0] }
            ?? reviewCreationUITestModelRoot.map { [$0] }
            ?? [ManagedModelStorage.modelsDirectory()]
        let storeResult = AppEnvironment.makeStore(
            after: restoreActivation,
            replayOutcome: coldStartRestore?.outcome,
            outcomeReadFailed: coldStartRestore?.outcomeReadFailed == true
        )
        let store = storeResult.store
        let systemPrompt = DefaultSystemPrompt.milestone1()
        let appVersion = AppEnvironment.currentAppVersion()
        let modelLibrary = ModelLibrary(
            store: store,
            runtimeClient: runtimeClient,
            managedModelRoots: guidedQAUITestManagedRoots
        )
        let tokenStore = APIKeyStoreComposition.live()
        self.store = store
        self.usingFallbackStore = storeResult.isFallback
        self.databaseRecoveryState = storeResult.recoveryState
        self.runtimeStatusController = RuntimeStatusController(runtimeClient: runtimeClient)
        self.runtimeClient = runtimeClient
        self.guidedQAUITestModelRoot = guidedQAUITestModelRoot
        self.reviewCreationUITestModelRoot = reviewCreationUITestModelRoot
        self.interruptedDraftRecoveryUITestRoot = interruptedDraftRecoveryUITestRoot
        self.modelLibrary = modelLibrary
        self.chatController = GlobalChatController(
            store: store,
            runtimeClient: runtimeClient,
            defaultSystemPrompt: systemPrompt,
            tokenStore: tokenStore
        )
        self.modelDownloadController = ModelDownloadController(
            store: store,
            modelLibrary: modelLibrary,
            fetcher: HuggingFaceClient()
        )
        self.settingsController = SettingsController(
            store: store,
            appVersion: appVersion,
            tokenStore: tokenStore
        )
        let documentStorage = DocumentStorage.makeDefault()
#if DEBUG
        let restoreUITestFixture = AppEnvironment.makeRestoreUITestFixtureIfRequested()
#else
        let restoreUITestFixture: RestoreUITestFixture? = nil
#endif
        let restoreLiveLayout = restoreUITestFixture?.liveLayout
            ?? AppEnvironment.makeRestoreLiveLayoutForController(
                blobsDirectory: documentStorage.blobsDirectory
            )
        let backupController = BackupController(
            store: store,
            blobsDirectory: documentStorage.blobsDirectory,
            appVersion: appVersion.marketingVersion,
            appBuild: appVersion.buildNumber,
            destinationFactory: restoreUITestFixture?.destinationFactory,
            restoreLiveLayout: restoreLiveLayout,
            restoreInspector: restoreUITestFixture?.inspector,
            restoreRunner: restoreUITestFixture?.runner,
            requestProcessExit: { NSApplication.shared.terminate(nil) },
            launchRestoreResult: restoreActivation,
            launchRestoreOutcome: coldStartRestore?.outcome,
            launchStagingFailure: coldStartRestore?.stagingFailure,
            acknowledgeRestoreOutcome: {
                guard let stagingRoot = coldStartRestore?.stagingRootDirectory else { return }
                try RestoreSidecarStore.acknowledgeActivationOutcome(
                    stagingRootDirectory: stagingRoot
                )
            },
            acknowledgeStagingFailure: {
                guard let stagingRoot = coldStartRestore?.stagingRootDirectory else { return }
                try RestoreSidecarStore.acknowledgeStagingFailure(
                    stagingRootDirectory: stagingRoot
                )
            }
        )
        if let restoreUITestFixture {
            _ = backupController.configureDestination(
                bookmarkData: Data("synthetic-ui-bookmark".utf8),
                url: restoreUITestFixture.destinationURL
            )
        }
        self.backupController = backupController
        self.assistantProfileController = AssistantProfileController(store: store, basePrompt: systemPrompt)
        // Firm structural style: autosaves to the store; MatterDraftingController reads the
        // persisted profile fresh at draft time via effectiveStyle(), so no threading is needed.
        self.firmStyleProfileController = FirmStyleProfileController(store: store)
        // Exemplar parsing rides the drafting model route (same resolution as letter drafting).
        self.parseFirmStyleExemplar = { kind, url in
            let router = ModelRouter(configuration: .fromEnvironment())
            switch await modelLibrary.ensureLoadedRoutedModelID(
                for: router.route(for: .drafting).role, configuration: router.configuration
            ) {
            case let .success(loadedModelID):
                return await FirmStyleExemplarParser(runtimeClient: runtimeClient, modelID: loadedModelID)
                    .parse(kind: kind, fileURL: url)
            case let .failure(issue):
                return ExemplarParseOutcome(candidate: FirmStyleProfile(), message: issue.message)
            }
        }
        self.sparkleUpdater = SparkleUpdaterController()
        self.recycleBinController = RecycleBinController(store: store)
        self.scratchPadController = ScratchPadController(store: store)
        self.publicRecordsController = PublicRecordsController(
            store: store,
            keyStore: tokenStore
        )
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
        // A generated/edited/deleted draft changes the day's billable-hour total
        // shown in the ScratchPad week strip — refresh those indicators whenever
        // the draft reloads.
        let scratchPad = self.scratchPadController
        billingDraft.onDraftMutated = { [weak scratchPad] in
            scratchPad?.refreshWeekBilledHours()
        }

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
        let corpusAnalysisRunner = CorpusAnalysisQueueRunner.live(
            store: store,
            modelLibrary: modelLibrary,
            runtimeClient: runtimeClient
        )
        let importService = DocumentImportService(store: store)
        let queue = DocumentProcessingQueue(
            store: store,
            importService: importService,
            makeIndexingService: {
                // Build a fresh indexing service per job using the currently
                // selected embedding model (if any).
                let model = try? store.documentSettings.fetchSelectedEmbeddingModel()
                let embedder = model.flatMap { RuntimeTextEmbedder(model: $0, runtimeClient: runtimeClient) }
                return DocumentIndexingService(store: store, embedder: embedder)
            },
            // Suggests a taxonomy category for each imported document using the
            // assigned task model. Hermetic UI-test launches disable the service:
            // a Documents-tab appearance must not start unrelated generation or
            // consume a scenario's deterministic runtime stream.
            classificationService: Self.isUITestMode ? nil : DocumentClassificationService(
                store: store,
                modelLibrary: modelLibrary,
                runtimeClient: runtimeClient
            ),
            corpusAnalysisRunner: { payload in
                if reviewCreationUITestScenario == "paused" {
                    try await Task.sleep(for: .seconds(300))
                    return
                }
                try await corpusAnalysisRunner.run(payload)
            },
            corpusAnalysisPauseRequester: { runID in
                corpusAnalysisRunner.requestPause(runID: runID)
            }
        )
        documentSetup.setReindexEnqueuer { [weak queue] matterID in
            _ = queue?.enqueueReindex(matterID: matterID)
        }
        importService.setReindexEnqueuer { [weak queue] matterID in
            _ = queue?.enqueueReindex(matterID: matterID)
        }
        self.documentQueue = queue
        let draftingStorage: DocumentStorage?
        if let interruptedDraftRecoveryUITestRoot {
            draftingStorage = DocumentStorage(root: interruptedDraftRecoveryUITestRoot)
        } else if Self.isUITestMode,
           let root = ProcessInfo.processInfo.environment["SUPRA_UI_TEST_DRAFT_STORAGE_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !root.isEmpty {
            draftingStorage = DocumentStorage(root: URL(fileURLWithPath: root, isDirectory: true))
        } else {
            draftingStorage = nil
        }
        let effectiveDraftingStorage = draftingStorage ?? documentStorage
        self.draftArtifactStorage = effectiveDraftingStorage
        self.draftArtifactReconciler = DraftArtifactReconciliationService(
            store: store,
            storage: effectiveDraftingStorage
        )
        let beforeMotionPersistence: MatterDraftingController.AsyncDraftCheckpoint?
        if Self.isUITestMode,
           ProcessInfo.processInfo.arguments.contains("-uiTestMotionDraftDelayed") {
            beforeMotionPersistence = {
                try await Task.sleep(for: .seconds(30))
            }
        } else {
            beforeMotionPersistence = nil
        }
        self.mattersController = MattersController(
            store: store,
            runtimeClient: runtimeClient,
            defaultSystemPrompt: systemPrompt,
            documentQueue: queue,
            submitCorpusAnalysis: { request, pinnedModel, approvedScopeReceipt in
                let prepared = try CorpusAnalysisQueuePreparer(store: store)
                    .prepareExhaustiveListSubmission(
                        request: request,
                        pinnedModel: pinnedModel
                    )
                return try queue.enqueueCorpusAnalysis(
                    prepared: prepared,
                    approvedScopeReceipt: approvedScopeReceipt,
                    startImmediately: reviewCreationUITestScenario != "setup"
                        && reviewCreationUITestScenario != "scopeDrift"
                )
            },
            makeCorpusAnalysisPinnedModel: { modelID in
                if reviewCreationUITestScenario == "slowVerification" {
                    try await Task.sleep(for: .seconds(300))
                    try Task.checkCancellation()
                }
                let pinnedModel = try await modelLibrary.makeCorpusAnalysisPinnedModel(modelID: modelID)
#if DEBUG
                if reviewCreationUITestScenario == "scopeDrift" {
                    try Self.seedUITestReviewCreationLateSource(store: store)
                }
#endif
                try Task.checkCancellation()
                return pinnedModel
            },
            isImportReady: { documentSetup.isReadyForImport },
            draftingStorage: draftingStorage,
            beforeMotionPersistence: beforeMotionPersistence
        )
        // Keep the ScratchPad `@matter` autocomplete in lockstep with the matter list,
        // so a matter created while the app is running is mentionable right away
        // instead of only after a restart.
        self.scratchPadController.observeMatters(self.mattersController.mattersPublisher)
        if Self.isUITestMode {
            seedUITestFixturesIfNeeded()
        }
        if Self.isDemoMode {
            seedDemoFixturesIfNeeded()
        }
        // Let speculative pre-warms back off while a generation is running, so they
        // never evict the model out from under an in-flight answer.
        modelLibrary.isRuntimeGenerating = { [weak self] in self?.runtimeServiceState == .generating }
        modelLibrary.isRuntimeReserved = { runtimeClient.ordinaryWorkIsBlocked }
        // When a model becomes loaded, classify any pending documents in the selected
        // matter (a no-op when none are pending). Collapse the load state to a Bool and
        // fire only on the transition into loaded.
        classifyOnModelLoadCancellable = modelLibrary.$loadState
            .map { state -> Bool in
                if case .loaded = state { return true } else { return false }
            }
            .removeDuplicates()
            .filter { $0 && !Self.isUITestMode }
            .sink { [weak self] _ in
                guard let self, let matterID = self.mattersController.selectedMatterID else { return }
                self.documentQueue.enqueueClassify(matterID: matterID)
            }
        // Headless probe dispatch (measurement qualification, finding #5): at most
        // ONE probe per launch — `HeadlessProbeMode.resolve` makes the modes
        // mutually exclusive and a conflict runs NOTHING. The model-dependent
        // probes run against the isolated throwaway store `makeStore()` opened for
        // this launch; the coverage probe is the one justified real-store
        // diagnostic (read-only replay of this store's own chat history), refused
        // with an emitted reason on fallback/recovery stores and in Debug builds.
        // Probes are triggered from init (not `bootstrap()`, which is driven by a
        // view `.task` that never fires in a windowless launch) and leave through
        // the app's normal termination path.
        switch Self.headlessProbeResolution {
        case .none:
            break
        case let .conflict(modes):
            Task { await self.emitHeadlessProbeConflict(modes) }
        case .single(.coverageShadow):
            #if DEBUG
            let isDebugBuild = true
            #else
            let isDebugBuild = false
            #endif
            if let reason = HeadlessProbeMode.coverageShadowUnavailableReason(
                isFallbackStore: storeResult.isFallback,
                hasRecoveryState: storeResult.recoveryState != nil,
                isDebugBuild: isDebugBuild
            ) {
                Task { await self.emitCoverageShadowUnavailable(reason) }
            } else {
                Task { await self.runCoverageShadowProbeIfRequested() }
            }
        case .single(.capability):
            Task { await self.runCapabilityProbeIfRequested() }
        case .single(.typedProseAB):
            Task { await self.runTypedProseABProbeIfRequested() }
        }
    }

    /// Multiple probe flags were passed: report the conflict and terminate without
    /// running any probe — mutual exclusivity is part of the probes' isolation
    /// contract.
    private func emitHeadlessProbeConflict(_ modes: [HeadlessProbeMode]) async {
        let payload: [String: Any] = [
            "status": "probe_conflict",
            "detail": "Headless probe modes are mutually exclusive; none were run.",
            "requested": modes.map(\.rawValue),
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("===HEADLESS_PROBE_CONFLICT===\n\(json)", forType: .string)
        print("===HEADLESS_PROBE_CONFLICT_BEGIN===")
        print(json)
        print("===HEADLESS_PROBE_CONFLICT_END===")
        terminateAfterHeadlessProbe()
    }

    /// The coverage probe was requested but cannot run (fallback store, recovery
    /// state, or a Debug build). Emit the typed reason instead of silently doing
    /// nothing — a headless harness polls the pasteboard/stdout for report
    /// delimiters and would otherwise hang forever — then leave through the
    /// normal termination path.
    private func emitCoverageShadowUnavailable(_ reason: String) async {
        let payload: [String: Any] = [
            "status": "coverage_probe_unavailable",
            "reason": reason,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("===COVERAGE_SHADOW_UNAVAILABLE===\n\(json)", forType: .string)
        print("===COVERAGE_SHADOW_UNAVAILABLE_BEGIN===")
        print(json)
        print("===COVERAGE_SHADOW_UNAVAILABLE_END===")
        terminateAfterHeadlessProbe()
    }

    /// Probes leave through the app's NORMAL termination path — never `exit(0)`
    /// from application code (measurement qualification, finding #5), so lifecycle
    /// teardown (delegates, XPC connections, pending writes) runs as on any quit.
    private func terminateAfterHeadlessProbe() {
        NSApplication.shared.terminate(nil)
    }

    /// Loads persisted state and refreshes runtime status on launch.
    func bootstrap() async {
        // Probe work is dispatched directly from init because a headless launch cannot
        // rely on this view-driven task. If a window nevertheless materializes, do not
        // race that probe with normal write-capable bootstrap work. This is essential
        // for the coverage probe, whose intentionally real-store operation is read-only.
        guard Self.headlessProbeResolution.permitsNormalBootstrap else { return }

        // Reconcile any validation run abandoned by a previous quit/crash so it
        // surfaces as cancelled rather than lingering as in-progress.
        try? store.validation.markUnfinishedRunsCancelled()
        // Complete or surface a publication interrupted after its durable
        // intent was recorded. Recovery/fallback launches are intentionally
        // read-only with respect to the user's normal managed storage.
        if !usingFallbackStore, databaseRecoveryState == nil {
            _ = try? draftArtifactReconciler.reconcilePendingIntents()
        }
        remediationRecoverySummary = (try? store.remediationRecovery.summary())
            ?? RemediationRecoverySummary(pendingCount: 0, pendingByKind: [:])
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
        if Self.isUITestMode {
            seedUITestFixturesIfNeeded()
            await seedUITestReviewProjectIfNeeded()
        }
        if Self.isDemoMode { seedDemoFixturesIfNeeded() }
        #if DEBUG
        dumpStoreToPasteboardIfRequested()
        dumpOpinionToPasteboardIfRequested()
        #endif
        await refreshRuntimeStatus()
        // Reconcile and claim persisted corpus work before scheduling the ordinary
        // chat-model warm. Both use the one chat-runtime slot, and exact review
        // loads must never race a routed fallback load during launch.
        documentQueue.bootstrap()
        // If the runtime already holds a model from a previous session, re-enable
        // chat without forcing the user to re-load it (the chat gate keys on
        // ModelLibrary.loadState, which otherwise starts idle each launch).
        modelLibrary.reconcileLoadedModel(runtimeStatusController.loadedModelID)
        if !documentQueue.hasPendingCorpusAnalysisWork {
            autoLoadStartupModelIfNeeded()
        }
        await documentSetupController.refreshAll()
        documentChunkerVersion = (try? store.documentSettings.loadSettings().chunkerVersion)
            ?? DocumentChunkerRolloutService.approvedDefaultVersion
        // D-06: upgrade existing stores exactly once after setup is readable but
        // before the interrupted-job queue resumes. The marker survives an
        // explicit later rollback, so bootstrap never silently overrides it.
        if !Self.isUITestMode, !Self.isDemoMode, !Self.isHeadlessProbeMode, !usingFallbackStore {
            await promoteApprovedDocumentChunkerDefaultIfNeeded()
        }
        // Warm the embedding model now that its selection/verification is known. It
        // lives in a separate runtime slot from the chat model, so this never evicts
        // the chat model — and it removes the first-use wait on Document Q&A, semantic
        // search, and import indexing.
        if !Self.isUITestMode, !Self.isHeadlessProbeMode { documentSetupController.prewarmEmbeddingModel() }
        // Auto-purge documents and chats soft-deleted past the retention window
        // (plan §12.2). Matters are never auto-purged — only manually from the Recycle Bin.
        let maintenance = DocumentMaintenance(store: store)
        maintenance.purgeExpired()
        maintenance.purgeExpiredChats()
        // P2 backup schedule: one launch check, never on quit. The controller
        // skips fresh/unconfigured destinations and performs file work off-main.
        if !Self.isUITestMode, !Self.isDemoMode, !Self.isHeadlessProbeMode, !usingFallbackStore {
            Task { await backupController.backUpOnLaunchIfStale() }
        }
        // Start Sparkle: scheduled background checks + silent download, surfacing a
        // single "Install and Relaunch" prompt. Skipped in UI tests.
        if !Self.isUITestMode, !Self.isDemoMode, !Self.isHeadlessProbeMode { sparkleUpdater.start() }
    }

    func switchDocumentChunker(to targetVersion: Int) async {
        guard !isChangingDocumentChunker else { return }
        isChangingDocumentChunker = true
        documentChunkerStatusMessage = "Rebuilding documents with chunker v\(targetVersion)…"
        defer { isChangingDocumentChunker = false }

        do {
            let result = try await makeDocumentChunkerRolloutService().switchAllMatters(
                to: targetVersion,
                actor: "user"
            )
            documentChunkerVersion = targetVersion
            documentChunkerStatusMessage = chunkerCompletionMessage(result)
        } catch {
            documentChunkerVersion = (try? store.documentSettings.loadSettings().chunkerVersion)
                ?? documentChunkerVersion
            documentChunkerStatusMessage = error.localizedDescription
        }
    }

    /// Runs the reasoning-framework capability probe against the currently loaded model:
    /// measures how reliably it emits the typed `AnswerDraft` schema over synthetic grounded
    /// fixtures (the Phase 1 typed-generation go/no-go). Returns nil when no model is loaded.
    /// Greedy, thinking-off decoding — mirroring how typed grounded generation will run.
    func runReasoningCapabilityProbe() async -> CapabilityReport? {
        guard let modelID = modelLibrary.loadedModelID else { return nil }
        var options = ModelRouter(configuration: .fromEnvironment())
            .route(forStructuredOutput: .documentQA)?.options ?? GenerationOptions()
        options.thinkingBudget = .off
        return await CapabilityHarness.run(
            fixtures: CapabilityHarness.standardFixtures(),
            modelID: modelID,
            options: options,
            systemPrompt: nil,
            runtimeClient: runtimeClient
        )
    }

    /// The currently selected embedding model wrapped for retrieval, or nil when none is selected
    /// or the record fails verification. Mirrors `makeDocumentChunkerRolloutService()` — the app's
    /// one idiom for vending the real embedder (the runtime client is otherwise private).
    func makeSelectedEmbedder() -> (any TextEmbedder)? {
        let selectedModel = try? store.documentSettings.fetchSelectedEmbeddingModel()
        return selectedModel.flatMap { RuntimeTextEmbedder(model: $0, runtimeClient: runtimeClient) }
    }

    /// Headless typed-vs-prose A/B (`-runTypedProseABProbe`, optional `-abRepeats N`): runs both
    /// grounded-answer paths over AUTHORED fixtures and reports the verifier's false-positive rate
    /// on each.
    ///
    /// Fixtures only — it never reads matter data, and the payload carries no client content,
    /// which is why the pasteboard channel is safe here. That constraint is also what makes the
    /// measurement possible: with authored evidence the correct answer is known, so a verifier
    /// flag can be classified as noise (it flagged a CORRECT answer) or as the gate working (it
    /// flagged a WRONG one). A comparison run against real questions could only report that the
    /// two paths differ, never which one was right.
    func runTypedProseABProbeIfRequested() async {
        guard case .single(.typedProseAB) = Self.headlessProbeResolution else { return }
        var payload: [String: Any] = ["storeIsolation": "temporary"]
        defer { emitTypedProseABPayload(payload) }

        // Isolated-store launch: rebuild the model registry from disk manifests
        // (see runCapabilityProbeIfRequested) — the fixtures are authored, but the
        // MODEL must still resolve without the user's database.
        DiskModelRegistrar.registerVerifiedModels(
            into: modelLibrary,
            root: ManagedModelStorage.modelsDirectory()
        )
        modelLibrary.refresh()
        let resolution = await modelLibrary.ensureLoadedChatModelID(for: .legalReasoning)
        guard case let .success(modelID) = resolution else {
            payload["status"] = "model_load_failed"
            payload["detail"] = String(describing: resolution)
            return
        }
        payload["probedModel"] = modelLibrary.models
            .first { $0.id == modelLibrary.loadedModelID?.rawValue.uuidString }?.displayName ?? "unknown"

        var options = ModelRouter(configuration: .fromEnvironment())
            .route(forStructuredOutput: .documentQA)?.options ?? GenerationOptions()
        options.thinkingBudget = .off

        let repeats = Self.intArgument(named: "-abRepeats") ?? 3
        payload["repeats"] = repeats
        let outcomes = await TypedProseABProbe.run(
            modelID: modelID, options: options, systemPrompt: nil,
            runtimeClient: runtimeClient, repeats: repeats
        )
        payload["status"] = "ok"
        for arm in [TypedProseArm.typed, .prose] {
            let report = TypedProseABScorer.report(outcomes: outcomes, arm: arm)
            payload[arm.rawValue] = [
                "total": report.total,
                "correct": report.correct,
                "correctRate": report.correctRate,
                "falsePositives": report.falsePositives,
                "falsePositiveRate": report.falsePositiveRate,
                "truePositives": report.truePositives,
                "missedErrors": report.missedErrors,
                "missedErrorRate": report.missedErrorRate,
                "trueNegatives": report.trueNegatives,
                "fellBack": report.fellBack,
            ]
        }
        // Raw-output artifact (measurement qualification): every outcome — fixture,
        // arm, verbatim answer, warnings, typed expectation — plus the per-arm
        // reports, so a published number can be independently RE-SCORED from the
        // emitted record alone. Fixture content is synthetic, so the payload still
        // carries no client data.
        let record = TypedProseABRunRecord(
            outcomes: outcomes,
            typed: TypedProseABScorer.report(outcomes: outcomes, arm: .typed),
            prose: TypedProseABScorer.report(outcomes: outcomes, arm: .prose)
        )
        if let data = try? JSONEncoder().encode(record),
           let object = try? JSONSerialization.jsonObject(with: data) {
            payload["runRecord"] = object
        }
    }

    /// A positive integer launch argument (`-flag 5`), or nil when absent or unparsable.
    private static func intArgument(named flag: String) -> Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(of: flag),
              arguments.indices.contains(marker + 1),
              let value = Int(arguments[marker + 1]), value > 0 else { return nil }
        return value
    }

    private func emitTypedProseABPayload(_ payload: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("===TYPED_PROSE_AB_REPORT===\n\(json)", forType: .string)
        print("===TYPED_PROSE_AB_REPORT_BEGIN===")
        print(json)
        print("===TYPED_PROSE_AB_REPORT_END===")
        terminateAfterHeadlessProbe()
    }

    /// Runs the Phase 2 coverage-routing evidence probe: replays this store's real matter-chat
    /// user questions through the keyword router and the corpus-coverage signal and tallies where
    /// they diverge — the go/no-go for flipping coverage to the primary router. Read-only. Uses
    /// the real embedder when one is selected (semantic coverage); nil falls back to FTS-only, a
    /// conservative lower bound reflected in `report.usedSemantic`.
    func runCoverageRoutingShadowProbe() async -> CoverageRoutingReport {
        await CoverageRoutingProbe.run(store: store, embedder: makeSelectedEmbedder())
    }

    /// Headless evidence run (`-runCoverageShadowProbe`): runs the coverage-routing probe over the
    /// real store and emits the tally as delimited JSON — to the general pasteboard (readable via
    /// `pbpaste`, the sandbox-crossing channel `-dumpChats` uses), stdout, and a container file —
    /// then exits. Read-only, so it is safe on the real store (Release only, per the
    /// launch-correct-build rule). No-op unless the flag is present. Uses FTS-only coverage
    /// (`embedder: nil`) so it does not depend on the runtime XPC/embedding model: a reliable,
    /// clearly-labeled lower bound (`usedSemantic: false`). The Diagnostics button runs the same
    /// probe with the real embedder for the full semantic signal.
    /// Headless capability run (`-runCapabilityProbe`): loads the chat model this app would
    /// normally use, runs the reasoning capability probe against it, emits the tally as delimited
    /// JSON on the same three channels as the coverage probe, and exits.
    ///
    /// Unlike the coverage probe, this one genuinely needs the runtime: typed generation is what
    /// it measures. It therefore loads a model via the ordinary `ensureLoadedChatModelID` path
    /// rather than assuming one is already loaded — nothing loads a model in a windowless launch.
    /// `SignedReleaseSmokeRunner` is the precedent that XPC connect/load/generate works without a
    /// rendered window.
    ///
    /// The payload also lists every registered model, because the question this exists to answer
    /// ("do I have a model that can do typed generation?") needs the inventory as much as the
    /// score — and the model store is inside the TCC-protected container, unreadable from a shell.
    ///
    /// Read-only with respect to matter data. Release only, per the launch-correct-build rule.
    func runCapabilityProbeIfRequested() async {
        guard case .single(.capability) = Self.headlessProbeResolution else { return }
        // Isolated-store launch (see HeadlessProbeMode): the registry is rebuilt
        // from the managed model directory's VERIFIED manifests — disk truth — so
        // the probe reports real inventory without opening the user's database or
        // touching the user's active-model selection/role assignments.
        DiskModelRegistrar.registerVerifiedModels(
            into: modelLibrary,
            root: ManagedModelStorage.modelsDirectory()
        )
        modelLibrary.refresh()
        let registered = modelLibrary.models.map { model -> [String: Any] in
            [
                "displayName": model.displayName,
                "isActive": model.isActive,
                "validationStatus": model.validationStatus ?? "none",
            ]
        }

        var payload: [String: Any] = ["registeredModels": registered, "storeIsolation": "temporary"]
        defer { emitCapabilityProbePayload(payload) }

        guard !registered.isEmpty else {
            payload["status"] = "no_models_registered"
            return
        }

        let resolution = await modelLibrary.ensureLoadedChatModelID(for: .legalReasoning)
        switch resolution {
        case let .failure(issue):
            payload["status"] = "model_load_failed"
            payload["detail"] = String(describing: issue)
            return
        case .success:
            break
        }

        let probedName = modelLibrary.models.first { $0.id == modelLibrary.loadedModelID?.rawValue.uuidString }?.displayName
        payload["probedModel"] = probedName ?? "unknown"

        guard let report = await runReasoningCapabilityProbe() else {
            payload["status"] = "probe_unavailable"
            return
        }
        payload["status"] = "ok"
        payload["total"] = report.total
        payload["generated"] = report.generated
        payload["firstAttempt"] = report.firstAttempt
        payload["fellBack"] = report.fellBack
        payload["refusalExpected"] = report.refusalExpected
        payload["refusalCorrect"] = report.refusalCorrect
        payload["successRate"] = report.successRate
        payload["firstAttemptRate"] = report.firstAttemptRate
        payload["fallbackRate"] = report.fallbackRate
        payload["avgAttempts"] = report.avgAttempts
        payload["refusalAccuracy"] = report.refusalAccuracy
        // The decision this probe exists to inform: typed generation is viable only when the model
        // holds the schema. An instruct model clears this; a reasoning distill does not.
        payload["typedGenerationViable"] = report.generated == report.total && report.total > 0
    }

    /// Writes the capability payload to pasteboard, stdout, and a temp file, then exits — the same
    /// three channels the coverage probe uses, because a GUI app's stdout is not captured and the
    /// container file is TCC-protected from other processes.
    private func emitCapabilityProbePayload(_ payload: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("capability-probe-report.json")
        try? json.data(using: .utf8)?.write(to: fileURL)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("===CAPABILITY_PROBE_REPORT===\n\(json)", forType: .string)
        print("===CAPABILITY_PROBE_REPORT_BEGIN===")
        print(json)
        print("===CAPABILITY_PROBE_REPORT_END===")
        terminateAfterHeadlessProbe()
    }

    func runCoverageShadowProbeIfRequested() async {
        guard case .single(.coverageShadow) = Self.headlessProbeResolution else { return }
        let report = await CoverageRoutingProbe.run(store: store, embedder: nil)
        let payload: [String: Any] = [
            "matterCount": report.matterCount,
            "questionsScanned": report.questionsScanned,
            "agreeGround": report.agreeGround,
            "agreeSkip": report.agreeSkip,
            "coverageWouldGround": report.coverageWouldGround,
            "coverageWouldSkip": report.coverageWouldSkip,
            "marginal": report.marginal,
            "usedSemantic": report.usedSemantic,
            "readErrors": report.readErrors,
            "completedCleanly": report.completedCleanly,
            "agreementRate": report.agreementRate,
            "divergenceRate": report.divergenceRate,
            "wouldGroundRate": report.wouldGroundRate,
            "wouldSkipRate": report.wouldSkipRate,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("coverage-shadow-report.json")
        try? json.data(using: .utf8)?.write(to: fileURL)
        // Pasteboard is the reliable channel out of the sandbox for a headless run (a GUI app's
        // stdout is not captured, and the container file is TCC-protected from other processes).
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("===COVERAGE_SHADOW_REPORT===\n\(json)", forType: .string)
        print("===COVERAGE_SHADOW_REPORT_BEGIN===")
        print(json)
        print("===COVERAGE_SHADOW_REPORT_END===")
        terminateAfterHeadlessProbe()
    }

    private func promoteApprovedDocumentChunkerDefaultIfNeeded() async {
        isChangingDocumentChunker = true
        defer { isChangingDocumentChunker = false }
        do {
            if let result = try await makeDocumentChunkerRolloutService()
                .promoteApprovedDefaultIfNeeded(actor: "system — approved by Cade Spivey") {
                documentChunkerStatusMessage = chunkerCompletionMessage(result)
            }
            documentChunkerVersion = try store.documentSettings.loadSettings().chunkerVersion
        } catch {
            documentChunkerVersion = (try? store.documentSettings.loadSettings().chunkerVersion)
                ?? documentChunkerVersion
            documentChunkerStatusMessage = "Approved chunker migration paused: \(error.localizedDescription)"
        }
    }

    private func makeDocumentChunkerRolloutService() -> DocumentChunkerRolloutService {
        let selectedModel = try? store.documentSettings.fetchSelectedEmbeddingModel()
        let embedder = selectedModel.flatMap { RuntimeTextEmbedder(model: $0, runtimeClient: runtimeClient) }
        return DocumentChunkerRolloutService(store: store, embedder: embedder)
    }

    private func chunkerCompletionMessage(_ result: DocumentChunkerRolloutResult) -> String {
        "Chunker v\(result.targetVersion) rebuilt \(result.reindexedDocuments) document(s): \(result.readyDocuments) ready, \(result.textIndexedDocuments) text-indexed, 0 pending."
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
        // Probe launches manage their own model loading (or none); the startup
        // auto-load must never race a probe's deliberate load.
        guard !Self.isUITestMode, !Self.isHeadlessProbeMode, case .idle = modelLibrary.loadState else { return }
        // The app opens on the chat screen, so warm the model chat will actually use —
        // the pinned model, else the Autoselect legal-reasoning model — instead of the
        // heavier high-quality reasoning model, which plain chat doesn't route to and
        // which would force a reload on the first message. Fall back to the generic
        // startup model only when no chat role is assigned yet.
        let forced = modelLibrary.forcedModelID?.rawValue.uuidString
        let forcedExists = forced.map { id in modelLibrary.models.contains { $0.id == id } } ?? false
        let target = (forcedExists ? forced : nil)
            ?? modelLibrary.preferredModelID(for: .legalReasoning)?.rawValue.uuidString
            ?? modelLibrary.startupModelID()
        guard let target else { return }
        Task {
            await modelLibrary.activateAndLoad(modelID: target)
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

    private static var reviewCreationUITestScenario: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard isUITestMode,
              arguments.contains("-uiTestReviewCreation"),
              let marker = arguments.firstIndex(of: "-uiTestReviewCreationScenario"),
              arguments.indices.contains(marker + 1) else { return nil }
        return arguments[marker + 1]
    }

    /// True when launched with `-demoMode`: the same hermetic throwaway store as UI
    /// tests, seeded with entirely FICTITIOUS demo data (fictional parties, clients,
    /// and documents; only the case law is real) for marketing screenshots. Never
    /// touches the user's real database.
    static var isDemoMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-demoMode")
    }

    /// The headless probe requested by this launch, if any — resolved once, mutually
    /// exclusive by construction. See `HeadlessProbeMode` for the isolation contract
    /// and the justification for shipping these diagnostics in the Release app.
    static var headlessProbeResolution: HeadlessProbeMode.Resolution {
        HeadlessProbeMode.resolve(arguments: ProcessInfo.processInfo.arguments)
    }

    /// True for any probe launch (including a conflicting one): normal launch side
    /// effects — Sparkle, model prewarm/auto-load, chunker promotion, backups — are
    /// skipped so a probe can never change the user's models, diagnostics, or data.
    static var isHeadlessProbeMode: Bool {
        switch headlessProbeResolution {
        case .none: return false
        case .single, .conflict: return true
        }
    }

    /// True when this launch must run against an isolated throwaway store. A
    /// conflicting probe launch runs nothing, but still gets the isolated store —
    /// the fail-closed direction is to never open the user's database.
    private static var headlessProbeRequiresIsolatedStore: Bool {
        switch headlessProbeResolution {
        case .none: return false
        case .conflict: return true
        case let .single(mode): return mode.requiresIsolatedStore
        }
    }

    /// Seeds a deterministic matter for UI tests if none exists yet.
    private func seedUITestFixturesIfNeeded() {
        mattersController.loadMatters()
        if mattersController.matters.isEmpty {
            _ = try? mattersController.createMatter(name: "McKernon Motors v. Liberty Rail")
            mattersController.loadMatters()
        }
        seedUITestCitationsChatIfNeeded()
        seedUITestRemediationWarningsIfNeeded()
        seedUITestInterruptedDraftRecoveryIfNeeded()
        seedUITestImportFailureIfNeeded()
        seedUITestInterruptedImportIfNeeded()
        seedUITestDocumentCorrectionIfNeeded()
        seedUITestDocumentRelationsIfNeeded()
        seedUITestGuidedQAIfNeeded()
        seedUITestReviewCreationIfNeeded()
        seedUITestMotionDraftIfNeeded()
    }

    /// Builds one coverage-complete, exact-v2 exhaustive result whose contrary
    /// evidence intentionally leaves it review-required, then freezes it as a
    /// Review Project only for the dedicated hosted Review tests. An additional
    /// switching flag adds one older, exact-run-backed project without enlarging
    /// the ordinary Review fixture. `-uiTestMode` keeps both synthetic graphs in a
    /// fresh, throwaway store rather than the user's database.
    private func seedUITestReviewProjectIfNeeded() async {
        guard Self.isUITestMode,
              ProcessInfo.processInfo.arguments.contains("-uiTestReviewProject"),
              let matterID = mattersController.matters.first?.id else { return }

        do {
            guard try store.caseFileReviews.fetchProjects(matterID: matterID).isEmpty else {
                return
            }

            let alphaExcerpt =
                "The fictional Atlas Supply Agreement fixes payment on March 18, 2031."
            let betaSupportingExcerpt =
                "The fictional Atlas Supply Agreement requires renewal notice at least 120 calendar days before expiration."
            let betaContraryExcerpt =
                "A fictional amendment states that either party may give renewal notice 90 calendar days before expiration."
            let sourceSpecs = [
                (
                    documentID: "ui-review-a-payment-document",
                    revisionID: "ui-review-a-payment-revision",
                    displayName: "Atlas Payment Schedule.txt",
                    text: alphaExcerpt
                ),
                (
                    documentID: "ui-review-b-renewal-document",
                    revisionID: "ui-review-b-renewal-revision",
                    displayName: "Atlas Renewal Clause.txt",
                    text: betaSupportingExcerpt
                ),
                (
                    documentID: "ui-review-c-amendment-document",
                    revisionID: "ui-review-c-amendment-revision",
                    displayName: "Atlas Amendment.txt",
                    text: betaContraryExcerpt
                ),
            ]
            let modelLineageJSON =
                #"{"artifact_fingerprint_sha256":"7777777777777777777777777777777777777777777777777777777777777777","content_binding_algorithm":"supra-release-model-sha256-v1","content_binding_schema_version":1,"model_repository":"synthetic/review-uitest","model_revision":"0123456789abcdef0123456789abcdef01234567"}"#

            for spec in sourceSpecs where try store.documentLibrary.fetchDocument(
                id: spec.documentID
            ) == nil {
                let contentDigest = SHA256.hash(data: Data(spec.text.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
                let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
                    id: "\(spec.documentID)-blob",
                    sha256: contentDigest,
                    byteSize: spec.text.utf8.count,
                    originalExtension: "txt",
                    managedRelativePath: "uitest/\(spec.displayName)"
                )).blob
                let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
                    id: spec.documentID,
                    matterID: matterID,
                    blobID: blob.id,
                    displayName: spec.displayName,
                    status: MatterDocumentStatus.ready.rawValue,
                    extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                    indexStatus: DocumentIndexStatus.textIndexed.rawValue,
                    sourceKind: DocumentSourceKind.text.rawValue,
                    extractionMethod: "synthetic@toolchain:review-uitest"
                ))
                _ = try store.documentRevisions.replacePartsAndPersistLineage(
                    documentID: document.id,
                    parts: [DocumentPagePartRecord(
                        id: "\(spec.documentID)-part",
                        documentID: document.id,
                        partIndex: 0,
                        sourceKind: DocumentSourceKind.text.rawValue,
                        normalizedText: spec.text,
                        charCount: spec.text.count
                    )],
                    revisions: [DocumentPartRevisionRecord(
                        id: spec.revisionID,
                        documentID: document.id,
                        partIndex: 0,
                        derivationKey: "review-uitest:\(spec.documentID)",
                        origin: "synthetic_test",
                        method: "plain-text",
                        text: spec.text,
                        charCount: spec.text.count
                    )],
                    selections: [DocumentPartSelectionRecord(
                        id: "\(spec.documentID)-selection",
                        documentID: document.id,
                        partIndex: 0,
                        selectedRevisionID: spec.revisionID,
                        selectionKey: "review-uitest:\(spec.documentID)",
                        selectedBy: "test",
                        decisionJSON: #"{"rule":"synthetic_review_ui_fixture"}"#
                    )]
                )
            }

            let result = try await ExhaustiveListTask(store: store).run(
                request: ExhaustiveListRequest(
                    runKey: "ui-review-project-run",
                    matterID: matterID,
                    title: "Atlas Supply Agreement review",
                    query: "Extract the exact payment deadline and renewal notice period, retaining contrary terms.",
                    scope: CorpusAnalysisScope(documentIDs: sourceSpecs.map(\.documentID)),
                    characterBudget: 4_219,
                    modelLineageJSON: modelLineageJSON
                )
            ) { input in
                func reference(
                    documentID: String,
                    revisionID: String,
                    quote: String
                ) throws -> CorpusAnalysisEvidenceReference {
                    guard let source = input.partition.sources.first(where: {
                        $0.documentID == documentID && $0.revisionID == revisionID
                    }) else {
                        throw CorpusAnalysisMapFailure.permanent(
                            "Synthetic Review UI source was not presented to the mapper."
                        )
                    }
                    guard let range = Self.reviewUITestCharacterRange(of: quote, in: source.text) else {
                        throw CorpusAnalysisMapFailure.permanent(
                            "Synthetic Review UI excerpt was not present in its exact slice."
                        )
                    }
                    return CorpusAnalysisEvidenceReference(
                        documentID: source.documentID,
                        revisionID: source.revisionID,
                        locatorJSON: source.locatorJSON,
                        quote: quote,
                        charStart: range.lowerBound,
                        charEnd: range.upperBound
                    )
                }

                let response = ReviewUITestMapResponse(items: [
                    ReviewUITestMapItem(
                        itemKey: "Synthetic payment deadline",
                        value: "March 18, 2031",
                        evidence: [try reference(
                            documentID: sourceSpecs[0].documentID,
                            revisionID: sourceSpecs[0].revisionID,
                            quote: alphaExcerpt
                        )],
                        contraryEvidence: []
                    ),
                    ReviewUITestMapItem(
                        itemKey: "Synthetic renewal notice period",
                        value: "120 calendar days",
                        evidence: [try reference(
                            documentID: sourceSpecs[1].documentID,
                            revisionID: sourceSpecs[1].revisionID,
                            quote: betaSupportingExcerpt
                        )],
                        contraryEvidence: [try reference(
                            documentID: sourceSpecs[2].documentID,
                            revisionID: sourceSpecs[2].revisionID,
                            quote: betaContraryExcerpt
                        )]
                    ),
                ])
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                return String(decoding: try encoder.encode(response), as: UTF8.self)
            }

            _ = try store.caseFileReviews.createOrFetchProject(
                matterID: matterID,
                sourceRunID: result.run.id,
                title: "Atlas Supply Agreement review",
                actor: "Synthetic UI reviewer",
                at: Date(timeIntervalSince1970: 1_931_478_400)
            )

            if ProcessInfo.processInfo.arguments.contains("-uiTestReviewProjectSwitching") {
                let amendmentSource = sourceSpecs[2]
                let amendmentResult = try await ExhaustiveListTask(store: store).run(
                    request: ExhaustiveListRequest(
                        runKey: "ui-review-project-switching-run",
                        matterID: matterID,
                        title: "Atlas Amendment review",
                        query: "Extract the exact amended renewal notice period.",
                        scope: CorpusAnalysisScope(documentIDs: [amendmentSource.documentID]),
                        characterBudget: 4_219,
                        modelLineageJSON: modelLineageJSON
                    )
                ) { input in
                    guard let source = input.partition.sources.first(where: {
                        $0.documentID == amendmentSource.documentID
                            && $0.revisionID == amendmentSource.revisionID
                    }) else {
                        throw CorpusAnalysisMapFailure.permanent(
                            "Synthetic Review switching source was not presented to the mapper."
                        )
                    }
                    guard let range = Self.reviewUITestCharacterRange(
                        of: betaContraryExcerpt,
                        in: source.text
                    ) else {
                        throw CorpusAnalysisMapFailure.permanent(
                            "Synthetic Review switching excerpt was not present in its exact slice."
                        )
                    }
                    let reference = CorpusAnalysisEvidenceReference(
                        documentID: source.documentID,
                        revisionID: source.revisionID,
                        locatorJSON: source.locatorJSON,
                        quote: betaContraryExcerpt,
                        charStart: range.lowerBound,
                        charEnd: range.upperBound
                    )
                    let response = ReviewUITestMapResponse(items: [
                        ReviewUITestMapItem(
                            itemKey: "Synthetic amended renewal notice period",
                            value: "90 calendar days",
                            evidence: [reference],
                            contraryEvidence: []
                        ),
                    ])
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    return String(decoding: try encoder.encode(response), as: UTF8.self)
                }

                let amendmentProject = try store.caseFileReviews.createOrFetchProject(
                    matterID: matterID,
                    sourceRunID: amendmentResult.run.id,
                    title: "Atlas Amendment review",
                    actor: "Synthetic UI reviewer",
                    at: Date(timeIntervalSince1970: 1_931_478_300)
                )

#if DEBUG
                if Self.isUITestMode,
                   ProcessInfo.processInfo.arguments.contains("-uiTestReviewNavigationFailure") {
                    try await store.database.writer.write { db in
                        try db.execute(
                            sql: """
                                UPDATE case_file_review_projects
                                SET active_table_id = NULL
                                WHERE id = ? AND active_table_id IS NOT NULL
                                """,
                            arguments: [amendmentProject.project.id]
                        )
                        guard db.changesCount == 1 else {
                            throw CaseFileReviewRepositoryError.corruptGraph(
                                amendmentProject.project.id
                            )
                        }
                    }
                }
#endif
            }
            mattersController.caseFileReviewController?.load()
        } catch {
            assertionFailure("Could not seed Review Project accessibility fixture: \(error)")
        }
    }

    /// Seeds the Guided New Review surface with two exact eligible documents,
    /// three named exclusions, and one tiny signed managed model. The paused
    /// scenario additionally creates a 1-of-3 durable corpus ledger so the hosted
    /// test can cross a real process boundary before resuming it. Every path is
    /// doubly gated and uses the UI-test Store; none can reach user data.
    private func seedUITestReviewCreationIfNeeded() {
#if DEBUG
        guard Self.isUITestMode,
              ProcessInfo.processInfo.arguments.contains("-uiTestReviewCreation"),
              let reviewCreationUITestModelRoot,
              let matterID = mattersController.matters.first?.id else { return }

        do {
            _ = try seedUITestReviewCreationModel(
                in: reviewCreationUITestModelRoot
            )
            for document in try store.documentLibrary.fetchDocuments(matterID: matterID)
                where document.displayName == "agreement.pdf" {
                _ = try store.documentLibrary.permanentlyDeleteDocument(
                    id: document.id,
                    actor: "guided-review-ui-test",
                    at: Date(timeIntervalSince1970: 1_931_478_200)
                )
            }
            let documents = try store.documentLibrary.fetchDocuments(matterID: matterID)
            if !documents.contains(where: { $0.id == "ui-review-create-default-document" }) {
                try seedUITestReviewCreationSources(matterID: matterID)
            }
            if Self.reviewCreationUITestScenario == "paused" {
                try seedUITestPausedReviewCreationRun(
                    matterID: matterID
                )
            }
        } catch {
            assertionFailure("Could not seed Guided Review creation fixture: \(error)")
        }
#endif
    }

#if DEBUG
    private func seedUITestReviewCreationModel(
        in authorizedRoot: URL
    ) throws -> ModelID {
        let modelIDString = "88888888-8888-4888-8888-888888888888"
        let modelDirectory = authorizedRoot
            .appendingPathComponent("guided-review-ui-model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        let artifacts: [(String, Data)] = [
            ("config.json", Data(#"{"model_type":"guided_review_ui_test"}"#.utf8)),
            ("model.safetensors", Data("guided-review-ui-test-weights".utf8)),
        ]
        for (name, data) in artifacts {
            try data.write(
                to: modelDirectory.appendingPathComponent(name, isDirectory: false),
                options: .atomic
            )
        }
        let manifest = ModelArtifactManifest(
            repositoryID: "supra-test/guided-review",
            revision: String(repeating: "8", count: 40),
            files: artifacts.map { name, data in
                ModelArtifactManifest.File(
                    relativePath: name,
                    size: Int64(data.count),
                    digestAlgorithm: .sha256,
                    digest: SHA256.hash(data: data)
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: ManagedModelStorage.manifestURL(in: modelDirectory),
            options: .atomic
        )
        try store.models.upsertModel(ModelRecord(
            id: modelIDString,
            displayName: "Synthetic Review Model",
            path: modelDirectory.path,
            isActive: true,
            validationStatus: "verified"
        ))
        modelLibrary.refresh()
        guard let uuid = UUID(uuidString: modelIDString) else {
            throw CaseFileReviewCreationError.modelUnavailable
        }
        return ModelID(uuid)
    }

    private func seedUITestReviewCreationSources(matterID: String) throws {
        let defaultText = String(repeating: "Atlas ready agreement renewal terms. ", count: 3)
        let amendmentText = String(repeating: "Atlas amendment fixes notice at ninety days. ", count: 6)
        try Self.insertUITestReviewCreationSource(
            store: store,
            matterID: matterID,
            id: "ui-review-create-default-document",
            name: "Atlas Ready Agreement.txt",
            text: defaultText,
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed
        )
        try Self.insertUITestReviewCreationSource(
            store: store,
            matterID: matterID,
            id: "ui-review-create-amendment-document",
            name: "Atlas Amendment.txt",
            text: amendmentText,
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed
        )
        try Self.insertUITestReviewCreationSource(
            store: store,
            matterID: matterID,
            id: "ui-review-create-review-required-document",
            name: "Beacon Review Draft.txt",
            text: nil,
            status: .needsReview,
            extractionStatus: .extracted,
            indexStatus: .textIndexed
        )
        try Self.insertUITestReviewCreationSource(
            store: store,
            matterID: matterID,
            id: "ui-review-create-extraction-failed-document",
            name: "Atlas Extraction Failure.txt",
            text: nil,
            status: .failed,
            extractionStatus: .failed,
            indexStatus: .failed
        )

        let batch = try store.documentJobs.createBatch(matterID: matterID)
        let unfinished = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matterID,
            sourceKey: "selection:review-creation-import-pending",
            sourceDisplayPath: "Atlas Import Pending.txt",
            sourceBookmark: Data("SYNTHETIC-REVIEW-CREATION-BOOKMARK".utf8),
            state: .selected
        )
        _ = try store.documentJobs.markState(sourceID: unfinished.id, state: .copying)
    }

    private static func seedUITestReviewCreationLateSource(store: SupraStore) throws {
        guard Self.isUITestMode,
              ProcessInfo.processInfo.arguments.contains("-uiTestReviewCreation"),
              Self.reviewCreationUITestScenario == "scopeDrift",
              let matterID = try store.matters.fetchMatters().first?.id else {
            throw CaseFileReviewCreationError.submissionFailed
        }
        let documentID = "ui-review-create-late-document"
        guard try !store.documentLibrary.fetchDocuments(matterID: matterID).contains(where: {
            $0.id == documentID
        }) else { return }
        try Self.insertUITestReviewCreationSource(
            store: store,
            matterID: matterID,
            id: documentID,
            name: "Atlas Late Addendum.txt",
            text: String(repeating: "Atlas late addendum extends renewal notice. ", count: 4),
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed
        )
    }

    private static func insertUITestReviewCreationSource(
        store: SupraStore,
        matterID: String,
        id: String,
        name: String,
        text: String?,
        status: MatterDocumentStatus,
        extractionStatus: DocumentExtractionStatus,
        indexStatus: DocumentIndexStatus
    ) throws {
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            id: "\(id)-blob",
            sha256: "\(id)-synthetic-sha",
            byteSize: text?.utf8.count ?? 0,
            originalExtension: "txt",
            managedRelativePath: "uitest/review-creation/\(name)"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            id: id,
            matterID: matterID,
            blobID: blob.id,
            displayName: name,
            status: status.rawValue,
            extractionStatus: extractionStatus.rawValue,
            indexStatus: indexStatus.rawValue,
            extractionMethod: "synthetic@toolchain:review-creation-uitest"
        ))
        guard let text else { return }
        let part = DocumentPagePartRecord(
            id: "\(id)-part",
            documentID: document.id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count
        )
        let revision = DocumentPartRevisionRecord(
            id: "\(id)-revision",
            documentID: document.id,
            partIndex: 0,
            derivationKey: "review-creation-uitest:\(id)",
            origin: "parser",
            method: "synthetic",
            text: text,
            charCount: text.count
        )
        let selection = DocumentPartSelectionRecord(
            id: "\(id)-selection",
            documentID: document.id,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "review-creation-uitest:\(id)",
            selectedBy: "policy",
            policyVersion: 1,
            decisionJSON: #"{"rule":"synthetic_review_creation_ui_fixture"}"#
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [part],
            revisions: [revision],
            selections: [selection]
        )
    }

    private func seedUITestPausedReviewCreationRun(
        matterID: String
    ) throws {
        let existing = try store.documentJobs.fetchJobs(matterID: matterID).contains {
            $0.kind == DocumentProcessingJobKind.corpusAnalysis.rawValue
        }
        guard !existing else { return }

        let pinnedModel = CorpusAnalysisPinnedModel(
            modelRepository: "supra-test/guided-review",
            modelRevision: String(repeating: "8", count: 40),
            contentBindingAlgorithm: RuntimeModelContentBinding.fingerprintAlgorithm,
            contentBindingSchemaVersion: RuntimeModelContentBinding.supportedManifestSchemaVersion,
            artifactFingerprintSHA256: SHA256.hash(
                data: Data("guided-review-paused-ui-pin".utf8)
            ).map { String(format: "%02x", $0) }.joined()
        )
        let request = ExhaustiveListQueuedRequest(
            taskSchemaVersion: ExhaustiveListTask.schemaVersion,
            promptBuilderVersion: ExhaustiveListTask.promptBuilderVersion,
            runKey: "ui-review-creation-paused-run",
            matterID: matterID,
            title: "Paused Atlas deadline review",
            query: "Extract the amended renewal deadline from the synthetic Atlas source.",
            scope: CorpusAnalysisScope(
                schemaVersion: 1,
                documentIDs: ["ui-review-create-amendment-document"]
            ),
            characterBudget: 100,
            maximumRetryCount: 2
        )
        let payload = try CorpusAnalysisQueuePreparer(store: store).prepareExhaustiveList(
            request: request,
            pinnedModel: pinnedModel
        )
        let partitions = try store.corpusAnalysis.fetchPartitions(
            matterID: matterID,
            runID: payload.runID
        )
        guard partitions.count == 3 else {
            throw CaseFileReviewCreationError.submissionFailed
        }
        _ = try store.corpusAnalysis.updateStatus(
            matterID: matterID,
            runID: payload.runID,
            to: .running
        )
        let first = try store.corpusAnalysis.beginAttempt(
            matterID: matterID,
            runID: payload.runID,
            partitionID: partitions[0].id
        )
        try store.corpusAnalysis.completeAttemptSucceeded(
            matterID: matterID,
            runID: payload.runID,
            partitionID: first.id,
            findingsJSON: "[]"
        )
        let payloadJSON = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let job = try store.documentJobs.enqueueJob(
            matterID: matterID,
            kind: DocumentProcessingJobKind.corpusAnalysis.rawValue,
            payloadJSON: payloadJSON
        )
        try store.documentJobs.pauseJob(id: job.id)
    }

#endif

    nonisolated private static func reviewUITestCharacterRange(
        of quote: String,
        in value: String
    ) -> Range<Int>? {
        guard let range = value.range(of: quote) else { return nil }
        return value.distance(from: value.startIndex, to: range.lowerBound)
            ..< value.distance(from: value.startIndex, to: range.upperBound)
    }

    private struct ReviewUITestMapResponse: Encodable, Sendable {
        var schemaVersion = 1
        var items: [ReviewUITestMapItem]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case items
        }
    }

    private struct ReviewUITestMapItem: Encodable, Sendable {
        var itemKey: String
        var value: String
        var evidence: [CorpusAnalysisEvidenceReference]
        var contraryEvidence: [CorpusAnalysisEvidenceReference]

        private enum CodingKeys: String, CodingKey {
            case itemKey = "item_key"
            case value
            case evidence
            case contraryEvidence = "contrary_evidence"
        }
    }

    /// Seeds one ready and one review-required revision-bound passage plus a
    /// throwaway model for the guided Q&A hosted test. Both synthetic runtime and
    /// model authority require the hermetic XCUITest launch contract.
    private func seedUITestGuidedQAIfNeeded() {
        guard let guidedQAUITestModelRoot,
              let matterID = mattersController.matters.first?.id else { return }
        do {
            try seedUITestGuidedQAModel(in: guidedQAUITestModelRoot)
            guard !(try store.documentLibrary.fetchDocuments(matterID: matterID)).contains(where: {
                $0.id == "ready-guided-document"
            }) else { return }

            func insertFixture(
                documentID: String,
                chunkID: String,
                name: String,
                text: String,
                status: MatterDocumentStatus
            ) throws {
                let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
                    id: "\(documentID)-blob",
                    sha256: "\(documentID)-synthetic-sha",
                    byteSize: text.utf8.count,
                    originalExtension: "txt",
                    managedRelativePath: "uitest/\(name)"
                )).blob
                let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
                    id: documentID,
                    matterID: matterID,
                    blobID: blob.id,
                    displayName: name,
                    status: status.rawValue,
                    extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                    indexStatus: DocumentIndexStatus.textIndexed.rawValue,
                    extractionMethod: "synthetic@toolchain:guided-qa-uitest"
                ))
                let part = DocumentPagePartRecord(
                    id: "\(documentID)-part",
                    documentID: document.id,
                    partIndex: 0,
                    sourceKind: DocumentSourceKind.text.rawValue,
                    normalizedText: text,
                    charCount: text.count
                )
                let revision = DocumentPartRevisionRecord(
                    id: "\(documentID)-revision",
                    documentID: document.id,
                    partIndex: 0,
                    derivationKey: "guided-qa-uitest:\(documentID)",
                    origin: "parser",
                    method: "synthetic",
                    text: text,
                    charCount: text.count
                )
                let selection = DocumentPartSelectionRecord(
                    id: "\(documentID)-selection",
                    documentID: document.id,
                    partIndex: 0,
                    selectedRevisionID: revision.id,
                    selectionKey: "guided-qa-uitest:\(documentID)",
                    selectedBy: "policy",
                    policyVersion: 1,
                    decisionJSON: #"{"rule":"synthetic_guided_qa_ui_fixture"}"#
                )
                _ = try store.documentRevisions.replacePartsAndPersistLineage(
                    documentID: document.id,
                    parts: [part],
                    revisions: [revision],
                    selections: [selection]
                )
                try store.documentIndex.replaceChunks(documentID: document.id, chunks: [
                    DocumentChunkRecord(
                        id: chunkID,
                        documentID: document.id,
                        pagePartID: part.id,
                        revisionID: revision.id,
                        chunkerVersion: 2,
                        chunkIndex: 0,
                        sourceKind: DocumentSourceKind.text.rawValue,
                        charStart: 0,
                        charEnd: text.count,
                        normalizedText: text,
                        displayExcerpt: text
                    ),
                ])
            }

            try insertFixture(
                documentID: "ready-guided-document",
                chunkID: "ready-guided-chunk",
                name: "Atlas Ready Agreement.txt",
                text: "ATLAS_READY_UI_CANARY. Rent is due on the first business day.",
                status: .ready
            )
            try insertFixture(
                documentID: "review-guided-document",
                chunkID: "review-guided-chunk",
                name: "Beacon Review Draft.txt",
                text: "BEACON_REVIEW_UI_CANARY. This draft needs attorney review.",
                status: .needsReview
            )
        } catch {
            assertionFailure("Could not seed guided Q&A accessibility fixture: \(error)")
        }
    }

    /// Installs a tiny integrity-valid model fixture and routes legal reasoning to
    /// it. The app still exercises ModelLibrary's production load + stable-lineage
    /// checks; only the runtime implementation is deterministic under the explicit
    /// guided-Q&A UI-test launch flag.
    private func seedUITestGuidedQAModel(in authorizedRoot: URL) throws {
        let modelID = "77777777-7777-4777-8777-777777777777"
        let modelDirectory = authorizedRoot
            .appendingPathComponent("guided-qa-ui-model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        let artifacts: [(String, Data)] = [
            ("config.json", Data(#"{"model_type":"guided_qa_ui_test"}"#.utf8)),
            ("model.safetensors", Data("guided-qa-ui-test-weights".utf8)),
        ]
        for (name, data) in artifacts {
            try data.write(
                to: modelDirectory.appendingPathComponent(name, isDirectory: false),
                options: .atomic
            )
        }
        let manifest = ModelArtifactManifest(
            repositoryID: "supra-test/guided-qa",
            revision: String(repeating: "7", count: 40),
            files: artifacts.map { name, data in
                ModelArtifactManifest.File(
                    relativePath: name,
                    size: Int64(data.count),
                    digestAlgorithm: .sha256,
                    digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: ManagedModelStorage.manifestURL(in: modelDirectory),
            options: .atomic
        )
        try store.models.upsertModel(ModelRecord(
            id: modelID,
            displayName: "Guided Q&A UI Test Model",
            path: modelDirectory.path,
            isActive: true,
            validationStatus: "verified"
        ))
        modelLibrary.refresh()
        modelLibrary.assignModel(modelID, to: .legalReasoning)
    }

    /// A fully fictional, revision-bound motion fixture used only by the hosted
    /// motion XCUITests. The success and blocked variants share the same complete
    /// Florida caption/service inputs; only authority readiness differs.
    private func seedUITestMotionDraftIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        let success = arguments.contains("-uiTestMotionDraftSuccess")
        let blocked = arguments.contains("-uiTestMotionDraftBlocked")
        guard success || blocked, let matterID = mattersController.matters.first?.id else { return }

        do {
            if var draft = mattersController.draft(forMatter: matterID) {
                draft.jurisdiction = "Florida"
                draft.partyPerspective = .defendant
                draft.court = "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA"
                draft.judge = "Hon. Jane Smith"
                draft.docketNumber = "2026-CA-001847"
                try mattersController.updateMatter(id: matterID, draft: draft)
            }

            var profile = AssistantProfile()
            profile.fullName = "Harvey Specter"
            profile.organization = "Pearson Specter Litt"
            profile.barNumber = "100847"
            profile.officeStreet = "200 West Forsyth Street"
            profile.officeSuite = "Suite 1400"
            profile.officeCity = "Jacksonville"
            profile.officeState = "Florida"
            profile.officeZip = "32202"
            profile.officePhone = "(904) 555-0142"
            profile.officeFax = "(904) 555-0143"
            profile.primaryEmail = "hspecter@pearsonspecterlitt.example"
            profile.secondaryEmails = ["litdocket@pearsonspecterlitt.example"]
            try store.appSettings.setSetting(AssistantProfile.profileKey, value: profile)

            let factName = "Motion Draft First Amended Complaint.txt"
            if !(try store.documentLibrary.fetchDocuments(matterID: matterID)).contains(where: { $0.displayName == factName }) {
                let text = "The fictional pleading alleges that Liberty Rail received rail components, without alleging a breached contractual duty. "
                    + "It identifies a shipment, describes the component category, and alleges receipt at the fictional project location, but it does not identify a contractual promise that Liberty Rail failed to perform. "
                    + "Full review tail: the fictional pleading alleges no damages amount."
                let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
                    sha256: DocumentStorage.sha256Hex(of: Data("uitest-motion-fact".utf8)),
                    byteSize: text.utf8.count,
                    originalExtension: "txt",
                    managedRelativePath: "uitest/\(factName)"
                )).blob
                let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
                    matterID: matterID,
                    blobID: blob.id,
                    displayName: factName,
                    status: MatterDocumentStatus.ready.rawValue,
                    extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                    indexStatus: DocumentIndexStatus.textIndexed.rawValue,
                    extractionMethod: "synthetic@toolchain:motion-uitest"
                ))
                let part = DocumentPagePartRecord(
                    id: "ui-motion-fact-part",
                    documentID: document.id,
                    partIndex: 0,
                    sourceKind: DocumentSourceKind.text.rawValue,
                    normalizedText: text,
                    charCount: text.count
                )
                let revision = DocumentPartRevisionRecord(
                    id: "ui-motion-fact-revision",
                    documentID: document.id,
                    partIndex: 0,
                    derivationKey: "motion-uitest:\(document.id)",
                    origin: "parser",
                    method: "synthetic",
                    text: text,
                    charCount: text.count
                )
                let selection = DocumentPartSelectionRecord(
                    id: "ui-motion-fact-selection",
                    documentID: document.id,
                    partIndex: 0,
                    selectedRevisionID: revision.id,
                    selectionKey: "motion-uitest:\(document.id)",
                    selectedBy: "policy",
                    policyVersion: 1,
                    decisionJSON: #"{"rule":"synthetic_motion_ui_fixture"}"#
                )
                _ = try store.documentRevisions.replacePartsAndPersistLineage(
                    documentID: document.id,
                    parts: [part],
                    revisions: [revision],
                    selections: [selection]
                )
                try store.documentIndex.replaceChunks(documentID: document.id, chunks: [
                    DocumentChunkRecord(
                        id: "ui-motion-fact-chunk",
                        documentID: document.id,
                        pagePartID: part.id,
                        revisionID: revision.id,
                        // This hand-authored hosted fixture uses the stable chunk ID
                        // asserted by XCUITest. Keep it on the supported v1 exact-slice
                        // contract; v2 IDs are owned by the production chunk producer.
                        chunkerVersion: 1,
                        chunkIndex: 0,
                        sourceKind: DocumentSourceKind.text.rawValue,
                        charStart: 0,
                        charEnd: text.count,
                        normalizedText: text,
                        displayExcerpt: text,
                        tokenCount: 24
                    )
                ])
            }

            let authorityName = blocked
                ? "Fictional Motion Authority — Review Required"
                : "Fictional Marine, LLC v. Harbor Works, Inc."
            let authority: AuthorityRecord
            if let existing = (try store.authorities.fetchAuthorities(matterID: matterID)).first(where: {
                $0.caseName == authorityName
            }) {
                authority = existing
            } else {
                let session = try store.research.createSession(
                    matterID: matterID,
                    title: "Fictional motion authority fixture",
                    issueText: "Failure to state a claim",
                    jurisdiction: "Florida",
                    status: .approved
                )
                let query = try store.research.createQuery(
                    researchSessionID: session.id,
                    queryText: "Florida motion to dismiss standard",
                    queryIndex: 0,
                    status: .approved
                )
                let result = try store.research.insertResult(ResearchResultRecord(
                    researchQueryID: query.id,
                    caseName: authorityName
                ))
                let citation = "Fictional Marine, LLC v. Harbor Works, Inc., 345 So. 3d 100, 104 (Fla. 1st DCA 2025)"
                let support = "A motion to dismiss for failure to state a cause of action tests legal sufficiency, accepts well-pleaded allegations as true, and does not accept conclusory allegations."
                authority = try store.authorities.insertAuthority(AuthorityRecord(
                    id: blocked ? "ui-motion-authority-blocked" : "ui-motion-authority-success",
                    matterID: matterID,
                    researchSessionID: session.id,
                    researchResultID: result.id,
                    caseName: authorityName,
                    citationJSON: String(decoding: try JSONEncoder().encode([citation]), as: UTF8.self),
                    preferredCitation: citation,
                    court: "Florida District Court of Appeal",
                    courtID: "fladistctapp",
                    reviewState: blocked
                        ? ResearchResultReviewState.needsLaterReview.rawValue
                        : ResearchResultReviewState.notAdverse.rawValue,
                    useStatus: AuthorityUseStatus.userMarkedVerified.rawValue,
                    opinionText: support,
                    caseSummary: support
                ))
            }
            if success {
                let support = "A motion to dismiss for failure to state a cause of action tests legal sufficiency, accepts well-pleaded allegations as true, and does not accept conclusory allegations."
                switch try store.authorities.reviewedPropositionState(
                    authorityID: authority.id,
                    groundKey: .failureToStateClaim
                ) {
                case .ready:
                    break
                case .notReviewed, .blocked(_):
                    _ = try store.authorities.reviewProposition(
                        authorityID: authority.id,
                        groundKey: .failureToStateClaim,
                        excerpt: support,
                        reviewedBy: profile.fullName
                    )
                }
            }
            mattersController.loadMatters()
        } catch {
            assertionFailure("Could not seed motion drafting UI fixture: \(error)")
        }
    }

    /// Seeds one completed encrypted-source rejection for the T-OPS-07 warning
    /// contract. The report and source row contain only synthetic fixture data.
    private func seedUITestImportFailureIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestImportFailure"),
              let matterID = mattersController.matters.first?.id else { return }
        do {
            let marker = "SupraAI UI-test actionable import failure"
            guard !(try store.documentJobs.fetchBatches(matterID: matterID)).contains(where: {
                $0.sourceRootDisplay == marker
            }) else { return }

            let displayName = "privileged-locked.pdf"
            let guidance = "Password-protected or encrypted files cannot be imported. Remove encryption from a copy and try again."
            let batch = try store.documentJobs.createBatch(
                matterID: matterID,
                sourceRootDisplay: marker
            )
            let source = try store.documentJobs.recordDiscovered(
                batchID: batch.id,
                matterID: matterID,
                sourceKey: "selection:0",
                sourceDisplayPath: displayName
            )
            _ = try store.documentJobs.markState(
                sourceID: source.id,
                state: .rejected,
                rejectionCode: "encrypted_source",
                reason: guidance
            )
            let reportJSON = """
            {"items":[{"displayName":"\(displayName)","sourceDisplayPath":"\(displayName)","disposition":"rejected","reason":"\(guidance)","rejectionCode":"encrypted_source"}],"counts":{"rejected":1}}
            """
            try store.documentJobs.updateBatchProgress(
                id: batch.id,
                discoveredCount: 1,
                importedCount: 0,
                failedCount: 1
            )
            try store.documentJobs.finalizeBatch(
                id: batch.id,
                status: .completeWithFailures,
                reportJSON: reportJSON
            )
        } catch {
            assertionFailure("Could not seed actionable import failure fixture: \(error)")
        }
    }

    /// Seeds one proposal-only draft/executed family for the T-UX-08 review flow.
    /// The relation evidence includes non-default diff counts so the UI test proves
    /// the immutable evidence surface is wired, not a generic placeholder.
    private func seedUITestDocumentRelationsIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestDocumentRelations"),
              let matterID = mattersController.matters.first?.id else { return }
        do {
            guard (try store.documentRelations.fetchAll(matterID: matterID)).isEmpty else { return }
            func insert(_ id: String, name: String) throws -> MatterDocumentRecord {
                let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
                    id: "uitest-relation-blob-\(id)",
                    sha256: "uitest-relation-sha-\(id)",
                    byteSize: 24,
                    originalExtension: "txt",
                    managedRelativePath: "uitest/\(name)"
                )).blob
                return try store.documentLibrary.insertDocument(MatterDocumentRecord(
                    id: "uitest-relation-\(id)",
                    matterID: matterID,
                    blobID: blob.id,
                    displayName: name,
                    status: MatterDocumentStatus.ready.rawValue,
                    extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                    indexStatus: DocumentIndexStatus.ready.rawValue
                ))
            }
            let draft = try insert("draft", name: "Atlas Agreement Draft.txt")
            let executed = try insert("executed", name: "Atlas Agreement Executed.txt")
            _ = try store.documentRelations.propose(
                matterID: matterID,
                fromDocumentID: draft.id,
                toDocumentID: executed.id,
                kind: .draftOf,
                evidenceJSON: #"{"schema_version":1,"role_signal":"draft_to_executed","combined_similarity":0.84,"changed_units":2,"inserted_units":1,"deleted_units":0}"#,
                confidence: 0.84,
                proposedBy: .system
            )
        } catch {
            assertionFailure("Could not seed relation review accessibility fixture: \(error)")
        }
    }

    /// Seeds one revision-backed text part only for T-UX-07. The fixture lives in
    /// the throwaway UI-test database and never touches the user's document store.
    private func seedUITestDocumentCorrectionIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestDocumentCorrection"),
              let matterID = mattersController.matters.first?.id else { return }
        do {
            guard !(try store.documentLibrary.fetchDocuments(matterID: matterID)).contains(where: {
                $0.displayName == "Correction Fixture.txt"
            }) else { return }
            let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
                sha256: "uitest-correction-fixture-sha",
                byteSize: 0,
                originalExtension: "txt",
                managedRelativePath: "uitest/Correction Fixture.txt"
            )).blob
            let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
                matterID: matterID,
                blobID: blob.id,
                displayName: "Correction Fixture.txt",
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.ready.rawValue,
                extractionMethod: "synthetic@toolchain:uitest"
            ))
            let part = DocumentPagePartRecord(
                documentID: document.id,
                partIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: "ORIGINAL-ALPHA",
                charCount: 14
            )
            try store.documentIndex.replaceParts(documentID: document.id, parts: [part])
            let revision = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
                documentID: document.id,
                partIndex: 0,
                derivationKey: "uitest-correction-original",
                origin: "parser",
                method: "synthetic",
                text: "ORIGINAL-ALPHA",
                charCount: 14
            ))
            _ = try store.documentRevisions.appendSelection(DocumentPartSelectionRecord(
                documentID: document.id,
                partIndex: 0,
                selectedRevisionID: revision.id,
                selectionKey: "uitest-correction-selection",
                selectedBy: "policy",
                policyVersion: 1,
                decisionJSON: #"{"rule":"synthetic_ui_fixture"}"#
            ))
        } catch {
            assertionFailure("Could not seed correction accessibility fixture: \(error)")
        }
    }

    /// Creates a five-source, three-complete/two-interrupted import only for the
    /// dedicated recovery UI tests. The backing files and store are both
    /// hermetic throwaways selected by `-uiTestMode`.
    private func seedUITestInterruptedImportIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestInterruptedImport"),
              let matterID = mattersController.matters.first?.id else { return }
        do {
            let marker = "SupraAI UI-test interrupted import"
            guard !(try store.documentJobs.fetchBatches(matterID: matterID)).contains(where: {
                $0.sourceRootDisplay == marker
            }) else { return }

            let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "SupraAI-UITest-Interrupted-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
            let batch = try store.documentJobs.createBatch(
                matterID: matterID,
                sourceRootDisplay: marker
            )
            for index in 1...5 {
                let name = "Resume Fixture \(index).txt"
                let url = fixtureRoot.appendingPathComponent(name)
                let bookmark: Data?
                if index > 3 {
                    try Data("Synthetic resumable UI fixture \(index).".utf8).write(to: url, options: .atomic)
                    bookmark = try url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                } else {
                    bookmark = nil
                }
                let source = try store.documentJobs.recordDiscovered(
                    batchID: batch.id,
                    matterID: matterID,
                    sourceKey: "selection:\(index - 1)",
                    sourceDisplayPath: name,
                    sourceBookmark: bookmark,
                    state: .selected
                )
                if index <= 3 {
                    _ = try store.documentJobs.markState(sourceID: source.id, state: .admitted)
                }
            }
            try store.documentJobs.updateBatchProgress(
                id: batch.id,
                discoveredCount: 5,
                importedCount: 3,
                failedCount: 0
            )
            _ = try store.documentJobs.enqueueJob(matterID: matterID, importBatchID: batch.id)
            _ = try store.documentJobs.activateNextJobIfIdle()
        } catch {
            assertionFailure("Could not seed interrupted import accessibility fixture: \(error)")
        }
    }

    /// Seeds one descriptor-valid preserved file and one integrity-invalid
    /// recovery row only for the dedicated hosted publication-recovery test.
    /// Both the Store and managed root are hermetic UI-test throwaways.
    private func seedUITestInterruptedDraftRecoveryIfNeeded() {
        guard interruptedDraftRecoveryUITestRoot != nil,
              let matterID = mattersController.matters.first?.id else { return }
        do {
            let validID = "ui-interrupted-draft-valid"
            let validOutput = Data("# Synthetic preserved interrupted publication\n".utf8)
            let validIntent: DraftArtifactIntentRecord
            if let existing = try store.draftArtifacts.intent(id: validID) {
                validIntent = existing
            } else {
                validIntent = try store.draftArtifacts.prepareGenericIntent(
                    matterID: matterID,
                    artifactKind: .customDescription,
                    format: .markdown,
                    fileName: "Interrupted-publication.md",
                    output: validOutput,
                    id: validID
                )
            }
            let validURL = draftArtifactStorage.exportsDirectory(forMatterID: matterID)
                .appendingPathComponent(validIntent.fileName, isDirectory: false)
            try FileManager.default.createDirectory(
                at: validURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: validURL.path) {
                try validOutput.write(to: validURL, options: .withoutOverwriting)
            }
            try store.draftArtifacts.markRecoveryRequired(id: validIntent.id)

            let corruptID = "ui-interrupted-draft-corrupt"
            if try store.draftArtifacts.intent(id: corruptID) == nil {
                _ = try store.draftArtifacts.prepareGenericIntent(
                    matterID: matterID,
                    artifactKind: .customDescription,
                    format: .markdown,
                    fileName: "Corrupt-interrupted-publication.md",
                    output: Data("# Synthetic corrupt lineage marker\n".utf8),
                    id: corruptID
                )
                try store.database.writer.write { db in
                    try db.execute(
                        sql: "UPDATE draft_artifact_intents SET file_name = ? WHERE id = ?",
                        arguments: ["../../outside-managed-storage.md", corruptID]
                    )
                }
            }
            try store.draftArtifacts.markRecoveryRequired(id: corruptID)
        } catch {
            assertionFailure("Could not seed interrupted draft recovery fixture: \(error)")
        }
    }

    /// Seeds explicit legacy-state fixtures only for the remediation accessibility
    /// smoke test. Keeping this behind a separate launch argument prevents the
    /// normal UI suite from depending on migrated data.
    private func seedUITestRemediationWarningsIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestRemediationWarnings"),
              let matterID = mattersController.matters.first?.id
        else { return }

        do {
            let existing = try store.structuredOutputs.fetchOutputs(matterID: matterID)
            if !existing.contains(where: { $0.title == "Legacy Verification Fixture" }) {
                let output = try store.structuredOutputs.createOutput(
                    matterID: matterID,
                    title: "Legacy Verification Fixture",
                    outputType: .documentQA,
                    status: .needsReview
                )
                _ = try store.structuredOutputs.createVersion(
                    structuredOutputID: output.id,
                    contentMarkdown: "# Legacy Verification Fixture\n\nSynthetic UI-test content.",
                    requiredSections: [],
                    presentSections: [],
                    missingSections: [],
                    verificationStatus: .legacyUnverified,
                    outputStatus: .needsReview
                )
                _ = try store.remediationRecovery.requireReview(
                    kind: .legacyStructuredOutput,
                    matterID: matterID,
                    relatedTable: "structured_outputs",
                    relatedID: output.id
                )
            }

            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            let day = try store.scratchPad.fetchOrCreateDay(formatter.string(from: Date()))
            let draft = try store.billing.drafts(dayID: day.id).first ?? store.billing.createDraft(
                dayID: day.id,
                lineItems: [BillingLineItemInput(
                    matterID: matterID,
                    narrative: "Synthetic migrated billing assignment",
                    hours: 0.5,
                    workDate: day.day
                )]
            )
            _ = try store.remediationRecovery.requireReview(
                kind: .multiMatterBillingDraft,
                matterID: nil,
                relatedTable: "billing_drafts",
                relatedID: draft.id
            )
        } catch {
            assertionFailure("Could not seed remediation accessibility fixture: \(error)")
        }
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
                let agreementText = "SECTION 3. The term of this Agreement is two (2) years from the Effective Date."
                try store.documentIndex.replaceParts(documentID: document.id, parts: [
                    DocumentPagePartRecord(
                        documentID: document.id,
                        partIndex: 0,
                        sourceKind: DocumentSourceKind.text.rawValue,
                        normalizedText: agreementText,
                        charCount: agreementText.count
                    )
                ])
                let revision = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
                    documentID: document.id,
                    partIndex: 0,
                    derivationKey: "uitest-agreement-revision",
                    origin: "parser",
                    method: "synthetic",
                    text: agreementText,
                    charCount: agreementText.count
                ))
                _ = try store.documentRevisions.appendSelection(DocumentPartSelectionRecord(
                    documentID: document.id,
                    partIndex: 0,
                    selectedRevisionID: revision.id,
                    selectionKey: "uitest-agreement-selection",
                    selectedBy: "policy",
                    policyVersion: 1,
                    decisionJSON: #"{"selected":"synthetic"}"#
                ))
                let structureNodes = [
                    DocumentStructureNodeRecord(
                        id: "uitest-structure-root",
                        documentID: document.id,
                        revisionID: revision.id,
                        nodeKey: "document",
                        ordinal: 0,
                        kind: "document"
                    ),
                    DocumentStructureNodeRecord(
                        id: "uitest-structure-body",
                        documentID: document.id,
                        revisionID: revision.id,
                        nodeKey: "body/paragraph/1",
                        parentNodeID: "uitest-structure-root",
                        ordinal: 0,
                        kind: "paragraph",
                        charStart: 0,
                        charEnd: agreementText.count,
                        payloadJSON: #"{"style":"Contract Body"}"#
                    ),
                    DocumentStructureNodeRecord(
                        id: "uitest-structure-footnote",
                        documentID: document.id,
                        revisionID: revision.id,
                        nodeKey: "footnote/1",
                        parentNodeID: "uitest-structure-root",
                        ordinal: 1,
                        kind: "footnote",
                        textContent: "Synthetic defined-term footnote",
                        payloadJSON: #"{"noteID":"1"}"#
                    ),
                    DocumentStructureNodeRecord(
                        id: "uitest-structure-comment",
                        documentID: document.id,
                        revisionID: revision.id,
                        nodeKey: "comment/1",
                        parentNodeID: "uitest-structure-root",
                        ordinal: 2,
                        kind: "comment",
                        textContent: "Synthetic reviewer comment"
                    ),
                ]
                try store.documentStructure.replaceStructure(
                    documentID: document.id,
                    revisionID: revision.id,
                    nodes: structureNodes,
                    edges: [
                        DocumentStructureEdgeRecord(
                            id: "uitest-structure-edge-footnote",
                            matterID: matterID,
                            fromNodeID: "uitest-structure-footnote",
                            toNodeID: "uitest-structure-body",
                            kind: "anchor_of"
                        ),
                        DocumentStructureEdgeRecord(
                            id: "uitest-structure-edge-comment",
                            matterID: matterID,
                            fromNodeID: "uitest-structure-comment",
                            toNodeID: "uitest-structure-body",
                            kind: "anchor_of"
                        ),
                    ]
                )
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

    #if DEBUG
    /// Debug-only (`-dumpOpinion <id>`): fetches one CourtListener opinion with
    /// the app's own credentials and puts the raw field lengths + bodyText and
    /// bestHTML excerpts on the pasteboard, so pagination-marker formats can be
    /// inspected outside the sandbox. Reads only.
    func dumpOpinionToPasteboardIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-dumpOpinion"),
              arguments.count > flagIndex + 1,
              let opinionID = Int(arguments[flagIndex + 1]) else { return }
        let tokenStore = EnvironmentBackedTokenStore(primary: KeychainTokenStore())
        let client = CourtListenerClient(
            httpClient: AuthorizedHTTPClient(
                keyStore: tokenStore,
                policy: NetworkPolicyService(),
                logger: NetworkRequestLogger(repository: store.networkRequests)
            )
        )
        Task { @MainActor in
            var dump: [String: Any] = ["opinionID": opinionID]
            if let detail = try? await client.fetchOpinion(id: opinionID) {
                dump["plainTextChars"] = detail.plainText?.count ?? 0
                dump["htmlChars"] = detail.html?.count ?? 0
                dump["htmlWithCitationsChars"] = detail.htmlWithCitations?.count ?? 0
                dump["htmlLawboxChars"] = detail.htmlLawbox?.count ?? 0
                dump["htmlColumbiaChars"] = detail.htmlColumbia?.count ?? 0
                if let raw = detail.bestHTML {
                    dump["bestHTMLHead"] = String(raw.prefix(6_000))
                    dump["bestHTMLMid"] = String(raw.dropFirst(max(0, raw.count / 2)).prefix(3_000))
                }
                if let body = detail.bodyText {
                    dump["bodyTextChars"] = body.count
                    dump["bodyTextHead"] = String(body.prefix(6_000))
                    dump["bodyTextMid"] = String(body.dropFirst(max(0, body.count / 2)).prefix(3_000))
                }
            } else {
                dump["error"] = "fetch failed (token? network?)"
            }
            if let data = try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(json, forType: .string)
            }
        }
    }

    /// Debug-only (`-dumpChats`): serializes every chat, message, citation, and
    /// saved authority to JSON on the general pasteboard, so store contents can be
    /// inspected from outside the sandbox without Full Disk Access. Reads only —
    /// never mutates the store.
    func dumpStoreToPasteboardIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-dumpChats") else { return }
        var dump: [String: Any] = [:]
        var chatDumps: [[String: Any]] = []
        let matters = (try? store.matters.fetchMatters()) ?? []
        var chats = (try? store.chats.fetchGlobalChats()) ?? []
        for matter in matters {
            chats += (try? store.chats.fetchMatterChats(matterID: matter.id)) ?? []
        }
        for chat in chats {
            let messages = (try? store.chats.fetchMessages(chatID: chat.id)) ?? []
            chatDumps.append([
                "id": chat.id,
                "title": chat.title,
                "scope": chat.scope,
                "messages": messages.map { message -> [String: Any] in
                    let citations = (try? store.chats.fetchCitations(messageID: message.id)) ?? []
                    return [
                        "role": message.role,
                        "status": message.status,
                        "createdAt": "\(message.createdAt)",
                        "content": message.content,
                        "citations": citations.map { c in
                            ["label": c.label, "kind": c.kind, "display": c.displayName ?? "", "url": c.url ?? "", "locator": c.locatorJSON ?? "", "match": c.matchText ?? ""]
                        },
                    ]
                },
            ])
        }
        dump["chats"] = chatDumps
        dump["matters"] = matters.map { ["id": $0.id, "name": $0.name, "jurisdiction": $0.jurisdiction] }
        dump["authorities"] = matters.flatMap { matter -> [[String: Any]] in
            ((try? store.authorities.fetchAuthorities(matterID: matter.id)) ?? []).map { a in
                [
                    "caseName": a.caseName,
                    "citationJSON": a.citationJSON,
                    "opinionID": a.opinionID ?? "",
                    "reviewState": a.reviewState,
                    "useStatus": a.useStatus,
                    "opinionTextChars": a.opinionText?.count ?? 0,
                ]
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(json, forType: .string)
        }
    }
    #endif

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
            // This fixture creates the matter directly, then delegates the same
            // practice-area starter-folder setup used by MattersController.createMatter.
            mattersController.seedStarterFolders(
                matterID: matter.id,
                practiceArea: "Commercial Litigation"
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

            // ScratchPad: two days of fictitious notes with generated billing
            // drafts, so the week strip's billable-hour indicators and the
            // review table render with content in screenshots.
            let dayFormatter = DateFormatter()
            dayFormatter.calendar = Calendar(identifier: .gregorian)
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.timeZone = .current
            dayFormatter.dateFormat = "yyyy-MM-dd"
            let todayString = dayFormatter.string(from: Date())
            let yesterdayString = dayFormatter.string(from: Date().addingTimeInterval(-86_400))
            let pad = try store.scratchPad.fetchOrCreateDay(todayString)
            try store.scratchPad.addEntry(
                dayID: pad.id,
                text: "Drafted opposition to motion to compel @MeridianFabrication #drafting",
                mentions: [matter.id], tags: ["drafting"]
            )
            try store.scratchPad.addEntry(
                dayID: pad.id,
                text: "TC w/ adjuster re coverage position #call",
                tags: ["call"]
            )
            try store.billing.createDraft(dayID: pad.id, lineItems: [
                BillingLineItemInput(
                    matterID: matter.id,
                    narrative: "Drafted opposition to motion to compel and supporting exhibits.",
                    hours: 2.4, workDate: todayString, utbmsTaskCode: "L350", utbmsActivityCode: "A103"
                ),
                BillingLineItemInput(
                    matterID: matter.id,
                    narrative: "Telephone conference with insurance adjuster regarding coverage position.",
                    hours: 0.4, workDate: todayString, utbmsTaskCode: "L120", utbmsActivityCode: "A106"
                ),
            ])
            let priorPad = try store.scratchPad.fetchOrCreateDay(yesterdayString)
            try store.scratchPad.addEntry(
                dayID: priorPad.id,
                text: "Reviewed Calloway deposition transcript @MeridianFabrication #review",
                mentions: [matter.id], tags: ["review"]
            )
            try store.billing.createDraft(dayID: priorPad.id, lineItems: [
                BillingLineItemInput(
                    matterID: matter.id,
                    narrative: "Reviewed Calloway deposition transcript for tie-down testimony.",
                    hours: 1.2, workDate: yesterdayString, utbmsTaskCode: "L330", utbmsActivityCode: "A104"
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

    /// Authorizes the one UI test that must retain Store state across a real
    /// process boundary. The caller-supplied root is accepted only inside this
    /// app sandbox's temporary directory; every other UI-test launch retains the
    /// existing fresh-per-process Store behavior.
    private static func interruptedDraftRecoveryUITestRoot() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        guard isUITestMode,
              arguments.contains("-uiTestInterruptedDraftRecovery"),
              let rawRoot = environment["SUPRA_UI_TEST_DRAFT_STORAGE_ROOT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawRoot.isEmpty
        else { return nil }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: rawRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix("\(temporaryRoot.path)/") else { return nil }
        return candidate
    }

#if DEBUG
    /// Allows only the dedicated hosted recovery fixture to inspect its own
    /// temporary managed root from inside the sandboxed app process.
    static var interruptedDraftRecoveryUITestManagedRoot: URL? {
        interruptedDraftRecoveryUITestRoot()
    }
#endif

    private static func interruptedDraftRecoveryUITestStoreURL() -> URL? {
        interruptedDraftRecoveryUITestRoot()?
            .appendingPathComponent(".supra-ui-test-store", isDirectory: true)
            .appendingPathComponent("SupraAI.sqlite", isDirectory: false)
    }

    /// Allows only the dedicated paused and cancellation Guided Review fixtures to
    /// retain their throwaway Store across relaunch. The XCUITest supplies a path
    /// inside this app container's temporary directory; all other Review launches
    /// stay fresh.
    private static func reviewCreationUITestRoot() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard isUITestMode,
              ProcessInfo.processInfo.arguments.contains("-uiTestReviewCreation"),
              let scenario = reviewCreationUITestScenario,
              ["paused", "slowVerification"].contains(scenario),
              let rawRoot = environment["SUPRA_UI_TEST_REVIEW_CREATION_ROOT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawRoot.isEmpty else { return nil }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: rawRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix("\(temporaryRoot.path)/") else { return nil }
        return candidate
    }

    private static func reviewCreationUITestStoreURL() -> URL? {
        reviewCreationUITestRoot()?
            .appendingPathComponent(".supra-ui-test-store", isDirectory: true)
            .appendingPathComponent("SupraAI.sqlite", isDirectory: false)
    }

    /// Opens the on-disk store, falling back to a temporary store so the app still
    /// launches if the Application Support database cannot be created. `isFallback`
    /// is true for that degraded last-resort store (not for the UI-test store).
    private static func makeStore(
        after restoreActivation: RestoreActivationResult?,
        replayOutcome: RestoreOutcomeRecord?,
        outcomeReadFailed: Bool
    ) -> (
        store: SupraStore,
        isFallback: Bool,
        recoveryState: DatabaseRecoveryState?
    ) {
        let requiresHermeticStore = isUITestMode
            || isDemoMode
            || !headlessProbeResolution.permitsUserStoreOpen
        if requiresHermeticStore {
            // UI tests / demo screenshots are isolated from the user's real
            // Application Support database. Only the dedicated recovery test gets
            // a stable path under its validated temporary managed root; all other
            // launches use a fresh UUID Store. Model-dependent headless probes get
            // the same isolation
            // (measurement qualification, finding #5): a probe launch never opens or
            // migrates the user's real store — which also removes the Debug-build
            // erase-on-schema-change hazard for probe runs.
            let url: URL
            if let persistentUITestStoreURL = interruptedDraftRecoveryUITestStoreURL()
                ?? reviewCreationUITestStoreURL() {
                try? FileManager.default.createDirectory(
                    at: persistentUITestStoreURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                url = persistentUITestStoreURL
            } else {
                url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("SupraAI-\(headlessProbeRequiresIsolatedStore ? "Probe" : "UITest")-\(UUID().uuidString).sqlite")
            }
            if let store = try? SupraStore(url: url) {
#if DEBUG
                if isUITestMode,
                   ProcessInfo.processInfo.arguments.contains("-uiTestRestoreRecoveryRequired") {
                    let safetyDirectory = url.deletingLastPathComponent()
                        .appendingPathComponent(
                            "\(url.deletingPathExtension().lastPathComponent)-restore-safety",
                            isDirectory: true
                        )
                    try? FileManager.default.createDirectory(
                        at: safetyDirectory.appendingPathComponent("blobs", isDirectory: true),
                        withIntermediateDirectories: true
                    )
                    try? Data("SYNTHETIC UI TEST SAFETY DATABASE".utf8).write(
                        to: safetyDirectory.appendingPathComponent("restore-safety.sqlite")
                    )
                    try? Data("SYNTHETIC UI TEST MANAGED BLOB".utf8).write(
                        to: safetyDirectory
                            .appendingPathComponent("blobs", isDirectory: true)
                            .appendingPathComponent("synthetic-managed-document.bin")
                    )
                    return (
                        store,
                        true,
                        DatabaseRecoveryState(
                            failure: .restore,
                            recoveryItemURL: safetyDirectory
                        )
                    )
                }
#endif
                return (store, false, nil)
            }

            // A failed temporary-store open must not widen this launch's authority
            // to the user's Application Support database. Stay hermetic even in the
            // degraded path, without fallback-file cleanup side effects.
            if let store = try? SupraStore.inMemory() { return (store, true, nil) }
            return (unavailableStore(), true, nil)
        }
        if restoreActivation?.status == .recoveryRequired
            || replayOutcome?.status == .recoveryRequired
            || outcomeReadFailed
        {
            return (
                makeFallbackStore(),
                true,
                DatabaseRecoveryState(
                    failure: .restore,
                    recoveryItemURL: restoreActivation?.recoverySafetyDirectoryURL
                )
            )
        }
        do {
            return (try SupraStore.openAppSupportStore(), false, nil)
        } catch let error as SupraDatabaseOpenError {
            let recoveryState: DatabaseRecoveryState
            switch error {
            case .snapshotFailed:
                recoveryState = DatabaseRecoveryState(failure: .snapshot, recoveryItemURL: nil)
            case let .migrationFailed(snapshotURL, _):
                recoveryState = DatabaseRecoveryState(
                    failure: .migration,
                    recoveryItemURL: snapshotURL
                )
            }
            return (makeFallbackStore(), true, recoveryState)
        } catch {
            // Non-migration open errors retain the existing visibly degraded mode.
            // Migration failures never reach this path: they are typed above and
            // replace the work surface with the blocking recovery UI.
        }
        return (makeFallbackStore(), true, nil)
    }

    /// Consumes a complete restore intent before any user-store writer or
    /// controller graph exists. Hermetic and headless launches skip this seam so
    /// test/demo/probe authority can never mutate the user's live data.
    private static func prepareColdStartRestore() -> ColdStartRestoreEvidence? {
        guard !isUITestMode, !isDemoMode, !isHeadlessProbeMode,
              let databaseURL = try? DatabasePath.appSupportDatabaseURL()
        else { return nil }
        let layout = RestoreLiveLayout(
            databaseURL: databaseURL,
            blobsDirectory: DocumentStorage.makeDefault().blobsDirectory,
            stagingRootDirectory: databaseURL.deletingLastPathComponent()
                .appendingPathComponent(RestoreService.stagingDirectoryName, isDirectory: true)
        )
        let activation = RestoreActivationService.activatePendingRestore(liveLayout: layout)
        let outcome: RestoreOutcomeRecord?
        let outcomeReadFailed: Bool
        do {
            outcome = try RestoreSidecarStore.readActivationOutcome(
                stagingRootDirectory: layout.stagingRootDirectory
            )
            outcomeReadFailed = false
        } catch {
            outcome = nil
            outcomeReadFailed = true
        }
        let stagingFailure: RestoreStagingFailureRecord?
        if activation.status == .noPendingRestore, outcome == nil, !outcomeReadFailed {
            stagingFailure = try? RestoreSidecarStore.readStagingFailure(
                stagingRootDirectory: layout.stagingRootDirectory
            )
        } else {
            stagingFailure = nil
        }
        return ColdStartRestoreEvidence(
            activation: activation,
            outcome: outcome,
            stagingFailure: stagingFailure,
            outcomeReadFailed: outcomeReadFailed,
            stagingRootDirectory: layout.stagingRootDirectory
        )
    }

    private static func makeRestoreLiveLayoutForController(
        blobsDirectory: URL
    ) -> RestoreLiveLayout? {
        guard !isUITestMode, !isDemoMode, !isHeadlessProbeMode,
              let databaseURL = try? DatabasePath.appSupportDatabaseURL()
        else { return nil }
        return RestoreLiveLayout(
            databaseURL: databaseURL,
            blobsDirectory: blobsDirectory,
            stagingRootDirectory: databaseURL.deletingLastPathComponent()
                .appendingPathComponent(RestoreService.stagingDirectoryName, isDirectory: true)
        )
    }

#if DEBUG
    /// Synthetic controller dependencies for the hosted restore UI tests. They
    /// are reachable only with both `-uiTestMode` and the dedicated scenario flag.
    private static func makeRestoreUITestFixtureIfRequested() -> RestoreUITestFixture? {
        let arguments = ProcessInfo.processInfo.arguments
        guard isUITestMode,
              let marker = arguments.firstIndex(of: "-uiTestRestoreScenario"),
              arguments.indices.contains(marker + 1),
              arguments[marker + 1] == "mixed"
        else { return nil }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SupraAI-UITest-Restore-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        let destination = root.appendingPathComponent("Backups", isDirectory: true)
        let createdAt = Date(timeIntervalSince1970: 1_786_000_500)

        func candidate(
            identifier: String,
            incompatibility: RestoreIncompatibility?
        ) -> RestoreSnapshotCandidate {
            let manifest = BackupManifest(
                appVersion: "2.3.2",
                appBuild: "391",
                schemaMigrationIdentifiers: ["v069_add_verification_dimensions"],
                createdAt: createdAt,
                sourceDbBytes: 8_388_608,
                referencedBlobCount: 3
            )
            return RestoreSnapshotCandidate(
                identifier: identifier,
                backupDirectoryURL: destination,
                snapshotURL: destination.appendingPathComponent("db/\(identifier).sqlite"),
                manifestURL: destination.appendingPathComponent("db/\(identifier).json"),
                manifest: manifest,
                summary: RestoreSnapshotSummary(
                    createdAt: createdAt,
                    appVersion: manifest.appVersion,
                    appBuild: manifest.appBuild,
                    databaseBytes: manifest.sourceDbBytes,
                    referencedBlobCount: manifest.referencedBlobCount
                ),
                databaseSHA256: String(repeating: incompatibility == nil ? "a" : "b", count: 64),
                referencedBlobs: [],
                incompatibility: incompatibility
            )
        }

        let candidates = [
            candidate(identifier: "SupraAI-20260731-090000-000", incompatibility: nil),
            candidate(
                identifier: "SupraAI-20260730-081500-000",
                incompatibility: .databaseIntegrityFailed
            ),
        ]
        let layout = RestoreLiveLayout(
            databaseURL: root.appendingPathComponent("Live/SupraAI.sqlite"),
            blobsDirectory: root.appendingPathComponent("Live/Documents/blobs", isDirectory: true),
            stagingRootDirectory: root.appendingPathComponent("Live/RestoreStaging", isDirectory: true)
        )
        return RestoreUITestFixture(
            destinationURL: destination,
            liveLayout: layout,
            destinationFactory: { _ in RestoreUITestDestination(url: destination) },
            inspector: { _ in candidates },
            runner: { selected, _, operationID, scheduledAt in
                // Keep the terminal surface observable across XCUITest's
                // accessibility polling interval before simulating completion.
                try await Task.sleep(for: .seconds(5))
                return RestoreStageSummary(
                    operationID: operationID.uuidString,
                    snapshotIdentifier: selected.identifier,
                    stagedAt: scheduledAt
                )
            }
        )
    }
#endif

    private static func makeFallbackStore() -> SupraStore {
        // Unique-named on-disk fallback so a corrupt/locked leftover fallback file
        // from a previous crash can't doom every subsequent launch. Prune stale
        // fallback files first since nothing persists across launches in this path.
        cleanupStaleFallbackStores()
        let fallbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraAI-fallback-\(UUID().uuidString).sqlite")
        if let store = try? SupraStore(url: fallbackURL) {
            return store
        }
        // Absolute last resort: an in-memory store so the app still launches
        // (degraded — nothing persists) instead of crashing on a broken disk.
        if let store = try? SupraStore.inMemory() {
            return store
        }
        return unavailableStore()
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

/// Deterministic app-side runtime used only by the explicit guided-Q&A UI-test
/// launch. The first answer completes through the production streaming path; a
/// second answer remains in flight until the production cancellation RPC closes
/// it, giving the hosted test a stable no-partial-write boundary without XPC/model
/// timing variance.
private final class GuidedQAUITestRuntimeClient: RuntimeClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var loadedModelID: ModelID?
    private var generationCount = 0
    private var heldGenerationID: GenerationID?
    private var heldContinuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?

    func connect() async throws {}

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        lock.withLock { loadedModelID = request.modelID }
        return LoadModelResponse(status: .loaded, modelID: request.modelID)
    }

    func generate(_ request: GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let call = lock.withLock { () -> Int in
            generationCount += 1
            return generationCount
        }
        if call == 1 {
            return AsyncThrowingStream { continuation in
                continuation.yield(GenerationEvent(
                    generationID: request.generationID,
                    sequenceNumber: 0,
                    timestamp: Date(),
                    type: .token,
                    tokenText: "Rent is due on the first business day [S1]."
                ))
                continuation.yield(GenerationEvent(
                    generationID: request.generationID,
                    sequenceNumber: 1,
                    timestamp: Date(),
                    type: .generationCompleted
                ))
                continuation.finish()
            }
        }
        return AsyncThrowingStream { continuation in
            lock.withLock {
                heldGenerationID = request.generationID
                heldContinuation = continuation
            }
        }
    }

    func countTokens(_ request: CountTokensRequest) async throws -> CountTokensResponse {
        CountTokensResponse(
            modelID: request.modelID,
            counts: request.texts.map { max(1, ($0.utf8.count + 3) / 4) }
        )
    }

    func cancelGeneration(_ generationID: GenerationID) async throws -> CancelGenerationResponse {
        let continuation = lock.withLock { () -> AsyncThrowingStream<GenerationEvent, Error>.Continuation? in
            guard heldGenerationID == generationID else { return nil }
            defer {
                heldGenerationID = nil
                heldContinuation = nil
            }
            return heldContinuation
        }
        continuation?.finish()
        return CancelGenerationResponse(
            status: continuation == nil ? .notFound : .cancelled,
            generationID: generationID
        )
    }

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] { [] }

    func unloadModel() async throws -> UnloadModelResponse {
        lock.withLock { loadedModelID = nil }
        return UnloadModelResponse(status: .unloaded)
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        let modelID = lock.withLock { loadedModelID }
        return LoadModelResponse(
            status: modelID == nil ? .failed : .loaded,
            modelID: modelID,
            error: modelID == nil
                ? RuntimeError(category: "ui_test", message: "No UI-test model is loaded.")
                : nil
        )
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        let state = lock.withLock { (loadedModelID, heldGenerationID) }
        return RuntimeStatus(
            state: state.1 == nil ? (state.0 == nil ? .modelUnloaded : .modelLoaded) : .generating,
            loadedModelID: state.0,
            activeGenerationID: state.1,
            message: nil,
            metrics: nil
        )
    }

    func restartRuntimeService() async throws {}
}

private struct RestoreUITestFixture {
    let destinationURL: URL
    let liveLayout: RestoreLiveLayout
    let destinationFactory: BackupController.DestinationFactory
    let inspector: BackupController.RestoreInspector
    let runner: BackupController.RestoreRunner
}

private struct ColdStartRestoreEvidence: Sendable {
    let activation: RestoreActivationResult
    let outcome: RestoreOutcomeRecord?
    let stagingFailure: RestoreStagingFailureRecord?
    let outcomeReadFailed: Bool
    let stagingRootDirectory: URL
}

@MainActor
private struct RestoreUITestDestination: BackupDestination {
    let url: URL

    func withAccess<T: Sendable>(_ operation: (URL) async throws -> T) async throws -> T {
        try await operation(url)
    }
}
