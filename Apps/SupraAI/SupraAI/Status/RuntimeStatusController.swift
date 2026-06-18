import Combine
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface

@MainActor
final class RuntimeStatusController: ObservableObject {
    @Published private(set) var serviceState: RuntimeServiceState = .disconnected
    @Published private(set) var loadedModelID: ModelID?
    @Published private(set) var statusMessage = "Checking runtime"

    private let runtimeClient: any RuntimeClientProtocol

    init(runtimeClient: any RuntimeClientProtocol = RuntimeClient()) {
        self.runtimeClient = runtimeClient
    }

    func refresh() async {
        do {
            let status = try await runtimeClient.runtimeStatus()
            apply(status)
        } catch {
            serviceState = .disconnected
            loadedModelID = nil
            statusMessage = error.localizedDescription
        }
    }

    private func apply(_ status: RuntimeStatus) {
        serviceState = status.state
        loadedModelID = status.loadedModelID
        statusMessage = status.message ?? status.state.rawValue
    }
}
