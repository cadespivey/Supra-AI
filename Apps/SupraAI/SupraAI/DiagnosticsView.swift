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

            Section {
                if history.runs.isEmpty {
                    Text("No validation runs yet. Run the suite from the Models tab.")
                        .foregroundStyle(.secondary)
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
