import AppKit
import SupraSessions
import SwiftUI
import UniformTypeIdentifiers

/// The matter's Authorities tab: the saved-authority library with drill-in to a
/// detail editor (spec §11).
struct MatterAuthoritiesView: View {
    @ObservedObject var controller: AuthoritiesController
    /// The matter's documents controller, so research uploaded here flows through
    /// the existing import → OCR → chunk → embed pipeline and becomes queryable.
    var documentsController: MatterDocumentsController?
    var onNewResearch: () -> Void = {}
    var onShowDocuments: () -> Void = {}
    @State private var pendingDelete: AuthoritiesController.AuthorityItem?
    @State private var importBanner: String?

    var body: some View {
        NavigationStack {
            MatterTabScaffold("Authorities") {
                Button { importResearch() } label: {
                    Label("Import Research", systemImage: "square.and.arrow.down")
                }
                .help("Import your own research (PDF, Word, RTF, or text). It's indexed for Ask Documents in the Documents tab.")
                .accessibilityIdentifier("authorities.importResearch.header")
                Button { onNewResearch() } label: {
                    Label("New Research Session", systemImage: "plus")
                }
                .accessibilityIdentifier("authorities.newResearch.header")
            } content: {
                VStack(spacing: 0) {
                    if let importBanner {
                        importBannerView(importBanner)
                    }
                    authoritiesContent
                }
            }
            .navigationDestination(for: String.self) { id in
                AuthorityDetailView(controller: controller, authorityID: id)
            }
        }
        .confirmationDialog(
            pendingDelete.map { "Remove “\($0.caseName)”?" } ?? "Remove authority?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Remove Authority", role: .destructive) {
                if let authority = pendingDelete { controller.deleteAuthority(id: authority.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes it from the matter's authority library. You can re-add it by saving the result again from Research.")
        }
        .onAppear { controller.load() }
    }

    @ViewBuilder
    private var authoritiesContent: some View {
        if controller.authorities.isEmpty {
            ContentUnavailableView {
                Label("No Authorities Saved", systemImage: "books.vertical")
            } description: {
                Text("Save reviewed CourtListener results, or import your own research, to build this matter's library.")
            } actions: {
                Button("Import Research") { importResearch() }
                Button("New Research Session") { onNewResearch() }
                    .accessibilityIdentifier("authorities.newResearch")
            }
            .accessibilityIdentifier("authorities.empty")
        } else {
            List(controller.authorities) { authority in
                NavigationLink(value: authority.id) { row(authority) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = authority } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) { pendingDelete = authority } label: {
                            Label("Delete Authority", systemImage: "trash")
                        }
                    }
            }
        }
    }

    private func importBannerView(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.callout)
            Spacer()
            Button("Open Documents") { onShowDocuments() }
                .buttonStyle(.link)
            Button { importBanner = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.1))
    }

    /// Picks research files and runs them through the matter's document pipeline
    /// (import → OCR/extract → chunk → embed), so the model can RAG over them via
    /// "Ask Documents". Respects the Document Intelligence setup gate.
    private func importResearch() {
        guard let documentsController else { return }
        guard documentsController.setupReady else {
            importBanner = "Finish Document Intelligence setup in Settings before importing research."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.researchContentTypes
        panel.prompt = "Import"
        panel.message = "Choose research files (PDF, Word, RTF, or text) to index for this matter"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        documentsController.importResearchDocuments(panel.urls)
        let count = panel.urls.count
        importBanner = "Importing \(count) research file\(count == 1 ? "" : "s") into the “Research” folder — track progress and ask questions in the Documents tab."
    }

    private static let researchContentTypes: [UTType] = {
        var types: [UTType] = [.pdf, .rtf, .plainText, .text]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        if let doc = UTType(filenameExtension: "doc") { types.append(doc) }
        return types
    }()

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func row(_ authority: AuthoritiesController.AuthorityItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(authority.caseName).font(.body.weight(.medium))
            HStack(spacing: 8) {
                if let citation = authority.preferredCitation ?? authority.citations.first { Text(citation) }
                if let court = authority.court { Text(court) }
                if let date = authority.dateFiled { Text(date, format: .dateTime.year().month().day()) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ReviewBadge(state: authority.reviewState)
                Text(authority.useStatus.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
