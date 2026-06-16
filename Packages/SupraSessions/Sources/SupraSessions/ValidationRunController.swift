import Combine
import Foundation
import SupraCore
import SupraDiagnostics
import SupraRuntimeClient
import SupraStore

/// Main-actor wrapper around `ValidationRunner` for the UI: runs the bundled
/// Milestone 1 suite against the active model and publishes progress + result.
@MainActor
public final class ValidationRunController: ObservableObject {
    public enum State: Sendable {
        case idle
        case running
        case finished(ValidationRunResult)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle

    private let runner: ValidationRunner

    public init(store: SupraStore, runtimeClient: any RuntimeClientProtocol, appVersion: AppVersion = .unknown) {
        self.runner = ValidationRunner(runtimeClient: runtimeClient, store: store, appVersion: appVersion)
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Clears any finished/failed result, e.g. when a different model is loaded.
    public func reset() {
        guard !isRunning else { return }
        state = .idle
    }

    /// Runs the bundled Milestone 1 suite against the given loaded model.
    public func runMilestone1(modelID: ModelID, modelName: String, modelPath: String?) {
        guard !isRunning else { return }
        state = .running
        Task {
            do {
                let suite = try BundledValidationSuite.milestone1()
                let result = try await runner.run(
                    suite: suite,
                    modelID: modelID,
                    modelName: modelName,
                    modelPath: modelPath
                )
                state = .finished(result)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
