import Combine
import Foundation
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraSessions
import SupraStore

@MainActor
final class AppEnvironment: ObservableObject {
    @Published var runtimeReadinessState: RuntimeReadinessState = .limited
    @Published var runtimeServiceState: RuntimeServiceState = .disconnected
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
        self.mattersController = MattersController(
            store: store,
            runtimeClient: runtimeClient,
            defaultSystemPrompt: systemPrompt
        )
    }

    var statusBadgeTitle: String {
        switch runtimeReadinessState {
        case .unavailable:
            "Runtime Failed"
        case .limited:
            "Limited Mode"
        case .chatReady, .embeddingsReady, .fullyReady:
            "Runtime Ready"
        case .degraded:
            "Local Mode"
        }
    }

    /// Loads persisted state and refreshes runtime status on launch.
    func bootstrap() async {
        modelLibrary.refresh()
        chatController.loadChats()
        await refreshRuntimeStatus()
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
