import SupraCore
import SupraSessions
import SwiftUI

/// Runtime status plus the history of validation runs persisted in the store.
struct DiagnosticsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var history: ValidationHistoryController
    @ObservedObject var validation: ValidationRunController

    var body: some View {
        List {
            Section("Runtime") {
                LabeledContent("State", value: environment.runtimeServiceState.rawValue)
                Text(environment.runtimeStatusMessage)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Document Intelligence Validation") {
                m3ValidationContent
            }

            Section {
                if history.runs.isEmpty {
                    ContentUnavailableView(
                        "No Diagnostics",
                        systemImage: "waveform.path.ecg",
                        description: Text("Run the Milestone 1 validation suite from the Models tab to see results here.")
                    )
                } else {
                    ForEach(history.runs) { run in
                        ValidationRunRow(run: run) { history.tests(forRun: run.id) }
                    }
                }
            } header: {
                HStack {
                    Text("Validation History")
                    Spacer()
                    Button {
                        history.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh validation history")
                }
            }
        }
        .task { history.refresh() }
        // Pick up runs that start or finish while Diagnostics is on screen.
        .onChange(of: validation.isRunning) { _, _ in
            history.refresh()
        }
        .onChange(of: environment.documentValidationController.isRunning) { _, _ in
            history.refresh()
        }
    }

    @ViewBuilder
    private var m3ValidationContent: some View {
        let controller = environment.documentValidationController
        let setupReady = environment.documentSetupController.isReadyForImport
        let loadedModelID = environment.modelLibrary.loadedModelID
        let canRun = setupReady && loadedModelID != nil && !controller.isRunning

        switch controller.state {
        case .idle:
            Text("Runs the M3 pipeline over a synthetic validation matter and saves a report below.")
                .font(.caption).foregroundStyle(.secondary)
        case let .running(scenario):
            HStack { ProgressView().controlSize(.small); Text("Running: \(scenario)…").font(.caption) }
        case let .finished(_, passed, total):
            Label("\(passed)/\(total) scenarios passed", systemImage: passed == total ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(passed == total ? .green : .orange)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
        }

        if !setupReady {
            Text("Complete Document Intelligence setup and load a chat model first.")
                .font(.caption).foregroundStyle(.orange)
        }
        Button("Run M3 Document Validation") {
            if let id = loadedModelID {
                controller.run(chatModelID: id, chatModelName: environment.modelLibrary.activeModel?.displayName ?? "Model")
            }
        }
        .disabled(!canRun)
    }
}

private struct ValidationRunRow: View {
    let run: ValidationRunSummary
    let loadTests: () -> [ValidationTestSummary]

    @State private var isExpanded = false
    @State private var tests: [ValidationTestSummary] = []

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(tests) { test in
                HStack {
                    Text(test.name)
                    Spacer()
                    Text(test.status.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color(for: test.status))
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(runStatusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(run.modelName) — \(run.suiteID) v\(run.suiteVersion)")
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Reload on every expand so a row never shows tests captured before the
        // run finished appending them.
        .onChange(of: isExpanded) { _, expandedNow in
            if expandedNow {
                tests = loadTests()
            }
        }
    }

    private var subtitle: String {
        let date = run.startedAt.formatted(date: .abbreviated, time: .shortened)
        let counts = "\(run.warningCount) warnings, \(run.errorCount) errors"
        let suffix = run.isUnfinished ? " · unfinished" : ""
        return "\(run.status.rawValue) · \(date) · \(counts)\(suffix)"
    }

    private var statusSymbol: String {
        switch run.status {
        case .passed: "checkmark.circle.fill"
        case .partial: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "slash.circle.fill"
        }
    }

    private var runStatusColor: Color {
        switch run.status {
        case .passed: .green
        case .partial: .yellow
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    private func color(for status: ValidationTestStatus) -> Color {
        switch status {
        case .passed: .green
        case .warning: .yellow
        case .failed: .red
        case .skipped, .cancelled: .secondary
        }
    }
}
