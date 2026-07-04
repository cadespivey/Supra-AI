import SupraCore
import SupraResearch
import SupraSessions
import SwiftUI

/// Plans a research session: collects the issue + filters, generates exactly
/// five editable CourtListener queries with the assigned legal-research model
/// (no network), and saves the approved ones (spec §9 / WO 24).
struct ResearchPlannerView: View {
    @ObservedObject var controller: ResearchSessionController
    @ObservedObject var library: ModelLibrary
    let matter: MatterSummary

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ResearchPlanDraft
    @State private var preferredCourtsText = ""
    @State private var excludedCourtsText = ""
    @State private var useDateRange = false
    @State private var startDate = Date(timeIntervalSince1970: 1_420_070_400) // 2015-01-01
    @State private var endDate = Date()
    @State private var routingMessage: String?
    @State private var isGeneratingAndRunning = false
    @State private var selectedCourtID: String
    @State private var focusChain = SupraFocusChain()
    @State private var focusedPlannerControlID = "none"
    /// Throwaway sink for the autocomplete field's court binding; the planner
    /// derives its court filter from `selectedCourtID` via `selectedScope`.
    @State private var jurisdictionCourt = ""

    /// Called after Save & Run persists the session and kicks off the run,
    /// so the parent can navigate straight into the session detail.
    var onSaveAndRun: ((String) -> Void)?

    init(
        controller: ResearchSessionController,
        library: ModelLibrary,
        matter: MatterSummary,
        onSaveAndRun: ((String) -> Void)? = nil
    ) {
        self.controller = controller
        self.library = library
        self.matter = matter
        self.onSaveAndRun = onSaveAndRun
        let selected = JurisdictionCatalog.shared.bestMatch(jurisdiction: matter.jurisdiction, court: matter.court)
        _draft = State(initialValue: ResearchPlanDraft(
            jurisdiction: matter.jurisdiction,
            partyPerspective: matter.partyPerspective.rawValue
        ))
        _selectedCourtID = State(initialValue: selected?.id ?? "")
    }

