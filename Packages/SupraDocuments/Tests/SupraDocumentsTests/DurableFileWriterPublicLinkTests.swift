import Foundation
@testable import SupraDocuments
import XCTest

final class DurableFileWriterPublicLinkTests: XCTestCase {
    // ACR-FILE-020. A concurrent exact hard link can appear only after the
    // quarantine has been removed, while rollback synchronizes the directory.
    // The writer must report that post-removal state distinctly rather than
    // returning success or claiming that quarantine material remains.
    func testACRFILE020PostRemovalPublicHardLinkIsReportedWithoutRetainedQuarantine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Supra-PostRemovalLink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
        let destination = parent.appendingPathComponent("motion.md")
        let retained = root.appendingPathComponent("retained-owned-motion.md")
        let payload = Data("# Exact post-removal link\n".utf8)
        let injector = PostRemovalPublicLinkInjector(
            destination: destination,
            retained: retained
        )
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { try injector.synchronize($0) }
        )
        let identity = try writer.writeNewOwned(
            payload,
            to: destination,
            containedIn: root,
            validator: { _ in }
        )
        var quarantine: URL?

        XCTAssertThrowsError(
            try writer.removeInstalledFile(
                matching: identity,
                at: destination,
                containedIn: root,
                contentValidator: { XCTAssertEqual($0, payload) },
                preRemovalCheckpoint: { candidate in
                    quarantine = candidate
                    try FileManager.default.linkItem(at: candidate, to: retained)
                }
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("publicDestinationStillLinkedAfterRemoval"),
                "expected the post-removal exact-link state, got \(error)"
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(quarantine).path))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(try Data(contentsOf: retained), payload)
    }
}

private final class PostRemovalPublicLinkInjector: @unchecked Sendable {
    private let destination: URL
    private let retained: URL

    init(destination: URL, retained: URL) {
        self.destination = destination
        self.retained = retained
    }

    func synchronize(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: retained.path),
              !FileManager.default.fileExists(atPath: destination.path) else {
            return
        }
        try FileManager.default.linkItem(at: retained, to: destination)
    }
}
