import SupraCore
import SupraRuntimeInterface
import SwiftUI

/// Runtime status for the local model service.
struct DiagnosticsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostics")
                        .font(.headline)
                    Text(runtimeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            List {
                Section("Runtime") {
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
                }

                Section("Next Step") {
                    Text(nextStep)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var runtimeSummary: String {
        switch environment.runtimeServiceState {
        case .modelLoaded, .generating:
            "Runtime is ready."
        case .modelUnloaded, .connected:
            "Runtime service is available; no model is loaded."
        case .starting, .modelLoading, .restarting:
            "Runtime is working."
        case .cancelling:
            "Generation is cancelling."
        case .disconnected:
            "Runtime service is unavailable."
        case .failed:
            "Runtime needs attention."
        }
    }

    private var nextStep: String {
        switch environment.runtimeServiceState {
        case .modelUnloaded, .connected:
            "Load or assign a model from the Models tab before running model-backed tasks."
        case .disconnected:
            "Refresh runtime status or relaunch the app if the service does not reconnect."
        case .failed:
            "Review the runtime message above, then refresh status after correcting the issue."
        default:
            "No action needed."
        }
    }

    private func refresh() {
        isRefreshing = true
        Task {
            await environment.refreshRuntimeStatus()
            isRefreshing = false
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
