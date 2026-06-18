import SupraCore
import SwiftUI

/// Runtime status for the local model service.
struct DiagnosticsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        List {
            Section("Runtime") {
                LabeledContent("State", value: environment.runtimeServiceState.rawValue)
                Text(environment.runtimeStatusMessage)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
