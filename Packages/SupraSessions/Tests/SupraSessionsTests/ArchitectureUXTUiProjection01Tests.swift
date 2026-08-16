import Foundation
import GRDB
import SupraCore
import SupraDocuments
import SupraStore
@testable import SupraSessions
import XCTest

/// T-UI-PROJECTION-01
///
/// Expected RED: the Documents and Billing controllers still publish Store records,
/// ScratchPad publishes `ScratchPadRepository.EntryHit`, and DiagnosticsView reads
/// `DiagnosticEventRecord` directly. The view-facing projection types and
/// Diagnostics controller exercised below do not exist yet.
@MainActor
final class ArchitectureUXTUiProjection01Tests: XCTestCase {
    private enum Wire {
        static let matterID = "matter-ui-projection-709"
        static let recordID = "record-713"
        static let documentID = "document-ui-projection-719"
        static let folderID = "folder-ui-projection-727"
        static let wire7 = "T_UI_PROJECTION_01_WIRE_731-v7"
        static let wire8 = "T_UI_PROJECTION_01_WIRE_731-v8"
        static let forbiddenDefault = "DEFAULT-000"
    }

    func testDocumentAndFolderSummariesPreserveIdentityUpdatesDeletesSortingAndFiltering() throws {
        let fixture = try makeDocumentFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let controller = MatterDocumentsController(
            matterID: Wire.matterID,
            store: fixture.store,
            queue: fixture.queue,
            isImportReady: { true },
            storage: fixture.storage
        )

        let documents: [MatterDocumentSummary] = controller.documents
        let folders: [DocumentFolderSummary] = controller.folders
        XCTAssertEqual(documents.map(\.id), [Wire.documentID, "document-ui-projection-733"])
        XCTAssertEqual(documents.first?.displayName, Wire.wire7)
        XCTAssertEqual(documents.first?.folderID, Wire.folderID)
        XCTAssertEqual(documents.first?.status, MatterDocumentStatus.ready)
        XCTAssertEqual(folders.map(\.id), [Wire.folderID, "folder-ui-projection-739"])
        XCTAssertEqual(folders.first?.name, "A-\(Wire.wire7)")
        XCTAssertFalse(documents.map(\.displayName).joined().contains(Wire.forbiddenDefault))

        controller.selectedSidebarID = Wire.folderID
        XCTAssertEqual(controller.visibleDocuments.map(\.id), [Wire.documentID])

        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE matter_documents SET display_name = ?, status = ?, updated_at = ? WHERE id = ?",
                arguments: [Wire.wire8, MatterDocumentStatus.needsReview.rawValue, Date(), Wire.documentID]
            )
        }
        controller.reload()
        XCTAssertEqual(controller.documents.first?.id, Wire.documentID)
        XCTAssertEqual(controller.documents.first?.displayName, Wire.wire8)
        XCTAssertEqual(controller.documents.first?.status, MatterDocumentStatus.needsReview)

        controller.softDelete(documentID: Wire.documentID)
        XCTAssertFalse(controller.documents.contains { $0.id == Wire.documentID })
        XCTAssertEqual(controller.trashedDocuments.map(\.id), [Wire.documentID])
    }

    func testBillingLineViewPreservesIdentityAcrossNPlusOneAndDelete() throws {
        let store = try SupraStore.inMemory()
        let day = try store.scratchPad.fetchOrCreateDay("2026-08-14")
        try store.database.writer.write { db in
            try BillingDraftRecord(
                id: "draft-ui-projection-743",
                dayID: day.id,
                version: 7,
                modelID: "model-ui-projection-751"
            ).insert(db)
            try BillingLineItemRecord(
                id: Wire.recordID,
                draftID: "draft-ui-projection-743",
                seq: 7,
                clientID: "client-ui-projection-757",
                matterID: nil,
                narrative: Wire.wire7,
                hours: 0.7,
                workDate: "2026-08-14",
                utbmsTaskCode: "L713",
                utbmsActivityCode: "A713",
                confidence: .high,
                sourceEntryIDsJSON: ScratchPadJSON.encodeStrings(["entry-ui-projection-761"])
            ).insert(db)
            try BillingLineItemRecord(
                id: "record-769",
                draftID: "draft-ui-projection-743",
                seq: 8,
                narrative: "Zulu UI projection",
                hours: 0.8,
                workDate: "2026-08-14"
            ).insert(db)
        }
        let controller = BillingDraftController(
            store: store,
            service: BillingDraftService(store: store) { _, _ in "{}" },
            timekeeper: BillingTimekeeper(
                id: "timekeeper-773",
                name: "Synthetic Timekeeper",
                classification: "PARTNER",
                defaultRate: 713,
                lawFirmID: "firm-719"
            )
        )
        controller.bind(dayID: day.id)

        let lines: [BillingLineView] = controller.lines
        XCTAssertEqual(lines.map(\.id), [Wire.recordID, "record-769"])
        XCTAssertEqual(lines.first?.seq, 7)
        XCTAssertEqual(lines.first?.narrative, Wire.wire7)
        XCTAssertEqual(lines.first?.sourceEntryIDs, ["entry-ui-projection-761"])
        XCTAssertFalse(lines.map(\.narrative).joined().contains(Wire.forbiddenDefault))

        controller.editLine(
            id: Wire.recordID,
            narrative: Wire.wire8,
            hours: 0.8,
            taskCode: "L719",
            activityCode: "A719"
        )
        XCTAssertEqual(controller.lines.first?.id, Wire.recordID)
        XCTAssertEqual(controller.lines.first?.seq, 7)
        XCTAssertEqual(controller.lines.first?.narrative, Wire.wire8)
        XCTAssertTrue(controller.lines.first?.userEdited == true)

        controller.deleteLine(id: Wire.recordID)
        XCTAssertEqual(controller.lines.map(\.id), ["record-769"])
    }

    func testScratchPadSearchHitMapsIdentityAndKeepsRepositoryOrderingAndFiltering() throws {
        let store = try SupraStore.inMemory()
        let day7 = try store.scratchPad.fetchOrCreateDay("2026-08-07")
        let day8 = try store.scratchPad.fetchOrCreateDay("2026-08-08")
        try store.database.writer.write { db in
            try ScratchPadEntryRecord(
                id: Wire.recordID,
                dayID: day7.id,
                seq: 7,
                text: "\(Wire.wire7) #projection",
                tagsJSON: ScratchPadJSON.encodeStrings(["projection"])
            ).insert(db)
            try ScratchPadEntryRecord(
                id: "record-787",
                dayID: day8.id,
                seq: 8,
                text: "\(Wire.wire8) #projection",
                tagsJSON: ScratchPadJSON.encodeStrings(["projection"])
            ).insert(db)
        }
        let controller = ScratchPadController(store: store)
        controller.search("T_UI_PROJECTION_01")

        let hits: [ScratchPadSearchHit] = controller.searchResults
        XCTAssertEqual(hits.map(\.id), ["record-787", Wire.recordID])
        XCTAssertEqual(hits.map(\.day), ["2026-08-08", "2026-08-07"])
        XCTAssertEqual(hits.last?.tags, ["projection"])
        XCTAssertFalse(hits.map(\.text).joined().contains(Wire.forbiddenDefault))

        controller.search("x")
        XCTAssertTrue(controller.searchResults.isEmpty)
    }

    func testDiagnosticEventSummaryPreservesIdentitySortingAndCategoryFilter() throws {
        let store = try SupraStore.inMemory()
        let older = Date(timeIntervalSince1970: 7)
        let newer = Date(timeIntervalSince1970: 8)
        try store.diagnostics.recordDiagnosticEvent(DiagnosticEventRecord(
            id: Wire.recordID,
            timestamp: older,
            severity: "info",
            category: "performance",
            message: Wire.wire7,
            technicalDetails: "private-detail-should-not-project",
            generationID: "generation-797",
            modelID: "model-799"
        ))
        try store.diagnostics.recordDiagnosticEvent(DiagnosticEventRecord(
            id: "record-809",
            timestamp: newer,
            severity: "warning",
            category: "network",
            message: "Network projection v8"
        ))

        let controller = DiagnosticsController(store: store)
        controller.reload(limit: 8)
        let events: [DiagnosticEventSummary] = controller.events
        XCTAssertEqual(events.map(\.id), ["record-809", Wire.recordID])
        XCTAssertEqual(events.last?.message, Wire.wire7)
        XCTAssertEqual(events.last?.modelID, "model-799")
        XCTAssertEqual(controller.performanceEvents(limit: 8).map(\.id), [Wire.recordID])
        XCTAssertFalse(events.map(\.message).joined().contains(Wire.forbiddenDefault))
    }

    func testShippingViewsDoNotNameStorePersistenceRecords() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SupraSessionsTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SupraSessions
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository
        let expectations: [(String, [String])] = [
            ("Apps/SupraAI/SupraAI/Documents/MatterDocumentsView.swift", [
                "MatterDocumentRecord", "DocumentFolderRecord",
            ]),
            ("Apps/SupraAI/SupraAI/Matters/MatterBillingView.swift", [
                "MatterDocumentRecord",
            ]),
            ("Apps/SupraAI/SupraAI/ScratchPad/BillingDraftView.swift", [
                "BillingLineItemRecord",
            ]),
            ("Apps/SupraAI/SupraAI/ScratchPad/ScratchPadView.swift", [
                "ScratchPadRepository.EntryHit",
            ]),
            ("Apps/SupraAI/SupraAI/DiagnosticsView.swift", [
                "DiagnosticEventRecord",
            ]),
        ]
        for (relativePath, forbiddenNames) in expectations {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for forbiddenName in forbiddenNames {
                XCTAssertFalse(
                    source.contains(forbiddenName),
                    "\(relativePath) must consume a Sessions projection, not \(forbiddenName)"
                )
            }
        }
    }

    func testSavedWorkHandsExactMatterAndVersionToNotesOrBillingWithoutCopyingContent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SupraSessionsTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SupraSessions
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository
        func source(_ relativePath: String) throws -> String {
            try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
        }

        let detail = try source("Apps/SupraAI/SupraAI/Outputs/OutputDetailView.swift")
        let outputs = try source("Apps/SupraAI/SupraAI/Outputs/MatterOutputsView.swift")
        let workspace = try source("Apps/SupraAI/SupraAI/Matters/MatterWorkspaceView.swift")
        let scratchPad = try source("Apps/SupraAI/SupraAI/ScratchPad/ScratchPadView.swift")
        let shell = try source("Apps/SupraAI/SupraAI/MainShellView.swift")

        XCTAssertTrue(detail.contains("SavedWorkNotesHandoff"))
        XCTAssertTrue(detail.contains("Button(\"Open Notes & Time\")"))
        XCTAssertTrue(detail.contains("Button(\"Open Billing Rules\")"))
        XCTAssertTrue(outputs.contains("matterID: matter.id"))
        XCTAssertTrue(outputs.contains("navigationPath.removeAll()"))
        XCTAssertTrue(workspace.contains("onOpenNotesAndTime"))
        XCTAssertTrue(workspace.contains("onOpenBilling: { tab = .billing }"))
        XCTAssertTrue(shell.contains("pendingSavedWorkNotesHandoff"))
        XCTAssertTrue(shell.contains("selectRoute(.scratchpad)"))
        XCTAssertTrue(scratchPad.contains("Button(\"Insert reference\")"))
        XCTAssertTrue(scratchPad.contains("[Saved Work: Saved chat answer"))
        XCTAssertTrue(scratchPad.contains("pendingMentions[matterHandle] = handoff.matterID"))
        XCTAssertFalse(scratchPad.contains("[Saved Work: \\(handoff.outputTitle)"))
        XCTAssertTrue(detail.contains("contentMarkdown: nil"))
    }

    private func makeDocumentFixture() throws -> (
        store: SupraStore,
        queue: DocumentProcessingQueue,
        storage: DocumentStorage,
        root: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("T-UI-PROJECTION-01-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SupraStore.inMemory()
        try store.database.writer.write { db in
            try MatterRecord(
                id: Wire.matterID,
                name: "Synthetic UI projection matter"
            ).insert(db)
        }
        try store.database.writer.write { db in
            try DocumentFolderRecord(
                id: Wire.folderID,
                matterID: Wire.matterID,
                name: "A-\(Wire.wire7)"
            ).insert(db)
            try DocumentFolderRecord(
                id: "folder-ui-projection-739",
                matterID: Wire.matterID,
                name: "Z-UI projection"
            ).insert(db)
            try DocumentBlobRecord(
                id: "blob-ui-projection-811",
                sha256: "sha-ui-projection-811",
                byteSize: 731,
                originalExtension: "txt",
                managedRelativePath: "blobs/ui-projection-811.txt"
            ).insert(db)
            try MatterDocumentRecord(
                id: Wire.documentID,
                matterID: Wire.matterID,
                blobID: "blob-ui-projection-811",
                folderID: Wire.folderID,
                displayName: Wire.wire7,
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.ready.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractionMethod: "synthetic-v7",
                extractedTextChecksum: "checksum-ui-projection-7",
                pagePartCount: 7,
                ocrConfidenceSummary: "confidence-0.713",
                hasUserEditedText: true
            ).insert(db)
            try MatterDocumentRecord(
                id: "document-ui-projection-733",
                matterID: Wire.matterID,
                blobID: "blob-ui-projection-811",
                displayName: "Zulu UI projection",
                status: MatterDocumentStatus.indexing.rawValue
            ).insert(db)
        }
        let storage = DocumentStorage(root: root.appendingPathComponent("Managed", isDirectory: true))
        let queue = DocumentProcessingQueue(
            store: store,
            importService: DocumentImportService(store: store, storage: storage, ocr: nil),
            makeIndexingService: { DocumentIndexingService(store: store, embedder: nil) },
            notifier: UIProjectionNoopNotifier()
        )
        return (store, queue, storage, root)
    }
}

private final class UIProjectionNoopNotifier: DocumentNotifying, @unchecked Sendable {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .authorized }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .authorized }
    func notify(title: String, body: String) async {}
}
