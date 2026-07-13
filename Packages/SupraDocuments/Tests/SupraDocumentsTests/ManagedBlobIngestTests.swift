import Foundation
@testable import SupraDocuments
import XCTest

final class ManagedBlobIngestTests: XCTestCase {
    func testACRBLOB001SourceMutationAfterReadCannotChangeManagedBytes() throws {
        // Expected RED: DocumentStorage has no one-read managed ingest boundary, so callers hash then copy a mutable source.
        let fixture = try Fixture()
        let original = Data("ORIGINAL-CANARY-42".utf8)
        let mutated = Data("MUTATED!-CANARY-42".utf8)
        try original.write(to: fixture.source)

        let storage = DocumentStorage(root: fixture.storageRoot) { stage in
            if stage == .afterSourceReadChunk {
                try mutated.write(to: fixture.source)
            }
        }
        let result = try storage.ingest(source: fixture.source)

        XCTAssertEqual(try Data(contentsOf: result.managedURL), original)
        XCTAssertNotEqual(try Data(contentsOf: result.managedURL), mutated)
        XCTAssertEqual(result.sha256, DocumentStorage.sha256Hex(of: original))
        XCTAssertEqual(result.byteSize, original.count)
        XCTAssertEqual(result.disposition, .installed)
    }

    func testACRBLOB002DuplicateIngestVerifiesAndReusesManagedFile() throws {
        // Expected RED: duplicate reuse currently trusts either the database row or destination path without verifying bytes.
        let fixture = try Fixture()
        let bytes = Data("DUPLICATE-BLOB-CANARY".utf8)
        try bytes.write(to: fixture.source)
        let storage = DocumentStorage(root: fixture.storageRoot)

        let first = try storage.ingest(source: fixture.source)
        let second = try storage.ingest(source: fixture.source)

        XCTAssertEqual(first.disposition, .installed)
        XCTAssertEqual(second.disposition, .reusedVerified)
        XCTAssertEqual(second.managedURL, first.managedURL)
        XCTAssertEqual(try Data(contentsOf: second.managedURL), bytes)
    }

    func testACRBLOB003CorruptPreexistingDestinationFailsClosed() throws {
        // Expected RED: a preexisting content-addressed path is currently reused solely because it exists.
        let fixture = try Fixture()
        let expected = Data("EXPECTED-BLOB-CANARY".utf8)
        let corrupt = Data("CORRUPT!-BLOB-CANARY".utf8)
        try expected.write(to: fixture.source)
        let storage = DocumentStorage(root: fixture.storageRoot)
        try storage.initializeStorage()
        let digest = DocumentStorage.sha256Hex(of: expected)
        let destination = storage.blobURL(sha256: digest, fileExtension: fixture.source.pathExtension)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try corrupt.write(to: destination)

        XCTAssertThrowsError(try storage.ingest(source: fixture.source)) { error in
            guard case DocumentStorage.IntegrityError.corruptManagedBlob(let actualDigest, _, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(actualDigest, digest)
        }
        XCTAssertEqual(try Data(contentsOf: destination), corrupt, "ingest must not silently overwrite an unverified destination")
    }

    func testACRBLOB004CancellationRemovesManagedTemporaryFile() throws {
        // Expected RED: the current hash-then-copy path has no cancellation cleanup contract.
        let fixture = try Fixture()
        let bytes = Data(repeating: 0x5a, count: 1_048_777)
        try bytes.write(to: fixture.source)
        let storage = DocumentStorage(root: fixture.storageRoot) { stage in
            if stage == .beforeInstall { throw CancellationError() }
        }

        XCTAssertThrowsError(try storage.ingest(source: fixture.source)) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        let tempContents = try FileManager.default.contentsOfDirectory(at: storage.tempDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(tempContents.isEmpty, "cancelled ingest left temporary files: \(tempContents)")
        let digest = DocumentStorage.sha256Hex(of: bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.blobURL(sha256: digest, fileExtension: "txt").path))
    }
}

private struct Fixture {
    let base: URL
    let source: URL
    let storageRoot: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedBlobIngest-\(UUID().uuidString)", isDirectory: true)
        source = base.appendingPathComponent("source.txt")
        storageRoot = base.appendingPathComponent("Managed", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
}
