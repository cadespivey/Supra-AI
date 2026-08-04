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
        try await assertPostInstallParentReplacementFailsClosed(throwsAfterReplacement: false)
    }

    // The callback's throwing path is equally untrusted: rollback through the
    // retained parent cannot turn a newly exposed exact public hard link into a
    // generic aborted result.
    func testACREXPORT018ThrowingPostInstallSyncParentReplacementStopsBeforeAudit() async throws {
        try await assertPostInstallParentReplacementFailsClosed(throwsAfterReplacement: true)
    }

    private func assertPostInstallParentReplacementFailsClosed(
        throwsAfterReplacement: Bool
    ) async throws {
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
            preservedParent: preservedParent,
            throwsAfterReplacement: throwsAfterReplacement
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
        let publicData = try Data(contentsOf: destination)
        let intents = try await store.database.writer.read { db in
            try DraftArtifactIntentRecord.fetchAll(
                db,
                sql: "SELECT * FROM draft_artifact_intents WHERE matter_id = ?",
                arguments: [matter.id]
            )
        }
        XCTAssertEqual(intents.count, 1)
        let intent = try XCTUnwrap(intents.first)
        XCTAssertEqual(publicData.count, intent.outputByteSize)
        XCTAssertEqual(DocumentStorage.sha256Hex(of: publicData), intent.outputSHA256)
        if !throwsAfterReplacement {
            XCTAssertEqual(
                publicData,
                try Data(
                    contentsOf: preservedParent.appendingPathComponent(
                        destination.lastPathComponent
                    )
                )
            )
        }
        XCTAssertEqual(intent.status, DraftArtifactIntentStatus.recoveryRequired.rawValue)
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
    }
}

private enum PostInstallSyncInjectedFailure: Error {
    case stopAfterReplacement
}

private final class PostInstallParentReplacementInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let parent: URL
    private let destination: URL
    private let preservedParent: URL
    private let throwsAfterReplacement: Bool
    private var replaced = false

    init(
        parent: URL,
        destination: URL,
        preservedParent: URL,
        throwsAfterReplacement: Bool
    ) {
        self.parent = parent
        self.destination = destination
        self.preservedParent = preservedParent
        self.throwsAfterReplacement = throwsAfterReplacement
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
        if throwsAfterReplacement {
            throw PostInstallSyncInjectedFailure.stopAfterReplacement
        }
    }
}
