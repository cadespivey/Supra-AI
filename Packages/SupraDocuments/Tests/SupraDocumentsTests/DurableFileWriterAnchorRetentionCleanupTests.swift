import Darwin
import Foundation
@testable import SupraDocuments
import XCTest

final class DurableFileWriterAnchorRetentionCleanupTests: XCTestCase {
    // ACR-FILE-040. Expected compile RED at 6315ee0c: there is no checkpoint
    // between managed-temporary creation and retained-anchor construction. If
    // retaining that capability fails, cleanup must unlink and synchronize the
    // exact empty inode before the original setup error may escape.
    func testACRFILE040AnchorRetentionFailureDurablyRemovesExactTemporary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Supra-Anchor-Retention-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
        let destination = parent.appendingPathComponent("motion.md")
        let probe = AnchorRetentionFailureProbe(
            expectedParent: parent,
            destinationName: destination.lastPathComponent
        )
        let syncProbe = AnchorRetentionSyncProbe(
            expectedParent: parent,
            injectionProbe: probe
        )
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            anchoredParentDirectorySynchronizer: {
                try syncProbe.synchronize(parentURL: $0, parentDescriptor: $1)
            },
            beforeManagedAnchorRetention: { try probe.inject(at: $0) }
        )

        XCTAssertThrowsError(
            try writer.writeNewOwned(
                Data("bytes must never be written".utf8),
                to: destination,
                containedIn: root,
                validator: { _ in XCTFail("validation must not run") }
            )
        ) { error in
            XCTAssertEqual(error as? AnchorRetentionInjectedFailure, .anchorRetention)
        }

        XCTAssertTrue(probe.didInject)
        XCTAssertEqual(syncProbe.postInjectionCallCount, 1)
        let temporaryURL = try XCTUnwrap(probe.temporaryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(
            try anchorRetentionTemporaryArtifacts(
                in: parent,
                destinationName: destination.lastPathComponent
            ).isEmpty
        )

        let initial = try XCTUnwrap(probe.initialStatus)
        let final = try probe.retainedStatus()
        XCTAssertEqual(final.st_dev, initial.st_dev)
        XCTAssertEqual(final.st_ino, initial.st_ino)
        XCTAssertEqual(final.st_gen, initial.st_gen)
        XCTAssertEqual(final.st_size, 0)
        XCTAssertEqual(UInt64(final.st_nlink), 0)
        XCTAssertEqual(try probe.retainedBytes(), Data())
    }
}

private final class AnchorRetentionFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedParent: URL
    private let destinationName: String
    private var descriptor: Int32 = -1
    private var capturedURL: URL?
    private var capturedStatus: stat?
    private var injected = false

    init(expectedParent: URL, destinationName: String) {
        self.expectedParent = expectedParent
        self.destinationName = destinationName
    }

    deinit {
        let retained = lock.withLock { descriptor }
        if retained >= 0 { Darwin.close(retained) }
    }

    var didInject: Bool { lock.withLock { injected } }
    var temporaryURL: URL? { lock.withLock { capturedURL } }
    var initialStatus: stat? { lock.withLock { capturedStatus } }

    func inject(at temporaryURL: URL) throws {
        XCTAssertEqual(
            temporaryURL.deletingLastPathComponent().standardizedFileURL,
            expectedParent.standardizedFileURL
        )
        XCTAssertTrue(
            isAnchorRetentionTemporaryName(
                temporaryURL.lastPathComponent,
                destinationName: destinationName
            )
        )
        let retained = temporaryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard retained >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var status = stat()
        guard Darwin.fstat(retained, &status) == 0 else {
            let code = errno
            Darwin.close(retained)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(status.st_size, 0)
        XCTAssertEqual(UInt64(status.st_nlink), 1)
        lock.withLock {
            descriptor = retained
            capturedURL = temporaryURL.standardizedFileURL
            capturedStatus = status
            injected = true
        }
        throw AnchorRetentionInjectedFailure.anchorRetention
    }

    func retainedStatus() throws -> stat {
        let retained = lock.withLock { descriptor }
        guard retained >= 0 else { throw AnchorRetentionProbeFailure.missingDescriptor }
        var status = stat()
        guard Darwin.fstat(retained, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status
    }

    func retainedBytes() throws -> Data {
        let retained = lock.withLock { descriptor }
        guard retained >= 0 else { throw AnchorRetentionProbeFailure.missingDescriptor }
        var byte: UInt8 = 0
        let count = Darwin.pread(retained, &byte, 1, 0)
        guard count >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return count == 0 ? Data() : Data([byte])
    }
}

private final class AnchorRetentionSyncProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedParent: URL
    private let injectionProbe: AnchorRetentionFailureProbe
    private var postInjectionCalls = 0

    init(expectedParent: URL, injectionProbe: AnchorRetentionFailureProbe) {
        self.expectedParent = expectedParent
        self.injectionProbe = injectionProbe
    }

    var postInjectionCallCount: Int { lock.withLock { postInjectionCalls } }

    func synchronize(parentURL: URL, parentDescriptor: Int32) throws {
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard injectionProbe.didInject else { return }
        XCTAssertEqual(
            parentURL.standardizedFileURL,
            expectedParent.standardizedFileURL
        )
        lock.withLock { postInjectionCalls += 1 }
    }
}

private func anchorRetentionTemporaryArtifacts(
    in parent: URL,
    destinationName: String
) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: parent,
        includingPropertiesForKeys: nil
    ).filter {
        isAnchorRetentionTemporaryName(
            $0.lastPathComponent,
            destinationName: destinationName
        )
    }
}

private func isAnchorRetentionTemporaryName(
    _ name: String,
    destinationName: String
) -> Bool {
    let prefix = ".\(destinationName).supra-tmp-"
    guard name.hasPrefix(prefix) else { return false }
    return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
}

private enum AnchorRetentionInjectedFailure: Error, Equatable {
    case anchorRetention
}

private enum AnchorRetentionProbeFailure: Error {
    case missingDescriptor
}
