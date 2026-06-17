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
        let now = Date()

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

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaintStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
