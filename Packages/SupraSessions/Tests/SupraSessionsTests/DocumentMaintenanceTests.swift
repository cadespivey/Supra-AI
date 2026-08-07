import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentMaintenanceTests: XCTestCase {
    func testPurgeRemovesExpiredButKeepsRecentAndCleansBlob() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let now = Date(timeIntervalSince1970: 1_790_006_401)

        // One blob shared by an expired and a recent instance → blob kept until both gone.
        let oldBlob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "old", byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/old.txt")).blob
        let expired = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id, blobID: oldBlob.id, displayName: "expired.txt",
            status: MatterDocumentStatus.deleted.rawValue,
            deletedAt: now.addingTimeInterval(-40 * 86_400)
        ))
        let recent = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id, blobID: oldBlob.id, displayName: "recent.txt",
            status: MatterDocumentStatus.deleted.rawValue,
            deletedAt: now.addingTimeInterval(-2 * 86_400)
        ))

        let maintenance = DocumentMaintenance(store: store, storage: DocumentStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        maintenance.setAutoPurgeDays(30)

        let purged = maintenance.purgeExpired(now: now)
        XCTAssertEqual(purged, 1)
        XCTAssertNil(try store.documentLibrary.fetchDocument(id: expired.id))
        XCTAssertNotNil(try store.documentLibrary.fetchDocument(id: recent.id))
        // Blob survives because the recent instance still references it.
        XCTAssertNotNil(try store.documentLibrary.fetchBlob(id: oldBlob.id))
        let deletionEvents = try store.auditEvents.fetchEvents(
            relatedTable: "matter_documents",
            relatedID: expired.id,
            eventType: "document_permanently_deleted"
        )
        XCTAssertEqual(
            deletionEvents.count,
            1,
            "auto-purge must rely on the repository's atomic base audit instead of duplicating it"
        )
        XCTAssertEqual(deletionEvents.first?.actor, "system")
        XCTAssertEqual(deletionEvents.first?.timestamp, now)
    }

    func testAutoPurgeDisabledWhenZeroDays() throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: "b", byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/b.txt")).blob
        _ = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id, blobID: blob.id, displayName: "x.txt",
            status: MatterDocumentStatus.deleted.rawValue, deletedAt: Date().addingTimeInterval(-1000 * 86_400)
        ))
        let maintenance = DocumentMaintenance(store: store, storage: DocumentStorage(root: FileManager.default.temporaryDirectory))
        maintenance.setAutoPurgeDays(0)
        XCTAssertEqual(maintenance.purgeExpired(), 0)
    }

    func testAutoPurgeDoesNotHollowADeletedButRestorableMatter() throws {
        // Expected RED: the expiry query includes documents soft-deleted by a
        // matter delete, so maintenance permanently removes their source graph
        // even though matters are manual-delete-only and still restorable.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Restorable matter 613")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "restorable-matter-blob-613",
            byteSize: 613,
            originalExtension: "txt",
            managedRelativePath: "blobs/restorable-matter-613.txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "Restorable source 613.txt",
            status: MatterDocumentStatus.ready.rawValue
        ))
        let now = Date(timeIntervalSince1970: 1_790_106_401)
        try store.matters.softDeleteMatter(
            id: matter.id,
            deletedAt: now.addingTimeInterval(-40 * 86_400)
        )
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestorableMatter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let maintenance = DocumentMaintenance(
            store: store,
            storage: DocumentStorage(root: storageRoot)
        )
        maintenance.setAutoPurgeDays(30)

        XCTAssertEqual(maintenance.purgeExpired(now: now), 0)
        XCTAssertNotNil(try store.documentLibrary.fetchDocument(id: document.id))
        XCTAssertNotNil(try store.documentLibrary.fetchBlob(id: blob.id))

        XCTAssertTrue(try store.matters.restoreMatter(id: matter.id))
        let restored = try XCTUnwrap(try store.documentLibrary.fetchDocument(id: document.id))
        XCTAssertNil(restored.deletedAt)
        XCTAssertEqual(restored.status, MatterDocumentStatus.ready.rawValue)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaintStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
