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
    @State private var selectedCourtID: String
    /// Throwaway sink for the autocomplete field's court binding; the planner
    /// derives its court filter from `selectedCourtID` via `selectedScope`.
    @State private var jurisdictionCourt = ""

    init(controller: ResearchSessionController, library: ModelLibrary, matter: MatterSummary) {
        self.controller = controller
        self.library = library
        self.matter = matter
        let selected = JurisdictionCatalog.shared.bestMatch(jurisdiction: matter.jurisdiction, court: matter.court)
        _draft = State(initialValue: ResearchPlanDraft(
            jurisdiction: matter.jurisdiction,
            partyPerspective: matter.partyPerspective.rawValue
        ))
        _selectedCourtID = State(initialValue: selected?.id ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("New Research Session")
                .font(.supraTitle)
                .padding([.horizontal, .top])

            Form {
                Section("Issue") {
                    TextField("Title", text: $draft.title)
                        .accessibilityIdentifier("planner.title")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Legal issue or question").font(.supraCaption).foregroundStyle(.secondary)
                        MultilineField(
                            placeholder: "e.g. Does the UCC govern a sale of goods under $500?",
                            text: $draft.issueText,
                            minLines: 4,
                            accessibilityID: "planner.issue"
                        )
                        .accessibilityIdentifier("planner.issue")
                    }
                    JurisdictionAutocompleteField(
                        jurisdiction: $draft.jurisdiction,
                        court: $jurisdictionCourt,
                        selectedCourtID: $selectedCourtID,
                        invalid: false
                    )
                    .accessibilityIdentifier("planner.jurisdiction")
                }

                Section("Filters (optional)") {
                    TextField("Additional preferred courts (comma-separated)", text: $preferredCourtsText)
                    TextField("Excluded courts (comma-separated)", text: $excludedCourtsText)
                    Toggle("Limit to a date range", isOn: $useDateRange)
                    if useDateRange {
                        DatePicker("From", selection: $startDate, displayedComponents: .date)
                        DatePicker("To", selection: $endDate, displayedComponents: .date)
                    }
                }

                Section {
                    Button { Task { await generate() } } label: {
                        HStack {
                            if isGenerating { ProgressView().controlSize(.small) }
                            Text(isGenerating ? "Generating…" : "Generate Search Plan")
                        }
                    }
                    .disabled(!draft.isValid || isGenerating)
                    .accessibilityIdentifier("planner.generate")
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
                                TextField("Query", text: $query.text)
                                    .accessibilityIdentifier("planner.query")
                                Button(role: .destructive) {
                                    controller.deleteQuery(id: query.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button { controller.addQuery() } label: {
                            Label("Add Query", systemImage: "plus")
                        }
                        .accessibilityIdentifier("planner.addQuery")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel", role: .cancel) {
                    controller.resetPlan()
                    dismiss()
                }
                Spacer()
                if !controller.plannedQueries.isEmpty {
                    Text("\(controller.approvedQueryCount) approved")
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                }
                Button("Save Plan") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.canSavePlan)
                    .accessibilityIdentifier("planner.save")
            }
            .padding()
        }
        .frame(minWidth: 560, idealWidth: 680, maxWidth: .infinity, minHeight: 640, idealHeight: 780, maxHeight: .infinity)
        .onAppear {
            library.refresh()
            Task { @MainActor in seedManualQueryIfNeeded() }
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
