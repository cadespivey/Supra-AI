import Combine
import SupraCore
import SupraRuntimeInterface

@MainActor
final class AppEnvironment: ObservableObject {
    @Published var runtimeReadinessState: RuntimeReadinessState = .limited
    @Published var runtimeServiceState: RuntimeServiceState = .disconnected
    @Published var runtimeStatusMessage = "Checking runtime"
    @Published var activeModelName: String?

    private let runtimeStatusController: RuntimeStatusController

    init(runtimeStatusController: RuntimeStatusController = RuntimeStatusController()) {
        self.runtimeStatusController = runtimeStatusController
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

    func refreshRuntimeStatus() async {
        await runtimeStatusController.refresh()
        runtimeReadinessState = runtimeStatusController.readinessState
        runtimeServiceState = runtimeStatusController.serviceState
        runtimeStatusMessage = runtimeStatusController.statusMessage
        activeModelName = runtimeStatusController.loadedModelID?.rawValue.uuidString
    }
}
