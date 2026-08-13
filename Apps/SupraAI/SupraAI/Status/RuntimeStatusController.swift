import Combine
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface

@MainActor
final class RuntimeStatusController: ObservableObject {
    @Published private(set) var serviceState: RuntimeServiceState = .disconnected
    @Published private(set) var loadedModelID: ModelID?
    @Published private(set) var statusMessage = "Checking runtime"
    @Published private(set) var recoverySnapshot: RuntimeRecoverySnapshot = .available

    private let runtimeClient: RuntimeSafetyClient

    init(runtimeClient: RuntimeSafetyClient) {
        self.runtimeClient = runtimeClient
    }

    func refresh() async {
        recoverySnapshot = runtimeClient.currentRecoverySnapshot()
        do {
            let status = try await runtimeClient.runtimeStatus()
            apply(status)
        } catch {
            serviceState = .disconnected
            loadedModelID = nil
            statusMessage = error.localizedDescription
        }
    }

    func recoverRuntime() async {
        recoverySnapshot = RuntimeRecoverySnapshot(
            phase: .recovering,
            message: recoverySnapshot.message
        )
        do {
            try await runtimeClient.recoverRuntime()
            await refresh()
        } catch {
            recoverySnapshot = runtimeClient.currentRecoverySnapshot()
            statusMessage = error.localizedDescription
        }
    }

    private func apply(_ status: RuntimeStatus) {
        serviceState = status.state
        loadedModelID = status.loadedModelID
        statusMessage = status.message ?? status.state.rawValue
    }
}
