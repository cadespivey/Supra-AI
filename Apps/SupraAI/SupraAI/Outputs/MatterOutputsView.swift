import SupraCore
import SupraSessions
import SwiftUI

/// The matter's Saved Work tab: lists structured work products and creates new
/// ones (spec §13). Store and controller names retain `Output` for compatibility.
struct MatterOutputsView: View {
    @ObservedObject var controller: StructuredOutputController
    @ObservedObject var library: ModelLibrary
    let matter: MatterSummary

    @State private var showNew = false
    @State private var navigationPath: [String] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            MatterTabScaffold("Saved Work") {
                Button { showNew = true } label: { Label("New Work Product", systemImage: "plus") }
            } content: {
                content
            }
            .navigationDestination(for: String.self) { id in
                OutputDetailView(controller: controller, library: library, outputID: id)
            }
        }
        .sheet(isPresented: $showNew) {
            NewOutputSheet(controller: controller, library: library)
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
                Label("No Saved Work", systemImage: "doc.text")
            } description: {
                Text("Create reusable legal work — issue spotting, rule synthesis, or drafting skeletons — from the context you provide. Chronologies are created from Documents.")
            } actions: {
                Button("New Work Product") { showNew = true }
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
                        AssuranceBadge(state: output.assuranceState)
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

    @Environment(\.dismiss) private var dismiss
    @State private var type: StructuredOutputType = .legalIssueSpotting
    @State private var context = ""
    @State private var groundInDocuments = false
    @State private var selectedDocIDs: Set<String> = []
    @State private var documents: [StructuredOutputController.DocumentChoice] = []
    @State private var routingMessage: String?
    @State private var identityProjection: MatterLegalIdentityReadProjection?
    @State private var identityMessage: String?
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
            Text("New Work Product").font(.supraTitle).padding([.horizontal, .top])
            Text("Pick a deliverable type and provide the issue, facts, or notes. Supra creates a structured, reviewable draft and saves it with this matter's work.")
                .font(.supraSubheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
                .padding(.top, 2)
            Form {
                Section("Matter identity") {
                    if let courtPresentation {
                        if let resolvedJurisdictionName = courtPresentation.resolvedJurisdictionName,
                           let resolvedCourtName = courtPresentation.resolvedCourtName {
                            LabeledContent("Jurisdiction", value: resolvedJurisdictionName)
                            LabeledContent("Court", value: resolvedCourtName)
                        } else {
                            Label("Choose a court in Matter Edit", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            if let savedCourtText = courtPresentation.savedCourtText,
                               !savedCourtText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("Imported court text “\(savedCourtText)” is retained as evidence, but is not a resolved court.")
                                    .font(.supraCaption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let draftPartyDefaults {
                        LabeledContent(
                            "Represented client",
                            value: "\(draftPartyDefaults.representedClientName) (\(draftPartyDefaults.representedDesignation))"
                        )
                        LabeledContent(
                            "Opposing party",
                            value: "\(draftPartyDefaults.opposingPartyName) (\(draftPartyDefaults.opposingDesignation))"
                        )
                    } else if identityProjection != nil {
                        Label("Resolve the represented client, opposing party, and service contact in Matter Edit", systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                    if let identityMessage {
                        Text(identityMessage).font(.supraCaption).foregroundStyle(.orange)
                    }
                }
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
                                Text(readiness.summaryText)
                                    .font(.supraCaption)
                                    .foregroundStyle(readiness.isFullyReady ? Color.secondary : Color.orange)
                                if !readiness.blockingReasons.isEmpty {
                                    Text(readiness.blockingReasons.joined(separator: " · "))
                                        .font(.supraCaption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Source documents")
                }
                Section {
                    if library.models.isEmpty {
                        Text("No local assistant is configured — finish AI Setup to generate.")
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
                    .disabled(selectedModelID.isEmpty || controller.isGenerating || !identitySnapshotAvailable)
            }
            .padding()
        }
        .frame(minWidth: 460, idealWidth: 540, maxWidth: .infinity, minHeight: 460, idealHeight: 600, maxHeight: .infinity)
        .onAppear {
            library.refresh()
            documents = controller.documentChoices()
            refreshIdentity()
            // Default the picker to the model routed for this output type, falling
            // back to any registered model.
            if selectedModelID.isEmpty || !library.models.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = routeModel?.id ?? library.models.first?.id ?? ""
            }
            // Warm the routed model (structured outputs often use the high-quality
            // reasoning role) while the user fills the form.
            if identitySnapshotAvailable, !AppEnvironment.isUITestMode, let role = route?.role {
                library.prewarm(role: role)
            }
        }
        // Re-default when the output type changes the routed model (only if the user
        // hasn't picked something still valid).
        .onChange(of: type) { _, _ in
            if let routed = routeModel?.id { selectedModelID = routed }
        }
    }

    private func generate() async {
        routingMessage = nil
        refreshIdentity()
        guard identitySnapshotAvailable else {
            routingMessage = identityMessage
                ?? "The matter identity snapshot is unavailable. Your context has been kept."
            return
        }
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

        let ok = await controller.createOutput(
            type: type,
            context: context,
            scope: scope,
            modelID: modelID,
            route: route
        )
        if ok { dismiss() }
    }

    private var courtPresentation: MatterCourtPresentation? {
        identityProjection?.courtPresentation
    }

    private var draftPartyDefaults: DraftPartyDefaults? {
        guard let identityProjection,
              case let .available(defaults) = identityProjection.draftParties else {
            return nil
        }
        return defaults
    }

    private var identitySnapshotAvailable: Bool {
        identityProjection != nil
    }

    private func refreshIdentity() {
        do {
            identityProjection = try controller.legalIdentityReadProjection()
            identityMessage = nil
        } catch {
            identityProjection = nil
            identityMessage = "This matter's legal identity is unavailable. Reopen the matter and try again."
        }
    }
}
