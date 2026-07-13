import Foundation
import GRDB
@testable import SupraStore
import XCTest

final class BlobIntegrityMigrationTests: XCTestCase {
    func testACRBLOB005V056MarksLegacyBlobUnverifiedWithoutChangingIdentity() throws {
        // Expected RED: v056 and the document_blobs integrity columns do not exist.
        let queue = try DatabaseQueue()
        let migrator = SupraMigrator.makeMigrator()
        try migrator.migrate(queue, upTo: "v055_add_output_verification_provenance")
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO document_blobs
                    (id, sha256, byte_size, original_extension, managed_relative_path, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: ["legacy-blob", "legacy-digest-canary", 313, "pdf", "blobs/le/legacy.pdf", createdAt]
            )
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let columns = try db.columns(in: "document_blobs").map(\.name)
            XCTAssertTrue(columns.contains("integrity_status"))
            XCTAssertTrue(columns.contains("verified_at"))
            XCTAssertTrue(columns.contains("integrity_error"))
            let blob = try XCTUnwrap(try DocumentBlobRecord.fetchOne(db, key: "legacy-blob"))
            XCTAssertEqual(blob.sha256, "legacy-digest-canary")
            XCTAssertEqual(blob.byteSize, 313)
            XCTAssertEqual(blob.managedRelativePath, "blobs/le/legacy.pdf")
            XCTAssertEqual(blob.integrityStatus, DocumentBlobIntegrityStatus.unverified.rawValue)
            XCTAssertNil(blob.verifiedAt)
            XCTAssertNil(blob.integrityError)
        }
    }
}
