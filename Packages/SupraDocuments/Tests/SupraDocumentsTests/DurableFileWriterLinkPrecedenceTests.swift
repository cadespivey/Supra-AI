import Darwin
import Foundation
@testable import SupraDocuments
import XCTest

final class DurableFileWriterLinkPrecedenceTests: XCTestCase {
    // ACR-FILE-039a. Expected compile RED at b07f07a5 because the typed
    // remaining-link error does not yet exist. Once it does, a proven survivor
    // must outrank a throwing parent-directory synchronizer after unlink.
    func testACRFILE039ManagedUnlinkRemainingLinkOutranksSyncFailure() throws {
        let fixture = try makeLinkPrecedenceFixture(label: "managed-unlink")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.parent.appendingPathComponent("unknown-unlink-survivor.md")
        let postSyncAlias = fixture.parent.appendingPathComponent(
            "unknown-unlink-post-sync-survivor.md"
        )
        let identity = try DurableFileWriter().writeNewOwned(
            fixture.payload,
            to: fixture.destination,
            containedIn: fixture.root,
            validator: { XCTAssertEqual($0, fixture.payload) }
        )
        let syncProbe = FreshLinkThrowingAnchoredSyncProbe(
            removedName: fixture.destination,
            survivingAlias: alias,
            postSyncAlias: postSyncAlias
        )
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            anchoredParentDirectorySynchronizer: {
                try syncProbe.synchronize(parentURL: $0, parentDescriptor: $1)
            },
            fileUnlinkCheckpoint: { candidate in
                XCTAssertEqual(
                    candidate.standardizedFileURL,
                    fixture.destination.standardizedFileURL
                )
                try FileManager.default.linkItem(at: candidate, to: alias)
                try assertLinkPrecedenceSameInode(
                    candidate,
                    alias,
                    expectedLinkCount: 2
                )
            }
        )

        XCTAssertThrowsError(
            try writer.unlinkFile(
                matching: identity,
                at: fixture.destination,
                containedIn: fixture.root
            )
        ) { error in
            guard case let .exactFileHasRemainingLinks(name, count) =
                    error as? DurableFileWriter.WriterError else {
                return XCTFail("Expected exact remaining-link error, got \(error)")
            }
            XCTAssertEqual(name, fixture.destination.lastPathComponent)
            XCTAssertEqual(count, 2)
        }

        XCTAssertEqual(syncProbe.callCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        try assertLinkPrecedenceSurvivor(
            alias,
            expected: fixture.payload,
            expectedLinkCount: 2
        )
        try assertLinkPrecedenceSurvivor(
            postSyncAlias,
            expected: fixture.payload,
            expectedLinkCount: 2
        )
        try assertLinkPrecedenceSameInode(
            alias,
            postSyncAlias,
            expectedLinkCount: 2
        )
    }

    // ACR-FILE-039b. The same precedence rule applies to quarantine removal:
    // once the exact inode is known to survive under an unknown link, a sync
    // throw cannot downgrade the result to synchronization uncertainty alone.
    func testACRFILE039CompensationRemainingLinkOutranksSyncFailure() throws {
        let fixture = try makeLinkPrecedenceFixture(label: "compensation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.parent.appendingPathComponent("unknown-compensation-survivor.md")
        let identity = try DurableFileWriter().writeNewOwned(
            fixture.payload,
            to: fixture.destination,
            containedIn: fixture.root,
            validator: { XCTAssertEqual($0, fixture.payload) }
        )
        let syncProbe = ThrowingAnchoredSyncProbe()
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            anchoredParentDirectorySynchronizer: {
                try syncProbe.synchronize(parentURL: $0, parentDescriptor: $1)
            }
        )
        var observedQuarantine: URL?

        XCTAssertThrowsError(
            try writer.removeInstalledFile(
                matching: identity,
                at: fixture.destination,
                containedIn: fixture.root,
                contentValidator: { XCTAssertEqual($0, fixture.payload) },
                preRemovalCheckpoint: { quarantine in
                    observedQuarantine = quarantine
                    try FileManager.default.linkItem(at: quarantine, to: alias)
                    try assertLinkPrecedenceSameInode(
                        quarantine,
                        alias,
                        expectedLinkCount: 2
                    )
                }
            )
        ) { error in
            guard case let .exactFileHasRemainingLinks(name, count) =
                    error as? DurableFileWriter.WriterError else {
                return XCTFail("Expected exact remaining-link error, got \(error)")
            }
            XCTAssertEqual(name, observedQuarantine?.lastPathComponent)
            XCTAssertEqual(count, 1)
        }

        XCTAssertEqual(syncProbe.callCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let quarantine = try XCTUnwrap(observedQuarantine)
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
        try assertLinkPrecedenceSurvivor(
            alias,
            expected: fixture.payload,
            expectedLinkCount: 1
        )
    }
}

private typealias LinkPrecedenceFixture = (
    root: URL,
    parent: URL,
    destination: URL,
    payload: Data
)

private func makeLinkPrecedenceFixture(label: String) throws -> LinkPrecedenceFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Supra-Link-Precedence-\(label)-\(UUID().uuidString)",
        isDirectory: true
    )
    let parent = root
        .appendingPathComponent("exports", isDirectory: true)
        .appendingPathComponent("matter-123", isDirectory: true)
    return (
        root,
        parent,
        parent.appendingPathComponent("motion.md"),
        Data("# Link precedence \(label)\n".utf8)
    )
}

