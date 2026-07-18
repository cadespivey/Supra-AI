import PDFKit
import Quartz
import SupraCore
import SupraDesignSystem
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
    @ObservedObject var library: ModelLibrary
    var chronologyController: DocumentChronologyController?

    @State private var showImporter = false
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    /// Where the New Folder popover files the folder: a specific parent (via a
    /// folder row's "New Subfolder") or nil to follow the sidebar selection.
    @State private var newFolderParentID: String?
    @State private var showTrash = false
    @State private var showChronology = false
    @State private var showRelationReview = false
    @State private var dropTargeted = false
    @State private var preview: PreviewItem?
    @State private var correctionDraft: DocumentPartCorrectionDraft?
    // Shared inspector-panel width, persisted across launches (same key as chat).
    @AppStorage("supra.slideOverWidth") private var previewWidthRaw: Double = 580
    private var previewWidth: Binding<CGFloat> {
        Binding(get: { CGFloat(previewWidthRaw) }, set: { previewWidthRaw = Double($0) })
    }
    @State private var dismissedImportFailureID: String?
    @AccessibilityFocusState private var importFailureFocused: Bool
    /// The single row whose action buttons (move/preview/open/delete) are revealed.
    @State private var selectedDocID: String?
    /// Documents ticked for multi-select sharing.
    @State private var checkedDocIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if !controller.setupReady {
                setupBanner
            }
            documentActionBar
            Divider()
            resumeImportBanner
            jobProgress
            importFailureBanner
            classifyPendingBanner
            // A fixed-width folder rail (not a resizable split): HSplitView rebalanced its
            // panes to their ideal widths whenever the document list changed on folder
            // selection, so the panes visibly jumped. A stable rail avoids that.
            HStack(spacing: 0) {
                folderSidebar
                    .frame(width: 220)
                Divider()
                mainContent
                    .frame(maxWidth: .infinity)
            }
            // The preview slides in over the list (it doesn't displace it); clicking a
            // row populates it.
            .overlay(alignment: .trailing) {
                if let item = preview {
                    PreviewSlideOver(model: item.model, width: previewWidth) { preview = nil }
                        // Esc closes the panel even when focus sits elsewhere in the
                        // tab (the panel's onExitCommand needs focus inside it).
                        .closesOnEscape(when: item.id == preview?.id) { preview = nil }
                }
            }
            .animation(.snappy(duration: 0.25), value: preview != nil)
        }
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
                SupraDropHint("Drop files to import")
            }
        }
        .sheet(isPresented: $showTrash) { trashSheet }
        .sheet(isPresented: $showChronology) {
            if let chronologyController {
                DocumentChronologySheet(
                    chronology: chronologyController,
                    scopeFolderID: controller.selectedFolderID,
                    library: library
                ) { showChronology = false }
            }
        }
        .sheet(isPresented: $showRelationReview) {
            DocumentRelationReviewSheet(
                controller: controller.relationReviewController
            ) { showRelationReview = false }
        }
        .sheet(item: $correctionDraft) { draft in
            PartTextEditSheet(draft: draft) { text, reason in
                try controller.saveCorrection(draft, text: text, reason: reason)
            }
        }
        .onAppear {
            controller.reload()
            controller.classifyPendingIfNeeded()
        }
    }

    // MARK: - Action Bar

    private var documentActionBar: some View {
        HStack(spacing: 8) {
            TextField("Search documents", text: $controller.searchText).supraField()
                .frame(minWidth: 140, idealWidth: 220, maxWidth: 260)
                .onSubmit { controller.runSearch() }
            SupraToolbarIconButton("Search Documents", systemImage: "magnifyingglass") {
                controller.runSearch()
            }

            Divider().frame(height: 20)

            SupraToolbarIconButton("New Folder", systemImage: "folder.badge.plus") {
                showNewFolder = true
            }

            SupraToolbarIconButton("Import Documents", systemImage: "tray.and.arrow.down") {
                showImporter = true
            }
            .disabled(!controller.setupReady)
            .accessibilityValue(controller.setupReady ? "Available" : "Unavailable until Document Intelligence setup is complete")
            .accessibilityHint(controller.setupReady ? "Opens the document picker" : "Complete setup in Settings before importing documents")

            Divider().frame(height: 20)

            SupraToolbarIconButton("Fact Chronology", systemImage: "calendar.badge.clock") {
                showChronology = true
            }
            .disabled(chronologyController == nil)

            Button {
                controller.relationReviewController.reload()
                showRelationReview = true
            } label: {
                // A single label root is important on macOS: separate top-level
                // label children are each bridged as a copy of the parent button.
                HStack(spacing: 6) {
                    Label("Review Relations", systemImage: "point.3.connected.trianglepath.dotted")
                    if controller.relationReviewController.pendingReviewCount > 0 {
                        Text("\(controller.relationReviewController.pendingReviewCount)")
                            .font(.supraCaption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            // The parent button announces this count through its
                            // accessibility value; the pill is visual decoration.
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.ghost)
            .accessibilityIdentifier("relations.openReview")
            .accessibilityValue(relationReviewAccessibilityValue)

            Spacer()

            SupraToolbarIconButton("Trash", systemImage: "trash", role: .destructive) {
                showTrash = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var relationReviewAccessibilityValue: String {
        let count = controller.relationReviewController.pendingReviewCount
        return count == 1 ? "1 unreviewed relation" : "\(count) unreviewed relations"
    }

    // MARK: - Sidebar

    /// The folder tree flattened for a plain List: depth drives indentation, so
    /// subfolders read as nested without disclosure chevrons.
    private var flattenedFolders: [(folder: DocumentFolderRecord, depth: Int)] {
        // Roots are the top-level folders PLUS any live folder whose parent
        // isn't live — a subfolder restored from Trash while its parent is
        // still trashed must stay visible, or the restore looks like it failed.
        // (It re-nests automatically when the parent is restored.)
        let liveIDs = Set(controller.folders.map(\.id))
        var visited = Set<String>()
        func walk(_ folder: DocumentFolderRecord, _ depth: Int) -> [(DocumentFolderRecord, Int)] {
            guard visited.insert(folder.id).inserted else { return [] }
            return [(folder, depth)] + controller.subfolders(of: folder.id).flatMap { walk($0, depth + 1) }
        }
        let roots = controller.folders.filter { folder in
            folder.parentFolderID.map { !liveIDs.contains($0) } ?? true
        }
        return roots.flatMap { walk($0, 0) }
    }

    private var folderSidebar: some View {
        List(selection: $controller.selectedSidebarID) {
            Label("All Documents", systemImage: "tray.full")
                .tag(MatterDocumentsController.allDocumentsTag)
                .dropDestination(for: String.self) { ids, _ in moveDropped(ids, toFolderID: nil); return true }
            Section("Folders") {
                ForEach(flattenedFolders, id: \.folder.id) { item in
                    Label(item.folder.name, systemImage: "folder")
                        .padding(.leading, CGFloat(item.depth) * 14)
                        .tag(item.folder.id)
                        .dropDestination(for: String.self) { ids, _ in moveDropped(ids, toFolderID: item.folder.id); return true }
                        .contextMenu {
                            Button {
                                newFolderParentID = item.folder.id
                                showNewFolder = true
                            } label: {
                                Label("New Subfolder", systemImage: "folder.badge.plus")
                            }
                            Button(role: .destructive) { controller.deleteFolder(id: item.folder.id) } label: {
                                Label("Delete Folder", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .popover(isPresented: $showNewFolder) {
            SupraPopoverFrame(newFolderTitle, width: 260) {
                TextField("Folder name", text: $newFolderName).supraField()
                HStack {
                    Spacer()
                    Button("Create") {
                        controller.createFolder(
                            name: newFolderName,
                            parentFolderID: newFolderParentID ?? controller.selectedFolderID
                        )
                        newFolderName = ""
                        newFolderParentID = nil
                        showNewFolder = false
                    }
                    .buttonStyle(.ghost)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onChange(of: showNewFolder) { _, shown in
            // The popover can be dismissed without creating; don't let a stale
            // parent leak into the next toolbar-triggered New Folder.
            if !shown { newFolderParentID = nil }
        }
    }

    /// Names the destination so "New Subfolder" reads differently from a
    /// root-level New Folder.
    private var newFolderTitle: String {
        let parentID = newFolderParentID ?? controller.selectedFolderID
        guard let parent = controller.folders.first(where: { $0.id == parentID }) else { return "New Folder" }
        return "New Subfolder in “\(parent.name)”"
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
                VStack(spacing: 0) {
                    selectionBar
                    Divider()
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func documentRow(_ doc: MatterDocumentRecord) -> some View {
        // The row itself is just identity: a multi-select tick, the name, its readiness
        // status, and the tags applied on import. The move/preview/open/delete actions
        // appear on the right only once the row is selected.
        let classification = controller.classification(forDocument: doc.id)
        let isSelected = selectedDocID == doc.id
        let isChecked = checkedDocIDs.contains(doc.id)
        return HStack(spacing: 8) {
            Button { toggleChecked(doc.id) } label: {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChecked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(isChecked ? "Deselect" : "Select for sharing")

            Image(systemName: doc.parentDocumentID == nil ? "doc.text" : "paperclip")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.displayName).lineLimit(1)
                HStack(spacing: 6) {
                    statusBadge(doc)
                    if let summary = doc.ocrConfidenceSummary {
                        Text(summary).font(.supraCaption).foregroundStyle(.orange)
                    }
                    if let classification {
                        classificationChips(classification)
                    }
                    ForEach(controller.tags(forDocument: doc.id)) { tag in
                        Text(tag.name).font(.supraCaption)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 8)
            if isSelected {
                rowActions(doc)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        // Double-click opens the file in the default app (suppressed while 2+ files are
        // ticked for a batch action); a single click selects the row to reveal its
        // actions; dragging it onto a folder moves it.
        .onTapGesture(count: 2) { if checkedDocIDs.count <= 1 { openInDefaultApp(doc) } }
        // Selection is idempotent: clicking the already-selected row keeps its
        // action cluster available (including after an editor or preview closes).
        .onTapGesture { selectedDocID = doc.id }
        .draggable(doc.id)
    }

    /// The trailing action cluster shown on the selected document row: preview, open in
    /// the default app, tag, move, and delete.
    @ViewBuilder
    private func rowActions(_ doc: MatterDocumentRecord) -> some View {
        Button { showPreview(doc) } label: { Image(systemName: "eye") }
            .buttonStyle(.plain)
            .help("Preview")
            .accessibilityLabel("Preview \(doc.displayName)")
            .accessibilityIdentifier("documents.preview")
        Button { openInDefaultApp(doc) } label: { Image(systemName: "arrow.up.forward.app") }
            .buttonStyle(.plain).help("Open & edit in your default app")
        Button {
            correctionDraft = controller.correctionDraft(documentID: doc.id)
        } label: {
            Image(systemName: "pencil.and.list.clipboard")
        }
        .buttonStyle(.plain)
        .help("Edit extracted text")
        .accessibilityIdentifier("documents.editExtractedText")
        Button { controller.retryProcessing(documentID: doc.id) } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .help(doc.status == MatterDocumentStatus.failed.rawValue
            ? "Retry processing"
            : "Reprocess extracted text")
        .accessibilityIdentifier("documents.reprocess")
        Menu {
            ForEach(controller.tags) { tag in
                Button { controller.toggleTag(tag.id, on: doc.id) } label: {
                    Label(tag.name, systemImage: controller.tags(forDocument: doc.id).contains { $0.id == tag.id } ? "checkmark" : "")
                }
            }
            if controller.tags.isEmpty { Text("No tags yet").foregroundStyle(.secondary) }
        } label: {
            Image(systemName: "tag")
        }
        .menuStyle(.borderlessButton).fixedSize().help("Tags")
        if doc.parentDocumentID == nil {
            Menu {
                Button { controller.moveDocument(id: doc.id, toFolderID: nil) } label: {
                    Label("All Documents", systemImage: doc.folderID == nil ? "checkmark" : "tray")
                }
                if controller.folders.isEmpty {
                    Text("Add a folder from the sidebar to organize documents")
                } else {
                    Divider()
                    ForEach(controller.folders) { folder in
                        Button { controller.moveDocument(id: doc.id, toFolderID: folder.id) } label: {
                            Label(folder.name, systemImage: doc.folderID == folder.id ? "checkmark" : "folder")
                        }
                    }
                }
            } label: {
                Image(systemName: "folder")
            }
            .menuStyle(.borderlessButton).fixedSize().help("Move to folder")
        }
        Button(role: .destructive) {
            controller.softDelete(documentID: doc.id)
            checkedDocIDs.remove(doc.id)
            if selectedDocID == doc.id { selectedDocID = nil }
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.ghostDanger).help("Move to trash")
    }

    private func toggleChecked(_ id: String) {
        if checkedDocIDs.contains(id) { checkedDocIDs.remove(id) } else { checkedDocIDs.insert(id) }
    }

    /// Opens the managed original in the user's default app. Because it opens the file
    /// Supra manages, saving in that app writes straight back to Supra's copy.
    private func openInDefaultApp(_ doc: MatterDocumentRecord) {
        guard let url = controller.fileURL(forDocument: doc.id) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Select-all + share bar above the document list.
    private var selectionBar: some View {
        let ids = controller.visibleDocuments.map(\.id)
        let allChecked = !ids.isEmpty && ids.allSatisfy { checkedDocIDs.contains($0) }
        let hasSelection = !checkedDocIDs.isEmpty
        return HStack(spacing: 8) {
            Button {
                if allChecked { ids.forEach { checkedDocIDs.remove($0) } }
                else { checkedDocIDs.formUnion(ids) }
            } label: {
                Label(allChecked ? "Deselect All" : "Select All",
                      systemImage: allChecked ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.ghost)
            if hasSelection {
                Text("\(checkedDocIDs.count) selected").foregroundStyle(.secondary)
            }
            Spacer()
            // Always laid out (only active once something is ticked) so the bar keeps a
            // constant height sized for the Share button instead of growing when it appears.
            ShareLink(items: sharedFileURLs) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.ghost)
            .disabled(!hasSelection)
            .opacity(hasSelection ? 1 : 0)
            .allowsHitTesting(hasSelection)
        }
        .font(.supraCaption)
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    /// Managed file URLs for the ticked documents, for the Share sheet.
    private var sharedFileURLs: [URL] {
        checkedDocIDs.compactMap { controller.fileURL(forDocument: $0) }
    }

    /// Moves dropped documents to a folder (nil = All Documents). Dropping any member of
    /// the multi-select set moves the whole set.
    private func moveDropped(_ ids: [String], toFolderID: String?) {
        let expanded = Set(ids.flatMap { checkedDocIDs.contains($0) ? Array(checkedDocIDs) : [$0] })
        for id in expanded { controller.moveDocument(id: id, toFolderID: toFolderID) }
    }

    /// Opens (or refreshes) the preview pane for a document.
    private func showPreview(_ doc: MatterDocumentRecord) {
        if let model = controller.preview(documentID: doc.id) {
            preview = PreviewItem(model: model)
        }
    }

    /// The classifier's suggested categorization, shown inline on a document row:
    /// the primary category prominently, secondary categories lightly, plus
    /// privilege/confidential flags. These are AI suggestions (hover for the
    /// reasoning); editing a document's text clears them for re-classification.
    @ViewBuilder
    private func classificationChips(_ classification: DocumentClassification) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles").font(.system(size: 8))
            Text(classification.primaryCategory.displayName)
        }
        .font(.supraCaption.weight(.medium))
        .foregroundStyle(.tint)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(Color.accentColor.opacity(0.18), in: Capsule())
        .help(classificationTooltip(classification))

        ForEach(classification.secondaryCategories, id: \.self) { category in
            Text(category.displayName).font(.supraCaption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.08), in: Capsule())
        }

        if classification.isPrivilegedLikely {
            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange)
                .help("Privilege appears likely from the content — review before producing.")
        }
        if classification.isConfidentialLikely {
            Image(systemName: "eye.slash.fill").font(.caption2).foregroundStyle(.secondary)
                .help("Confidential or sensitive information appears likely.")
        }
    }

    private func classificationTooltip(_ classification: DocumentClassification) -> String {
        var parts = ["Suggested category: \(classification.primaryCategory.displayName)"]
        if classification.confidence > 0 {
            parts.append("\(Int((classification.confidence * 100).rounded()))% confidence")
        }
        if !classification.reasoningSummary.isEmpty { parts.append(classification.reasoningSummary) }
        return parts.joined(separator: " · ")
    }

    private var searchResults: some View {
        List(controller.searchHits) { hit in
            Button {
                if let model = controller.preview(chunkID: hit.id) { preview = PreviewItem(model: model) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(hit.documentName).font(.supraHeadline)
                        Text(hit.locatorDisplay).font(.supraCaption).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
                    }
                    Text(hit.excerpt).font(.supraCaption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var resumeImportBanner: some View {
        if let interrupted = queue.resumableImports.first(where: { $0.matterID == controller.matterID }) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
                Text(interrupted.message)
                    .font(.supraCaption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .accessibilityIdentifier("documents.resumeMessage")
                Spacer()
                Button("Resume") {
                    queue.resume(jobID: interrupted.jobID)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("documents.resumeAction")
                Button("Discard") {
                    queue.discard(jobID: interrupted.jobID)
                }
                .buttonStyle(.ghost)
                .accessibilityIdentifier("documents.discardAction")
            }
            .padding(8)
            .background(Color.orange.opacity(0.12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("documents.resumeBanner")
            .accessibilityLabel("Import interrupted")
            .accessibilityValue(interrupted.message)
        }
    }

    private var setupBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Document import is disabled until Document Intelligence setup is complete in Settings.")
                .font(.supraCaption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("documents.importUnavailableWarning")
        .accessibilityLabel("Document import unavailable")
        .accessibilityValue("Complete Document Intelligence setup in Settings before importing files")
    }

    /// In-app banner for the most recent import that completed with failures
    /// (otherwise the only signal is the Audit tab / an easily-missed notification).
    @ViewBuilder
    private var importFailureBanner: some View {
        if let failure = queue.lastImportFailure,
           failure.matterID == controller.matterID,
           !queue.resumableImports.contains(where: { $0.matterID == controller.matterID }),
           dismissedImportFailureID != failure.id {
            let itemNoun = failure.failedCount == 1 ? "item" : "items"
            let message = failure.details.isEmpty
                ? "Imported \(failure.importedCount) of \(failure.discoveredCount). \(failure.failedCount) need attention — see the Audit tab for details."
                : "Imported \(failure.importedCount) of \(failure.discoveredCount). Review the \(failure.failedCount) \(itemNoun) below."
            VStack(alignment: .leading, spacing: 6) {
                SupraWarningBanner(
                    .warning,
                    title: "Some files couldn’t be imported",
                    message: message
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("documents.importFailureWarning")
                .accessibilityLabel("Document import warning")
                .accessibilityValue("Some files could not be imported. \(message)")
                .accessibilityFocused($importFailureFocused)

                ForEach(Array(failure.details.enumerated()), id: \.offset) { _, detail in
                    let detailAccessibilityValue = [
                        detail.rejectionCode.map { "Code: \($0)" },
                        detail.reason,
                    ].compactMap { $0 }.joined(separator: ". ")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(detail.displayName)
                            .font(.supraCaption)
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("documents.importFailureDetail.\(detail.displayName)")
                            .accessibilityLabel(detail.displayName)
                            .accessibilityValue(detailAccessibilityValue)
                        if let code = detail.rejectionCode {
                            Text("Code: \(code)")
                                .font(.supraCaption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        if let reason = detail.reason {
                            Text(reason)
                                .font(.supraCaption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                HStack {
                    Spacer()
                    Button {
                        importFailureFocused = false
                        dismissedImportFailureID = failure.id
                        queue.clearImportFailure()
                    } label: {
                        Label("Dismiss import warning", systemImage: "xmark")
                    }
                    .buttonStyle(.ghost)
                    .accessibilityIdentifier("documents.dismissImportFailureWarning")
                    .accessibilityHint("Removes this warning; rejection details remain in the Audit tab")
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .task(id: failure.id) {
                importFailureFocused = false
                await Task.yield()
                importFailureFocused = true
            }
        }
    }

    /// A quiet prompt to classify documents that were imported while no model was
    /// available (so they never got a taxonomy suggestion). Hidden while a job for this
    /// matter is running — its classify phase will pick them up.
    @ViewBuilder
    private var classifyPendingBanner: some View {
        if controller.unclassifiedCount > 0, controller.activeJob == nil {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                Text(controller.unclassifiedCount == 1
                    ? "1 document not yet classified"
                    : "\(controller.unclassifiedCount) documents not yet classified")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Classify") { controller.classifyPendingIfNeeded() }
                    .buttonStyle(.ghost)
                    .disabled(controller.activeJob != nil)
            }
            .font(.supraCaption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var jobProgress: some View {
        if let job = controller.activeJob {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(phaseLabel(job.phase)).font(.supraCaption)
                    Spacer()
                    if job.totalUnits > 0 {
                        Text("\(job.completedUnits)/\(job.totalUnits)").font(.supraCaption).monospacedDigit()
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
        SupraSheetScaffold("Trash", onClose: { showTrash = false }) {
            if controller.trashedDocuments.isEmpty && controller.trashedFolders.isEmpty {
                ContentUnavailableView("Trash is Empty", systemImage: "trash", description: Text("Soft-deleted documents and folders appear here."))
                    .frame(minWidth: 460, minHeight: 240)
            } else {
                List {
                    if !controller.trashedFolders.isEmpty {
                        Section("Folders") {
                            ForEach(controller.trashedFolders) { folder in
                                HStack {
                                    Label(folder.name, systemImage: "folder")
                                    Spacer()
                                    Button("Restore") { controller.restoreFolder(id: folder.id) }
                                        .buttonStyle(.ghost)
                                }
                            }
                        }
                    }
                    Section("Documents") {
                        ForEach(controller.trashedDocuments) { doc in
                            HStack {
                                Text(doc.displayName)
                                Spacer()
                                Button("Restore") { controller.restore(documentID: doc.id) }
                                    .buttonStyle(.ghost)
                                Button("Delete Permanently", role: .destructive) { controller.permanentlyDelete(documentID: doc.id) }
                                    .buttonStyle(.ghostDanger)
                            }
                        }
                    }
                }
                .frame(minWidth: 480, minHeight: 320)
            }
        }
    }

    private func statusBadge(_ document: MatterDocumentRecord) -> some View {
        let reindexing = controller.isCorrectionReindexing(document)
        let (label, color) = reindexing
            ? ("Reindexing", Color.blue)
            : Self.statusAppearance(document.status)
        return Text(label)
            .font(.supraCaption.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .accessibilityIdentifier(reindexing ? "documents.reindexingBadge" : "")
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
        case .classifying: "Classifying…"
        case .finalizingReport: "Finishing…"
        default: "Processing…"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard controller.setupReady else { return false }
        // The sidebar can change while item providers resolve. A drop belongs to
        // the folder selected when the user released it, not a later selection.
        let targetFolderID = controller.selectedFolderID
        let group = DispatchGroup()
        // NSItemProvider completion handlers run concurrently, so collect through a
        // lock instead of mutating a captured array (a data race — and a Swift 6
        // sendable-capture error).
        let collector = DroppedURLCollector()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collector.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collector.drain()
            if !urls.isEmpty { controller.importItems(urls, targetFolderID: targetFolderID) }
        }
        return true
    }
}

/// Thread-safe URL collector for the concurrent drag-and-drop `NSItemProvider`
/// completion handlers in `handleDrop`.
private final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) { lock.withLock { urls.append(url) } }
    func drain() -> [URL] { lock.withLock { urls } }
}

/// Sheet-presentable wrapper for a preview model.
struct PreviewItem: Identifiable {
    let id = UUID()
    let model: DocumentPreviewModel
}

/// Fact chronology over the matter's documents (WO 42), in a table or narrative
/// format. Large scopes are batched; results are saved with their source set.
struct DocumentChronologySheet: View {
    @ObservedObject var chronology: DocumentChronologyController
    let scopeFolderID: String?
    @ObservedObject var library: ModelLibrary
    let onClose: () -> Void

    @State private var format: DocumentChronologyFormat = .table
    @State private var scopeThisFolder = false
    @State private var routingMessage: String?

    private var router: ModelRouter { ModelRouter(configuration: .fromEnvironment()) }
    private var route: ModelRoute? { router.route(forStructuredOutput: format.outputType) }
    private var routeModel: ModelSummary? {
        guard let route else { return nil }
        return library.resolvedModel(for: route.role, configuration: router.configuration)
    }

    private var scope: RetrievalScope {
        (scopeThisFolder && scopeFolderID != nil) ? RetrievalScope(folderIDs: [scopeFolderID!]) : .wholeMatter
    }

    var body: some View {
        SupraSheetScaffold("Fact Chronology", onClose: onClose) {
            chronologyContent
        } footer: {
            if let result = chronology.lastResult {
                Button("Regenerate") { Task { await regenerate(outputID: result.outputID) } }
                    .buttonStyle(.ghost)
                    .disabled(chronology.isGenerating || routeModel == nil)
            }
            Spacer()
            if chronology.isGenerating {
                ProgressView().controlSize(.small)
                if let caption = progressCaption {
                    Text(caption)
                        .font(.supraCaption)
                        .foregroundStyle(.secondary)
                }
                if chronology.progress != .saving {
                    Button("Cancel") { chronology.cancel() }
                        .buttonStyle(.ghost)
                }
            }
            Button("Generate") { Task { await generate() } }
                .buttonStyle(.ghost)
                .keyboardShortcut(.defaultAction)
                .disabled(chronology.isGenerating || routeModel == nil)
        }
        .frame(minWidth: 540, idealWidth: 640, maxWidth: .infinity, minHeight: 480, idealHeight: 620, maxHeight: .infinity)
        .onAppear { library.refresh() }
    }

    private var chronologyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                LabeledContent("Format") {
                    GhostSegmentedControl(
                        selection: $format,
                        segments: [(DocumentChronologyFormat.table, "Table", ""), (DocumentChronologyFormat.narrative, "Narrative", "")]
                    )
                }
                if scopeFolderID != nil {
                    Toggle("Limit to the selected folder", isOn: $scopeThisFolder)
                }
                if let readiness = chronology.scopeReadiness(scope: scope) {
                    Text(readiness.summaryText)
                        .font(.supraCaption).foregroundStyle(readiness.isFullyReady ? Color.secondary : Color.orange)
                    if !readiness.blockingReasons.isEmpty {
                        Text(readiness.blockingReasons.joined(separator: " · "))
                            .font(.supraCaption).foregroundStyle(.orange)
                    }
                }
                routeStatus
                if let routingMessage {
                    Text(routingMessage).font(.supraCaption).foregroundStyle(.orange)
                }
                if let message = chronology.message {
                    Text(message).font(.supraCaption).foregroundStyle(.orange)
                }
                if let summary = chronology.summaryMessage {
                    Text(summary).font(.supraCaption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let result = chronology.lastResult {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if let assurance = result.assuranceState {
                            AssuranceBadge(state: assurance)
                        }
                        if result.status == StructuredOutputStatus.needsReview.rawValue {
                            Label("Needs review — \(result.warnings.joined(separator: " "))", systemImage: "exclamationmark.triangle")
                                .font(.supraCaption).foregroundStyle(.orange)
                        }
                        Text((try? AttributedString(markdown: result.markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(result.markdown))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
                .frame(minHeight: 220)
            }
        }
    }

    @ViewBuilder
    private var routeStatus: some View {
        if let route {
            if let routeModel {
                Text("Uses \(route.role.displayName): \(routeModel.displayName)")
                    .font(.supraCaption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Assign a \(route.role.displayName) model in Models to build a chronology.")
                    .font(.supraCaption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Footer caption for the generation stage; a large scope shows per-pass
    /// progress ("Pass 2 of 3…") while it maps batches.
    private var progressCaption: String? {
        switch chronology.progress {
        case .idle: nil
        case .harvesting: "Harvesting…"
        case .generating: "Generating…"
        case let .mapping(batch, total): "Pass \(batch) of \(total)…"
        case .merging: "Merging…"
        case .synthesizing: "Synthesizing…"
        case .verifying: "Verifying…"
        case .saving: "Saving…"
        }
    }

    private func generate() async {
        guard let resolved = await resolveRouteModel() else { return }
        _ = await chronology.generate(
            scope: scope,
            format: format,
            modelID: resolved.modelID,
            modelLineage: resolved.modelLineage,
            route: resolved.route
        )
    }

    private func regenerate(outputID: String) async {
        guard let resolved = await resolveRouteModel() else { return }
        _ = await chronology.regenerate(
            outputID: outputID,
            modelID: resolved.modelID,
            modelLineage: resolved.modelLineage,
            route: resolved.route
        )
    }

    private func resolveRouteModel() async -> (
        modelID: ModelID,
        modelLineage: DocumentGenerationModelLineage,
        route: ModelRoute
    )? {
        routingMessage = nil
        guard let route else {
            routingMessage = "No route is available for this chronology."
            return nil
        }
        switch await library.ensureLoadedRoutedModelID(for: route.role, configuration: router.configuration) {
        case let .success(modelID):
            guard let modelLineage = library.generationLineage(for: modelID) else {
                routingMessage = DocumentGenerationLineageError.stableModelIdentityUnavailable.localizedDescription
                return nil
            }
            return (modelID, modelLineage, route)
        case let .failure(issue):
            routingMessage = issue.message
            return nil
        }
    }
}

/// In-app source preview (WO 40): PDF page, image, QuickLook-rendered original
/// file, or normalized text with a best-effort highlight, plus source
/// metadata/warnings. Never fails silently — an unavailable visual falls back to
/// normalized text (plan §11.2).
struct DocumentPreviewView: View {
    let model: DocumentPreviewModel
    let onClose: () -> Void
    @State private var showingStructure = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.documentName).font(.supraTitle)
                    Text(model.locatorDisplay).font(.supraSubheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.structureNodes.isEmpty {
                    Button {
                        showingStructure.toggle()
                    } label: {
                        Label(
                            showingStructure ? "Show Document" : "Extraction Structure",
                            systemImage: showingStructure
                                ? "doc.text"
                                : "point.3.connected.trianglepath.dotted"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(showingStructure ? "Return to the document preview" : "Inspect extracted nodes and relationships")
                    .accessibilityIdentifier("documentPreview.structureToggle")
                }
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding()
            if !model.warnings.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(model.warnings.joined(separator: " ")).font(.supraCaption).foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal).padding(.bottom, 6)
            }
            if let revisionNotice = model.revisionNotice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: model.revisionID == nil ? "clock.badge.questionmark" : "clock.badge.checkmark")
                        .foregroundStyle(model.revisionID == nil ? Color.orange : Color.secondary)
                    Text(revisionNotice)
                        .font(.supraCaption)
                        .foregroundStyle(model.revisionID == nil ? Color.orange : Color.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
                .accessibilityIdentifier("documentPreview.revisionNotice")
            }
            Divider()
            Group {
                if showingStructure {
                    DocumentStructurePreviewView(
                        nodes: model.structureNodes,
                        edges: model.structureEdges
                    )
                } else {
                    body(for: model.kind)
                }
            }
                .frame(minWidth: 560, minHeight: 460)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("documentPreview")
    }

    @ViewBuilder
    private func body(for kind: DocumentPreviewModel.Kind) -> some View {
        switch kind {
        case let .pdf(path, pageIndex, highlightText):
            PDFKitView(url: URL(fileURLWithPath: path), pageIndex: pageIndex, highlightText: highlightText)
        case let .quickLook(path, excerpt):
            VStack(spacing: 0) {
                if let excerpt, !excerpt.isEmpty {
                    citedPassageBanner(excerpt)
                    Divider()
                }
                if FileManager.default.fileExists(atPath: path) {
                    QuickLookView(url: URL(fileURLWithPath: path))
                } else {
                    Label("Original file unavailable.", systemImage: "doc.questionmark")
                        .font(.supraCaption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case let .image(path, _):
            ScrollView([.horizontal, .vertical]) {
                if let image = NSImage(contentsOf: URL(fileURLWithPath: path)) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Text("Image could not be loaded.").foregroundStyle(.secondary).padding()
                }
            }
        case let .text(content, start, end):
            ScrollView {
                Text(Self.highlighted(content, start: start, end: end))
                    .supraReadingBody()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        case let .unavailable(reason, fallbackText):
            VStack(alignment: .leading, spacing: 8) {
                Label(reason, systemImage: "doc.questionmark").font(.supraCaption).foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    Text(fallbackText.isEmpty ? "No extracted text available." : fallbackText)
                        .supraReadingBody()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }

    private static func highlighted(_ text: String, start: Int?, end: Int?) -> AttributedString {
        var attributed = AttributedString(text)
        guard let start, let end, start >= 0, start < end, end <= text.count else { return attributed }
        let lower = attributed.index(attributed.startIndex, offsetByCharacters: start)
        let upper = attributed.index(attributed.startIndex, offsetByCharacters: end)
        attributed[lower..<upper].backgroundColor = .yellow.opacity(0.4)
        return attributed
    }

    /// QuickLook renders the real file but can't paint the cited range inside it, so
    /// this banner surfaces the cited passage above the preview (with a copy button)
    /// — the closest stand-in for the in-document highlight PDFs/text get.
    @ViewBuilder
    private func citedPassageBanner(_ excerpt: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "quote.opening").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cited passage").font(.supraCaption).foregroundStyle(.secondary)
                Text(excerpt.count > 280 ? String(excerpt.prefix(280)) + "…" : excerpt)
                    .font(.supraBody)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(excerpt, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy cited passage")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12))
    }
}

/// A deliberately compact inspection view for the persisted extraction graph.
/// Legal-document structure is presented as a hierarchy first and relationships
/// second: the same mental model as clauses/notes/anchors, without exposing raw
/// database identifiers or displacing the ordinary document preview.
struct DocumentStructurePreviewView: View {
    let nodes: [DocumentStructurePreviewNode]
    let edges: [DocumentStructurePreviewEdge]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Extraction Structure", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.supraSubheadline.weight(.semibold))
                Spacer()
                Text("\(nodes.count) nodes · \(edges.count) relationships")
                    .font(.supraCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.07))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("documentPreview.structureSummary")

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(nodes) { node in
                        nodeRow(node)
                        Divider().padding(.leading, 16 + indentation(for: node))
                    }

                    if !edges.isEmpty {
                        Text("Relationships")
                            .font(.supraSubheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.top, 18)
                            .padding(.bottom, 8)

                        ForEach(edges) { edge in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                Text(prettyKind(edge.kind))
                                    .font(.supraCaption.weight(.semibold))
                                Text("\(edge.fromNodeKey) → \(edge.toNodeKey)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(edge.display)
                            .accessibilityIdentifier(
                                "documentPreview.structure.edge.\(edge.kind).\(edge.fromNodeKey).\(edge.toNodeKey)"
                            )
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private func nodeRow(_ node: DocumentStructurePreviewNode) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(node.depth == 0 ? Color.accentColor : Color.accentColor.opacity(0.38))
                .frame(width: 3, height: node.depth == 0 ? 34 : 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(prettyKind(node.kind))
                        .font(.supraCaption.weight(.semibold))
                        .foregroundStyle(node.depth == 0 ? Color.primary : Color.secondary)
                    Text(node.nodeKey)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    if let range = rangeText(node) {
                        Text(range)
                            .font(.supraCaption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }

                if let text = node.textContent, !text.isEmpty {
                    Text(text)
                        .font(.supraBody)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }

                if let payload = node.payloadJSON, !payload.isEmpty {
                    Text(prettyPayload(payload))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, 16 + indentation(for: node))
        .padding(.trailing, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(node.depth == 0 ? Color.accentColor.opacity(0.035) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(prettyKind(node.kind)): \(node.nodeKey)")
        .accessibilityValue(accessibilityValue(node))
        .accessibilityIdentifier("documentPreview.structure.node.\(node.nodeKey)")
    }

    private func indentation(for node: DocumentStructurePreviewNode) -> CGFloat {
        CGFloat(min(node.depth, 8)) * 14
    }

    private func rangeText(_ node: DocumentStructurePreviewNode) -> String? {
        guard let start = node.charStart, let end = node.charEnd else { return nil }
        return "chars \(start)–\(end)"
    }

    private func prettyKind(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func prettyPayload(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: formatted, encoding: .utf8) else { return raw }
        return string
    }

    private func accessibilityValue(_ node: DocumentStructurePreviewNode) -> String {
        [
            node.textContent,
            node.payloadJSON,
            rangeText(node),
            node.parentNodeKey.map { "Parent: \($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: ". ")
    }
}

/// PDFKit preview navigated to a page, with a best-effort text-match highlight.
struct PDFKitView: NSViewRepresentable {
    let url: URL
    let pageIndex: Int?
    let highlightText: String?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document == nil {
            view.document = PDFDocument(url: url)
        }
        guard let document = view.document else { return }
        if let pageIndex, pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) {
            view.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: page.bounds(for: .mediaBox).height)))
        }
        if let highlightText, !highlightText.isEmpty {
            let snippet = String(highlightText.prefix(80))
            let selections = document.findString(snippet, withOptions: [.caseInsensitive])
            let candidatePageIndexes = selections.map { selection in
                selection.pages.first.map(document.index(for:)) ?? NSNotFound
            }
            if let index = PDFLocatorHighlightPolicy.selectionIndex(
                targetPageIndex: pageIndex,
                candidatePageIndexes: candidatePageIndexes
            ) {
                let selection = selections[index]
                selection.color = .yellow
                view.highlightedSelections = [selection]
                view.go(to: selection)
            } else {
                view.highlightedSelections = []
            }
        } else {
            view.highlightedSelections = []
        }
    }
}

/// Renders the original document file with QuickLook (the same engine as Finder's
/// preview pane), so Word/RTF/spreadsheet/email files look like their real selves
/// instead of stripped plain text.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url {
            view.previewItem = url as NSURL
        }
    }
}

/// A right-anchored document preview that slides in OVER the content (it does not
/// displace the list/conversation underneath). A leading drag handle resizes it; a
/// border + shadow set it apart. Use via `.overlay(alignment: .trailing)`.
struct PreviewSlideOver: View {
    let model: DocumentPreviewModel
    @Binding var width: CGFloat
    let onClose: () -> Void

    // Floor matches DocumentPreviewView's intrinsic content minWidth (560) so the
    // panel can never be dragged narrower than the content can render (which would
    // overflow the fixed-width frame).
    static let minWidth: CGFloat = 560
    static let maxWidth: CGFloat = 1100

    var body: some View {
        SlideOverPanel(width: $width, minWidth: Self.minWidth, maxWidth: Self.maxWidth, onClose: onClose) {
            DocumentPreviewView(model: model, onClose: onClose)
        }
    }
}

/// The thin draggable strip on the leading edge of the slide-over; dragging it left
/// widens the panel (covering more), right narrows it — the content underneath never
/// moves. Shows a horizontal-resize cursor on hover.
struct PreviewResizeHandle: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    @State private var dragStartWidth: CGFloat?
    // NSCursor.push()/pop() share a process-wide stack and must balance exactly. This
    // flag guarantees we only pop a cursor we actually pushed — otherwise an exit
    // hover with no prior enter (common during the slide transition) would pop a
    // cursor belonging to other UI, and a teardown mid-hover would leak ours.
    @State private var pushed = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    if !pushed { NSCursor.resizeLeftRight.push(); pushed = true }
                } else if pushed {
                    NSCursor.pop(); pushed = false
                }
            }
            .onDisappear {
                if pushed { NSCursor.pop(); pushed = false }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = dragStartWidth ?? width
                        if dragStartWidth == nil { dragStartWidth = width }
                        width = min(maxWidth, max(minWidth, start - value.translation.width))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}
