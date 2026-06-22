import Foundation
import SupraCore
import SupraDocuments
import SupraStore
@testable import SupraSessions
import XCTest

@MainActor
final class BillingProfileControllerTests: XCTestCase {

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BillingProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }

    func testSaveAndReloadOverrideAndCodeSet() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Meridian MSA")
        let controller = BillingProfileController(matterID: matter.id, store: store)

        XCTAssertEqual(controller.codeSet, .none)
        XCTAssertFalse(controller.hasUnsavedChanges)

        controller.overrideInstructions = "Cap intra-office conferences; bill travel at 50%."
        controller.codeSet = .transactional
        controller.markEdited()
        XCTAssertTrue(controller.hasUnsavedChanges)
        controller.save()
        XCTAssertFalse(controller.hasUnsavedChanges)

        // A fresh controller reads the persisted profile.
        let reloaded = BillingProfileController(matterID: matter.id, store: store)
        XCTAssertEqual(reloaded.overrideInstructions, "Cap intra-office conferences; bill travel at 50%.")
        XCTAssertEqual(reloaded.codeSet, .transactional)

        // And it round-trips through the repository.
        let profile = try XCTUnwrap(store.billing.billingProfile(matterID: matter.id))
        XCTAssertEqual(profile.billingCodeSet, "transactional")
    }

    func testEmptyOverrideSavesAsNil() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let controller = BillingProfileController(matterID: matter.id, store: store)
        controller.overrideInstructions = "   "
        controller.save()
        let profile = try XCTUnwrap(store.billing.billingProfile(matterID: matter.id))
        XCTAssertNil(profile.overrideInstructions)
    }

    func testGuidelineDocumentsListReflectsTaggedDocs() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "VyStar")
        // A document tagged "billing guideline" plus an untagged one.
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "g", byteSize: 1, originalExtension: "pdf", managedRelativePath: "blobs/g.pdf")).blob
        let guideline = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id, blobID: blob.id, displayName: "VyStar Billing Guidelines.pdf",
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        ))
        let other = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id, blobID: blob.id, displayName: "complaint.pdf"
        ))
        let tag = try store.documentLibrary.createTag(matterID: matter.id, name: BillingInstructions.guidelineTagName)
        try store.documentLibrary.assignTag(tagID: tag.id, documentID: guideline.id)

        let controller = BillingProfileController(matterID: matter.id, store: store)
        XCTAssertEqual(controller.guidelineDocuments.map(\.id), [guideline.id])
        XCTAssertTrue(controller.isExtracted(guideline))
        XCTAssertFalse(controller.guidelineDocuments.contains { $0.id == other.id })

        // Removing untags (but leaves the doc in the library).
        controller.removeGuideline(documentID: guideline.id)
        XCTAssertTrue(controller.guidelineDocuments.isEmpty)
        XCTAssertNotNil(try store.documentLibrary.fetchDocument(id: guideline.id))
    }

    /// The import path auto-tags only the documents from its own batch — a
    /// pre-existing (or concurrently-imported) matter document is never mis-tagged.
    func testImportGuidelinesTagsOnlyItsOwnBatch() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "VyStar")

        // A pre-existing, untagged matter document that must stay untagged.
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(sha256: "pre", byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/pre.txt")
        ).blob
        let preExisting = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(matterID: matter.id, blobID: blob.id, displayName: "complaint.txt")
        )

        // A real processing queue + a guideline source file on disk.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("GuidelineImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let queue = DocumentProcessingQueue(
            store: store,
            importService: DocumentImportService(store: store, storage: DocumentStorage(root: base.appendingPathComponent("store")), ocr: nil),
            makeIndexingService: { DocumentIndexingService(store: store, embedder: nil) },
            notifier: SilentNotifier() // SystemDocumentNotifier needs an app bundle (crashes headless)
        )
        let guidelineURL = base.appendingPathComponent("VyStar Billing Guidelines.txt")
        try "Travel is billed at 50 percent. Block billing is prohibited.".write(to: guidelineURL, atomically: true, encoding: .utf8)

        let controller = BillingProfileController(matterID: matter.id, store: store, queue: queue, isImportReady: { true })
        controller.importGuidelines([guidelineURL])
        await queue.waitUntilIdle()
        controller.reconcileGuidelineTags() // deterministic stand-in for the queue observer

        XCTAssertEqual(controller.guidelineDocuments.map(\.displayName), ["VyStar Billing Guidelines.txt"])
        XCTAssertFalse(controller.guidelineDocuments.contains { $0.id == preExisting.id }, "pre-existing doc must not be auto-tagged")
    }
}

/// A no-op notifier so the processing queue doesn't reach for the user-notification
/// center (which has no app bundle under `swift test` and would crash).
private struct SilentNotifier: DocumentNotifying {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .authorized }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .authorized }
    func notify(title: String, body: String) async {}
}
