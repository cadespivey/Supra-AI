import SupraCore
import SupraSessions
import SwiftUI

/// The matter's Outputs tab: lists structured outputs and creates new ones
/// (spec §13).
struct MatterOutputsView: View {
    @ObservedObject var controller: StructuredOutputController
    let matter: MatterSummary
    let loadedModelID: ModelID?

    @State private var showNew = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Structured Outputs").font(.headline)
                        Text("Reusable legal work product the local model drafts from this matter — issue spotting, rule synthesis, and drafting skeletons. Document Q&A and chronologies are created from the Documents tab.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button { showNew = true } label: { Label("New Output", systemImage: "plus") }
                }
                .padding()
                Divider()
                content
            }
            .navigationDestination(for: String.self) { id in
                OutputDetailView(controller: controller, outputID: id, loadedModelID: loadedModelID)
            }
        }
        .sheet(isPresented: $showNew) {
            NewOutputSheet(controller: controller, matter: matter, loadedModelID: loadedModelID)
        }
        .onAppear { controller.loadOutputs() }
    }

    @ViewBuilder
    private var content: some View {
        if controller.outputs.isEmpty {
            ContentUnavailableView {
                Label("No Outputs", systemImage: "doc.text")
            } description: {
                Text("Generate reusable legal outputs — issue spotting, rule synthesis, or drafting skeletons — that the local model drafts from the context you provide. (Document Q&A and chronologies are created from the Documents tab.)")
            } actions: {
                Button("New Output") { showNew = true }
            }
        } else {
            List(controller.outputs) { output in
                NavigationLink(value: output.id) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(output.title).font(.body.weight(.medium))
                            Spacer()
                            Text(output.status).font(.caption2).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Text(StructuredOutputLabels.label(output.outputType))
                            Text(output.updatedAt, format: .dateTime.month().day())
                            if output.missingCount > 0 {
                                Text("\(output.missingCount) missing").foregroundStyle(.orange)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

enum StructuredOutputLabels {
    static func label(_ rawType: String) -> String {
        rawType.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct NewOutputSheet: View {
    @ObservedObject var controller: StructuredOutputController
    let matter: MatterSummary
    let loadedModelID: ModelID?

    @Environment(\.dismiss) private var dismiss
    @State private var type: StructuredOutputType = .legalIssueSpotting
    @State private var context = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("New Structured Output").font(.title2.weight(.semibold)).padding([.horizontal, .top])
            Text("Pick a deliverable type and give the model the issue, facts, or notes to work from. It produces a structured, reviewable draft saved to this matter's Outputs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
                .padding(.top, 2)
            Form {
                Picker("Type", selection: $type) {
                    // Document Q&A / chronology outputs are generated from the
                    // Documents tab, so they are excluded from this research sheet.
                    ForEach(StructuredOutputType.allCases.filter { !$0.isDocumentOutput }, id: \.self) { type in
                        Text(StructuredOutputLabels.label(type.rawValue)).tag(type)
                    }
                }
                Section {
                    TextField("Issue, facts, or notes for this output", text: $context, axis: .vertical)
                        .lineLimit(4...10)
                } header: {
                    Text("Context")
                } footer: {
                    Text("Free text the model reasons over. Grounding an output in specific documents is coming soon — for now, paste the relevant facts here.")
                }
                if loadedModelID == nil {
                    Text("Load a model in the Models tab to generate.").font(.caption).foregroundStyle(.secondary)
                }
                if let message = controller.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                if controller.isGenerating { ProgressView().controlSize(.small) }
                Button("Generate") { Task { await generate() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(loadedModelID == nil || controller.isGenerating)
            }
            .padding()
        }
        .frame(width: 520, height: 520)
    }

    private func generate() async {
        let prefix = """
        Matter: \(matter.name)
        Jurisdiction: \(matter.jurisdiction)
        Party perspective: \(matter.partyPerspective.rawValue)

        """
        let ok = await controller.createOutput(type: type, context: prefix + context, modelID: loadedModelID)
        if ok { dismiss() }
    }
}
