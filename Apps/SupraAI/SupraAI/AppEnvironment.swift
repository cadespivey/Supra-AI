import Combine
import Foundation
import SupraCore
import SupraNetworking
import SupraResearch
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraSessions
import SupraStore

@MainActor
final class AppEnvironment: ObservableObject {
    @Published var runtimeReadinessState: RuntimeReadinessState = .limited
    @Published var runtimeServiceState: RuntimeServiceState = .disconnected
    /// Bumped to ask the Matters screen to open its New Matter editor (e.g. from
    /// the sidebar's New Matter button).
    @Published var newMatterRequests = 0
    @Published var runtimeStatusMessage = "Checking runtime"
    @Published var activeModelName: String?

    let store: SupraStore
    let modelLibrary: ModelLibrary
    let chatController: GlobalChatController
    let validationController: ValidationRunController
    let validationHistory: ValidationHistoryController
    let modelDownloadController: ModelDownloadController
    let settingsController: SettingsController
    let mattersController: MattersController
    // Milestone 3: document intelligence setup.
    let documentSetupController: DocumentIntelligenceSetupController
    let embeddingDownloadController: EmbeddingModelDownloadController
    let documentQueue: DocumentProcessingQueue
    let documentValidationController: DocumentValidationRunController

    private let runtimeStatusController: RuntimeStatusController

    init() {
        let runtimeClient = RuntimeClient()
        let store = AppEnvironment.makeStore()
        let systemPrompt = DefaultSystemPrompt.milestone1()
        let appVersion = AppEnvironment.currentAppVersion()
        let modelLibrary = ModelLibrary(store: store, runtimeClient: runtimeClient)
        self.store = store
        self.runtimeStatusController = RuntimeStatusController(runtimeClient: runtimeClient)
        self.modelLibrary = modelLibrary
        self.chatController = GlobalChatController(
            store: store,
            runtimeClient: runtimeClient,
            defaultSystemPrompt: systemPrompt
        )
        self.validationController = ValidationRunController(
            store: store,
            runtimeClient: runtimeClient,
            appVersion: appVersion,
            systemPrompt: systemPrompt
        )
        self.validationHistory = ValidationHistoryController(store: store)
        self.modelDownloadController = ModelDownloadController(
            store: store,
            modelLibrary: modelLibrary,
            fetcher: HuggingFaceClient()
        )
        self.settingsController = SettingsController(store: store, appVersion: appVersion)

        // Document intelligence controllers must exist before MattersController so
        // it can vend a per-matter Documents controller wired to the queue + gate.
        let documentSetup = DocumentIntelligenceSetupController(store: store, runtimeClient: runtimeClient)
        self.documentSetupController = documentSetup
        self.embeddingDownloadController = EmbeddingModelDownloadController(
            store: store,
            fetcher: HuggingFaceClient()
        )
        let queue = DocumentProcessingQueue(
            store: store,
            importService: DocumentImportService(store: store),
            makeIndexingService: {
                // Build a fresh indexing service per job using the currently
                // selected embedding model (if any).
                let model = try? store.documentSettings.fetchSelectedEmbeddingModel()
                let embedder = model.flatMap { RuntimeTextEmbedder(model: $0, runtimeClient: runtimeClient) }
                return DocumentIndexingService(store: store, embedder: embedder)
            }
        )
        self.documentQueue = queue
        self.mattersController = MattersController(
            store: store,
            runtimeClient: runtimeClient,
            defaultSystemPrompt: systemPrompt,
            documentQueue: queue,
            isImportReady: { documentSetup.isReadyForImport }
        )
        self.documentValidationController = DocumentValidationRunController(store: store, runtimeClient: runtimeClient)
    }

    var statusBadgeTitle: String {
        // Exact Milestone 2 §14.2 labels. "Generating" takes precedence over the
        // readiness-derived label while a generation is in flight.
        if runtimeServiceState == .generating { return "Generating" }
        return switch runtimeReadinessState {
        case .unavailable:
            "Runtime Failed"
        case .limited:
            "Limited Mode"
        case .chatReady, .embeddingsReady, .fullyReady:
            "Runtime Ready"
        case .degraded:
            "Local"
        }
    }

    /// Loads persisted state and refreshes runtime status on launch.
    func bootstrap() async {
        // Reconcile any validation run abandoned by a previous quit/crash so it
        // surfaces as cancelled rather than lingering as in-progress.
        try? store.validation.markUnfinishedRunsCancelled()
        modelLibrary.refresh()
        chatController.loadChats()
        await refreshRuntimeStatus()
        // If the runtime already holds a model from a previous session, re-enable
        // chat without forcing the user to re-load it (the chat gate keys on
        // ModelLibrary.loadState, which otherwise starts idle each launch).
        modelLibrary.reconcileLoadedModel(runtimeStatusController.loadedModelID)
        await documentSetupController.refreshAll()
        // Reconcile any document job interrupted by a previous quit (plan §5.4).
        documentQueue.bootstrap()
        // Auto-purge documents soft-deleted past the retention window (plan §12.2).
        DocumentMaintenance(store: store).purgeExpired()
    }

    func refreshRuntimeStatus() async {
        await runtimeStatusController.refresh()
        runtimeReadinessState = runtimeStatusController.readinessState
        runtimeServiceState = runtimeStatusController.serviceState
        runtimeStatusMessage = runtimeStatusController.statusMessage
        activeModelName = modelLibrary.activeModel?.displayName
    }

    /// Opens the on-disk store, falling back to a temporary store so the app
    /// still launches if the Application Support database cannot be created.
    private static func makeStore() -> SupraStore {
        if let store = try? SupraStore.openAppSupportStore() {
            return store
        }
        let fallbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraAI-fallback.sqlite")
        // The temporary store is a last resort; if it also fails the app cannot persist anything.
        return (try? SupraStore(url: fallbackURL)) ?? unavailableStore()
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
