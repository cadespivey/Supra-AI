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
    /// Off by default: the search runs across all courts (the jurisdiction still
    /// shapes query wording and binding/persuasive classification). On restricts the
    /// CourtListener search to the jurisdiction's own courts only.
    @State private var restrictToJurisdictionCourts = false
    /// When restricting to a state's courts, also fold in the federal courts that apply
    /// that state's law (its circuit + district/bankruptcy courts + SCOTUS).
    @State private var includeRelatedFederal = false
    @State private var routingMessage: String?
    /// True while a Generate + Save / Generate + Run action runs end to end.
    @State private var actionInFlight = false
    @State private var selectedCourtID: String
    @State private var focusChain = SupraFocusChain()
    @State private var focusedPlannerControlID = "none"

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
                    JurisdictionScopeField(
                        jurisdiction: $draft.jurisdiction,
                        selectedCourtID: $selectedCourtID
                    )
                    Toggle("Restrict search to the jurisdiction's courts", isOn: $restrictToJurisdictionCourts)
                        .accessibilityIdentifier("planner.restrictCourts")
                    Text("Off (recommended) searches every court, so persuasive authority — like out-of-state UCC cases — isn't missed. On limits the search to the courts above.")
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                    if restrictToJurisdictionCourts, selectedStateName != nil {
                        Toggle("Also include federal courts applying this state's law", isOn: $includeRelatedFederal)
                            .accessibilityIdentifier("planner.includeRelatedFederal")
                    }
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
                    routeStatus
                    if hasModel, !controller.plannedQueries.isEmpty {
                        Label("\(controller.approvedQueryCount) queries ready", systemImage: "checkmark.circle.fill")
                            .font(.supraCaption).foregroundStyle(.green)
                    }
                    if let routingMessage {
                        Text(routingMessage).font(.supraCaption).foregroundStyle(.orange)
                    }
                    if let message = planMessage {
                        Text(message).font(.supraCaption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(hasModel
                        ? "Generate + Save queries the assigned model proposes and returns you to Research to run later. Generate + Run runs them immediately and opens the results, where you can edit and re-run any query. No network request is made until a plan runs."
                        : "No legal-research model is assigned — add queries manually below, or assign one in Models to have them generated for you.")
                }

                if showsQuerySection {
                    Section("Queries") {
                        // Iterate by element identity and drive edits through the
                        // controller's id-keyed mutators. The binding-collection form
                        // (`ForEach($controller.plannedQueries)`) vends *index-based*
                        // element bindings whose getter does `array[index]`; when Save
                        // clears `plannedQueries` while a query field is still focused,
                        // that stale getter indexes an empty array and traps
                        // (Array._checkSubscript / EXC_BREAKPOINT). These id-keyed
                        // closures read a captured value and look edits up by id, so a
                        // concurrent clear is a safe no-op.
                        ForEach(controller.plannedQueries) { query in
                            HStack(spacing: 8) {
                                Toggle("Approved", isOn: Binding(
                                    get: { query.approved },
                                    set: { controller.setApproved($0, for: query.id) }
                                )).labelsHidden()
                                    .accessibilityIdentifier("planner.approved")
                                BoxedLeadingTextField(
                                    placeholder: "Query",
                                    text: Binding(
                                        get: { query.text },
                                        set: { controller.updateText($0, for: query.id) }
                                    ),
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
            Button { Task { await act(run: false) } } label: {
                Text(actionInFlight ? "Working…" : (hasModel ? "Generate + Save" : "Save"))
            }
            .buttonStyle(.ghost)
            .disabled(!canAct)
            .accessibilityIdentifier("planner.generateSave")
            .help(hasModel
                ? "Generate the queries and save the session — return to Research to run it later"
                : "Save the session — return to Research to run it later")
            Button { Task { await act(run: true) } } label: {
                HStack(spacing: 6) {
                    if actionInFlight { ProgressView().controlSize(.small) }
                    Text(actionInFlight ? "Working…" : (hasModel ? "Generate + Run" : "Save & Run"))
                }
            }
            .buttonStyle(.ghostAccent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canAct)
            .accessibilityIdentifier("planner.generateRun")
            .help(hasModel
                ? "Generate the queries, run them, and open the results"
                : "Save the session, run it, and open the results")
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
            // Warm the legal-research model as soon as the planner opens so neither the
            // speculative pre-run nor the explicit Generate pays the multi-second load.
            if hasModel {
                Task { _ = await library.ensureLoadedRoutedModelID(for: route.role, configuration: router.configuration) }
            }
        }
        .task(id: speculationKey) {
            await speculativelyGenerate()
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

    /// The manual query editor is only for when there's no model to generate queries.
    /// When a model IS assigned, queries are generated (often speculatively, before the
    /// user commits) and reviewed alongside their results — not previewed here.
    private var showsQuerySection: Bool {
        routeModel == nil
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

    /// True when a legal-research model is assigned, so the planner can generate
    /// queries; otherwise the user enters them by hand.
    private var hasModel: Bool { routeModel != nil }

    /// Changes whenever an input that shapes the generated queries changes, so the
    /// speculative pre-run re-fires (and stale pre-generated queries are dropped).
    private var speculationKey: String {
        [
            draft.issueText,
            draft.jurisdiction,
            selectedCourtID,
            preferredCourtsText,
            excludedCourtsText,
            restrictToJurisdictionCourts ? "1" : "0",
            useDateRange ? "\(startDate.timeIntervalSince1970)-\(endDate.timeIntervalSince1970)" : "0"
        ].joined(separator: "\u{1}")
    }

    /// Only speculate once there's a real issue to work from and a model to run it.
    private var shouldSpeculate: Bool {
        hasModel && draft.isValid
            && draft.issueText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20
    }

    /// Pre-runs the query generation while the user is still in the planner, so the
    /// queries are already waiting the instant they press Generate + Save/Run. Fires on
    /// a debounce after typing settles; `.task(id:)` cancels a superseded run, and any
    /// queries generated for a now-changed input are dropped so a commit can't save the
    /// wrong ones. Runs silently — routing/plan errors surface only on an explicit
    /// commit, never mid-typing.
    private func speculativelyGenerate() async {
        if hasModel, !actionInFlight, !controller.plannedQueries.isEmpty {
            controller.resetPlan()
        }
        guard shouldSpeculate, !actionInFlight else { return }
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        guard !Task.isCancelled, !actionInFlight, controller.plannedQueries.isEmpty else { return }
        if case .generating = controller.planState { return }
        // Don't evict a model out from under a generation running elsewhere.
        if library.isRuntimeGenerating() { return }
        // Only proceed with a real (loaded) model — a failed load stays silent and
        // leaves no half-built manual query behind for the commit to trip over.
        guard case let .success(modelID) = await library.ensureLoadedRoutedModelID(
            for: route.role, configuration: router.configuration
        ) else { return }
        guard !Task.isCancelled, !actionInFlight, controller.plannedQueries.isEmpty else { return }
        syncFilters()
        await controller.generatePlan(draft: draft, modelID: modelID, route: route)
    }

    /// Both footer actions enable once the issue/jurisdiction are valid and there is
    /// something to commit — a model to generate from, or manually entered queries.
    private var canAct: Bool {
        guard !actionInFlight, draft.isValid else { return false }
        return hasModel || controller.canSavePlan
    }

    /// The single commit path behind both footer buttons: generate the queries (when a
    /// model is assigned and none are pending yet — e.g. from the speculative pre-run),
    /// then either save and return to the Research tab, or save + run and open the
    /// results. Failed generation leaves the sheet open with its routing/plan message
    /// so the user can fix it or fall back to manual queries.
    private func act(run: Bool) async {
        actionInFlight = true
        defer { actionInFlight = false }
        // If a speculative generation is mid-flight, wait it out and reuse its queries
        // rather than starting a second (the single-slot runtime serialises generation).
        while case .generating = controller.planState {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if hasModel, controller.plannedQueries.isEmpty {
            await generate()
        }
        guard controller.canSavePlan else { return }
        if run {
            saveAndRun()
        } else {
            syncFilters()
            if (try? controller.savePlan(draft: draft)) != nil {
                controller.loadSessions()
                dismiss()
            }
        }
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
        // The jurisdiction always shapes how queries are worded (jurisdictionContext
        // above) and how results are later classified as binding vs. persuasive. The
        // *search* is only hard-restricted to the jurisdiction's own courts when the
        // user opts in — otherwise it runs across all courts. Binding-only searching
        // silently drops the out-of-jurisdiction persuasive authority that dominates
        // uniform-law issues (e.g. UCC Article 2), which returned zero results.
        var courtIDs: [String] = []
        if restrictToJurisdictionCourts {
            courtIDs = scope?.courtListenerIDs ?? []
            // "Include federal courts applying this state's law" broadens the restricted
            // set (it's meaningless when the search is already unrestricted).
            if includeRelatedFederal, let stateName = selectedStateName {
                courtIDs = unique(courtIDs + JurisdictionCatalog.shared.relatedFederalCourtIDs(forState: stateName))
            }
        }
        draft.courtFilterIDs = courtIDs
        draft.dateRangeStart = useDateRange ? startDate : nil
        draft.dateRangeEnd = useDateRange ? endDate : nil
    }

    /// The selected jurisdiction's state name, when a state is chosen — gates the
    /// "include federal courts applying this state's law" option.
    private var selectedStateName: String? {
        guard let option = JurisdictionCatalog.shared.option(id: selectedCourtID),
              option.system == .state else { return nil }
        return option.state ?? option.jurisdictionName
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

/// A structured jurisdiction picker: choose Federal or State, then the specific court.
/// Capped at appellate levels (SCOTUS / U.S. Courts of Appeals; a state as a whole) —
/// trial-court opinions aren't precedential, so drilling to the trial/county level
/// rarely helps research. Two quick menus replace the free-text search entirely.
struct JurisdictionScopeField: View {
    @Binding var jurisdiction: String
    @Binding var selectedCourtID: String

    private let catalog = JurisdictionCatalog.shared
    @State private var system: JurisdictionSystem = .state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Jurisdiction").font(.subheadline).foregroundStyle(.secondary)
            Picker("Court system", selection: systemBinding) {
                Text("Federal").tag(JurisdictionSystem.federal)
                Text("State").tag(JurisdictionSystem.state)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("planner.jurisdictionSystem")

            Picker(selection: courtBinding) {
                Text(system == .state ? "Choose a state…" : "Choose a court…").tag("")
                ForEach(system == .state ? catalog.stateJurisdictions : catalog.federalAppellateCourts) { option in
                    Text(label(for: option)).tag(option.id)
                }
            } label: {
                Text(system == .state ? "State" : "Court")
            }
            .accessibilityIdentifier("planner.jurisdictionCourt")

            if let scope = selectedScope {
                Text("Binding authority: " + scope.mandatoryAuthorities.prefix(3).joined(separator: "; "))
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            // Reflect an incoming selection (e.g. pre-filled from the matter) in the
            // segment so the right menu is shown.
            if let current = catalog.option(id: selectedCourtID) { system = current.system }
        }
    }

    private var systemBinding: Binding<JurisdictionSystem> {
        Binding(
            get: { system },
            set: { newSystem in
                system = newSystem
                // Drop a now-mismatched court choice when switching systems.
                if let current = catalog.option(id: selectedCourtID), current.system != newSystem {
                    selectedCourtID = ""
                    jurisdiction = ""
                }
            }
        )
    }

    private var courtBinding: Binding<String> {
        Binding(
            get: { selectedCourtID },
            set: { newID in
                selectedCourtID = newID
                jurisdiction = catalog.option(id: newID)?.jurisdictionName ?? ""
            }
        )
    }

    private var selectedScope: JurisdictionAuthorityScope? {
        catalog.option(id: selectedCourtID).map(catalog.authorityScope(for:))
    }

    private func label(for option: JurisdictionOption) -> String {
        system == .state ? option.jurisdictionName : option.displayName
    }
}
