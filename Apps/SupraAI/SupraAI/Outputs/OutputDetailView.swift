import AppKit
import SupraCore
import SupraSessions
import SwiftUI

/// Structured output detail (spec §13.3): version picker, Markdown preview with a
/// raw toggle, missing-section list, linked research session, and the Repair
/// Structure action when sections are missing.
struct OutputDetailView: View {
    @ObservedObject var controller: StructuredOutputController
    let outputID: String
    let loadedModelID: ModelID?

    @State private var selectedVersionID: String?
    @State private var showRaw = false

    var body: some View {
        let versions = controller.versions(forOutput: outputID)
        let selected = versions.first { $0.id == selectedVersionID }
            ?? versions.first { $0.isActive }
            ?? versions.last

        VStack(alignment: .leading, spacing: 0) {
            controlBar(versions: versions, selected: selected)
            Divider()
            if let selected {
                ScrollView {
                    Group {
                        if showRaw {
                            Text(selected.markdown)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            MarkdownPreview(markdown: selected.markdown)
                        }
                    }
                    .padding()
                }
                if !selected.missingSections.isEmpty {
                    missingBar(selected)
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
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(DocumentExportFormat.allCases, id: \.self) { format in
                    Button(format.fileExtension.uppercased()) {
                        if let url = controller.exportOutput(outputID: outputID, format: format) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            let activeMissing = versions.first { $0.isActive }?.missingSections ?? []
            if !activeMissing.isEmpty {
                Button("Repair Structure") { Task { await controller.repairOutput(outputID, modelID: loadedModelID) } }
                    .disabled(loadedModelID == nil || controller.isGenerating)
                if controller.isGenerating { ProgressView().controlSize(.small) }
            }
        }
        .padding()
    }

    private func missingBar(_ version: StructuredOutputController.VersionItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Missing sections (\(version.missingSections.count))")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Text(version.missingSections.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
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
            Text(LocalizedStringKey(line)).font(.callout).textSelection(.enabled)
        }
    }
}
