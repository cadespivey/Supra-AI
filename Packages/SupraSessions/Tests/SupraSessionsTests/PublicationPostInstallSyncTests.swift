import Darwin
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

    // ACR-EXPORT-020. The final directory-sync callback can mutate the installed
    // inode without changing its identity. Success still has to bind the bytes
    // returned by validation to the bytes present after that last callback.
    func testACREXPORT020PostInstallSyncContentMutationStopsBeforeAudit() async throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Post-install content mutation")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Supra-PostInstallMutation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DocumentStorage(root: root)
        let destination = storage.exportsDirectory(forMatterID: matter.id)
            .appendingPathComponent("Post-sync-mutation-fixed.md")
        let mutated = Data("# Mutated during final synchronization\n".utf8)
        let injector = FinalSyncContentMutationInjector(
            destination: destination,
            replacement: mutated
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
                title: "Post sync mutation",
                description: "Final synchronization must not detach validation from bytes."
            )
        )

        if case .success = result {
            XCTFail("post-install content mutation unexpectedly published successfully")
        }
        XCTAssertTrue(injector.didMutate)
        XCTAssertEqual(auditCallCount, 0)
        XCTAssertEqual(try Data(contentsOf: destination), mutated)
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

    // ACR-EXPORT-021. Inspection errors after the final callback are publication
    // uncertainty, not ordinary write failures: the exact installed inode is
    // already public and must remain attached to a recoverable intent.
    func testACREXPORT021PostInstallInspectionErrorRequiresRecovery() async throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Post-install inspection error")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Supra-PostInstallUnreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DocumentStorage(root: root)
        let destination = storage.exportsDirectory(forMatterID: matter.id)
            .appendingPathComponent("Post-sync-unreadable-fixed.md")
        let injector = FinalSyncUnreadableDestinationInjector(destination: destination)
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
                title: "Post sync unreadable",
                description: "Inspection errors after install require recovery."
            )
        )

        if case .success = result { XCTFail("unreadable installed file unexpectedly succeeded") }
        XCTAssertTrue(injector.didChangePermissions)
        XCTAssertEqual(auditCallCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        _ = chmod(destination.path, S_IRUSR | S_IWUSR)
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
        XCTAssertEqual(intent.status, DraftArtifactIntentStatus.recoveryRequired.rawValue)
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
    }

    // ACR-EXPORT-022. A throwing final-sync callback can move the exact inode to
    // a hidden residue. Absence at the destination is insufficient to authorize
    // abort while those exact bytes remain in the managed directory.
    func testACREXPORT022ThrowingPostInstallMoveRequiresRecovery() async throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Post-install moved residue")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Supra-PostInstallMoved-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DocumentStorage(root: root)
        let destination = storage.exportsDirectory(forMatterID: matter.id)
            .appendingPathComponent("Post-sync-moved-fixed.md")
        let residue = destination.deletingLastPathComponent()
            .appendingPathComponent(".post-sync-residue-\(UUID().uuidString)")
        let injector = FinalSyncMoveInjector(destination: destination, residue: residue)
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
                title: "Post sync moved",
                description: "Moved exact bytes remain a recovery artifact."
            )
        )

        if case .success = result { XCTFail("moved installed file unexpectedly succeeded") }
        XCTAssertTrue(injector.didMove)
        XCTAssertEqual(auditCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let residueData = try Data(contentsOf: residue)
        let intents = try await store.database.writer.read { db in
            try DraftArtifactIntentRecord.fetchAll(
                db,
                sql: "SELECT * FROM draft_artifact_intents WHERE matter_id = ?",
                arguments: [matter.id]
            )
        }
        XCTAssertEqual(intents.count, 1)
        let intent = try XCTUnwrap(intents.first)
        XCTAssertEqual(residueData.count, intent.outputByteSize)
        XCTAssertEqual(DocumentStorage.sha256Hex(of: residueData), intent.outputSHA256)
        XCTAssertEqual(intent.status, DraftArtifactIntentStatus.recoveryRequired.rawValue)
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
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

private final class FinalSyncUnreadableDestinationInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private var changedPermissions = false

    init(destination: URL) {
        self.destination = destination
    }

    var didChangePermissions: Bool { lock.withLock { changedPermissions } }

    func synchronize(_ directory: URL) throws {
        let shouldChange = lock.withLock { () -> Bool in
            guard !changedPermissions,
                  FileManager.default.fileExists(atPath: destination.path) else {
                return false
            }
            changedPermissions = true
            return true
        }
        guard shouldChange else { return }
        guard chmod(destination.path, 0) == 0 else { throw POSIXError(.EACCES) }
    }
}

private final class FinalSyncMoveInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let residue: URL
    private var moved = false

    init(destination: URL, residue: URL) {
        self.destination = destination
        self.residue = residue
    }

    var didMove: Bool { lock.withLock { moved } }

    func synchronize(_ directory: URL) throws {
        let shouldMove = lock.withLock { () -> Bool in
            guard !moved, FileManager.default.fileExists(atPath: destination.path) else {
                return false
            }
            moved = true
            return true
        }
        guard shouldMove else { return }
        try FileManager.default.moveItem(at: destination, to: residue)
        throw PostInstallSyncInjectedFailure.stopAfterReplacement
    }
}

private final class FinalSyncContentMutationInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let replacement: Data
    private var mutated = false

    init(destination: URL, replacement: Data) {
        self.destination = destination
        self.replacement = replacement
    }

    var didMutate: Bool { lock.withLock { mutated } }

    func synchronize(_ directory: URL) throws {
        let shouldMutate = lock.withLock { () -> Bool in
            guard !mutated, FileManager.default.fileExists(atPath: destination.path) else {
                return false
            }
            mutated = true
            return true
        }
        guard shouldMutate else { return }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.synchronize()
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
