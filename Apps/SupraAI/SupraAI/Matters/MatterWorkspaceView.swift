import Foundation
import SupraSessions
import SwiftUI

/// The workspace for a single matter: a detail header plus the matter tab set
/// (Chat, Research, Authorities, Outputs, Documents, and Audit). Audit is placed
/// last as the least frequently used tab.
struct MatterWorkspaceView: View {
    @ObservedObject var controller: MattersController
    @ObservedObject var library: ModelLibrary
    @ObservedObject var queue: DocumentProcessingQueue
    @ObservedObject var settings: SettingsController
    let matter: MatterSummary

    @State private var tab: MatterTab = .chat
    @State private var showEditor = false
    @State private var confirmingDelete = false
    @State private var showDraftSheet = false
    @State private var lastUITestTabCommand: String?
    /// Set when an action outside the Research tab (the Authorities "New Research
    /// Session" button) wants the planner to open as the Research tab appears.
    @State private var autoOpenResearchPlanner = false

    enum MatterTab: String, CaseIterable, Identifiable {
        case chat = "Chat"
        case research = "Research"
        case authorities = "Authorities"
        case outputs = "Outputs"
        case documents = "Documents"
        case billing = "Billing"
        case audit = "Audit"

        var id: String { rawValue }
        var label: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showEditor) {
            MatterEditorSheet(
                mode: .edit,
                draft: controller.draft(forMatter: matter.id) ?? MatterDraft()
            ) { draft in
                try? controller.updateMatter(id: matter.id, draft: draft)
            }
        }
        .sheet(isPresented: $showDraftSheet) {
            if let drafting = controller.draftingController {
                MatterDraftingView(controller: drafting, library: library, matterID: matter.id, matterName: matter.name)
            }
        }
        .confirmationDialog(
            "Delete “\(matter.name)”?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Matter", role: .destructive) { controller.deleteMatter(id: matter.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This hides the matter and its chats. You can't undo this from the app.")
        }
        .task { await pollUITestTabCommand() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(matter.name).font(.supraTitle)
                Text(matterSubtitle)
                    .font(.supraSubheadline)
                    .foregroundStyle(.secondary)
                if let detail = matterClientDetail {
                    Text(detail)
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if controller.draftingController != nil {
                Button { showDraftSheet = true } label: { Label("Draft", systemImage: "doc.badge.plus") }
                    .buttonStyle(.ghost)
            }
            Button { showEditor = true } label: { Label("Edit", systemImage: "pencil") }
                .buttonStyle(.ghost)
            Button(role: .destructive) { confirmingDelete = true } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.ghostDanger)
        }
        .padding()
    }

    private var matterSubtitle: String {
        var parts = [matter.jurisdiction]
        if let court = matter.court?.trimmingCharacters(in: .whitespacesAndNewlines), !court.isEmpty {
            parts.append(court)
        }
        parts.append(matter.partyPerspective.rawValue.capitalized)
        return parts.joined(separator: " · ")
    }