private func assertLinkPrecedenceSurvivor(
    _ url: URL,
    expected: Data,
    expectedLinkCount: UInt64,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    XCTAssertEqual(try Data(contentsOf: url), expected, file: file, line: line)
    XCTAssertEqual(
        try DocumentStorage.sha256Hex(ofFileAt: url),
        DocumentStorage.sha256Hex(of: expected),
        file: file,
        line: line
    )
    var status = stat()
    XCTAssertEqual(
        url.path.withCString { Darwin.lstat($0, &status) },
        0,
        file: file,
        line: line
    )
    XCTAssertEqual(UInt64(status.st_nlink), expectedLinkCount, file: file, line: line)
}

private func assertLinkPrecedenceSameInode(
    _ lhs: URL,
    _ rhs: URL,
    expectedLinkCount: UInt64,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    var lhsStatus = stat()
    var rhsStatus = stat()
    XCTAssertEqual(
        lhs.path.withCString { Darwin.lstat($0, &lhsStatus) },
        0,
        file: file,
        line: line
    )
    XCTAssertEqual(
        rhs.path.withCString { Darwin.lstat($0, &rhsStatus) },
        0,
        file: file,
        line: line
    )
    XCTAssertEqual(lhsStatus.st_dev, rhsStatus.st_dev, file: file, line: line)
    XCTAssertEqual(lhsStatus.st_ino, rhsStatus.st_ino, file: file, line: line)
    XCTAssertEqual(UInt64(lhsStatus.st_nlink), expectedLinkCount, file: file, line: line)
    XCTAssertEqual(UInt64(rhsStatus.st_nlink), expectedLinkCount, file: file, line: line)
}

private final class ThrowingAnchoredSyncProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func synchronize(parentURL: URL, parentDescriptor: Int32) throws {
        XCTAssertFalse(parentURL.lastPathComponent.isEmpty)
        var status = stat()
        XCTAssertEqual(Darwin.fstat(parentDescriptor, &status), 0)
        lock.withLock { calls += 1 }
        throw LinkPrecedenceInjectedFailure.parentSynchronization
    }
}

private final class FreshLinkThrowingAnchoredSyncProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let removedName: URL
    private let survivingAlias: URL
    private let postSyncAlias: URL
    private var calls = 0

    init(removedName: URL, survivingAlias: URL, postSyncAlias: URL) {
        self.removedName = removedName
        self.survivingAlias = survivingAlias
        self.postSyncAlias = postSyncAlias
    }

    var callCount: Int { lock.withLock { calls } }

    func synchronize(parentURL: URL, parentDescriptor: Int32) throws {
        XCTAssertEqual(
            parentURL.standardizedFileURL,
            removedName.deletingLastPathComponent().standardizedFileURL
        )
        var status = stat()
        XCTAssertEqual(Darwin.fstat(parentDescriptor, &status), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedName.path))
        try FileManager.default.linkItem(at: survivingAlias, to: postSyncAlias)
        try assertLinkPrecedenceSameInode(
            survivingAlias,
            postSyncAlias,
            expectedLinkCount: 2
        )
        lock.withLock { calls += 1 }
        throw LinkPrecedenceInjectedFailure.parentSynchronization
    }
}

private enum LinkPrecedenceInjectedFailure: Error {
    case parentSynchronization
}
