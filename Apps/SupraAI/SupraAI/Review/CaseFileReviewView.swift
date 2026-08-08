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
                valueEditor = nil
            }
        }
        .onChange(of: controller.selectedProjectID) { _, _ in
            valueEditor = nil
            valueFieldFocused = false
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
                        set: { controller.selectProject($0) }
                    )
                ) {
                    ForEach(controller.projects) { project in
                        Text(project.title).tag(project.id)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .accessibilityLabel("Review Project")
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
                Table(
                    controller.rows,
                    selection: Binding(
                        get: { controller.selectedCellID },
                        set: { cellID in
                            if let cellID {
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
                            valueEditor = nil
                            controller.selectCell(row.cellID)
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
        }
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
        do {
            try controller.openReview(
                sourceRunID: output.sourceRunID,
                title: output.title
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func markReviewed(_ row: CaseFileReviewController.Row) {
        do {
            try controller.markReviewed(cellID: row.cellID)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func beginEditing(_ row: CaseFileReviewController.Row) {
        closeSources()
        valueEditor = ValueEditorState(
            cellID: row.cellID,
            finding: row.finding,
            generatedValue: row.generatedValue,
            currentValue: row.displayValue,
            isEdited: row.valueState == .edited,
            draft: row.displayValue
        )
    }

    private func valueEditorPresented(for cellID: String) -> Binding<Bool> {
        Binding(
            get: { valueEditor?.cellID == cellID },
            set: { isPresented in
                if !isPresented, valueEditor?.cellID == cellID {
                    valueEditor = nil
                    valueFieldFocused = false
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
                        valueEditor = nil
                        valueFieldFocused = false
                    }
                    .buttonStyle(.ghost)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("review.valueEditor.cancel")

                    Button("Save changes") {
                        saveValueEditor(editor)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!valueEditorHasChanges)
                    .accessibilityIdentifier("review.valueEditor.save")
                }
            }
        }
        .padding(16)
        .frame(width: 430)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.valueEditor")
    }

    private var valueEditorHasChanges: Bool {
        guard let editor = valueEditor else { return false }
        let normalized = editor.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized != editor.currentValue
    }

    private func saveValueEditor(_ editor: ValueEditorState) {
        do {
            try controller.editValue(cellID: editor.cellID, value: editor.draft)
            valueEditor = nil
            valueFieldFocused = false
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func restoreGeneratedValue(_ editor: ValueEditorState) {
        do {
            try controller.useGeneratedValue(cellID: editor.cellID)
            valueEditor = nil
            valueFieldFocused = false
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func closeSources() {
        previewModel = nil
        controller.clearSelection()
    }
}

private struct ValueEditorState {
    let cellID: String
    let finding: String
    let generatedValue: String
    let currentValue: String
    let isEdited: Bool
    var draft: String
}
