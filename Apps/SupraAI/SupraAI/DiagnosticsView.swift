import SupraCore
import SupraRuntimeInterface
import SupraSessions
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
    @State private var networkCleanupMessage: String?
    @State private var capabilityReport: CapabilityReport?
    @State private var runningCapabilityProbe = false
    @State private var capabilityProbeMessage: String?
    @State private var typedGenerationEnabled = false
    @State private var coverageReport: CoverageRoutingReport?
    @State private var runningCoverageProbe = false
    @State private var shadowLoggingEnabled = false

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
                HStack {
                    Text("Active version")
                    Spacer()
                    Text("v\(environment.documentChunkerVersion)")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("v\(environment.documentChunkerVersion)")
                        .accessibilityIdentifier("diagnostics.chunker.version")
                }

                if environment.isChangingDocumentChunker {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(environment.documentChunkerStatusMessage)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(environment.documentChunkerStatusMessage)
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    let target = environment.documentChunkerVersion == 2 ? 1 : 2
                    Task { await environment.switchDocumentChunker(to: target) }
                } label: {
                    HStack {
                        Text(chunkerSwitchTitle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(environment.isChangingDocumentChunker)
                .accessibilityIdentifier("diagnostics.chunker.switch")
            } header: {
                Text("Document Chunker").font(.supraHeadline).textCase(nil).foregroundStyle(.primary)
            } footer: {
                Text("Chunker v2 is the approved default. The v1 rollback rebuilds chunks only; persisted revisions and historical citation display remain intact.")
            }

            Section {
                Button("Remove Stored Query Fingerprints") {
                    do {
                        let count = try environment.store.networkRequests.removeStoredQueryMetadata()
                        networkCleanupMessage = count == 1
                            ? "Removed query metadata from 1 network audit record."
                            : "Removed query metadata from \(count) network audit records."
                    } catch {
                        networkCleanupMessage = "Query metadata could not be removed."
                    }
                }
                if let networkCleanupMessage {
                    Text(networkCleanupMessage)
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(networkCleanupMessage)
                }
            } header: {
                Text("Network Privacy").font(.supraHeadline).textCase(nil).foregroundStyle(.primary)
            } footer: {
                Text("New query values use installation-scoped pseudonyms. This removes all stored query markers, including legacy fingerprints, while retaining other audit metadata where possible.")
            }

            Section {
                if let report = capabilityReport {
                    LabeledContent("Generated", value: "\(report.generated)/\(report.total) cases")
                    LabeledContent("Success rate", value: Self.percent(report.successRate))
                    LabeledContent("First-attempt rate", value: Self.percent(report.firstAttemptRate))
                    LabeledContent("Fallback rate", value: Self.percent(report.fallbackRate))
                    LabeledContent("Avg attempts", value: String(format: "%.2f", report.avgAttempts))
                    LabeledContent("Refusal accuracy", value: Self.percent(report.refusalAccuracy))
                }
                if runningCapabilityProbe {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Running probe…").foregroundStyle(.secondary)
                    }
                } else {
                    Button("Run Reasoning Capability Probe") {
                        Task {
                            runningCapabilityProbe = true
                            capabilityProbeMessage = nil
                            let report = await environment.runReasoningCapabilityProbe()
                            capabilityReport = report
                            if report == nil {
                                capabilityProbeMessage = "Load a model in the Models tab first."
                            }
                            runningCapabilityProbe = false
                        }
                    }
                    .disabled(environment.modelLibrary.loadedModelID == nil
                        || environment.runtimeServiceState == .generating)
                    .accessibilityIdentifier("diagnostics.capability.run")
                }
                if let capabilityProbeMessage {
                    Text(capabilityProbeMessage).font(.supraCaption).foregroundStyle(.secondary)
                }
                Toggle("Use typed generation for document Q&A (experimental)", isOn: $typedGenerationEnabled)
                    .accessibilityIdentifier("diagnostics.typedGeneration.toggle")
                    .onChange(of: typedGenerationEnabled) { _, enabled in
                        try? environment.store.appSettings.setSetting(
                            GlobalChatController.typedGroundedGenerationKey, value: enabled
                        )
                    }
            } header: {
                Text("Reasoning Capability").font(.supraHeadline).textCase(nil).foregroundStyle(.primary)
            } footer: {
                Text("Measures how reliably the loaded model emits the typed AnswerDraft schema over synthetic grounded fixtures — the Phase 1 typed-generation go/no-go. Synthetic text only; runs several generations, so it takes a moment. When the toggle is on, a matter's document Q&A is answered by typed generation (validated exactly), falling back to the prose path if the model can't hold the schema.")
            }

            Section {
                if let report = coverageReport {
                    LabeledContent("Questions scanned", value: "\(report.questionsScanned)")
                    LabeledContent("Matters", value: "\(report.matterCount)")
                    LabeledContent("Would-ground (keyword miss)", value: Self.percent(report.wouldGroundRate))
                    LabeledContent("Would-skip (over-ground)", value: Self.percent(report.wouldSkipRate))
                    LabeledContent("Agreement", value: Self.percent(report.agreementRate))
                    LabeledContent("Coverage retrieval", value: report.usedSemantic ? "Semantic" : "Keyword-only")
                }
                if runningCoverageProbe {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Running probe…").foregroundStyle(.secondary)
                    }
                } else {
                    Button("Run Coverage Routing Probe") {
                        Task {
                            runningCoverageProbe = true
                            coverageReport = await environment.runCoverageRoutingShadowProbe()
                            runningCoverageProbe = false
                        }
                    }
                    .accessibilityIdentifier("diagnostics.coverageRouting.run")
                }
                Toggle("Log coverage-routing shadow during matter chat", isOn: $shadowLoggingEnabled)
                    .accessibilityIdentifier("diagnostics.coverageShadow.toggle")
                    .onChange(of: shadowLoggingEnabled) { _, enabled in
                        try? environment.store.appSettings.setSetting(
                            CoverageRoutingShadow.shadowEnabledKey, value: enabled
                        )
                    }
            } header: {
                Text("Coverage Routing Shadow").font(.supraHeadline).textCase(nil).foregroundStyle(.primary)
            } footer: {
                Text("Replays this matter set's real chat questions through the keyword router and the corpus-coverage signal, tallying where they diverge — the Phase 2 go/no-go for making coverage the primary router. “Would-ground” is the share of questions the keyword router skipped that the corpus actually covers; “would-skip” is keyword over-grounding. Reads only; runs a retrieval per question. The toggle logs the same comparison live during matter chat (metadata only).")
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
            typedGenerationEnabled = (try? environment.store.appSettings.getSetting(
                GlobalChatController.typedGroundedGenerationKey, as: Bool.self
            )) ?? false
            shadowLoggingEnabled = (try? environment.store.appSettings.getSetting(
                CoverageRoutingShadow.shadowEnabledKey, as: Bool.self
            )) ?? false
            while !Task.isCancelled {
                await environment.refreshRuntimeStatus()
                refreshTimings()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func refreshTimings() {
        let recent = (try? environment.store.diagnostics.fetchRecentDiagnostics(limit: 100)) ?? []
        timings = recent.filter { $0.category == "performance" }.prefix(8).map { $0 }
    }

    private var chunkerSwitchTitle: String {
        environment.documentChunkerVersion == 2
            ? "Rebuild with Chunker v1"
            : "Restore Chunker v2"
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
