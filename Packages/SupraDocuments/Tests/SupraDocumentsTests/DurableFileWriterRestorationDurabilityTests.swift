import Darwin
import Foundation
import XCTest
@testable import SupraDocuments

final class DurableFileWriterRestorationDurabilityTests: XCTestCase {
    // ACR-FILE-043a. Quarantining a foreign replacement is a namespace change
    // even when the writer immediately restores that exact entry. The retained
    // parent must be synchronized before the removal reports that it did not
    // remove the writer-owned file.
    func testACRFILE043aForeignReplacementRestoreSynchronizesRetainedParent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
            .appendingPathComponent("motion.docx")
        let parent = destination.deletingLastPathComponent()
        let preservedOwned = root.appendingPathComponent("preserved-owned.docx")
        let ownedBytes = Data("writer-owned-motion".utf8)
        let foreignBytes = Data("foreign-replacement".utf8)

        let identity = try DurableFileWriter().writeNewOwned(
            ownedBytes,
            to: destination,
            containedIn: root,
            validator: { _ in }
        )
        try FileManager.default.moveItem(at: destination, to: preservedOwned)
        try foreignBytes.write(to: destination)

        let synchronizer = RestorationDirectorySynchronizationRecorder()
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            anchoredParentDirectorySynchronizer: {
                try synchronizer.synchronize(parentURL: $0, parentDescriptor: $1)
            }
        )

        let removed = try writer.removeInstalledFile(
            matching: identity,
            at: destination,
            containedIn: root,
            contentValidator: { _ in
                XCTFail("A foreign replacement must not enter owned-content validation")
            }
        )

        XCTAssertFalse(removed)
        XCTAssertEqual(synchronizer.directories, [parent.standardizedFileURL])
        XCTAssertEqual(try Data(contentsOf: destination), foreignBytes)
        XCTAssertEqual(try Data(contentsOf: preservedOwned), ownedBytes)
    }

    // ACR-FILE-043b. If the restore cannot be made durable, the writer must
    // classify the result as uncertain instead of reporting an ordinary
    // not-owned outcome after putting the replacement back in public view.
    func testACRFILE043bForeignReplacementRestoreSyncFailureIsUncertain() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
            .appendingPathComponent("motion.docx")
        let preservedOwned = root.appendingPathComponent("preserved-owned.docx")
        let ownedBytes = Data("writer-owned-motion".utf8)
        let foreignBytes = Data("foreign-replacement".utf8)

        let identity = try DurableFileWriter().writeNewOwned(
            ownedBytes,
            to: destination,
            containedIn: root,
            validator: { _ in }
        )
        try FileManager.default.moveItem(at: destination, to: preservedOwned)
        try foreignBytes.write(to: destination)

        let writer = DurableFileWriter(
            faultInjector: { _ in },
            anchoredParentDirectorySynchronizer: { _, _ in
                throw InjectedRestorationSynchronizationFailure.injected
            }
        )

        XCTAssertThrowsError(
            try writer.removeInstalledFile(
                matching: identity,
                at: destination,
                containedIn: root,
                contentValidator: { _ in
                    XCTFail("A foreign replacement must not enter owned-content validation")
                }
            )
        ) { error in
            guard case .restoredEntrySynchronizationFailed =
                error as? DurableFileWriter.WriterError else {
                return XCTFail("Expected uncertain restoration durability, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: destination), foreignBytes)
        XCTAssertEqual(try Data(contentsOf: preservedOwned), ownedBytes)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Supra-DurableFileWriter-Restore-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private enum InjectedRestorationSynchronizationFailure: Error {
    case injected
}

private final class RestorationDirectorySynchronizationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDirectories: [URL] = []

    var directories: [URL] {
        lock.withLock { recordedDirectories }
    }

    func synchronize(parentURL: URL, parentDescriptor: Int32) throws {
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        lock.withLock {
            recordedDirectories.append(parentURL.standardizedFileURL)
        }
    }
}
