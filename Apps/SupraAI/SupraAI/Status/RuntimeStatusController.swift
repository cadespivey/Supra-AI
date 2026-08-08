import Combine
import SupraCore
import SupraRuntimeClient
import SupraRuntimeInterface

@MainActor
final class RuntimeStatusController: ObservableObject {
    @Published private(set) var serviceState: RuntimeServiceState = .disconnected
    @Published private(set) var loadedModelID: ModelID?
    @Published private(set) var statusMessage = "Checking runtime"
    @Published private(set) var admissionSnapshot: RuntimeAdmissionSnapshot = .available

    private let runtimeClient: any RuntimeClientProtocol
    private var admissionObservationTask: Task<Void, Never>?

    init(runtimeClient: any RuntimeClientProtocol) {
        self.runtimeClient = runtimeClient
        guard let exclusiveClient = runtimeClient as? ExclusiveRuntimeClient else { return }
        admissionObservationTask = Task { [weak self] in
            for await snapshot in exclusiveClient.admissionSnapshots() {
                guard !Task.isCancelled else { return }
                self?.admissionSnapshot = snapshot
            }
        }
    }

    deinit {
        admissionObservationTask?.cancel()
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
