import Foundation
import GRDB
@testable import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class PublicationPostInstallSyncTests: XCTestCase {
    // ACR-EXPORT-018. The install fsync callback is the final external boundary
    // inside the writer. If it detaches the retained parent and exposes an exact
    // hard link at a replacement public path, the writer must fail before audit
    // and leave the prepared intent recoverable.
    func testACREXPORT018PostInstallSyncParentReplacementStopsBeforeAudit() async throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Post-install sync matter")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Supra-PostInstallSync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DocumentStorage(root: root)
        let parent = storage.exportsDirectory(forMatterID: matter.id)
        let destination = parent.appendingPathComponent("Post-sync-fixed.md")
        let preservedParent = root.appendingPathComponent("preserved-parent", isDirectory: true)
        let injector = PostInstallParentReplacementInjector(
            parent: parent,
            destination: destination,
            preservedParent: preservedParent
        )
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { try injector.synchronize($0) }
        )
        var auditCallCount = 0
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            fileWriter: writer,
            fileStampProvider: { "fixed" },
            auditRecorder: { _ in auditCallCount += 1 }
        )

        let result = await controller.draftCustomDescription(
            matterID: matter.id,
            input: .init(
                title: "Post sync",
                description: "Do not cross audit after the final filesystem callback."
            )
        )

        if case .success = result {
            XCTFail("post-install parent replacement unexpectedly published successfully")
        }
        XCTAssertTrue(injector.didReplaceParent)
        XCTAssertEqual(auditCallCount, 0)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            try Data(contentsOf: preservedParent.appendingPathComponent(destination.lastPathComponent))
        )
        let statuses = try await store.database.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT status FROM draft_artifact_intents WHERE matter_id = ?",
                arguments: [matter.id]
            )
        }
        XCTAssertEqual(statuses, [DraftArtifactIntentStatus.recoveryRequired.rawValue])
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
    }
}

private final class PostInstallParentReplacementInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let parent: URL
    private let destination: URL
    private let preservedParent: URL
    private var replaced = false

    init(parent: URL, destination: URL, preservedParent: URL) {
        self.parent = parent
        self.destination = destination
        self.preservedParent = preservedParent
    }

    var didReplaceParent: Bool { lock.withLock { replaced } }

    func synchronize(_ directory: URL) throws {
        let shouldReplace = lock.withLock { () -> Bool in
            guard !replaced,
                  FileManager.default.fileExists(atPath: destination.path) else {
                return false
            }
            replaced = true
            return true
        }
        guard shouldReplace else { return }
        try FileManager.default.moveItem(at: parent, to: preservedParent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.linkItem(
            at: preservedParent.appendingPathComponent(destination.lastPathComponent),
            to: destination
        )
    }
}