    private var matterClientDetail: String? {
        var parts: [String] = []
        if let clientNames = matter.clientNames?.trimmingCharacters(in: .whitespacesAndNewlines), !clientNames.isEmpty {
            parts.append(clientNames)
        }
        if let internalID = matter.internalMatterID?.trimmingCharacters(in: .whitespacesAndNewlines), !internalID.isEmpty {
            parts.append("ID \(internalID)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var tabBar: some View {
        HStack {
            Spacer(minLength: 0)
            GhostSegmentedControl(
                selection: $tab,
                segments: MatterTab.allCases.map { ($0, $0.label, "matterTab.\($0.rawValue)") }
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    @MainActor
    private func pollUITestTabCommand() async {
        guard AppEnvironment.isUITestMode,
              let path = ProcessInfo.processInfo.environment["SUPRA_UI_TEST_TAB_COMMAND_FILE"],
              !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        while !Task.isCancelled {
            let rawValue = (try? String(contentsOf: url, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let rawValue, !rawValue.isEmpty, rawValue != lastUITestTabCommand {
                lastUITestTabCommand = rawValue
                if let target = MatterTab(rawValue: rawValue) {
                    tab = target
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .chat:
            if let chatController = controller.chatController {
                GlobalChatsView(controller: chatController, library: library, settings: settings, listStyle: .inline)
            } else {
                placeholder("Chat unavailable", "Select the matter again to load its chats.", systemImage: "bubble.left.and.bubble.right")
            }
        case .research:
            if let research = controller.researchController {
                MatterResearchView(
                    controller: research,
                    library: library,
                    matter: matter,
                    autoOpenPlanner: $autoOpenResearchPlanner
                )
            } else {
                placeholder(
                    "Research unavailable",
                    "Select the matter again to load its research sessions.",
                    systemImage: "magnifyingglass"
                )
            }
        case .authorities:
            if let authorities = controller.authoritiesController {
                MatterAuthoritiesView(
                    controller: authorities,
                    documentsController: controller.documentsController,
                    library: library,
                    onNewResearch: {
                        autoOpenResearchPlanner = true
                        tab = .research
                    },
                    onShowDocuments: { tab = .documents }
                )
            } else {
                placeholder(
                    "Authorities unavailable",
                    "Select the matter again to load its authority library.",
                    systemImage: "books.vertical"
                )
            }
        case .outputs:
            if let outputs = controller.outputsController {
                MatterOutputsView(controller: outputs, library: library, matter: matter)
            } else {
                placeholder(
                    "Outputs unavailable",
                    "Select the matter again to load its structured outputs.",
                    systemImage: "doc.text"
                )
            }
        case .billing:
            if let billingProfile = controller.billingProfileController {
                MatterBillingView(controller: billingProfile)
            } else {
                placeholder(
                    "Billing unavailable",
                    "Select the matter again to load its billing rules.",
                    systemImage: "dollarsign.square"
                )
            }
        case .audit:
            auditTab
        case .documents:
            if let documents = controller.documentsController {
                MatterDocumentsView(
                    controller: documents,
                    queue: queue,
                    library: library,
                    qaController: controller.documentQAController,
                    chronologyController: controller.documentChronologyController
                )
            } else {
                placeholder(
                    "Documents unavailable",
                    "Select the matter again to load its documents.",
                    systemImage: "doc.on.doc"
                )
            }
        }
    }

    @ViewBuilder
    private var auditTab: some View {
        MatterTabScaffold("Activity Log") {
            let entries = controller.auditEntries(forMatter: matter.id)
            if entries.isEmpty {
                placeholder("No Activity Yet", "Matter, research, authority, and output actions are logged here.", systemImage: "list.bullet.rectangle")
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(auditEventLabel(entry.eventType)).font(.supraHeadline)
                            Spacer()
                            Text(entry.timestamp, format: .dateTime.month().day().hour().minute())
                                .font(.supraCaption)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.summary).font(.supraCaption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func placeholder(_ title: String, _ message: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func auditEventLabel(_ eventType: String) -> String {
        switch eventType {
        case "matter_created": "Matter Created"
        case "matter_updated": "Matter Updated"
        case "chat_moved_to_matter": "Chat Moved Into Matter"
        case "research_queries_approved": "Research Queries Approved"
        case "courtlistener_search_started": "CourtListener Search Started"
        case "authority_status_changed": "Authority Status Changed"
        case "authority_soft_deleted": "Authority Removed"
        case "structured_output_created": "Structured Output Created"
        case "structured_output_repaired": "Structured Output Repaired"
        case "qa_generated": "Document Q&A Generated"
        case "chronology_generated": "Chronology Generated"
        case "document_import_started": "Document Import Started"
        case "document_job_failed": "Document Job Failed"
        case "document_ocr_completed": "Document OCR Completed"
        case "document_ocr_failed": "Document OCR Failed"
        case "semantic_indexing_completed": "Semantic Indexing Completed"
        case "text_indexing_completed": "Text Indexing Completed"
        case "folder_soft_deleted": "Folder Moved to Trash"
        case "folder_restored": "Folder Restored"
        case "document_soft_deleted": "Document Moved to Trash"
        case "document_restored": "Document Restored"
        case "document_permanently_deleted": "Document Permanently Deleted"
        case "document_intelligence_setup_changed": "Document Intelligence Setup Changed"
        case "document_intelligence_setup_completed": "Document Intelligence Setup Completed"
        case "document_intelligence_setup_invalidated": "Document Intelligence Setup Invalidated"
        case "m3_validation_completed": "Milestone 3 Validation Completed"
        case "export_completed": "Export Completed"
        case "billing_draft_generated": "Billing Draft Generated"
        case "legal_model_route": "Model Route Used"
        default:
            eventType
                .split(separator: "_")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }
}

/// Uniform chrome for a matter's list-style tabs (Research, Authorities, Outputs,
/// Audit): a title row with optional trailing actions, a divider, and a content
/// area that fills the remaining height — so empty states stay centered instead of
/// floating in the middle of the pane.
struct MatterTabScaffold<Actions: View, Content: View>: View {
    private let title: String
    private let actions: Actions
    private let content: Content

    init(
        _ title: String,
        @ViewBuilder actions: () -> Actions = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                actions
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
