import SupraCore
import SupraDesignSystem
import SupraSessions
import SwiftUI

/// Human review surface for proposal-only document-family analysis. The narrow
/// queue keeps scan state on the left; immutable evidence and exact actions stay
/// visible together on the right so review never becomes a confidence-only click.
struct DocumentRelationReviewSheet: View {
    @ObservedObject var controller: DocumentRelationReviewController
    let onClose: () -> Void

    @State private var selectedRelationID: String?
    @State private var overrideItem: DocumentRelationReviewItem?

    private var selectedItem: DocumentRelationReviewItem? {
        if let selectedRelationID,
           let selected = controller.items.first(where: { $0.id == selectedRelationID }) {
            return selected
        }
        return controller.items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                queue
                    .frame(width: 280)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 840, minHeight: 540)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("relations.reviewSheet")
        .onAppear {
            controller.reload()
            selectedRelationID = selectedRelationID ?? controller.items.first?.id
        }
        .sheet(item: $overrideItem) { item in
            RelationOverrideSheet(item: item, controller: controller)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Document Relations")
                    .font(.supraTitle)
                Text("Review evidence before any version is treated as operative.")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: onClose)
                .buttonStyle(.ghost)
        }
        .padding(16)
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.pendingReviewCount > 0 {
                Label(
                    "\(controller.pendingReviewCount) block clean version-sensitive results",
                    systemImage: "exclamationmark.shield.fill"
                )
                .font(.supraCaption.weight(.medium))
                .foregroundStyle(.orange)
                .padding(12)
                .accessibilityIdentifier("relations.blocker")
            } else {
                Label("Required review complete", systemImage: "checkmark.shield.fill")
                    .font(.supraCaption.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(12)
                    .accessibilityIdentifier("relations.reviewComplete")
            }
            Divider()
            List(selection: $selectedRelationID) {
                ForEach(controller.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(kindLabel(item.kind))
                                .font(.supraHeadline)
                            Spacer(minLength: 4)
                            stateBadge(item.reviewState)
                        }
                        Text("\(item.fromDocumentName) → \(item.toDocumentName)")
                            .font(.supraCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                    .tag(item.id)
                    .accessibilityLabel("\(kindLabel(item.kind)): \(item.fromDocumentName) to \(item.toDocumentName)")
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(kindLabel(item.kind))
                            .font(.supraTitle)
                        Text(item.fromDocumentName)
                            .font(.supraHeadline)
                        Label(item.toDocumentName, systemImage: "arrow.down")
                            .font(.supraSubheadline)
                            .foregroundStyle(.secondary)
                    }

                    evidenceCard(
                        title: "Proposal evidence",
                        systemImage: "waveform.path.ecg",
                        text: item.evidenceSummary,
                        identifier: "relations.evidence"
                    )
                    evidenceCard(
                        title: "Structural difference",
                        systemImage: "rectangle.split.3x1",
                        text: item.diffSummary,
                        identifier: "relations.diff"
                    )

                    if let auditConfirmation = controller.auditConfirmation {
                        Label(auditConfirmation, systemImage: "checkmark.seal.fill")
                            .font(.supraCaption)
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("relations.auditConfirmation")
                    }
                    if let errorMessage = controller.errorMessage {
                        SupraWarningBanner(.blocking, title: "Review not saved", message: errorMessage)
                    }

                    Divider()
                    HStack(spacing: 10) {
                        Button("Confirm") {
                            _ = try? controller.confirm(relationID: item.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(item.reviewState != .proposed)
                        .accessibilityIdentifier("relations.confirm")

                        Button("Reject", role: .destructive) {
                            _ = try? controller.reject(relationID: item.id)
                        }
                        .buttonStyle(.ghostDanger)
                        .disabled(item.reviewState != .proposed)
                        .accessibilityIdentifier("relations.reject")

                        Button("Override") { overrideItem = item }
                            .buttonStyle(.ghost)
                            .disabled(item.reviewState == .confirmed)
                            .accessibilityIdentifier("relations.override")
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "No Relations",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Relation proposals appear here after document analysis.")
            )
        }
    }

    private func evidenceCard(
        title: String,
        systemImage: String,
        text: String,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.supraHeadline)
            Text(text)
                .font(.supraSubheadline)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func stateBadge(_ state: DocumentRelationReviewState?) -> some View {
        let presentation: (label: String, color: Color) = switch state {
        case .confirmed: ("Confirmed", .green)
        case .rejected: ("Rejected", .secondary)
        default: ("Proposed", .orange)
        }
        Text(presentation.label)
            .font(.supraCaption.weight(.medium))
            .foregroundStyle(presentation.color)
    }

    private func kindLabel(_ kind: DocumentRelationKind?) -> String {
        switch kind {
        case .exactDuplicate: "Exact duplicate"
        case .normalizedDuplicate: "Normalized duplicate"
        case .renderVariant: "Render variant"
        case .nearDuplicate: "Near duplicate"
        case .draftOf: "Draft of"
        case .executedCopyOf: "Executed copy of"
        case .amendmentOf: "Amendment of"
        case .redlineOf: "Redline of"
        case .supersedes: "Supersedes"
        case .exhibitOf: "Exhibit of"
        case .attachmentOf: "Attachment of"
        case nil: "Document relation"
        }
    }
}

private struct RelationOverrideSheet: View {
    let item: DocumentRelationReviewItem
    @ObservedObject var controller: DocumentRelationReviewController
    @Environment(\.dismiss) private var dismiss

    @State private var reverseDirection = true
    @State private var kind = DocumentRelationKind.supersedes

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Override Relation")
                .font(.supraTitle)
            Text("The original proposal will remain rejected in the audit trail. The corrected relation is a new user proposal and is confirmed only when you save.")
                .font(.supraSubheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Relation", selection: $kind) {
                ForEach(DocumentRelationKind.allCases.filter { !$0.isSymmetric }, id: \.self) { kind in
                    Text(kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                        .tag(kind)
                }
            }
            Toggle("Reverse document direction", isOn: $reverseDirection)

            Text(directionSummary)
                .font(.supraCaption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.ghost)
                Spacer()
                Button("Save & Confirm Override") {
                    let from = reverseDirection ? item.relation.toDocumentID : item.relation.fromDocumentID
                    let to = reverseDirection ? item.relation.fromDocumentID : item.relation.toDocumentID
                    let evidence = #"{"schema_version":1,"basis":"user_review_override"}"#
                    if (try? controller.createAndConfirmOverride(
                        replacingRelationID: item.id,
                        fromDocumentID: from,
                        toDocumentID: to,
                        kind: kind,
                        evidenceJSON: evidence
                    )) != nil {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("relations.saveOverride")
            }
        }
        .padding(20)
        .frame(width: 480)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("relations.overrideSheet")
    }

    private var directionSummary: String {
        let from = reverseDirection ? item.toDocumentName : item.fromDocumentName
        let to = reverseDirection ? item.fromDocumentName : item.toDocumentName
        return "\(from) → \(to)"
    }
}
