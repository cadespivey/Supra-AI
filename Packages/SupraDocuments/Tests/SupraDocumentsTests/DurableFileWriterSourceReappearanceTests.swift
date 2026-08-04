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
