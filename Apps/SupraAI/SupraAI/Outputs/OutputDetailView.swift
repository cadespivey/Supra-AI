import AppKit
import SupraCore
import SupraSessions
import SwiftUI

/// Structured output detail (spec §13.3): version picker, Markdown preview with a
/// raw toggle, missing-section list, linked research session, and the Repair
/// Structure action when sections are missing.
struct OutputDetailView: View {
    @ObservedObject var controller: StructuredOutputController
    @ObservedObject var library: ModelLibrary
    let outputID: String

    @State private var selectedVersionID: String?
    @State private var showRaw = false
    @State private var routingMessage: String?

    private var router: ModelRouter { ModelRouter(configuration: .fromEnvironment()) }

    private var outputType: StructuredOutputType? {
        controller.outputs
            .first { $0.id == outputID }
            .flatMap { StructuredOutputType(rawValue: $0.outputType) }
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
                            MarkdownPreview(markdown: selected.markdown)
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
        .navigationTitle(controller.outputs.first { $0.id == outputID }?.title ?? "Output")
        .onAppear { controller.loadOutputs() }
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
            if selected?.verificationStatus == OutputVerificationStatus.allSupported.rawValue {
                Menu {
                    Section("Format") {
                        ForEach(DocumentExportFormat.allCases, id: \.self) { format in
                            Button(format.fileExtension.uppercased()) {
                                if let url = controller.exportOutput(outputID: outputID, format: format) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
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
                .help("Export verified output")
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
        if version.verificationStatus != OutputVerificationStatus.allSupported.rawValue {
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
                .accessibilityElement(children: .ignore)
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
        }
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
                Text("[\(source.label)] \(source.documentName)\(source.locatorDisplay.isEmpty ? "" : " — \(source.locatorDisplay)")")
                    .font(.supraCaption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// Lightweight block-level Markdown preview: heading lines are styled by level,
/// everything else renders with inline Markdown.
struct MarkdownPreview: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lines: [String] {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") {
            Text(trimmed.dropFirst(4)).font(.subheadline.weight(.semibold))
        } else if trimmed.hasPrefix("## ") {
            Text(trimmed.dropFirst(3)).font(.headline)
        } else if trimmed.hasPrefix("# ") {
            Text(trimmed.dropFirst(2)).font(.title3.weight(.bold))
        } else if trimmed.isEmpty {
            Color.clear.frame(height: 2)
        } else {
            // Parse inline Markdown explicitly rather than via LocalizedStringKey,
            // which would treat model output as a localization key / format string
            // (so a stray "%@" or key-like line could be mis-rendered).
            Text(Self.inlineMarkdown(line)).font(.callout).textSelection(.enabled)
        }
    }

    private static func inlineMarkdown(_ line: String) -> AttributedString {
        (try? AttributedString(
            markdown: line,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(line)
    }
}
