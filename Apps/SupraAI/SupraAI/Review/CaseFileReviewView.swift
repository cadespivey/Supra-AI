import SupraSessions
import SwiftUI

/// The first visible Review Project workbench: a native four-column finding
/// matrix with a source-focused trailing inspector. Creation/configuration stays
/// in the exhaustive-output workflow; this surface opens only eligible exact
/// outputs and gives counsel one narrow, auditable review action.
struct CaseFileReviewView: View {
    @ObservedObject var controller: CaseFileReviewController

    @Environment(\.colorScheme) private var colorScheme
    @State private var sourcesWidth: CGFloat = 640
    @State private var previewModel: DocumentPreviewModel?
    @State private var actionError: String?
    @State private var valueEditor: ValueEditorState?
    @State private var activeFilter: CaseFileReviewController.RowFilter = .all
    @State private var pendingNavigation: PendingReviewNavigation?
    @State private var discardNavigationPresented = false
    @FocusState private var valueFieldFocused: Bool

    // Approved evidence rail: #A77920 in light appearance, #D2AC5C in dark.
    private var evidenceRailColor: Color {
        if colorScheme == .dark {
            return Color(red: 210.0 / 255.0, green: 172.0 / 255.0, blue: 92.0 / 255.0)
        }
        return Color(red: 167.0 / 255.0, green: 121.0 / 255.0, blue: 32.0 / 255.0)
    }

    private let evidenceRailWidth: CGFloat = 3

    var body: some View {
        ZStack(alignment: .trailing) {
            MatterTabScaffold("Review", actions: {
                reviewActions
            }) {
                VStack(spacing: 0) {
                    if let message = controller.message {
                        Text(message)
                            .font(.supraCaption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                        Divider()
                    }
                    reviewContent
                }
            }
            .alert(
                "Discard value changes?",
                isPresented: $discardNavigationPresented
            ) {
                Button("Keep editing", role: .cancel) {
                    keepEditingAfterNavigationRequest()
                }
                .accessibilityIdentifier("review.projectSwitch.cancel")
                Button("Discard and switch", role: .destructive) {
                    discardAndPerformPendingNavigation()
                }
                .accessibilityIdentifier("review.projectSwitch.discard")
            } message: {
                Text(discardNavigationMessage)
            }

            if controller.selectedCellID != nil {
                SlideOverPanel(
                    width: $sourcesWidth,
                    minWidth: 560,
                    maxWidth: 980,
                    onClose: closeSources
                ) {
                    if let previewModel {
                        DocumentPreviewView(model: previewModel) {
                            self.previewModel = nil
                        }
                    } else {
                        sourcesInspector
                    }
                }
            }
        }
        .onAppear { controller.load() }
        .onChange(of: controller.selectedCellID) { _, _ in
            previewModel = nil
            if controller.selectedCellID != nil {
                clearValueEditor()
            }
        }
        .onChange(of: controller.selectedProjectID) { _, _ in
            activeFilter = .all
            previewModel = nil
            clearValueEditor()
        }
        .onChange(of: controller.rows) { _, _ in
            reconcileVisibleSelection()
        }
        .alert(
            "Review action failed",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "The Review Project could not be updated.")
        }
    }

