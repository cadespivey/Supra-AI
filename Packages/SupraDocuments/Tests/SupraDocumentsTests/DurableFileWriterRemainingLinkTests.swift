import Darwin
import Foundation
@testable import SupraDocuments
import XCTest

final class DurableFileWriterRemainingLinkTests: XCTestCase {
    // ACR-FILE-030. Expected RED: compensation currently removes its known
    // quarantine name and reports success even when an untrusted checkpoint
    // added another exact hard link under an unknown same-directory name.
    // Successful rollback requires descriptor-bound proof that st_nlink is zero.
    func testACRFILE030CompensationRejectsUnknownRemainingExactHardLink() throws {
        let fixture = try makeFixture(label: "compensation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unknownLink = fixture.destination.deletingLastPathComponent()
            .appendingPathComponent("unknown-exact-compensation-link.md")
        let writer = DurableFileWriter()
        let identity = try writer.writeNewOwned(
            fixture.payload,
            to: fixture.destination,
            containedIn: fixture.root,
            validator: { XCTAssertEqual($0, fixture.payload) }
        )
        var checkpointCallCount = 0

        XCTAssertThrowsError(
            try writer.removeInstalledFile(
                matching: identity,
                at: fixture.destination,
                containedIn: fixture.root,
                quarantineCheckpoint: { _, quarantine in
                    checkpointCallCount += 1
                    try FileManager.default.linkItem(at: quarantine, to: unknownLink)
                    try assertSameInode(quarantine, unknownLink, expectedLinkCount: 2)
                },
                contentValidator: { XCTAssertEqual($0, fixture.payload) }
            ),
            "rollback must not report success while an unknown exact link remains"
        )

        XCTAssertEqual(checkpointCallCount, 1)
        XCTAssertEqual(try Data(contentsOf: unknownLink), fixture.payload)
    }

    // ACR-FILE-031. Expected RED: the general managed unlink path likewise
    // proves only that its known source name disappeared. It must retain an
    // exact descriptor through unlink and reject a nonzero remaining link count.
    func testACRFILE031ManagedUnlinkRejectsUnknownRemainingExactHardLink() throws {
        let fixture = try makeFixture(label: "managed-unlink")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unknownLink = fixture.destination.deletingLastPathComponent()
            .appendingPathComponent("unknown-exact-managed-link.md")
        let checkpointCalls = RemainingLinkCallCounter()
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { _ in },
            fileUnlinkCheckpoint: { candidate in
                checkpointCalls.recordCall()
                XCTAssertEqual(
                    candidate.standardizedFileURL,
                    fixture.destination.standardizedFileURL
                )
                try FileManager.default.linkItem(at: candidate, to: unknownLink)
                try assertSameInode(candidate, unknownLink, expectedLinkCount: 2)
            }
        )
        let identity = try writer.writeNewOwned(
            fixture.payload,
            to: fixture.destination,
            containedIn: fixture.root,
            validator: { XCTAssertEqual($0, fixture.payload) }
        )

        XCTAssertThrowsError(
            try writer.unlinkFile(
                matching: identity,
                at: fixture.destination,
                containedIn: fixture.root
            ),
            "managed unlink must not report success while an unknown exact link remains"
        )

        XCTAssertEqual(checkpointCalls.count, 1)
        XCTAssertEqual(try Data(contentsOf: unknownLink), fixture.payload)
    }

    private func makeFixture(
        label: String
    ) throws -> (root: URL, destination: URL, payload: Data) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Supra-Remaining-Link-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        let destination = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
            .appendingPathComponent("motion.md")
        return (root, destination, Data("# Exact link-count proof\n".utf8))
    }
}

private final class RemainingLinkCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    var count: Int { lock.withLock { callCount } }

    func recordCall() {
        lock.withLock { callCount += 1 }
    }
}

private func assertSameInode(
    _ lhs: URL,
    _ rhs: URL,
    expectedLinkCount: UInt16,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    var lhsStatus = stat()
    var rhsStatus = stat()
    XCTAssertEqual(lhs.path.withCString { Darwin.lstat($0, &lhsStatus) }, 0, file: file, line: line)
    XCTAssertEqual(rhs.path.withCString { Darwin.lstat($0, &rhsStatus) }, 0, file: file, line: line)
    XCTAssertEqual(lhsStatus.st_dev, rhsStatus.st_dev, file: file, line: line)
    XCTAssertEqual(lhsStatus.st_ino, rhsStatus.st_ino, file: file, line: line)
    XCTAssertEqual(lhsStatus.st_nlink, expectedLinkCount, file: file, line: line)
    XCTAssertEqual(rhsStatus.st_nlink, expectedLinkCount, file: file, line: line)
}
