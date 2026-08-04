import Foundation
@testable import SupraDocuments
import XCTest

final class DurableFileWriterDirectoryEdgeRaceTests: XCTestCase {
    // ACR-FILE-023. A directory edge must be opened before its containing
    // directory is synchronized, then re-authenticated afterward. Otherwise a
    // sync callback can replace the just-created child and make publication
    // continue inside a directory the writer never authenticated.
    func testACRFILE023CreatedRootReplacementDuringContainingSyncFailsClosed() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("Supra-Edge-Race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("managed-root", isDirectory: true)
        let preservedRoot = container.appendingPathComponent("preserved-root", isDirectory: true)
        let destination = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
            .appendingPathComponent("motion.md")
        let injector = CreatedRootReplacementInjector(
            containingDirectory: container,
            root: root,
            preservedRoot: preservedRoot
        )
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { try injector.synchronize($0) }
        )

        XCTAssertThrowsError(
            try writer.writeNewOwned(
                Data("# Never enter replacement root\n".utf8),
                to: destination,
                containedIn: root,
                validator: { _ in }
            )
        )
        XCTAssertTrue(injector.didReplaceRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedRoot.path))
    }
}

private final class CreatedRootReplacementInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let containingDirectory: URL
    private let root: URL
    private let preservedRoot: URL
    private var replaced = false

    init(containingDirectory: URL, root: URL, preservedRoot: URL) {
        self.containingDirectory = containingDirectory.standardizedFileURL
        self.root = root
        self.preservedRoot = preservedRoot
    }

    var didReplaceRoot: Bool { lock.withLock { replaced } }

    func synchronize(_ directory: URL) throws {
        let shouldReplace = lock.withLock { () -> Bool in
            guard !replaced, directory.standardizedFileURL == containingDirectory else {
                return false
            }
            replaced = true
            return true
        }
        guard shouldReplace else { return }
        try FileManager.default.moveItem(at: root, to: preservedRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
}
