import AppKit
import SupraCore
import SupraDesignSystem
import SupraSessions
import SwiftUI

/// A presentation-only request to carry one exact Saved Work identity to Notes
/// & Time. The legal content is deliberately absent: the receiving surface may
/// insert the reference after another explicit action, but it cannot silently
/// turn the work product into a billing narrative.
struct SavedWorkNotesHandoff: Identifiable, Equatable {
    let id: String
    let matterID: String
    let matterName: String
    let outputID: String
    let outputTitle: String
    let versionID: String
    let versionIndex: Int
    let contentMarkdown: String?
}

/// Structured output detail (spec §13.3): version picker, Markdown preview with a
/// raw toggle, missing-section list, linked research session, and the Repair
/// Structure action when sections are missing.
struct OutputDetailView: View {
    @ObservedObject var controller: StructuredOutputController
    @ObservedObject var library: ModelLibrary
    let outputID: String
    let matterID: String
    let matterName: String
    let onOpenDocuments: () -> Void
    let onOpenNotesAndTime: (SavedWorkNotesHandoff) -> Void
    let onOpenBilling: () -> Void

    @State private var selectedVersionID: String?
    @State private var showRaw = false
    @State private var routingMessage: String?
    @State private var sourcePreview: PreviewItem?
    @State private var pendingExportFormat: DocumentExportFormat?

    private var router: ModelRouter { ModelRouter(configuration: .fromEnvironment()) }

    private var outputType: StructuredOutputType? {
        controller.outputs
            .first { $0.id == outputID }
            .flatMap { StructuredOutputType(rawValue: $0.outputType) }
    }

    private var outputTitle: String {
        controller.outputs.first { $0.id == outputID }?.title ?? "Output"
    }

    private var repairRoute: ModelRoute? {
        outputType.flatMap { router.repairRoute(forStructuredOutput: $0) }
    }

    private var repairModel: ModelSummary? {
        guard let repairRoute else { return nil }
        return library.resolvedModel(for: repairRoute.role, configuration: router.configuration)
    }

