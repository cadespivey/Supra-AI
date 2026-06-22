import PDFKit
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
    var qaController: DocumentQAController?
    var chronologyController: DocumentChronologyController?

    @State private var showImporter = false
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var showTrash = false
    @State private var showQA = false
    @State private var showChronology = false
    @State private var dropTargeted = false
    @State private var preview: PreviewItem?
    @State private var dismissedImportFailureID: String?

    var body: some View {
        VStack(spacing: 0) {
            if !controller.setupReady {
                setupBanner
            }
            documentActionBar
            Divider()
            jobProgress
            importFailureBanner
            HSplitView {
                folderSidebar
                    .frame(minWidth: 200, maxWidth: 280)
                mainContent
                    .frame(minWidth: 360)
                }
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
                Text("Drop files to import")
                    .padding(8).background(.thinMaterial, in: Capsule()).padding(.top, 8)
            }
        }
        .sheet(isPresented: $showTrash) { trashSheet }
        .sheet(isPresented: $showQA) {
            if let qaController {
                DocumentQASheet(
                    qa: qaController,
                    scopeFolderID: controller.selectedFolderID,
                    library: library
                ) { showQA = false }
            }
        }
        .sheet(isPresented: $showChronology) {
            if let chronologyController {
                DocumentChronologySheet(
                    chronology: chronologyController,
                    scopeFolderID: controller.selectedFolderID,
                    library: library
                ) { showChronology = false }
            }
        }
        .sheet(item: $preview) { item in
            DocumentPreviewView(model: item.model) { preview = nil }
        }
        .onAppear { controller.reload() }
    }

    // MARK: - Action Bar

    private var documentActionBar: some View {
        HStack(spacing: 8) {
            TextField("Search documents", text: $controller.searchText)
                .textFieldStyle(.roundedBorder)
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

            Divider().frame(height: 20)

            SupraToolbarIconButton("Ask Documents", systemImage: "bubble.left.and.text.bubble.right") {
                showQA = true
            }
            .disabled(qaController == nil)

            SupraToolbarIconButton("Fact Chronology", systemImage: "calendar.badge.clock") {
                showChronology = true
            }
            .disabled(chronologyController == nil)

            Spacer()

            SupraToolbarIconButton("Trash", systemImage: "trash", role: .destructive) {
                showTrash = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Sidebar

    private var folderSidebar: some View {
        List(selection: $controller.selectedSidebarID) {
            Label("All Documents", systemImage: "tray.full").tag(MatterDocumentsController.allDocumentsTag)
            Section("Folders") {
                ForEach(controller.folders) { folder in
                    Label(folder.name, systemImage: "folder").tag(folder.id)
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
        // The suggestion chips come from the stored classification metadata; the
        // user's own tags are shown separately (the classifier creates no tags).
        let classification = controller.classification(forDocument: doc.id)
        return HStack {
            Image(systemName: doc.parentDocumentID == nil ? "doc.text" : "paperclip")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.displayName).lineLimit(1)
                HStack(spacing: 6) {
                    statusBadge(doc.status)
                    if let summary = doc.ocrConfidenceSummary {
                        Text(summary).font(.caption2).foregroundStyle(.orange)
                    }
                    if let classification {
                        classificationChips(classification)
                    }
                    ForEach(controller.tags(forDocument: doc.id)) { tag in
                        Text(tag.name).font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
            Spacer()
            Button {
                if let model = controller.preview(documentID: doc.id) { preview = PreviewItem(model: model) }
            } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .help("Preview")
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
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Move to folder")
            }
            Button(role: .destructive) { controller.softDelete(documentID: doc.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
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
        .font(.caption2.weight(.medium))
        .foregroundStyle(.tint)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(Color.accentColor.opacity(0.18), in: Capsule())
        .help(classificationTooltip(classification))

        ForEach(classification.secondaryCategories, id: \.self) { category in
            Text(category.displayName).font(.caption2)
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
                        Text(hit.documentName).font(.callout.weight(.medium))
                        Text(hit.locatorDisplay).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
                    }
                    Text(hit.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .buttonStyle(.plain)
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

    /// In-app banner for the most recent import that completed with failures
    /// (otherwise the only signal is the Audit tab / an easily-missed notification).
    @ViewBuilder
    private var importFailureBanner: some View {
        if let failure = queue.lastImportFailure,
           failure.matterID == controller.matterID,
           dismissedImportFailureID != failure.id {
            SupraWarningBanner(
                .warning,
                title: "Some files couldn’t be imported",
                message: "Imported \(failure.importedCount) of \(failure.discoveredCount). \(failure.failedCount) need attention — see the Audit tab for details."
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    dismissedImportFailureID = failure.id
                    queue.clearImportFailure()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(8)
                .help("Dismiss")
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
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
                                Button("Delete Permanently", role: .destructive) { controller.permanentlyDelete(documentID: doc.id) }
                            }
                        }
                    }
                }
                .frame(minWidth: 480, minHeight: 320)
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
        case .classifying: "Classifying…"
        case .finalizingReport: "Finishing…"
        default: "Processing…"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard controller.setupReady else { return false }
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
            if !urls.isEmpty { controller.importItems(urls) }
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

/// Source-grounded Q&A over the matter's documents (WO 41). Auto-source by
/// default; answers are saved to the Outputs tab with their source set.
struct DocumentQASheet: View {
    @ObservedObject var qa: DocumentQAController
    let scopeFolderID: String?
    @ObservedObject var library: ModelLibrary
    let onClose: () -> Void

    @State private var question = ""
    @State private var mode: DocumentAnswerMode = .short
    @State private var scopeThisFolder = false
    @State private var routingMessage: String?

    private var router: ModelRouter { ModelRouter(configuration: .fromEnvironment()) }
    private var route: ModelRoute? { router.route(forStructuredOutput: mode.outputType) }
    private var routeModel: ModelSummary? {
        guard let route else { return nil }
        return library.resolvedModel(for: route.role, configuration: router.configuration)
    }

    private var scope: RetrievalScope {
        (scopeThisFolder && scopeFolderID != nil) ? RetrievalScope(folderIDs: [scopeFolderID!]) : .wholeMatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Ask the Documents").font(.title2.weight(.semibold))
                Spacer()
                Button("Done", action: onClose)
            }
            .padding()
            Divider()
            Form {
                TextField("Your question", text: $question, axis: .vertical)
                    .lineLimit(2...4)
                Picker("Answer style", selection: $mode) {
                    Text("Short").tag(DocumentAnswerMode.short)
                    Text("Memo").tag(DocumentAnswerMode.memo)
                }
                .pickerStyle(.segmented)
                if scopeFolderID != nil {
                    Toggle("Limit to the selected folder", isOn: $scopeThisFolder)
                }
                if let readiness = qa.scopeReadiness(scope: scope) {
                    Text("\(readiness.readyDocuments)/\(readiness.totalDocuments) documents indexed")
                        .font(.caption).foregroundStyle(readiness.isFullyReady ? Color.secondary : Color.orange)
                }
                routeStatus
                if let routingMessage {
                    Text(routingMessage).font(.caption).foregroundStyle(.orange)
                }
                if let message = qa.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)

            if let result = qa.lastResult {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if result.status == StructuredOutputStatus.needsReview.rawValue {
                            Label("Needs review — \(result.warnings.joined(separator: " "))", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Text(Self.markdown(result.markdown))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
                .frame(minHeight: 200)
            }

            Divider()
            HStack {
                if let result = qa.lastResult {
                    Button("Regenerate") { Task { await regenerate(outputID: result.outputID) } }
                        .disabled(qa.isGenerating || routeModel == nil)
                }
                Spacer()
                if qa.isGenerating { ProgressView().controlSize(.small) }
                Button("Ask") { Task { await ask() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(qa.isGenerating || routeModel == nil || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 620, height: 600)
        .onAppear { library.refresh() }
    }

    @ViewBuilder
    private var routeStatus: some View {
        if let route {
            if let routeModel {
                Text("Uses \(route.role.displayName): \(routeModel.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Assign a \(route.role.displayName) model in Models to ask documents.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func ask() async {
        guard let resolved = await resolveRouteModel() else { return }
        _ = await qa.generate(
            question: question,
            scope: scope,
            mode: mode,
            modelID: resolved.modelID,
            route: resolved.route
        )
    }

    private func regenerate(outputID: String) async {
        guard let resolved = await resolveRouteModel() else { return }
        _ = await qa.regenerate(outputID: outputID, modelID: resolved.modelID, route: resolved.route)
    }

    private func resolveRouteModel() async -> (modelID: ModelID, route: ModelRoute)? {
        routingMessage = nil
        guard let route else {
            routingMessage = "No route is available for this document output."
            return nil
        }
        switch await library.ensureLoadedRoutedModelID(for: route.role, configuration: router.configuration) {
        case let .success(modelID):
            return (modelID, route)
        case let .failure(issue):
            routingMessage = issue.message
            return nil
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// One-shot fact chronology over the matter's documents (WO 42), in a table or
/// narrative format. Saved to the Outputs tab with its source set.
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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Fact Chronology").font(.title2.weight(.semibold))
                Spacer()
                Button("Done", action: onClose)
            }
            .padding()
            Divider()
            Form {
                Picker("Format", selection: $format) {
                    Text("Table").tag(DocumentChronologyFormat.table)
                    Text("Narrative").tag(DocumentChronologyFormat.narrative)
                }
                .pickerStyle(.segmented)
                if scopeFolderID != nil {
                    Toggle("Limit to the selected folder", isOn: $scopeThisFolder)
                }
                if let readiness = chronology.scopeReadiness(scope: scope) {
                    Text("\(readiness.readyDocuments)/\(readiness.totalDocuments) documents indexed")
                        .font(.caption).foregroundStyle(readiness.isFullyReady ? Color.secondary : Color.orange)
                }
                routeStatus
                if let routingMessage {
                    Text(routingMessage).font(.caption).foregroundStyle(.orange)
                }
                if let message = chronology.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)

            if let result = chronology.lastResult {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if result.status == StructuredOutputStatus.needsReview.rawValue {
                            Label("Needs review — \(result.warnings.joined(separator: " "))", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Text((try? AttributedString(markdown: result.markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(result.markdown))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
                .frame(minHeight: 220)
            }

            Divider()
            HStack {
                if let result = chronology.lastResult {
                    Button("Regenerate") { Task { await regenerate(outputID: result.outputID) } }
                        .disabled(chronology.isGenerating || routeModel == nil)
                }
                Spacer()
                if chronology.isGenerating { ProgressView().controlSize(.small) }
                Button("Generate") { Task { await generate() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chronology.isGenerating || routeModel == nil)
            }
            .padding()
        }
        .frame(width: 640, height: 620)
        .onAppear { library.refresh() }
    }

    @ViewBuilder
    private var routeStatus: some View {
        if let route {
            if let routeModel {
                Text("Uses \(route.role.displayName): \(routeModel.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Assign a \(route.role.displayName) model in Models to build a chronology.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func generate() async {
        guard let resolved = await resolveRouteModel() else { return }
        _ = await chronology.generate(
            scope: scope,
            format: format,
            modelID: resolved.modelID,
            route: resolved.route
        )
    }

    private func regenerate(outputID: String) async {
        guard let resolved = await resolveRouteModel() else { return }
        _ = await chronology.regenerate(outputID: outputID, modelID: resolved.modelID, route: resolved.route)
    }

    private func resolveRouteModel() async -> (modelID: ModelID, route: ModelRoute)? {
        routingMessage = nil
        guard let route else {
            routingMessage = "No route is available for this chronology."
            return nil
        }
        switch await library.ensureLoadedRoutedModelID(for: route.role, configuration: router.configuration) {
        case let .success(modelID):
            return (modelID, route)
        case let .failure(issue):
            routingMessage = issue.message
            return nil
        }
    }
}

/// In-app source preview (WO 40): PDF page, image, or normalized text with a
/// best-effort highlight, plus source metadata/warnings. Never fails silently —
/// an unavailable visual falls back to normalized text (plan §11.2).
struct DocumentPreviewView: View {
    let model: DocumentPreviewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.documentName).font(.headline)
                    Text(model.locatorDisplay).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding()
            if !model.warnings.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(model.warnings.joined(separator: " ")).font(.caption).foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal).padding(.bottom, 6)
            }
            Divider()
            body(for: model.kind)
                .frame(minWidth: 560, minHeight: 460)
        }
    }

    @ViewBuilder
    private func body(for kind: DocumentPreviewModel.Kind) -> some View {
        switch kind {
        case let .pdf(path, pageIndex, highlightText):
            PDFKitView(url: URL(fileURLWithPath: path), pageIndex: pageIndex, highlightText: highlightText)
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
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        case let .unavailable(reason, fallbackText):
            VStack(alignment: .leading, spacing: 8) {
                Label(reason, systemImage: "doc.questionmark").font(.callout).foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    Text(fallbackText.isEmpty ? "No extracted text available." : fallbackText)
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
            if let selection = document.findString(snippet, withOptions: [.caseInsensitive]).first {
                selection.color = .yellow
                view.highlightedSelections = [selection]
                view.go(to: selection)
            }
        }
    }
}