    var body: some View {
        SupraSheetScaffold("New Research Session", doneLabel: "Cancel", onClose: { controller.resetPlan(); dismiss() }) {
            Form {
                Section("Issue") {
                    BoxedLeadingTextField(
                        placeholder: "Title",
                        text: $draft.title,
                        focusChain: focusChain,
                        focusOrder: 10,
                        accessibilityID: "planner.title"
                    )
                        .accessibilityIdentifier("planner.title")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Legal issue or question").font(.subheadline).foregroundStyle(.secondary)
                        MultilineField(
                            placeholder: "e.g. Does the UCC govern a sale of goods under $500?",
                            text: $draft.issueText,
                            minLines: 4,
                            focusChain: focusChain,
                            focusOrder: 20,
                            accessibilityID: "planner.issue"
                        )
                        .accessibilityIdentifier("planner.issue")
                    }
                    JurisdictionAutocompleteField(
                        jurisdiction: $draft.jurisdiction,
                        court: $jurisdictionCourt,
                        selectedCourtID: $selectedCourtID,
                        invalid: false,
                        focusChain: focusChain,
                        focusOrder: 30,
                        accessibilityID: "planner.jurisdiction"
                    )
                    .accessibilityIdentifier("planner.jurisdiction")
                }

                Section("Filters (optional)") {
                    BoxedLeadingTextField(
                        placeholder: "Additional preferred courts (comma-separated)",
                        text: $preferredCourtsText,
                        focusChain: focusChain,
                        focusOrder: 40,
                        accessibilityID: "planner.preferredCourts"
                    )
                    .accessibilityIdentifier("planner.preferredCourts")
                    BoxedLeadingTextField(
                        placeholder: "Excluded courts (comma-separated)",
                        text: $excludedCourtsText,
                        focusChain: focusChain,
                        focusOrder: 50,
                        accessibilityID: "planner.excludedCourts"
                    )
                    .accessibilityIdentifier("planner.excludedCourts")
                    HStack {
                        Text("Limit to a date range")
                        Spacer()
                        FocusChainSwitch(
                            isOn: $useDateRange,
                            focusChain: focusChain,
                            focusOrder: 60,
                            accessibilityID: "planner.dateRange"
                        )
                    }
                    if useDateRange {
                        DatePicker("From", selection: $startDate, displayedComponents: .date)
                        DatePicker("To", selection: $endDate, displayedComponents: .date)
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        Button { Task { await generateAndRun() } } label: {
                            HStack {
                                if isGeneratingAndRunning { ProgressView().controlSize(.small) }
                                Text(isGeneratingAndRunning ? "Generating…" : "Generate & Run")
                            }
                        }
                        .buttonStyle(.ghostAccent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!draft.isValid || isGenerating || isGeneratingAndRunning)
                        .accessibilityIdentifier("planner.generateAndRun")
                        .help("Generate queries with the assigned model, approve them all, save, and run — one step (⌘Return)")
                        Button { Task { await generate() } } label: {
                            HStack {
                                if isGenerating, !isGeneratingAndRunning { ProgressView().controlSize(.small) }
                                Text("Generate for Review")
                            }
                        }
                        .buttonStyle(.ghost)
                        .disabled(!draft.isValid || isGenerating || isGeneratingAndRunning)
                        .accessibilityIdentifier("planner.generate")
                        .help("Generate proposed queries and review or edit them before running")
                    }
                    routeStatus
                    if let routingMessage {
                        Text(routingMessage).font(.supraCaption).foregroundStyle(.orange)
                    }
                    if let message = planMessage {
                        Text(message).font(.supraCaption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("The assigned legal-research model proposes queries locally. No network request is made until you run the plan. You can add queries manually if no model is assigned.")
                }

                if showsQuerySection {
                    Section("Proposed Queries — approve the ones to run") {
                        ForEach($controller.plannedQueries) { $query in
                            HStack(spacing: 8) {
                                Toggle("Approved", isOn: $query.approved).labelsHidden()
                                    .accessibilityIdentifier("planner.approved")
                                BoxedLeadingTextField(
                                    placeholder: "Query",
                                    text: $query.text,
                                    accessibilityID: "planner.query"
                                )
                                    .accessibilityIdentifier("planner.query")
                                Button(role: .destructive) {
                                    controller.deleteQuery(id: query.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.ghostDanger)
                            }
                        }
                        Button { controller.addQuery() } label: {
                            Label("Add Query", systemImage: "plus")
                        }
                        .buttonStyle(.ghost)
                        .accessibilityIdentifier("planner.addQuery")
                    }
                }
            }
            .formStyle(.grouped)
        } footer: {
            Spacer()
            if !controller.plannedQueries.isEmpty {
                Text("\(controller.approvedQueryCount) approved")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
            }
            Button("Save Plan") { save() }
                .buttonStyle(.ghost)
                .disabled(!controller.canSavePlan)
                .accessibilityIdentifier("planner.save")
            Button("Save & Run") { saveAndRun() }
                .buttonStyle(.ghostAccent)
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canSavePlan)
                .accessibilityIdentifier("planner.saveAndRun")
        }
        .frame(minWidth: 560, idealWidth: 680, maxWidth: .infinity, minHeight: 640, idealHeight: 780, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            #if DEBUG
            if AppEnvironment.isUITestMode {
                Text(focusedPlannerControlID)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("planner.focused.\(focusedPlannerControlID)")
                    .accessibilityLabel(focusedPlannerControlID)
            }
            #endif
        }
        .onAppear {
            #if DEBUG
            if AppEnvironment.isUITestMode {
                focusChain.onFocusChange = { focusedPlannerControlID = $0 ?? "none" }
                DispatchQueue.main.async { focusChain.noteFirstRegisteredControl() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focusChain.noteFirstRegisteredControl() }
            }
            #endif
            // Reliable window-ready trigger for initial focus on Title, with a
            // short retry — register-time async can fire before the sheet's
            // window is attached on slower presentations. Idempotent + guarded.
            DispatchQueue.main.async { focusChain.installInitialFocusIfPossible() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focusChain.installInitialFocusIfPossible() }
            library.refresh()
            Task { @MainActor in seedManualQueryIfNeeded() }
        }
        .onDisappear {
            #if DEBUG
            focusChain.onFocusChange = nil
            #endif
        }
    }

    private var router: ModelRouter { ModelRouter(configuration: .fromEnvironment()) }

    private var route: ModelRoute { router.route(for: .legalResearch) }

    private var routeModel: ModelSummary? {
        library.resolvedModel(for: route.role, configuration: router.configuration)
    }

    private var isGenerating: Bool {
        if case .generating = controller.planState { return true }
        return false
    }

    /// Show the query editor (incl. "Add Query") whenever there are queries OR a
    /// generation attempt has finished — so manual entry stays reachable when
    /// generation returns nothing (no model loaded / incomplete / failed).
    private var showsQuerySection: Bool {
        if !controller.plannedQueries.isEmpty { return true }
        if routeModel == nil { return true }
        switch controller.planState {
        case .ready, .incomplete, .failed: return true
        case .idle, .generating: return false
        }
    }

    private var planMessage: String? {
        switch controller.planState {
        case let .incomplete(message), let .failed(message):
            return message
        case .idle, .generating, .ready:
            return nil
        }
    }

    @ViewBuilder
    private var routeStatus: some View {
        if let routeModel {
            Text("Uses \(route.role.displayName): \(routeModel.displayName)")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
        } else {
            Text("Assign a \(route.role.displayName) model in Models to generate a search plan, or add queries manually.")
                .font(.supraCaption)
                .foregroundStyle(.orange)
        }
    }

    private func generate() async {
        syncFilters()
        routingMessage = nil
        let modelID: ModelID?
        switch await library.ensureLoadedRoutedModelID(for: route.role, configuration: router.configuration) {
        case let .success(loaded):
            modelID = loaded
        case let .failure(issue):
            routingMessage = issue.message
            modelID = nil
        }
        await controller.generatePlan(draft: draft, modelID: modelID, route: route)
    }

    private func save() {
        syncFilters()
        if (try? controller.savePlan(draft: draft)) != nil {
            dismiss()
        }
    }

    /// One step from issue to running session: generate queries with the
    /// assigned model (they arrive approved), save, and run. On any
    /// generation failure the sheet stays open with the routing/plan message
    /// visible so the user can fall back to review or manual queries.
    private func generateAndRun() async {
        isGeneratingAndRunning = true
        defer { isGeneratingAndRunning = false }
        await generate()
        guard controller.canSavePlan else { return }
        saveAndRun()
    }

    /// Saves the plan and immediately starts the run — no reopening the saved
    /// session just to press Run. The parent navigates into the session so the
    /// user watches results (or the token/run message) arrive.
    private func saveAndRun() {
        syncFilters()
        guard let sessionID = try? controller.savePlan(draft: draft) else { return }
        controller.openSession(sessionID)
        dismiss()
        onSaveAndRun?(sessionID)
        Task { await controller.runApprovedSearches() }
    }

    private func seedManualQueryIfNeeded() {
        guard routeModel == nil, controller.plannedQueries.isEmpty else { return }
        controller.addQuery()
    }

    private func syncFilters() {
        let scope = selectedScope
        let additionalPreferred = splitList(preferredCourtsText)
        if additionalPreferred.isEmpty {
            draft.preferredCourts = scope?.preferredCourtNames ?? []
        } else {
            draft.preferredCourts = unique(additionalPreferred + (scope?.preferredCourtNames ?? []))
        }
        draft.excludedCourts = splitList(excludedCourtsText)
        draft.jurisdictionContext = scope?.modelContext ?? ""
        draft.courtFilterIDs = scope?.courtListenerIDs ?? []
        draft.dateRangeStart = useDateRange ? startDate : nil
        draft.dateRangeEnd = useDateRange ? endDate : nil
    }

    private var selectedScope: JurisdictionAuthorityScope? {
        if let option = JurisdictionCatalog.shared.option(id: selectedCourtID) {
            return JurisdictionCatalog.shared.authorityScope(for: option)
        }
        return JurisdictionCatalog.shared.authorityScope(jurisdiction: draft.jurisdiction)
    }

    private func splitList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }
}
