import Foundation
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class BlobIntegrityServiceTests: XCTestCase {
    func testACRBLOB006VerifierPersistsTypedMissingAndCorruptStatesInBoundedBatch() throws {
        // Expected RED: no bounded blob reconciler or typed integrity state exists.
        let fixture = try Fixture()
        let missingBytes = Data("MISSING-BLOB-CANARY".utf8)
        let corruptExpected = Data("EXPECTED-CORRUPT-CANARY".utf8)
        let corruptActual = Data("ACTUAL!!-CORRUPT-CANARY".utf8)
        let verifiedBytes = Data("VERIFIED-BLOB-CANARY".utf8)
        let missing = try fixture.insertBlob(id: "a-missing", bytes: missingBytes, writeManagedFile: false)
        let corrupt = try fixture.insertBlob(id: "b-corrupt", bytes: corruptExpected, managedBytes: corruptActual)
        let deferred = try fixture.insertBlob(id: "c-verified", bytes: verifiedBytes)

        let batch = try BlobIntegrityService(store: fixture.store, storage: fixture.storage)
            .verifyBatch(limit: 2)

        XCTAssertEqual(batch.results.map(\.blobID), [missing.id, corrupt.id])
        XCTAssertEqual(batch.results.map(\.state), [.missing, .corrupt])
        XCTAssertEqual(batch.nextCursor, corrupt.id)
        XCTAssertEqual(try fixture.store.documentLibrary.fetchBlob(id: missing.id)?.integrityStatus, DocumentBlobIntegrityStatus.missing.rawValue)
        XCTAssertEqual(try fixture.store.documentLibrary.fetchBlob(id: corrupt.id)?.integrityStatus, DocumentBlobIntegrityStatus.corrupt.rawValue)
        XCTAssertNotNil(try fixture.store.remediationRecovery.pendingItem(kind: .blobRepair, relatedID: missing.id))
        XCTAssertNotNil(try fixture.store.remediationRecovery.pendingItem(kind: .blobRepair, relatedID: corrupt.id))
        XCTAssertEqual(deferred.id, "c-verified")
        XCTAssertNil(try fixture.store.documentLibrary.fetchBlob(id: deferred.id)?.verifiedAt, "limit must bound verification work")
    }

    func testACRBLOB007RepairReimportsExpectedBytesAndMarksRowVerified() throws {
        // Expected RED: users have no repair/reimport API for a missing managed blob.
        let fixture = try Fixture()
        let bytes = Data("REPAIR-SOURCE-CANARY".utf8)
        let blob = try fixture.insertBlob(id: "repair-blob", bytes: bytes, writeManagedFile: false)
        let reimport = fixture.base.appendingPathComponent("reimport.txt")
        try bytes.write(to: reimport)
        let service = BlobIntegrityService(store: fixture.store, storage: fixture.storage)
        _ = try service.verifyBatch(limit: 1)
        XCTAssertNotNil(try fixture.store.remediationRecovery.pendingItem(kind: .blobRepair, relatedID: blob.id))

        let repaired = try service.repair(blobID: blob.id, reimportFrom: reimport)

        XCTAssertEqual(repaired.state, .verified)
        XCTAssertEqual(try Data(contentsOf: fixture.storage.url(forManagedRelativePath: blob.managedRelativePath)), bytes)
        let persisted = try XCTUnwrap(fixture.store.documentLibrary.fetchBlob(id: blob.id))
        XCTAssertEqual(persisted.integrityStatus, DocumentBlobIntegrityStatus.verified.rawValue)
        XCTAssertNotNil(persisted.verifiedAt)
        XCTAssertNil(persisted.integrityError)
        XCTAssertNil(try fixture.store.remediationRecovery.pendingItem(kind: .blobRepair, relatedID: blob.id))
    }

    func testACRBLOB008RepairRejectsDifferentContentAndPreservesCorruptDestination() throws {
        // Expected RED: no repair API enforces the existing content-addressed identity.
        let fixture = try Fixture()
        let expected = Data("EXPECTED-REPAIR-CANARY".utf8)
        let corrupt = Data("CORRUPT!-REPAIR-CANARY".utf8)
        let wrong = Data("WRONG!!!-REPAIR-CANARY".utf8)
        let blob = try fixture.insertBlob(id: "wrong-repair", bytes: expected, managedBytes: corrupt)
        let reimport = fixture.base.appendingPathComponent("wrong.txt")
        try wrong.write(to: reimport)
        let service = BlobIntegrityService(store: fixture.store, storage: fixture.storage)

        XCTAssertThrowsError(try service.repair(blobID: blob.id, reimportFrom: reimport)) { error in
            guard case BlobIntegrityService.ServiceError.reimportContentMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.storage.url(forManagedRelativePath: blob.managedRelativePath)), corrupt)
    }

    func testACRBLOB011RepairAtomicallyReplacesCorruptDestination() throws {
        // Expected RED: there was no verified repair path that could replace corrupt bytes without deleting the destination first.
        let fixture = try Fixture()
        let expected = Data("EXPECTED-ATOMIC-REPAIR".utf8)
        let corrupt = Data("CORRUPT!-ATOMIC-REPAIR".utf8)
        let blob = try fixture.insertBlob(id: "atomic-repair", bytes: expected, managedBytes: corrupt)
        let reimport = fixture.base.appendingPathComponent("atomic-reimport.txt")
        try expected.write(to: reimport)
        let service = BlobIntegrityService(store: fixture.store, storage: fixture.storage)

        let repaired = try service.repair(blobID: blob.id, reimportFrom: reimport)

        XCTAssertEqual(repaired.state, .verified)
        XCTAssertEqual(try Data(contentsOf: fixture.storage.url(forManagedRelativePath: blob.managedRelativePath)), expected)
        XCTAssertNotEqual(try Data(contentsOf: fixture.storage.url(forManagedRelativePath: blob.managedRelativePath)), corrupt)
    }
}

private struct Fixture {
    let base: URL
    let storage: DocumentStorage
    let store: SupraStore

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobIntegrityService-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        storage = DocumentStorage(root: base.appendingPathComponent("Managed", isDirectory: true))
        try storage.initializeStorage()
        store = try SupraStore(url: base.appendingPathComponent("test.sqlite"))
    }

    func insertBlob(
        id: String,
        bytes: Data,
        managedBytes: Data? = nil,
        writeManagedFile: Bool = true
    ) throws -> DocumentBlobRecord {
        let digest = DocumentStorage.sha256Hex(of: bytes)
        let path = DocumentStorage.blobRelativePath(sha256: digest, fileExtension: "txt")
        if writeManagedFile {
            let url = storage.url(forManagedRelativePath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (managedBytes ?? bytes).write(to: url)
        }
        return try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            id: id,
            sha256: digest,
            byteSize: bytes.count,
            originalExtension: "txt",
            managedRelativePath: path
        )).blob
    }
}
