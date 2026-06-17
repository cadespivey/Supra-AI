import SupraCore
import SupraSessions
import SupraStore
import SwiftUI
import UniformTypeIdentifiers

/// The matter Documents tab (Milestone 3 WO 39): folder list, document list with
/// processing status, import (picker + drag-and-drop), tags, search, trash, and
/// live job progress. Import is gated on completed Document Intelligence setup.
struct MatterDocumentsView: View {
    @ObservedObject var controller: MatterDocumentsController
    @ObservedObject var queue: DocumentProcessingQueue

    @State private var showImporter = false
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var showTrash = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if !controller.setupReady {
                setupBanner
            }
            jobProgress
            HSplitView {
                folderSidebar
                    .frame(minWidth: 200, maxWidth: 280)
                mainContent
                    .frame(minWidth: 360)
            }
        }
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: controller.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result { controller.importItems(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay(alignment: .top) {
            if dropTargeted {
                Text("Drop files to import")
                    .padding(8).background(.thinMaterial, in: Capsule()).padding(.top, 8)
            }
        }
        .sheet(isPresented: $showTrash) { trashSheet }
        .onAppear { controller.reload() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            TextField("Search documents", text: $controller.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { controller.runSearch() }
            Button { controller.runSearch() } label: { Image(systemName: "magnifyingglass") }
            Button { showNewFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            Button { showImporter = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .disabled(!controller.setupReady)
            Button { showTrash = true } label: { Label("Trash", systemImage: "trash") }
        }
    }

    // MARK: - Sidebar

    private var folderSidebar: some View {
        List(selection: $controller.selectedFolderID) {
            Label("All Documents", systemImage: "tray.full").tag(String?.none)
            Section("Folders") {
                ForEach(controller.folders) { folder in
                    Label(folder.name, systemImage: "folder").tag(String?.some(folder.id))
                        .contextMenu {
                            Button("Delete Folder", role: .destructive) { controller.deleteFolder(id: folder.id) }
                        }
                }
            }
        }
        .popover(isPresented: $showNewFolder) {
            VStack(alignment: .leading) {
                Text("New Folder").font(.headline)
                TextField("Folder name", text: $newFolderName)
                    .frame(width: 220)
                HStack {
                    Spacer()
                    Button("Create") {
                        controller.createFolder(name: newFolderName, parentFolderID: controller.selectedFolderID)
                        newFolderName = ""
                        showNewFolder = false
                    }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if !controller.searchText.isEmpty, !controller.searchHits.isEmpty {
            searchResults
        } else {
            documentList
        }
    }

    private var documentList: some View {
        Group {
            if controller.visibleDocuments.isEmpty {
                ContentUnavailableView(
                    "No Documents",
                    systemImage: "doc.on.doc",
                    description: Text(controller.setupReady ? "Import files or drag them here." : "Complete Document Intelligence setup to import.")
                )
            } else {
                List {
                    ForEach(controller.visibleDocuments) { doc in
                        documentRow(doc)
                        ForEach(controller.childAttachments(of: doc.id)) { child in
                            documentRow(child).padding(.leading, 20)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func documentRow(_ doc: MatterDocumentRecord) -> some View {
        HStack {
            Image(systemName: doc.parentDocumentID == nil ? "doc.text" : "paperclip")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.displayName).lineLimit(1)
                HStack(spacing: 6) {
                    statusBadge(doc.status)
                    if let summary = doc.ocrConfidenceSummary {
                        Text(summary).font(.caption2).foregroundStyle(.orange)
                    }
                    ForEach(controller.tags(forDocument: doc.id)) { tag in
                        Text(tag.name).font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
            Spacer()
            Menu {
                ForEach(controller.tags) { tag in
                    Button {
                        controller.toggleTag(tag.id, on: doc.id)
                    } label: {
                        Label(tag.name, systemImage: controller.tags(forDocument: doc.id).contains { $0.id == tag.id } ? "checkmark" : "")
                    }
                }
                if controller.tags.isEmpty { Text("No tags yet").foregroundStyle(.secondary) }
            } label: {
                Image(systemName: "tag")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button(role: .destructive) { controller.softDelete(documentID: doc.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private var searchResults: some View {
        List(controller.searchHits) { hit in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(hit.documentName).font(.callout.weight(.medium))
                    Text(hit.locatorDisplay).font(.caption2).foregroundStyle(.secondary)
                }
                Text(hit.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    // MARK: - Pieces

    private var setupBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Document import is disabled until Document Intelligence setup is complete in Settings.")
                .font(.callout)
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }

    @ViewBuilder
    private var jobProgress: some View {
        if let job = controller.activeJob {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(phaseLabel(job.phase)).font(.caption)
                    Spacer()
                    if job.totalUnits > 0 {
                        Text("\(job.completedUnits)/\(job.totalUnits)").font(.caption).monospacedDigit()
                    }
                }
                if job.totalUnits > 0 {
                    ProgressView(value: Double(job.completedUnits), total: Double(max(job.totalUnits, 1)))
                }
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.08))
        }
    }

    private var trashSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trash").font(.title2.weight(.semibold)).padding()
            Divider()
            if controller.trashedDocuments.isEmpty {
                ContentUnavailableView("Trash is Empty", systemImage: "trash", description: Text("Soft-deleted documents appear here."))
                    .frame(minWidth: 420, minHeight: 240)
            } else {
                List(controller.trashedDocuments) { doc in
                    HStack {
                        Text(doc.displayName)
                        Spacer()
                        Button("Restore") { controller.restore(documentID: doc.id) }
                        Button("Delete Permanently", role: .destructive) { controller.permanentlyDelete(documentID: doc.id) }
                    }
                }
                .frame(minWidth: 460, minHeight: 300)
            }
            Divider()
            HStack { Spacer(); Button("Done") { showTrash = false }.keyboardShortcut(.defaultAction) }.padding()
        }
    }

    private func statusBadge(_ status: String) -> some View {
        let (label, color) = Self.statusAppearance(status)
        return Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private static func statusAppearance(_ status: String) -> (String, Color) {
        switch MatterDocumentStatus(rawValue: status) {
        case .ready: ("Ready", .green)
        case .failed: ("Failed", .red)
        case .needsReview: ("Needs review", .orange)
        case .needsOCR, .ocrPending: ("OCR", .orange)
        case .importing, .extracting, .indexing, .embedding: ("Processing", .blue)
        case .deleted: ("Deleted", .secondary)
        case .none: (status, .secondary)
        }
    }

    private func phaseLabel(_ phase: String) -> String {
        switch DocumentProcessingPhase(rawValue: phase) {
        case .discovering: "Discovering files…"
        case .copyingHashing: "Copying & hashing…"
        case .expandingAttachments: "Expanding attachments…"
        case .extractingText: "Extracting text…"
        case .detectingOCR, .ocrProcessing: "Running OCR…"
        case .chunking: "Chunking…"
        case .fullTextIndexing: "Indexing…"
        case .semanticEmbedding: "Embedding…"
        case .finalizingReport: "Finishing…"
        default: "Processing…"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard controller.setupReady else { return false }
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { controller.importItems(urls) }
        }
        return true
    }
}
