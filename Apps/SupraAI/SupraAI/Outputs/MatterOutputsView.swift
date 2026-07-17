import SupraCore
import SupraSessions
import SwiftUI

/// The matter's Outputs tab: lists structured outputs and creates new ones
/// (spec §13).
struct MatterOutputsView: View {
    @ObservedObject var controller: StructuredOutputController
    @ObservedObject var library: ModelLibrary
    let matter: MatterSummary

    @State private var showNew = false
    @State private var navigationPath: [String] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            MatterTabScaffold("Structured Outputs") {
                Button { showNew = true } label: { Label("New Output", systemImage: "plus") }
            } content: {
                content
            }
            .navigationDestination(for: String.self) { id in
                OutputDetailView(controller: controller, library: library, outputID: id)
            }
        }
        .sheet(isPresented: $showNew) {
            NewOutputSheet(controller: controller, library: library, matter: matter)
        }
        .onAppear { controller.loadOutputs() }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .supraDebugOpenOutput)) { note in
            guard AppEnvironment.isUITestMode,
                  let title = note.object as? String,
                  let output = controller.outputs.first(where: { $0.title == title }) else { return }
            navigationPath = [output.id]
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if controller.outputs.isEmpty {
            ContentUnavailableView {
                Label("No Outputs", systemImage: "doc.text")
            } description: {
                Text("Generate reusable legal outputs — issue spotting, rule synthesis, or drafting skeletons — that the local model drafts from the context you provide. (Chronologies are created from the Documents tab.)")
            } actions: {
                Button("New Output") { showNew = true }
            }
        } else {
            List(controller.outputs) { output in
                NavigationLink(value: output.id) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(output.title).font(.supraHeadline)
                            Spacer()
                            Text(output.status).font(.supraCaption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Text(StructuredOutputLabels.label(output.outputType))
                            Text(output.updatedAt, format: .dateTime.month().day())
                            if output.missingCount > 0 {
                                Text("\(output.missingCount) missing").foregroundStyle(.orange)
                            }
                        }
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("output.row.\(output.title)")
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
    @ObservedObject var library: ModelLibrary
    let matter: MatterSummary

    @Environment(\.dismiss) private var dismiss
    @State private var type: StructuredOutputType = .legalIssueSpotting
    @State private var context = ""
    @State private var groundInDocuments = false
    @State private var selectedDocIDs: Set<String> = []
    @State private var documents: [StructuredOutputController.DocumentChoice] = []
    @State private var routingMessage: String?
    /// The model the user picks to generate this output. Defaults to the routed
    /// model for the output type, but any registered (non-embedding) model can be
    /// chosen. Empty only when no models are registered.
    @State private var selectedModelID: String = ""

    private var router: ModelRouter { ModelRouter(configuration: .fromEnvironment()) }
    private var route: ModelRoute? { router.route(forStructuredOutput: type) }
    private var routeModel: ModelSummary? {
        guard let route else { return nil }
        return library.resolvedModel(for: route.role, configuration: router.configuration)
    }

    private var scope: RetrievalScope? {
        guard groundInDocuments, !selectedDocIDs.isEmpty else { return nil }
        return RetrievalScope(documentIDs: Array(selectedDocIDs))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("New Structured Output").font(.supraTitle).padding([.horizontal, .top])
            Text("Pick a deliverable type and give the model the issue, facts, or notes to work from. It produces a structured, reviewable draft saved to this matter's Outputs.")
                .font(.supraSubheadline)
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
                    MultilineField(
                        placeholder: "The issue, key facts, or your notes",
                        text: $context,
                        minLines: 4
                    )
                } header: {
                    Text("Context")
                } footer: {
                    Text("Free text the model reasons over (the issue, key facts, or your notes).")
                }
                Section {
                    Toggle("Ground in specific documents", isOn: $groundInDocuments)
                    if groundInDocuments {
                        if documents.isEmpty {
                            Text("No documents in this matter yet — import them in the Documents tab.")
                                .font(.supraCaption).foregroundStyle(.secondary)
                        } else {
                            ForEach(documents) { doc in
                                Button {
                                    if selectedDocIDs.contains(doc.id) { selectedDocIDs.remove(doc.id) } else { selectedDocIDs.insert(doc.id) }
                                } label: {
                                    HStack {
                                        Image(systemName: selectedDocIDs.contains(doc.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedDocIDs.contains(doc.id) ? Color.accentColor : Color.secondary)
                                        Text(doc.name).lineLimit(1)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            if !selectedDocIDs.isEmpty,
                               let readiness = controller.scopeReadiness(scope: RetrievalScope(documentIDs: Array(selectedDocIDs))) {
                                Text("\(readiness.readyDocuments)/\(readiness.totalDocuments) selected documents indexed")
                                    .font(.supraCaption)
                                    .foregroundStyle(readiness.isFullyReady ? Color.secondary : Color.orange)
                            }
                        }
                    }
                } header: {
                    Text("Source documents")
                }
                Section {
                    if library.models.isEmpty {
                        Text("No models registered — add one in the Models tab to generate.")
                            .font(.supraCaption).foregroundStyle(.orange)
                    } else {
                        Picker("Model", selection: $selectedModelID) {
                            ForEach(library.models) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                    }
                } header: {
                    Text("Model")
                }
                if let routingMessage {
                    Text(routingMessage).font(.supraCaption).foregroundStyle(.orange)
                }
                if let message = controller.message {
                    Text(message).font(.supraCaption).foregroundStyle(.orange)
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
                    .disabled(selectedModelID.isEmpty || controller.isGenerating)
            }
            .padding()
        }
        .frame(minWidth: 460, idealWidth: 540, maxWidth: .infinity, minHeight: 460, idealHeight: 600, maxHeight: .infinity)
        .onAppear {
            library.refresh()
            documents = controller.documentChoices()
            // Default the picker to the model routed for this output type, falling
            // back to any registered model.
            if selectedModelID.isEmpty || !library.models.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = routeModel?.id ?? library.models.first?.id ?? ""
            }
            // Warm the routed model (structured outputs often use the high-quality
            // reasoning role) while the user fills the form.
            if !AppEnvironment.isUITestMode, let role = route?.role { library.prewarm(role: role) }
        }
        // Re-default when the output type changes the routed model (only if the user
        // hasn't picked something still valid).
        .onChange(of: type) { _, _ in
            if let routed = routeModel?.id { selectedModelID = routed }
        }
    }

    private func generate() async {
        routingMessage = nil
        guard let route else { return }
        guard !selectedModelID.isEmpty else {
            routingMessage = "Select a model to generate this output."
            return
        }
        // Load exactly the model the user picked (their choice overrides the routed
        // default).
        await library.activateAndLoad(modelID: selectedModelID)
        guard let chosenUUID = UUID(uuidString: selectedModelID),
              library.loadedModelID?.rawValue == chosenUUID else {
            if case let .failed(message) = library.loadState {
                routingMessage = message
            } else {
                routingMessage = "The selected model could not be loaded."
            }
            return
        }
        let modelID = ModelID(chosenUUID)

        let prefix = matterContextPrefix
        let ok = await controller.createOutput(
            type: type,
            context: prefix + context,
            scope: scope,
            modelID: modelID,
            route: route
        )
        if ok { dismiss() }
    }

    private var matterContextPrefix: String {
        var lines = [
            "Matter: \(matter.name)",
            "Jurisdiction: \(matter.jurisdiction)",
            "Party perspective: \(matter.partyPerspective.rawValue)"
        ]
        if let court = nonEmpty(matter.court) {
            lines.append("Court: \(court)")
        }
        if let clientNames = nonEmpty(matter.clientNames) {
            lines.append("Client name(s): \(clientNames)")
        }
        if let internalMatterID = nonEmpty(matter.internalMatterID) {
            lines.append("Internal matter ID: \(internalMatterID)")
        }
        if let matterDescription = nonEmpty(matter.matterDescription) {
            lines.append("Matter description: \(matterDescription)")
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