    @ViewBuilder
    private var reviewActions: some View {
        HStack(spacing: 10) {
            if controller.projects.count > 1 {
                Picker(
                    "Project",
                    selection: Binding(
                        get: { controller.selectedProjectID ?? "" },
                        set: { requestNavigation(.selectProject($0)) }
                    )
                ) {
                    ForEach(controller.projects) { project in
                        Text(project.title).tag(project.id)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .accessibilityLabel("Review Project")
                .accessibilityValue(selectedProject?.title ?? "")
                .accessibilityIdentifier("review.projectPicker")
            } else if let project = controller.projects.first {
                Text(project.title)
                    .font(.supraSubheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if controller.eligibleOutputs.count == 1,
               let output = controller.eligibleOutputs.first {
                Button {
                    open(output)
                } label: {
                    Label("Open Review", systemImage: "rectangle.and.text.magnifyingglass")
                }
                .buttonStyle(.ghost)
            } else if !controller.eligibleOutputs.isEmpty {
                Menu {
                    ForEach(controller.eligibleOutputs) { output in
                        Button(output.title) { open(output) }
                    }
                } label: {
                    Label("Open Review", systemImage: "rectangle.and.text.magnifyingglass")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var reviewContent: some View {
        VStack(spacing: 0) {
            if let project = selectedProject, project.status == "stale" {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Review source changed")
                            .font(.supraHeadline)
                        Text("Frozen findings and excerpts remain available, but one or more live source records can no longer be verified.")
                            .font(.supraCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 9)
                .background(Color.orange.opacity(colorScheme == .dark ? 0.12 : 0.08))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("review.staleNotice")
                Divider()
            }

            if controller.rows.isEmpty {
                ContentUnavailableView(
                    controller.projects.isEmpty ? "No review project" : "No findings",
                    systemImage: "tablecells",
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                reviewControlStrip
                Divider()

                if filteredRows.isEmpty {
                    VStack(spacing: 12) {
                        ContentUnavailableView(
                            "No findings match",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text(
                                "Choose another filter to see the rest of this Review Project."
                            )
                        )
                        .accessibilityIdentifier("review.filteredEmpty")
                        Button("Show all findings") {
                            setFilter(.all)
                        }
                        .accessibilityIdentifier("review.filter.showAll")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    reviewMatrix(rows: filteredRows)
                }
            }
        }
    }

    private var reviewControlStrip: some View {
        HStack(spacing: 14) {
            reviewProgress

            Spacer(minLength: 12)

            if valueEditorIsDirty {
                unsavedEditControls
            } else {
                reviewFilterControls
            }
        }
        .padding(.horizontal, 14)
        .padding(.trailing, controller.selectedCellID == nil ? 0 : sourcesWidth)
        .frame(minHeight: 38)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.controlStrip")
    }

    private var reviewProgress: some View {
        let progress = controller.reviewProgress
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(progress.reviewedCount) of \(progress.totalCount) reviewed")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel(
                    "\(progress.reviewedCount) of \(progress.totalCount) findings reviewed"
                )
                .accessibilityHint("Review progress")
                .accessibilityIdentifier("review.progress")
            ProgressView(
                value: Double(progress.reviewedCount),
                total: Double(max(progress.totalCount, 1))
            )
            .progressViewStyle(.linear)
            .tint(.accentColor)
            .accessibilityHidden(true)
        }
        .frame(minWidth: 145, idealWidth: 180, maxWidth: 220, alignment: .leading)
    }

    private var reviewFilterControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                ForEach(CaseFileReviewController.RowFilter.allCases, id: \.self) { filter in
                    reviewFilterButton(filter)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            Menu {
                ForEach(CaseFileReviewController.RowFilter.allCases, id: \.self) { filter in
                    identifiedFilterControl(
                        Button {
                            setFilter(filter)
                        } label: {
                            if activeFilter == filter {
                                Label(filterTitle(filter), systemImage: "checkmark")
                            } else {
                                Text(filterTitle(filter))
                            }
                        },
                        filter: filter
                    )
                }
            } label: {
                Text("\(filterTitle(activeFilter)) · \(filterCount(activeFilter))")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Filter findings")
            .accessibilityValue(filterTitle(activeFilter))
            .accessibilityIdentifier("review.filter.menu")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.filters")
    }

    private func reviewFilterButton(
        _ filter: CaseFileReviewController.RowFilter
    ) -> some View {
        identifiedFilterControl(
            Button {
                setFilter(filter)
            } label: {
                HStack(spacing: 5) {
                    Text(filterTitle(filter))
                    Text("\(filterCount(filter))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.supraCaption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    activeFilter == filter
                        ? Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(alignment: .leading) {
                    if filter == .evidenceAttention {
                        Rectangle()
                            .fill(evidenceRailColor)
                            .frame(width: evidenceRailWidth)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(filterTitle(filter))
            .accessibilityValue(findingCount(filterCount(filter)))
            .accessibilityAddTraits(activeFilter == filter ? .isSelected : []),
            filter: filter
        )
    }

    @ViewBuilder
    private func identifiedFilterControl<Content: View>(
        _ content: Content,
        filter: CaseFileReviewController.RowFilter
    ) -> some View {
        switch filter {
        case .all:
            content.accessibilityIdentifier("review.filter.all")
        case .needsReview:
            content.accessibilityIdentifier("review.filter.needsReview")
        case .edited:
            content.accessibilityIdentifier("review.filter.edited")
        case .evidenceAttention:
            content.accessibilityIdentifier("review.filter.evidenceAttention")
        }
    }

    private var unsavedEditControls: some View {
        HStack(spacing: 8) {
            Label("Unsaved edit", systemImage: "pencil")
                .font(.supraCaption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("review.unsavedEdit")
            Button("Resume") {
                resumeValueEditor()
            }
            .buttonStyle(.ghost)
            .accessibilityIdentifier("review.unsavedEdit.resume")
            Button("Discard") {
                clearValueEditor()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("review.unsavedEdit.discard")
        }
    }

    private func reviewMatrix(
        rows: [CaseFileReviewController.Row]
    ) -> some View {
        Table(
            rows,
            selection: Binding(
                get: { controller.selectedCellID },
                set: { cellID in
                    if valueEditorIsDirty {
                        resumeValueEditor()
                    } else if let cellID {
                        clearValueEditor()
                        controller.selectCell(cellID)
                    } else {
                        controller.clearSelection()
                    }
                }
            )
        ) {
            TableColumn("Finding") { row in
                Text(row.finding)
                    .font(.supraBody)
                    .lineLimit(2)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        if controller.selectedCellID == row.cellID {
                            Rectangle()
                                .fill(evidenceRailColor)
                                .frame(width: evidenceRailWidth, height: 24)
                        }
                    }
                    .accessibilityIdentifier("review.row.\(row.cellID)")
            }
            .width(min: 180, ideal: 240)

            TableColumn("Generated value") { row in
                HStack(spacing: 8) {
                    Button {
                        beginEditing(row)
                    } label: {
                        HStack(spacing: 6) {
                            Text(row.displayValue)
                                .font(.supraBody)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(row.displayValue)
                    .accessibilityValue(
                        row.valueState == .edited ? "Edited" : "Generated"
                    )
                    .accessibilityIdentifier("review.value.\(row.cellID)")
                    .accessibilityHint("Edit this Review value")
                    .popover(
                        isPresented: valueEditorPresented(for: row.cellID),
                        arrowEdge: .bottom
                    ) {
                        valueEditorPopover
                    }

                    if row.valueState == .edited {
                        Text("Edited")
                            .font(.supraCaption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("review.edited.\(row.cellID)")
                    }
                }
            }
            .width(min: 180, ideal: 300)

            TableColumn("Sources") { row in
                Button {
                    openSources(row)
                } label: {
                    Text(sourceSummary(row))
                        .font(.supraSubheadline)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("review.sources.\(row.cellID)")
                .accessibilityHint("Open supporting and contrary evidence")
            }
            .width(min: 150, ideal: 190)

            TableColumn("Review") { row in
                if row.reviewState == .reviewed {
                    Label("Reviewed", systemImage: "checkmark.circle.fill")
                        .font(.supraSubheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("review.reviewed.\(row.cellID)")
                        .help(reviewedHelp(row))
                } else {
                    Button("Mark Reviewed") {
                        markReviewed(row)
                    }
                    .buttonStyle(.ghost)
                    .accessibilityIdentifier("review.markReviewed.\(row.cellID)")
                    .accessibilityHint("Record that this finding was reviewed at its current value")
                }
            }
            .width(min: 130, ideal: 150)
        }
        .accessibilityIdentifier("review.matrix")
    }

    private var sourcesInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sources")
                        .font(.supraTitle)
                    if let row = selectedRow {
                        Text(row.finding)
                            .font(.supraCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button(action: closeSources) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.ghost)
                .accessibilityLabel("Close Sources")
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let row = selectedRow, row.valueState == .edited {
                        editedSourcesNotice(row)
                    }
                    evidenceSection(
                        "Supporting evidence",
                        evidence: controller.selectedEvidence.filter { $0.kind == .supporting },
                        emptyMessage: "No supporting evidence is recorded for this finding."
                    )
                    evidenceSection(
                        "Contrary evidence",
                        evidence: controller.selectedEvidence.filter { $0.kind == .contrary },
                        emptyMessage: "No contrary evidence is recorded for this finding."
                    )
                }
                .padding()
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(evidenceRailColor)
                .frame(width: evidenceRailWidth)
        }
        .accessibilityIdentifier("review.sourcesInspector")
    }

    private func editedSourcesNotice(_ row: CaseFileReviewController.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Attorney-edited value", systemImage: "pencil")
                .font(.supraHeadline)
            Text("Sources are frozen from the generated result. They do not validate the attorney-edited value.")
                .font(.supraSubheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("review.sourcesEditedNotice")
            VStack(alignment: .leading, spacing: 2) {
                Text("Generated result")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                Text(row.generatedValue)
                    .font(.supraBody)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("review.sourcesGeneratedValue.\(row.cellID)")
            }
        }
        .padding(12)
        .background(.secondary.opacity(colorScheme == .dark ? 0.12 : 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func evidenceSection(
        _ title: String,
        evidence: [CaseFileReviewController.Evidence],
        emptyMessage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.supraHeadline)
            if evidence.isEmpty {
                Text(emptyMessage)
                    .font(.supraSubheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(evidence) { item in
                    evidenceRow(item)
                    if item.id != evidence.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func evidenceRow(_ evidence: CaseFileReviewController.Evidence) -> some View {
        Button {
            previewModel = controller.preview(evidenceID: evidence.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(evidence.citationLabel)
                            .font(.supraHeadline)
                        Text(evidence.documentName)
                            .font(.supraSubheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(evidence.excerpt)
                        .font(.supraBody)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(5)
                    if !evidence.isAvailable {
                        Label(
                            evidence.unavailableReason ?? "Original source unavailable; frozen excerpt retained.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("review.evidence.\(evidence.id)")
        .accessibilityHint("Open the recorded document revision")
    }

    private var selectedRow: CaseFileReviewController.Row? {
        guard let selectedCellID = controller.selectedCellID else { return nil }
        return controller.rows.first { $0.cellID == selectedCellID }
    }

    private var selectedProject: CaseFileReviewController.Project? {
        guard let selectedProjectID = controller.selectedProjectID else { return nil }
        return controller.projects.first { $0.id == selectedProjectID }
    }

    private var filteredRows: [CaseFileReviewController.Row] {
        controller.rows(matching: activeFilter)
    }

    private var discardNavigationMessage: String {
        let finding = valueEditor?.finding ?? "this finding"
        return "Switching Review Projects will discard the unsaved changes to “\(finding)”."
    }

    private var emptyDescription: String {
        if controller.projects.isEmpty, controller.eligibleOutputs.isEmpty {
            return "Verified exhaustive outputs appear here when their exact source proof is ready."
        }
        if controller.projects.isEmpty {
            return "Open an eligible exhaustive output to review its findings and recorded sources."
        }
        return "This Review Project does not contain any persisted findings."
    }

    private func sourceSummary(_ row: CaseFileReviewController.Row) -> String {
        if row.contrarySourceCount > 0 {
            return "\(row.supportingSourceCount) supporting · \(row.contrarySourceCount) contrary"
        }
        return "\(row.supportingSourceCount) supporting"
    }

    private func reviewedHelp(_ row: CaseFileReviewController.Row) -> String {
        guard let reviewedBy = row.reviewedBy, let reviewedAt = row.reviewedAt else {
            return "Reviewed"
        }
        return "Reviewed by \(reviewedBy) on \(reviewedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func open(_ output: CaseFileReviewController.EligibleOutput) {
        requestNavigation(.openOutput(output))
    }

    private func requestNavigation(_ navigation: PendingReviewNavigation) {
        if case let .selectProject(projectID) = navigation,
           projectID == controller.selectedProjectID {
            return
        }

        if valueEditorIsDirty {
            valueEditor?.isPresented = false
            valueFieldFocused = false
            pendingNavigation = navigation
            discardNavigationPresented = true
            return
        }

        clearValueEditor()
        performNavigation(navigation)
    }

    private func performNavigation(_ navigation: PendingReviewNavigation) {
        switch navigation {
        case let .selectProject(projectID):
            controller.selectProject(projectID)
            if controller.selectedProjectID == projectID {
                activeFilter = .all
                previewModel = nil
            }
        case let .openOutput(output):
            do {
                try controller.openReview(
                    sourceRunID: output.sourceRunID,
                    title: output.title
                )
                activeFilter = .all
                previewModel = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func keepEditingAfterNavigationRequest() {
        pendingNavigation = nil
        resumeValueEditor()
    }

    private func discardAndPerformPendingNavigation() {
        let navigation = pendingNavigation
        pendingNavigation = nil
        clearValueEditor()
        if let navigation {
            performNavigation(navigation)
        }
    }

    private func setFilter(_ filter: CaseFileReviewController.RowFilter) {
        guard filter != activeFilter else { return }
        guard !valueEditorIsDirty else {
            resumeValueEditor()
            return
        }

        clearValueEditor()
        let visibleCellIDs = Set(controller.rows(matching: filter).map(\.cellID))
        if let selectedCellID = controller.selectedCellID,
           !visibleCellIDs.contains(selectedCellID) {
            closeSources()
        }
        activeFilter = filter
    }

    private func reconcileVisibleSelection() {
        guard let selectedCellID = controller.selectedCellID else { return }
        let visibleCellIDs = Set(filteredRows.map(\.cellID))
        if !visibleCellIDs.contains(selectedCellID) {
            closeSources()
        }
    }

    private func filterTitle(_ filter: CaseFileReviewController.RowFilter) -> String {
        switch filter {
        case .all: "All"
        case .needsReview: "Needs review"
        case .edited: "Edited"
        case .evidenceAttention: "Evidence attention"
        }
    }

    private func filterCount(_ filter: CaseFileReviewController.RowFilter) -> Int {
        controller.rows(matching: filter).count
    }

    private func findingCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "finding" : "findings")"
    }

    private func openSources(_ row: CaseFileReviewController.Row) {
        if valueEditorIsDirty {
            resumeValueEditor()
            return
        }
        clearValueEditor()
        controller.selectCell(row.cellID)
    }

    private func markReviewed(_ row: CaseFileReviewController.Row) {
        if valueEditorIsDirty {
            resumeValueEditor()
            return
        }
        do {
            try controller.markReviewed(cellID: row.cellID)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func beginEditing(_ row: CaseFileReviewController.Row) {
        if valueEditorIsDirty {
            resumeValueEditor()
            return
        }

        guard let projectID = controller.selectedProjectID else { return }
        closeSources()
        valueEditor = ValueEditorState(
            projectID: projectID,
            cellID: row.cellID,
            finding: row.finding,
            generatedValue: row.generatedValue,
            currentValue: row.displayValue,
            isEdited: row.valueState == .edited,
            draft: row.displayValue,
            isPresented: true
        )
    }

    private func valueEditorPresented(for cellID: String) -> Binding<Bool> {
        Binding(
            get: {
                valueEditor?.cellID == cellID && valueEditor?.isPresented == true
            },
            set: { isPresented in
                guard valueEditor?.cellID == cellID else { return }
                valueEditor?.isPresented = isPresented
                if !isPresented {
                    valueFieldFocused = false
                    if !valueEditorIsDirty {
                        valueEditor = nil
                    }
                }
            }
        )
    }

    private var valueDraft: Binding<String> {
        Binding(
            get: { valueEditor?.draft ?? "" },
            set: { valueEditor?.draft = $0 }
        )
    }

    private var valueEditorPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let editor = valueEditor {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit value")
                        .font(.supraTitle)
                    Text(editor.finding)
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Generated result")
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                    Text(editor.generatedValue)
                        .font(.supraBody)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("review.valueEditor.generatedValue")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Reviewed value")
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: valueDraft)
                        .font(.supraBody)
                        .frame(minHeight: 72, maxHeight: 120)
                        .padding(5)
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(.separator, lineWidth: 1)
                        }
                        .focused($valueFieldFocused)
                        .accessibilityLabel("Reviewed value")
                        .accessibilityIdentifier("review.valueEditor.field")
                        .onAppear {
                            DispatchQueue.main.async {
                                valueFieldFocused = true
                            }
                        }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sources remain attached to the generated result.")
                    Text("Changing this value—including Use generated value—clears any prior Reviewed mark.")
                }
                .font(.supraCaption)
                .foregroundStyle(.secondary)

                Divider()

                HStack(spacing: 8) {
                    if editor.isEdited {
                        Button("Use generated value") {
                            restoreGeneratedValue(editor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("review.valueEditor.useGenerated")
                    }
                    Spacer()
                    Button("Cancel") {
                        clearValueEditor()
                    }
                    .buttonStyle(.ghost)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("review.valueEditor.cancel")

                    Button("Save changes") {
                        saveValueEditor(editor)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!valueEditorCanSave)
                    .accessibilityIdentifier("review.valueEditor.save")
                }
            }
        }
        .padding(16)
        .frame(width: 430)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.valueEditor")
    }

    private var valueEditorIsDirty: Bool {
        guard let editor = valueEditor else { return false }
        let normalized = editor.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized != editor.currentValue
    }

    private var valueEditorCanSave: Bool {
        guard let editor = valueEditor else { return false }
        let normalized = editor.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized != editor.currentValue
    }

    private func saveValueEditor(_ editor: ValueEditorState) {
        guard editor.projectID == controller.selectedProjectID else {
            actionError = "The selected Review Project changed before this value could be saved."
            return
        }
        do {
            try controller.editValue(cellID: editor.cellID, value: editor.draft)
            clearValueEditor()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func restoreGeneratedValue(_ editor: ValueEditorState) {
        guard editor.projectID == controller.selectedProjectID else {
            actionError = "The selected Review Project changed before this value could be restored."
            return
        }
        do {
            try controller.useGeneratedValue(cellID: editor.cellID)
            clearValueEditor()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func resumeValueEditor() {
        guard valueEditor?.projectID == controller.selectedProjectID else {
            clearValueEditor()
            return
        }
        valueEditor?.isPresented = true
        DispatchQueue.main.async {
            valueFieldFocused = true
        }
    }

    private func clearValueEditor() {
        valueEditor = nil
        valueFieldFocused = false
    }

    private func closeSources() {
        previewModel = nil
        controller.clearSelection()
    }
}

private struct ValueEditorState {
    let projectID: String
    let cellID: String
    let finding: String
    let generatedValue: String
    let currentValue: String
    let isEdited: Bool
    var draft: String
    var isPresented: Bool
}

private enum PendingReviewNavigation {
    case selectProject(String)
    case openOutput(CaseFileReviewController.EligibleOutput)
}