    var body: some View {
        let versions = controller.versions(forOutput: outputID)
        let selected = versions.first { $0.id == selectedVersionID }
            ?? versions.first { $0.isActive }
            ?? versions.last

        VStack(alignment: .leading, spacing: 0) {
            controlBar(versions: versions, selected: selected)
            Divider()
            if let message = controller.message {
                Text(message)
                    .font(.supraCaption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }
            if let failure = controller.lastMutationFailure,
               pendingExportFormat != nil {
                UserMutationFailureBanner(
                    failure: failure,
                    retry: retryExport,
                    correct: correctExport
                )
                .padding(.horizontal)
                .padding(.top, 6)
                .accessibilityIdentifier("output.mutationFailure")
            }
            if let selected {
                verificationBar(selected)
                ScrollView {
                    Group {
                        if showRaw {
                            Text(selected.markdown)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            // Rendered work product is a long-form reading surface —
                            // body text with reading leading and a capped measure. (Raw
                            // markdown above stays monospaced.)
                            SupraMarkdownView(
                                text: selected.markdown,
                                presentation: .savedOutput
                            )
                                .supraReadingBody()
                        }
                    }
                    .padding()
                }
                if !selected.missingSections.isEmpty {
                    missingBar(selected)
                }
                let groundingSources = controller.sources(forVersion: selected.id)
                if !groundingSources.isEmpty {
                    sourcesBar(groundingSources)
                }
            } else {
                ContentUnavailableView("No content yet", systemImage: "doc")
            }
        }
        .navigationTitle(outputTitle)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("output.detail.\(outputTitle)")
        .onAppear { controller.loadOutputs() }
        .sheet(item: $sourcePreview) { item in
            DocumentPreviewView(model: item.model) { sourcePreview = nil }
        }
    }

    @ViewBuilder
    private func controlBar(versions: [StructuredOutputController.VersionItem],
                            selected: StructuredOutputController.VersionItem?) -> some View {
        HStack(spacing: 12) {
            if versions.count > 1 {
                Picker("Version", selection: Binding(
                    get: { selected?.id ?? versions.last?.id ?? "" },
                    set: { selectedVersionID = $0 }
                )) {
                    ForEach(versions) { version in
                        Text("v\(version.index)\(version.isActive ? " (active)" : "")").tag(version.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 160)
            }
            Toggle("Raw", isOn: $showRaw).toggleStyle(.button)
            if let sessionID = controller.outputs.first(where: { $0.id == outputID })?.researchSessionID, !sessionID.isEmpty {
                Label("Linked to research session", systemImage: "link")
                    .font(.supraCaption).foregroundStyle(.secondary)
            }
            Spacer()
            if let selected {
                Menu {
                    Button("Open Notes & Time") {
                        onOpenNotesAndTime(
                            SavedWorkNotesHandoff(
                                id: "\(outputID)@\(selected.id)",
                                matterID: matterID,
                                matterName: matterName,
                                outputID: outputID,
                                outputTitle: outputTitle,
                                versionID: selected.id,
                                versionIndex: selected.index,
                                contentMarkdown: nil
                            )
                        )
                    }
                    .accessibilityIdentifier("output.openNotesAndTime")
                    Button("Open Billing Rules") {
                        onOpenBilling()
                    }
                    .accessibilityIdentifier("output.openBillingRules")
                } label: {
                    Label("Related Work", systemImage: "arrow.triangle.branch")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("output.relatedWork")
                .help("Open this matter's separate Notes & Time or Billing Rules workflow")
            }
            if let selected,
               selected.verificationStatus == OutputVerificationStatus.allSupported.rawValue,
               OutputAssurancePresentation.isExportEligible(selected.assuranceState) {
                Menu {
                    Section("Format") {
                        ForEach(DocumentExportFormat.allCases, id: \.self) { format in
                            Button(format.fileExtension.uppercased()) {
                                performExport(format: format)
                            }
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("output.export")
                .accessibilityLabel("Export output, available")
                .accessibilityHint("Choose an export format")
                .help("Export output with its assurance state and source appendix")
            } else {
                Button(action: {}) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .disabled(true)
                .accessibilityIdentifier("output.export")
                .accessibilityLabel("Export output unavailable until the output is reverified or regenerated")
                .accessibilityHint("Reverify retained sources or regenerate from fresh sources to enable export")
                .help("Reverify or regenerate before export")
            }
            let activeMissing = versions.first { $0.isActive }?.missingSections ?? []
            if !activeMissing.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Button("Repair Structure") { Task { await repairStructure() } }
                        .disabled(repairModel == nil || controller.isGenerating)
                    repairRouteStatus
                }
                if controller.isGenerating { ProgressView().controlSize(.small) }
            }
        }
        .padding()
    }

    @ViewBuilder
    private func verificationBar(_ version: StructuredOutputController.VersionItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AssuranceBadge(state: version.assuranceState)
                .accessibilityIdentifier("output.assurance.\(version.assuranceState.rawValue)")
            if version.assuranceState == .stale {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("A dependency changed")
                            .font(.supraHeadline)
                        Text(version.staleReason ?? "A retained source or processing dependency changed. Regenerate or recheck against the current matter sources.")
                            .font(.supraCaption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open Documents") {
                        onOpenDocuments()
                    }
                    .fixedSize()
                    .accessibilityIdentifier("output.stale.openDocuments")
                    .accessibilityHint("Review the changed matter source and rebuild readiness before creating a new verified version")
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("output.staleWarning")
                .accessibilityLabel(
                    "Stale dependency. \(version.staleReason ?? "A retained source or processing dependency changed.")"
                )
            } else if version.verificationStatus != OutputVerificationStatus.allSupported.rawValue {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(version.verificationStatus == OutputVerificationStatus.legacyUnverified.rawValue
                            ? "Previous output needs revalidation"
                            : "Output support needs review")
                            .font(.supraHeadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(version.verificationStatus == OutputVerificationStatus.legacyUnverified.rawValue
                            ? "This version predates proposition verification. Reverify its retained sources or regenerate from fresh sources before relying on or exporting it."
                            : "One or more propositions are unsupported or unverifiable. Export remains unavailable until a supported replacement is active.")
                            .font(.supraCaption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    if version.verificationStatus == OutputVerificationStatus.legacyUnverified.rawValue {
                        Button("Reverify Sources") {
                            _ = controller.reverifyOutput(outputID)
                        }
                        .fixedSize()
                        .layoutPriority(1)
                        .accessibilityHint("Checks this version against its retained source packet without deleting the original")
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("output.verificationWarning")
                .accessibilityLabel(
                    version.verificationStatus == OutputVerificationStatus.legacyUnverified.rawValue
                        ? "Output verification status. Previous output needs revalidation. This version predates proposition verification. Reverify its retained sources or regenerate from fresh sources before relying on or exporting it."
                        : "Output verification status. Output support needs review. One or more propositions are unsupported or unverifiable. Export remains unavailable until a supported replacement is active."
                )
                .accessibilityValue(
                    version.verificationStatus == OutputVerificationStatus.legacyUnverified.rawValue
                        ? "Previous output needs revalidation. This version predates proposition verification. Reverify its retained sources or regenerate from fresh sources before relying on or exporting it."
                        : "Output support needs review. One or more propositions are unsupported or unverifiable. Export remains unavailable until a supported replacement is active."
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var repairRouteStatus: some View {
        if let repairRoute {
            if let repairModel {
                Text("\(repairRoute.role.shortDisplayName): \(repairModel.displayName)")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Assign \(repairRoute.role.displayName) model")
                    .font(.supraCaption)
                    .foregroundStyle(.orange)
            }
        }
        if let routingMessage {
            Text(routingMessage)
                .font(.supraCaption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    private func repairStructure() async {
        routingMessage = nil
        guard let repairRoute else { return }
        let modelID: ModelID
        switch await library.ensureLoadedRoutedModelID(for: repairRoute.role, configuration: router.configuration) {
        case let .success(loaded):
            modelID = loaded
        case let .failure(issue):
            routingMessage = issue.message
            return
        }
        _ = await controller.repairOutput(outputID, modelID: modelID, route: repairRoute)
    }

    private func performExport(format: DocumentExportFormat) {
        pendingExportFormat = format
        let outcome = controller.attemptExportOutput(
            outputID: outputID,
            format: format
        )
        guard outcome.allowsSuccessPresentation,
              let url = outcome.committedValue else { return }
        pendingExportFormat = nil
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func retryExport() {
        guard let pendingExportFormat else { return }
        performExport(format: pendingExportFormat)
    }

    private func correctExport() {
        _ = controller.reverifyOutput(outputID)
    }

    private func missingBar(_ version: StructuredOutputController.VersionItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Missing sections (\(version.missingSections.count))")
                .font(.supraHeadline).foregroundStyle(.orange)
            Text(version.missingSections.joined(separator: ", "))
                .font(.supraCaption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func sourcesBar(_ sources: [StructuredOutputController.SourceItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Grounded in \(sources.count) document source\(sources.count == 1 ? "" : "s")", systemImage: "doc.text.magnifyingglass")
                .font(.supraHeadline).foregroundStyle(.secondary)
            ForEach(sources) { source in
                Button {
                    if let model = controller.previewSource(id: source.id) {
                        sourcePreview = PreviewItem(model: model)
                    }
                } label: {
                    Text("[\(source.label)] \(source.documentName)\(source.locatorDisplay.isEmpty ? "" : " — \(source.locatorDisplay)")")
                        .font(.supraCaption).foregroundStyle(.secondary).lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("output.source.\(source.label)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// Compact assurance row shared by Outputs, grounded chat, and chronology.
/// The label is the exact domain-pinned string; color and icon never substitute
/// a second, potentially conflicting state description.
struct AssuranceBadge: View {
    let state: OutputAssuranceState

    var body: some View {
        Label(OutputAssurancePresentation.text(for: state), systemImage: icon)
            .font(.supraCaption.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityLabel(OutputAssurancePresentation.text(for: state))
    }

    private var color: Color {
        switch state {
        case .propositionSupported, .corpusComplete:
            .green
        case .preliminary:
            .secondary
        case .supportNeedsReview, .corpusIncomplete, .negativeBlocked, .stale:
            .orange
        }
    }

    private var icon: String {
        switch state {
        case .preliminary: "hare"
        case .supportNeedsReview: "exclamationmark.triangle"
        case .propositionSupported: "checkmark.seal"
        case .corpusIncomplete: "square.dashed"
        case .corpusComplete: "checkmark.shield"
        case .negativeBlocked: "nosign"
        case .stale: "clock.arrow.circlepath"
        }
    }
}
