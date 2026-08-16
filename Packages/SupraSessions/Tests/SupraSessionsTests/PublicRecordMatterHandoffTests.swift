import Foundation
import SupraDocuments
import SupraResearch
import SupraStore
@testable import SupraSessions
import XCTest

@MainActor
final class PublicRecordMatterHandoffTests: XCTestCase {
    private enum Wire {
        static let matterName = "Public Record Matter 751"
        static let complaintID = "884211"
        static let company = "Synthetic Harbor Bank"
        static let narrative = "Synthetic consumer allegation for a hermetic handoff fixture."
        static let sourceURL = "https://www.consumerfinance.gov/data-research/consumer-complaints/search/detail/884211"
    }

    func testExplicitSnapshotImportUsesOrdinaryReadinessAndIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PublicRecordMatterHandoffTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DocumentStorage(root: root.appendingPathComponent("Managed", isDirectory: true))
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: Wire.matterName)
        let service = PublicRecordMatterHandoff(
            store: store,
            importService: DocumentImportService(store: store, storage: storage, ocr: nil),
            indexingService: DocumentIndexingService(store: store, embedder: nil),
            stagingRoot: root.appendingPathComponent("Staging", isDirectory: true)
        )
        let record = CfpbComplaintRecord(
            complaintId: Wire.complaintID,
            company: Wire.company,
            product: "Checking account",
            issue: "Account closure",
            state: "FL",
            dateReceived: "2026-08-01",
            narrative: Wire.narrative,
            sourceUrl: Wire.sourceURL,
            retrievedAt: Date(timeIntervalSince1970: 1_786_700_000),
            raw: .object(["complaint_id": .string(Wire.complaintID)])
        )
        let snapshot = PublicRecordSnapshot.cfpb(record)

        let first = await service.addToMatter(snapshot: snapshot, matterID: matter.id)
        guard case let .awaitingReadiness(firstReceipt) = first else {
            return XCTFail("A public record without an embedding model must remain visibly not ready")
        }
        XCTAssertEqual(firstReceipt.snapshotID, "cfpb:\(Wire.complaintID)")
        XCTAssertEqual(firstReceipt.matterID, matter.id)
        XCTAssertFalse(firstReceipt.reusedExistingDocument)
        XCTAssertFalse(firstReceipt.readinessReceipt.isBaseReady)
        XCTAssertTrue(firstReceipt.readinessReceipt.exclusions.contains(.activeEmbeddingModelMissing))

        let document = try XCTUnwrap(store.documentLibrary.fetchDocument(id: firstReceipt.documentID))
        let blob = try XCTUnwrap(store.documentLibrary.fetchBlob(id: document.blobID))
        let retained = try String(
            contentsOf: storage.url(forManagedRelativePath: blob.managedRelativePath),
            encoding: .utf8
        )
        XCTAssertTrue(retained.contains("Provider: CFPB Consumer Complaint Database"))
        XCTAssertTrue(retained.contains("Record identity: cfpb:\(Wire.complaintID)"))
        XCTAssertTrue(retained.contains(Wire.narrative))
        XCTAssertTrue(retained.contains(Wire.sourceURL))
        XCTAssertTrue(retained.contains("allegation, not an agency finding"))

        let second = await service.addToMatter(snapshot: snapshot, matterID: matter.id)
        guard case let .awaitingReadiness(secondReceipt) = second else {
            return XCTFail("The idempotent retry must retain the same canonical readiness state")
        }
        XCTAssertEqual(secondReceipt.documentID, firstReceipt.documentID)
        XCTAssertTrue(secondReceipt.reusedExistingDocument)
        XCTAssertNil(secondReceipt.importBatchID)
        XCTAssertEqual(try store.documentLibrary.fetchDocuments(matterID: matter.id).count, 1)
    }
}
