import SupraCore
import SupraSessions
import SwiftUI

/// Compact setup for one fixed-matrix Review. The source ledger is deliberately
/// visible before submission so counsel can see exactly what will and will not
/// enter the frozen local corpus.
struct CaseFileReviewCreationSheet: View {
    private enum ScopeChoice: String, CaseIterable {
        case all
        case selected
    }

    @ObservedObject var controller: CaseFileReviewCreationController
    let models: [ModelSummary]
    let hardwareProfile: MacHardwareProfile
    @Binding var isPresented: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var projectName = ""
    @State private var instruction = ""
    @State private var scopeChoice: ScopeChoice = .all
    @State private var selectedDocumentIDs = Set<String>()
    @State private var selectedModelID: String?
    @State private var wholeMatterPreview: CaseFileReviewCreationController.ScopePreview?
    @State private var errorMessage: String?
    @State private var scopeChangedNotice: String?
    @State private var isSubmitting = false
    @State private var submissionTask: Task<Void, Never>?

    private var ledgerAccent: Color {
        colorScheme == .dark
            ? Color(red: 210.0 / 255.0, green: 172.0 / 255.0, blue: 92.0 / 255.0)
            : Color(red: 167.0 / 255.0, green: 121.0 / 255.0, blue: 32.0 / 255.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("New Review")
                        .font(.supraTitle)
                    Text("Freeze an exact source set and build a reviewable finding matrix.")
                        .font(.supraSubheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    setupFields
                    scopeLedger
                    matrixPreview
                    executionDisclosure
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 10) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.supraCaption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer()
                }

                Button("Cancel") { cancelSubmissionAndDismiss() }
                    .buttonStyle(.ghost)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("review.creation.dismiss")
                Button(isSubmitting ? "Verifying model…" : "Start Review") {
                    startReview()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
                .accessibilityIdentifier("review.creation.start")
            }
            .padding(16)
        }
        .frame(width: 760)
        .frame(minHeight: 620, idealHeight: 680, maxHeight: 760)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.creation.sheet")
        .onAppear {
            if selectedModelID == nil {
                selectedModelID = models.first?.id
            }
            refreshWholeMatterPreview()
        }
        .onDisappear {
            cancelSubmission()
        }
    }

    private var setupFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow(alignment: .firstTextBaseline) {
                Text("Name")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                TextField("Lease renewal review", text: $projectName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name")
                    .accessibilityIdentifier("review.creation.name")
            }

            GridRow(alignment: .top) {
                Text("Review for")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                    .padding(.top, 7)
                TextEditor(text: $instruction)
                    .font(.supraBody)
                    .frame(minHeight: 68, maxHeight: 96)
                    .padding(5)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.separator, lineWidth: 1)
                    }
                    .accessibilityLabel("Review instruction")
                    .accessibilityIdentifier("review.creation.instruction")
            }

            GridRow(alignment: .center) {
                Text("Managed local model")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                if models.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("No managed local model", systemImage: "exclamationmark.triangle")
                            .font(.supraSubheadline)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("review.creation.model")
                        modelHardwareAdvisory
                    }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Picker("", selection: $selectedModelID) {
                            ForEach(models) { model in
                                Text("\(model.displayName) · Managed")
                                    .tag(Optional(model.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 360, alignment: .leading)
                        .accessibilityLabel("Managed local model")
                        .accessibilityValue(selectedModelLabel)
                        .accessibilityIdentifier("review.creation.model")

                        modelHardwareAdvisory
                    }
                }
            }
        }
    }

    private var modelHardwareAdvisory: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hardwareProfileText)
                .font(.supraCaption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("review.creation.hardware")
            Text(selectedModelFitExplanation)
                .font(.supraCaption)
                .foregroundStyle(selectedModelFitIsCaution ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("review.creation.modelFit")
        }
    }

    private var hardwareProfileText: String {
        let gibibytes = hardwareProfile.physicalMemoryBytes / 1_073_741_824
        return "\(gibibytes) GB unified memory"
    }

    private var selectedModelFit: ModelFitAssessment? {
        guard let selectedModelID,
              let model = models.first(where: { $0.id == selectedModelID }),
              let repositoryID = model.managedRepositoryID else { return nil }
        return LocalAIRecommendationPolicy.fitAssessment(
            textRepoID: repositoryID,
            profile: hardwareProfile
        )
    }

    private var selectedModelFitExplanation: String {
        selectedModelFit?.explanation
            ?? "Fit unknown — this model has no verified hardware metadata."
    }

    private var selectedModelFitIsCaution: Bool {
        selectedModelFit?.level == .caution
    }

    private var scopeLedger: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text("Source scope")
                    .font(.supraHeadline)
                Spacer()
                HStack(spacing: 4) {
                    scopeButton("All ready documents", choice: .all)
                        .accessibilityIdentifier("review.creation.scope.all")
                    scopeButton("Selected documents", choice: .selected)
                        .accessibilityIdentifier("review.creation.scope.selected")
                }
            }

            if let preview = wholeMatterPreview {
                if let scopeChangedNotice {
                    Label(scopeChangedNotice, systemImage: "arrow.clockwise")
                        .font(.supraCaption)
                        .foregroundStyle(.orange)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("review.creation.scopeChanged")
                }

                if scopeChoice == .all {
                    Text("\(preview.eligibleCount) eligible · \(preview.excludedCount) excluded")
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("review.creation.scopeSummary")
                } else {
                    Text(selectedScopeSummary)
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("review.creation.selectedSummary")
                }

                VStack(spacing: 0) {
                    ForEach(Array(preview.members.enumerated()), id: \.element.memberKey) { index, member in
                        sourceRow(member)
                        if index < preview.members.count - 1 {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
                .background(.secondary.opacity(colorScheme == .dark ? 0.10 : 0.055))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(ledgerAccent)
                        .frame(width: 3)
                }
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.supraSubheadline)
                    .foregroundStyle(.orange)
            } else {
                ProgressView("Inspecting exact source scope…")
                    .controlSize(.small)
            }
        }
    }

    private func scopeButton(_ title: String, choice: ScopeChoice) -> some View {
        Button {
            scopeChoice = choice
            errorMessage = nil
            scopeChangedNotice = nil
        } label: {
            Text(title)
                .font(.supraCaption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    scopeChoice == choice
                        ? Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(scopeChoice == choice ? .isSelected : [])
    }

    @ViewBuilder
    private func sourceRow(_ member: CorpusAnalysisSnapshotMember) -> some View {
        let documentID = member.documentID
        let isEligible = member.disposition == .eligible
        let selected = documentID.map { selectedDocumentIDs.contains($0) } == true
        let selectable = scopeChoice == .selected && isEligible && documentID != nil

        if scopeChoice == .selected {
            Button {
                guard selectable, let documentID else { return }
                if selected {
                    selectedDocumentIDs.remove(documentID)
                } else {
                    selectedDocumentIDs.insert(documentID)
                }
                errorMessage = nil
                scopeChangedNotice = nil
            } label: {
                sourceRowContents(
                    member,
                    isEligible: isEligible,
                    selected: selected,
                    selectable: selectable
                )
            }
            .buttonStyle(.plain)
            .disabled(!selectable)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(sourceAccessibilityLabel(member))
            .accessibilityValue(
                selectable ? (selected ? "Selected" : "Not selected") : "Unavailable"
            )
            .modifier(SourceAccessibilityIdentifier(member: member))
        } else {
            sourceRowContents(
                member,
                isEligible: isEligible,
                selected: selected,
                selectable: false
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(sourceAccessibilityLabel(member))
            .modifier(SourceAccessibilityIdentifier(member: member))
        }
    }

    private func sourceRowContents(
        _ member: CorpusAnalysisSnapshotMember,
        isEligible: Bool,
        selected: Bool,
        selectable: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: sourceIcon(
                    isEligible: isEligible,
                    isSelected: selected,
                    selectable: selectable
            ))
            .foregroundStyle(isEligible ? Color.green : Color.secondary)
            .frame(width: 16)

            Text(member.displayName)
                .font(.supraSubheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 12)

            if let reason = member.reason {
                Text(reasonLabel(reason))
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Ready")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var matrixPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review Matrix")
                .font(.supraHeadline)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    matrixColumn("Finding", width: geometry.size.width * 0.30)
                    matrixColumn("Generated value", width: geometry.size.width * 0.32)
                    matrixColumn("Sources", width: geometry.size.width * 0.22)
                    matrixColumn("Review", width: geometry.size.width * 0.16)
                }
            }
            .frame(height: 34)
            .background(.secondary.opacity(colorScheme == .dark ? 0.12 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review.creation.columnPreview")
        }
    }

    private func matrixColumn(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.supraCaption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(width: width, height: 34, alignment: .leading)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }

    private var executionDisclosure: some View {
        Label(
            "Exact frozen corpus · Local model · runs in background",
            systemImage: "lock.shield"
        )
        .font(.supraCaption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("review.creation.disclosure")
    }

    private var selectedModelLabel: String {
        guard let selectedModelID,
              let model = models.first(where: { $0.id == selectedModelID }) else {
            return "No managed local model"
        }
        return "\(model.displayName) · Managed"
    }

    private var selectedScopeSummary: String {
        let eligibleNames = wholeMatterPreview?.members.compactMap { member -> String? in
            guard member.disposition == .eligible,
                  let documentID = member.documentID,
                  selectedDocumentIDs.contains(documentID) else { return nil }
            return member.displayName
        } ?? []
        guard !eligibleNames.isEmpty else { return "0 eligible selected" }
        return "\(eligibleNames.count) eligible · \(eligibleNames.joined(separator: ", "))"
    }

    private var selectedEligibleCount: Int {
        wholeMatterPreview?.members.count { member in
            member.disposition == .eligible
                && member.documentID.map { selectedDocumentIDs.contains($0) } == true
        } ?? 0
    }

    private var canStart: Bool {
        !isSubmitting
            && !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedModelID?.isEmpty == false
            && wholeMatterPreview?.eligibleCount ?? 0 > 0
            && (scopeChoice == .all || selectedEligibleCount > 0)
    }

    private func refreshWholeMatterPreview() {
        do {
            let preview = try controller.inspectScope(scope: .wholeMatter)
            wholeMatterPreview = preview
            let eligibleDocumentIDs = Set(preview.members.compactMap { member -> String? in
                guard member.disposition == .eligible else { return nil }
                return member.documentID
            })
            selectedDocumentIDs.formIntersection(eligibleDocumentIDs)
            errorMessage = nil
        } catch {
            wholeMatterPreview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func startReview() {
        guard canStart,
              let selectedModelID,
              let uuid = UUID(uuidString: selectedModelID) else { return }
        isSubmitting = true
        errorMessage = nil
        let scope = scopeChoice == .all
            ? CorpusAnalysisScope.wholeMatter
            : CorpusAnalysisScope(
                schemaVersion: 1,
                documentIDs: selectedDocumentIDs.sorted()
            )
        guard let expectedScopePreview = expectedScopePreview(for: scope) else {
            isSubmitting = false
            return
        }
        let task = Task { @MainActor in
            do {
                _ = try await controller.startReview(
                    projectName: projectName,
                    instruction: instruction,
                    scope: scope,
                    expectedScopePreview: expectedScopePreview,
                    modelID: ModelID(uuid)
                )
                try Task.checkCancellation()
                submissionTask = nil
                isPresented = false
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                submissionTask = nil
                if error as? CaseFileReviewCreationError == .scopeChanged {
                    refreshWholeMatterPreview()
                    scopeChangedNotice =
                        "Source scope changed. Review the updated receipt, then start again."
                    isSubmitting = false
                    return
                }
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
        submissionTask = task
    }

    private func expectedScopePreview(
        for scope: CorpusAnalysisScope
    ) -> CaseFileReviewCreationController.ScopePreview? {
        guard let wholeMatterPreview else { return nil }
        guard scopeChoice == .selected else { return wholeMatterPreview }
        let selectedMembers = wholeMatterPreview.members.filter { member in
            member.disposition == .eligible
                && member.documentID.map { selectedDocumentIDs.contains($0) } == true
        }
        return CaseFileReviewCreationController.ScopePreview(
            scope: scope,
            members: selectedMembers
        )
    }

    private func cancelSubmissionAndDismiss() {
        cancelSubmission()
        isPresented = false
    }

    private func cancelSubmission() {
        submissionTask?.cancel()
        submissionTask = nil
        isSubmitting = false
    }

    private func sourceIcon(
        isEligible: Bool,
        isSelected: Bool,
        selectable: Bool
    ) -> String {
        if selectable { return isSelected ? "checkmark.square.fill" : "square" }
        return isEligible ? "checkmark.circle.fill" : "minus.circle"
    }

    private func reasonLabel(_ reason: String) -> String {
        if isUnfinishedImportReason(reason) { return "Import unfinished" }
        return switch reason {
        case "review_required": "Review required"
        case "extraction_failed": "Extraction failed"
        case "selected_document_unavailable": "Unavailable"
        default: reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func sourceAccessibilityLabel(_ member: CorpusAnalysisSnapshotMember) -> String {
        if let reason = member.reason {
            return "\(member.displayName) — \(reasonLabel(reason))"
        }
        return "\(member.displayName) — Ready"
    }
}

private struct SourceAccessibilityIdentifier: ViewModifier {
    let member: CorpusAnalysisSnapshotMember

    @ViewBuilder
    func body(content: Content) -> some View {
        if let reason = member.reason {
            if isUnfinishedImportReason(reason) {
                content.accessibilityIdentifier("review.creation.excluded.importUnfinished")
            } else {
                switch reason {
                case "review_required":
                    content.accessibilityIdentifier("review.creation.excluded.reviewRequired")
                case "extraction_failed":
                    content.accessibilityIdentifier("review.creation.excluded.extractionFailed")
                default:
                    content.accessibilityIdentifier("review.creation.excluded.\(member.memberKey)")
                }
            }
        } else if let documentID = member.documentID {
            content.accessibilityIdentifier("review.creation.document.\(documentID)")
        } else {
            content
        }
    }
}

private func isUnfinishedImportReason(_ reason: String) -> Bool {
    switch reason.lowercased() {
    case "selected", "discovered", "validated", "copying", "interrupted",
         "import interrupted before completion.":
        true
    default:
        false
    }
}

/// Durable status for the most recent Guided Review. This remains in the
/// workbench after setup closes, keeping background work visible and actionable.
struct CaseFileReviewCreationRunCard: View {
    let run: CaseFileReviewCreationController.Run
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onOpenResults: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var railColor: Color {
        colorScheme == .dark
            ? Color(red: 210.0 / 255.0, green: 172.0 / 255.0, blue: 92.0 / 255.0)
            : Color(red: 167.0 / 255.0, green: 121.0 / 255.0, blue: 32.0 / 255.0)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(run.title)
                        .font(.supraHeadline)
                        .lineLimit(1)
                        .accessibilityIdentifier("review.creation.runTitle")
                    Text(run.statusLabel)
                        .font(.supraCaption)
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.11))
                        .clipShape(Capsule())
                        .accessibilityIdentifier("review.creation.status")
                }
                Text(run.instruction)
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("review.creation.runInstruction")
                HStack(spacing: 8) {
                    Text("\(run.progressLabel) resolved")
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("review.creation.progress")
                    if let queuePosition = run.queuePosition, run.state == .queued {
                        Text("Queue \(queuePosition + 1)")
                            .font(.supraCaption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let detail = run.detail {
                    Text(detail)
                        .font(.supraCaption)
                        .foregroundStyle(run.state == .failed ? .orange : .secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if run.availableActions.contains(.pause) {
                    Button("Pause", action: onPause)
                        .buttonStyle(.ghost)
                        .accessibilityIdentifier("review.creation.pause")
                }
                if run.availableActions.contains(.resume) {
                    Button("Resume", action: onResume)
                        .buttonStyle(.ghost)
                        .accessibilityIdentifier("review.creation.resume")
                }
                if run.availableActions.contains(.cancel) {
                    Button("Cancel", role: .destructive, action: onCancel)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("review.creation.cancel")
                }
                if run.availableActions.contains(.openResults) {
                    Button("Open results", action: onOpenResults)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("review.creation.openResults")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.secondary.opacity(colorScheme == .dark ? 0.10 : 0.055))
        .overlay(alignment: .leading) {
            Rectangle().fill(railColor).frame(width: 3)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.creation.run")
    }

    private var statusColor: Color {
        switch run.state {
        case .failed: .orange
        case .cancelled: .secondary
        case .finished: .green
        case .paused: railColor
        default: .accentColor
        }
    }
}
