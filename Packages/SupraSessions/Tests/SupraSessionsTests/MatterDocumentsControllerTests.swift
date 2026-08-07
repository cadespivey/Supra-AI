import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

/// Controller-level behavior of the matter Documents tab beyond import targeting
/// (which MatterDocumentsImportTargetTests covers): here, the unclassified-count
/// gate that drives the "N documents not yet classified" caption and its
/// Classify button.
@MainActor
final class MatterDocumentsControllerTests: XCTestCase {

    func testPermanentDeleteFailureKeepsDocumentAndSurfacesErrorWithoutFalseSuccess() throws {
        // Expected RED: the controller currently swallows the repository error,
        // writes a caller-owned success event, and gives the user no failure state.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ControllerDeleteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic deletion rollback")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "controller-delete-rollback-97",
            byteSize: 97,
            originalExtension: "txt",
            managedRelativePath: "blobs/controller-delete-rollback-97.txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "rollback-97.txt"
        ))
        try store.documentLibrary.softDeleteDocument(id: document.id)
        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER controller_reject_document_delete_audit
                BEFORE INSERT ON audit_events
                WHEN NEW.event_type = 'document_permanently_deleted'
                BEGIN
                    SELECT RAISE(ABORT, 'synthetic controller delete rollback');
                END
                """)
        }
        let storage = DocumentStorage(root: base.appendingPathComponent("Managed"))
        let importService = DocumentImportService(store: store, storage: storage, ocr: nil)
        let queue = DocumentProcessingQueue(
            store: store,
            importService: importService,
            makeIndexingService: { DocumentIndexingService(store: store, embedder: nil) },
            notifier: NoopDocumentNotifier()
        )
        let controller = MatterDocumentsController(
            matterID: matter.id,
            store: store,
            queue: queue,
            isImportReady: { true },
            storage: storage
        )

        controller.permanentlyDelete(documentID: document.id)

        XCTAssertNotNil(try store.documentLibrary.fetchDocument(id: document.id))
        XCTAssertTrue(controller.trashedDocuments.contains { $0.id == document.id })
        XCTAssertTrue(controller.message?.contains("synthetic controller delete rollback") ?? false)
        XCTAssertTrue(
            try store.auditEvents.fetchEvents(
                relatedTable: "matter_documents",
                relatedID: document.id,
                eventType: "document_permanently_deleted"
            ).isEmpty
        )
    }

    // Expected RED: observed 2 — `unclassifiedCount` today counts every document
    // that satisfies `needsClassification`, including one whose extracted text sits
    // below the 40-character classification floor (`OCRPolicy.minimumUsableTextLength`).
    // `classifyMatter` permanently skips such documents (its minimum-text guard), so
    // the caption stays at "1 documents not yet classified" forever and the Classify
    // button visibly no-ops (the live repro: an OCR'd blank scan in needs_review).
    // The count must include only documents the classifier can actually classify:
    // needsClassification AND usable text at or above the floor.
    func testUnclassifiedCountExcludesDocumentsBelowClassificationTextFloor() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ControllerTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = base.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let storage = DocumentStorage(root: base.appendingPathComponent("Managed", isDirectory: true))
        let importService = DocumentImportService(store: store, storage: storage, ocr: nil)

        // (a) A classifiable document: extracted, unclassified, comfortably over the
        // floor — imported through the real pipeline so its parts carry real counts.
        let agreementText = "Service agreement with an indemnification and limitation-of-liability clause."
        XCTAssertGreaterThanOrEqual(
            agreementText.filter { !$0.isWhitespace }.count, OCRPolicy.minimumUsableTextLength,
            "fixture: the agreement must clear the classification floor"
        )
        let agreementURL = sourceDir.appendingPathComponent("agreement.txt")
        try agreementText.write(to: agreementURL, atomically: true, encoding: .utf8)
        _ = try await importService.importSources([agreementURL], matterID: matter.id)

        // (b) An OCR'd blank scan: ocr_complete / needs_review with too little text to
        // ever classify. Seeded directly (demo-fixture pattern) with a real part row.
        let scanText = "Too short."
        XCTAssertLessThan(
            scanText.filter { !$0.isWhitespace }.count, OCRPolicy.minimumUsableTextLength,
            "fixture: the scan must sit under the classification floor"
        )
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "controller-test-blank-scan",
            byteSize: 0,
            originalExtension: "png",
            managedRelativePath: "test/blank-scan.png"
        )).blob
        let scan = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "blank-scan.png",
            status: MatterDocumentStatus.needsReview.rawValue,
            extractionStatus: DocumentExtractionStatus.ocrComplete.rawValue
        ))
        try store.documentIndex.replaceParts(documentID: scan.id, parts: [
            DocumentPagePartRecord(
                documentID: scan.id, partIndex: 0,
                sourceKind: DocumentSourceKind.image.rawValue,
                normalizedText: scanText, charCount: scanText.count, ocrConfidence: 0.2
            )
        ])

        let queue = DocumentProcessingQueue(
            store: store,
            importService: importService,
            makeIndexingService: { DocumentIndexingService(store: store, embedder: nil) },
            notifier: NoopDocumentNotifier()
        )
        let controller = MatterDocumentsController(
            matterID: matter.id, store: store, queue: queue,
            isImportReady: { true }, storage: storage
        )
        controller.reload()

        // Precondition: BOTH documents pass the needsClassification gate, so the text
        // floor is the only discriminator and the count below is the pin.
        let documents = try store.documentLibrary.fetchDocuments(matterID: matter.id)
        XCTAssertEqual(documents.count, 2, "precondition: the agreement and the scan are both live")
        XCTAssertTrue(
            documents.allSatisfy(DocumentClassificationService.needsClassification),
            "precondition: both documents satisfy the needsClassification gate"
        )

        // Only the agreement is classifiable. The sub-floor scan must not be counted —
        // counting it is what pins the caption/button to a Classify that no-ops.
        XCTAssertEqual(
            controller.unclassifiedCount, 1,
            "unclassifiedCount must exclude documents under the classification text floor"
        )
    }
}

/// Queue notifier stub — the system notifier would hit UNUserNotificationCenter,
/// which is unavailable in an SPM test process.
private final class NoopDocumentNotifier: DocumentNotifying, @unchecked Sendable {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .authorized }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .authorized }
    func notify(title: String, body: String) async {}
}
