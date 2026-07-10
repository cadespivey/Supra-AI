import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

/// Gating test for folder-targeted imports (T-DD-01): dropping or picking files
/// while a folder is selected in the Documents sidebar must file them into that
/// folder, not into the All Documents root.
@MainActor
final class MatterDocumentsImportTargetTests: XCTestCase {

    // Expected RED: assertion failure — `importItems(_:)` currently ignores the
    // sidebar selection and always imports to the root, so the imported
    // document's folderID is nil, not the selected folder's id.
    func testImportItemsFilesIntoTheSelectedFolderAndRootForAllDocuments() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportTargetTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = base.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let intoFolder = sourceDir.appendingPathComponent("dropped-into-folder.txt")
        try Data("Deposition summary for the folder drop.".utf8).write(to: intoFolder)
        let atRoot = sourceDir.appendingPathComponent("dropped-at-root.txt")
        try Data("Root-level import with All Documents selected.".utf8).write(to: atRoot)

        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let storage = DocumentStorage(root: base.appendingPathComponent("Managed", isDirectory: true))
        let queue = DocumentProcessingQueue(
            store: store,
            importService: DocumentImportService(store: store, storage: storage),
            makeIndexingService: { DocumentIndexingService(store: store, embedder: nil) },
            notifier: NoopDocumentNotifier()
        )
        let controller = MatterDocumentsController(
            matterID: matter.id, store: store, queue: queue,
            isImportReady: { true }, storage: storage
        )
        let folder = try store.documentLibrary.createFolder(matterID: matter.id, name: "Depositions")
        controller.reload()

        // Import with a folder selected: the document must land in that folder.
        controller.selectedSidebarID = folder.id
        controller.importItems([intoFolder])
        await queue.waitUntilIdle()
        let filed = try XCTUnwrap(
            store.documentLibrary.fetchDocuments(matterID: matter.id)
                .first { $0.displayName == "dropped-into-folder.txt" }
        )
        XCTAssertEqual(
            filed.folderID, folder.id,
            "an import made while a folder is selected must file into that folder"
        )

        // With All Documents selected, imports keep landing at the root.
        controller.selectedSidebarID = MatterDocumentsController.allDocumentsTag
        controller.importItems([atRoot])
        await queue.waitUntilIdle()
        let rooted = try XCTUnwrap(
            store.documentLibrary.fetchDocuments(matterID: matter.id)
                .first { $0.displayName == "dropped-at-root.txt" }
        )
        XCTAssertNil(rooted.folderID, "All Documents keeps the existing root-import behavior")
    }
}

/// Queue notifier stub — the system notifier would hit UNUserNotificationCenter,
/// which is unavailable in an SPM test process.
private final class NoopDocumentNotifier: DocumentNotifying, @unchecked Sendable {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .authorized }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .authorized }
    func notify(title: String, body: String) async {}
}
