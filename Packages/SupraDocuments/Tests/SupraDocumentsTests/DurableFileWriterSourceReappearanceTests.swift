import Foundation
@testable import SupraDocuments
import XCTest

final class DurableFileWriterSourceReappearanceTests: XCTestCase {
    // ACR-FILE-025. Synchronization is an observable boundary. If the exact
    // owned inode is relinked at a supposedly removed source name during that
    // callback, neither compensation nor managed unlink may report success.
    func testACRFILE025RemovedManagedSourceMustRemainAbsentAfterSynchronization() throws {
        try assertCompensationSourceReappearanceFailsClosed()
        try assertManagedUnlinkSourceReappearanceFailsClosed()
    }

    // ACR-FILE-028. Absence through the retained directory descriptor is not
    // enough if synchronization detaches that parent and exposes the exact inode
    // again at the same caller-visible source path in a replacement parent.
    func testACRFILE028RemovedManagedSourceMustRemainAbsentAtLexicalPath() throws {
        try assertCompensationLexicalSourceReappearanceFailsClosed()
        try assertManagedUnlinkLexicalSourceReappearanceFailsClosed()
    }

    private func assertCompensationSourceReappearanceFailsClosed() throws {
        let fixture = try makeFixture(label: "compensation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let injector = SourceReappearanceInjector(source: fixture.destination)
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { try injector.synchronize($0) }
        )
        let identity = try writer.writeNewOwned(
            fixture.payload,
            to: fixture.destination,
            containedIn: fixture.root,
            validator: { _ in }
        )
        var quarantine: URL?

        XCTAssertThrowsError(
            try writer.removeInstalledFile(
                matching: identity,
                at: fixture.destination,
                containedIn: fixture.root,
                contentValidator: { _ in },
                preRemovalCheckpoint: { candidate in
                    quarantine = candidate
                    try injector.retainExactLink(from: candidate)
                    injector.setSource(candidate)
                }
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("sourceNameReappeared"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantine)), fixture.payload)
    }

    private func assertManagedUnlinkSourceReappearanceFailsClosed() throws {
        let fixture = try makeFixture(label: "unlink")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let injector = SourceReappearanceInjector(source: fixture.destination)
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { try injector.synchronize($0) }
        )
        let identity = try writer.writeNewOwned(
            fixture.payload,
            to: fixture.destination,
            containedIn: fixture.root,
            validator: { _ in }
        )
        try injector.retainExactLink(from: fixture.destination)

        XCTAssertThrowsError(
            try writer.unlinkFile(
                matching: identity,
                at: fixture.destination,
                containedIn: fixture.root
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("sourceNameReappeared"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.payload)
    }

    private func assertCompensationLexicalSourceReappearanceFailsClosed() throws {
        let fixture = try makeFixture(label: "compensation-lexical")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let parent = fixture.destination.deletingLastPathComponent()
        let injector = LexicalSourceReappearanceInjector(
            root: fixture.root,
            parent: parent
        )
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { try injector.synchronize($0) }
        )
        let identity = try writer.writeNewOwned(
            fixture.payload,
            to: fixture.destination,
            containedIn: fixture.root,
            validator: { _ in }
        )
        var quarantine: URL?

        XCTAssertThrowsError(
            try writer.removeInstalledFile(
                matching: identity,
                at: fixture.destination,
                containedIn: fixture.root,
                contentValidator: { _ in },
                preRemovalCheckpoint: { candidate in
                    quarantine = candidate
                    try injector.prepareExactReappearance(of: candidate)
                }
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("sourceNameReappeared"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantine)), fixture.payload)
    }

    private func assertManagedUnlinkLexicalSourceReappearanceFailsClosed() throws {
        let fixture = try makeFixture(label: "unlink-lexical")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let parent = fixture.destination.deletingLastPathComponent()
        let injector = LexicalSourceReappearanceInjector(
            root: fixture.root,
            parent: parent
        )
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { try injector.synchronize($0) }
        )
        let identity = try writer.writeNewOwned(
            fixture.payload,
            to: fixture.destination,
            containedIn: fixture.root,
            validator: { _ in }
        )
        try injector.prepareExactReappearance(of: fixture.destination)

        XCTAssertThrowsError(
            try writer.unlinkFile(
                matching: identity,
                at: fixture.destination,
                containedIn: fixture.root
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("sourceNameReappeared"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.payload)
    }

    private func makeFixture(label: String) throws -> (root: URL, destination: URL, payload: Data) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Supra-Source-Reappearance-\(label)-\(UUID().uuidString)", isDirectory: true)
        let destination = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
            .appendingPathComponent("motion.md")
        return (root, destination, Data("# Reappearing exact source\n".utf8))
    }
}

private final class LexicalSourceReappearanceInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private let parent: URL
    private let preservedParent: URL
    private var retained: URL?
    private var source: URL?
    private var replaced = false

    init(root: URL, parent: URL) {
        self.root = root
        self.parent = parent
        self.preservedParent = root.appendingPathComponent(
            "preserved-source-parent-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    func prepareExactReappearance(of source: URL) throws {
        let retained = root.appendingPathComponent("retained-source-\(UUID().uuidString)")
        try FileManager.default.linkItem(at: source, to: retained)
        lock.withLock {
            self.retained = retained
            self.source = source
        }
    }

    func synchronize(_ directory: URL) throws {
        let state = lock.withLock { () -> (URL, URL)? in
            guard !replaced,
                  let retained,
                  let source,
                  !FileManager.default.fileExists(atPath: source.path) else {
                return nil
            }
            replaced = true
            return (retained, source)
        }
        guard let (retained, source) = state else { return }
        try FileManager.default.moveItem(at: parent, to: preservedParent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: retained, to: source)
    }
}

private final class SourceReappearanceInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var retained: URL?
    private var source: URL

    init(source: URL) {
        self.source = source
    }

    func retainExactLink(from candidate: URL) throws {
        let retained = candidate.deletingLastPathComponent()
            .appendingPathComponent("retained-source-\(UUID().uuidString)")
        try FileManager.default.linkItem(at: candidate, to: retained)
        lock.withLock { self.retained = retained }
    }

    func setSource(_ source: URL) {
        lock.withLock { self.source = source }
    }

    func synchronize(_ directory: URL) throws {
        let (retained, source) = lock.withLock { (self.retained, self.source) }
        guard let retained,
              FileManager.default.fileExists(atPath: retained.path),
              !FileManager.default.fileExists(atPath: source.path) else {
            return
        }
        try FileManager.default.linkItem(at: retained, to: source)
    }
}
