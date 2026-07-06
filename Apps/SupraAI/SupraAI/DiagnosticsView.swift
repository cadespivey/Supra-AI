import SupraCore
import SupraRuntimeInterface
import SupraStore
import SwiftUI

/// Runtime status for the local model service. Refreshes automatically every 10
/// seconds while the tab is open — no manual refresh needed.
struct DiagnosticsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// Recent model-load / generation timings (category `performance`), so pre-warming
    /// wins are visible: a warmed model shows its load time up front, and the first
    /// message's first-token latency no longer includes a multi-second load.
    @State private var timings: [DiagnosticEventRecord] = []

    var body: some View {
        List {
            Section {
                LabeledContent("State", value: environment.runtimeServiceState.displayName)
                LabeledContent("Message") {
                    Text(environment.runtimeStatusMessage)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent(
                    "Loaded model",
                    value: environment.modelLibrary.loadedModel?.displayName ?? "None"
                )
                LabeledContent(
                    "Registered models",
                    value: "\(environment.modelLibrary.models.count)"
                )
            } header: {
                Text("Runtime").font(.supraHeadline).textCase(nil).foregroundStyle(.primary)
            }

            if !timings.isEmpty {
                Section {
                    ForEach(timings, id: \.id) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.message)
                            Text(event.timestamp, format: .dateTime.hour().minute().second())
                                .font(.supraCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Recent Timings").font(.supraHeadline).textCase(nil).foregroundStyle(.primary)
                } footer: {
                    Text("Model loads and generation latency. Pre-warming moves the load out of your first request.")
                }
            }

            Section {
                Text(nextStep)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Next Step").font(.supraHeadline).textCase(nil).foregroundStyle(.primary)
            }
        }
        // Refresh on appear, then poll every 10 seconds while visible; the task is
        // cancelled automatically when the tab goes away.
        .task {
            while !Task.isCancelled {
                await environment.refreshRuntimeStatus()
                refreshTimings()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func refreshTimings() {
        let recent = (try? environment.store.diagnostics.fetchRecentDiagnostics(limit: 100)) ?? []
        timings = recent.filter { $0.category == "performance" }.prefix(8).map { $0 }
    }

    private var nextStep: String {
        switch environment.runtimeServiceState {
        case .modelUnloaded, .connected:
            "Load or assign a model from the Models tab before running model-backed tasks."
        case .disconnected:
            "The runtime service is unavailable; relaunch the app if it does not reconnect."
        case .failed:
            "Review the runtime message above and correct the issue — status updates automatically."
        default:
            "No action needed."
        }
    }
}

private extension RuntimeServiceState {
    var displayName: String {
        switch self {
        case .disconnected: "Disconnected"
        case .starting: "Starting"
        case .connected: "Connected"
        case .modelUnloaded: "Model unloaded"
        case .modelLoading: "Model loading"
        case .modelLoaded: "Model loaded"
        case .generating: "Generating"
        case .cancelling: "Cancelling"
        case .failed: "Failed"
        case .restarting: "Restarting"
        }
    }
}
