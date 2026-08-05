import Darwin
import Foundation
import GRDB
@testable import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class PublicationTemporaryCleanupTests: XCTestCase {
    private enum InjectedFailure: Error { case stop }

    // ACR-EXPORT-019. Pre-install unwind cannot be a best-effort defer. If the
    // writer cannot remove and synchronize its exact managed temporary, the
    // retained temp must remain associated with a recovery-required intent
    // rather than an aborted row reconciliation will ignore.
    func testACREXPORT019FailedManagedTemporaryCleanupRequiresRecovery() async throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Temporary cleanup matter")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Supra-Temp-Cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DocumentStorage(root: root)
        let parent = storage.exportsDirectory(forMatterID: matter.id)
        let writer = DurableFileWriter { stage in
            guard stage == .beforeValidation else { return }
            guard Darwin.chmod(parent.path, S_IRUSR | S_IXUSR) == 0 else {
                throw POSIXError(.EACCES)
            }
            throw InjectedFailure.stop
        }
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            fileWriter: writer,
            fileStampProvider: { "fixed" }
        )

        let result = await controller.draftCustomDescription(
            matterID: matter.id,
            input: .init(
                title: "Temporary cleanup",
                description: "Retain recovery state when exact temp cleanup is uncertain."
            )
        )
        _ = Darwin.chmod(parent.path, S_IRWXU)

        guard case let .failure(.renderFailed(message)) = result else {
            return XCTFail("expected cleanup uncertainty, got \(result)")
        }
        XCTAssertTrue(message.contains("temporary cleanup"), message)
        let residues = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".supra-tmp-") }
        XCTAssertEqual(residues.count, 1)
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

    // Removing the exact managed temporary is only half the unwind. If the
    // containing-directory sync fails after unlink, the namespace remains
    // crash-uncertain and the prepared intent must remain recoverable.
    func testACREXPORT019FailedManagedTemporaryCleanupSynchronizationRequiresRecovery() async throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Temporary cleanup sync matter")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Supra-Temp-Cleanup-Sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DocumentStorage(root: root)
        let parent = storage.exportsDirectory(forMatterID: matter.id)
        let destination = parent.appendingPathComponent("Temporary-cleanup-sync-fixed.md")
        let injector = TemporaryCleanupSyncFailureInjector()
        let writer = DurableFileWriter(
            faultInjector: { try injector.inject($0) },
            parentDirectorySynchronizer: { try injector.synchronize($0) }
        )
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            fileWriter: writer,
            fileStampProvider: { "fixed" }
        )

        let result = await controller.draftCustomDescription(
            matterID: matter.id,
            input: .init(
                title: "Temporary cleanup sync",
                description: "Retain recovery state when temporary unlink durability is uncertain."
            )
        )

        guard case let .failure(.renderFailed(message)) = result else {
            return XCTFail("expected cleanup synchronization uncertainty, got \(result)")
        }
        XCTAssertTrue(message.contains("temporary cleanup"), message)
        XCTAssertTrue(message.contains("synchronization"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
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

    // ACR-EXPORT-023. Cleanup must prove absence at the caller-visible temp path,
    // not only through a descriptor for a parent detached during synchronization.
    func testACREXPORT023LexicalManagedTemporaryReappearanceRequiresRecovery() async throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Lexical temporary reappearance")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Supra-Temp-Lexical-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DocumentStorage(root: root)
        let parent = storage.exportsDirectory(forMatterID: matter.id)
        let injector = TemporaryCleanupLexicalReappearanceInjector(
            root: root,
            parent: parent
        )
        let writer = DurableFileWriter(
            faultInjector: { try injector.inject($0) },
            parentDirectorySynchronizer: { try injector.synchronize($0) }
        )
        let controller = MatterDraftingController(
            store: store,
            storage: storage,
            fileWriter: writer,
            fileStampProvider: { "fixed" }
        )

        let result = await controller.draftCustomDescription(
            matterID: matter.id,
            input: .init(
                title: "Lexical temporary",
                description: "A reappearing exact temporary remains recoverable."
            )
        )

        guard case let .failure(.renderFailed(message)) = result else {
            return XCTFail("expected lexical cleanup uncertainty, got \(result)")
        }
        XCTAssertTrue(message.contains("temporary cleanup"), message)
        let residue = try XCTUnwrap(injector.source)
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
}

private final class TemporaryCleanupLexicalReappearanceInjector: @unchecked Sendable {
    private enum InjectedFailure: Error { case beforeValidation }

    private let lock = NSLock()
    private let root: URL
    private let parent: URL
    private let preservedParent: URL
    private var retained: URL?
    private var sourceURL: URL?
    private var replaced = false

    init(root: URL, parent: URL) {
        self.root = root
        self.parent = parent
        self.preservedParent = root.appendingPathComponent(
            "preserved-temporary-parent-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    var source: URL? { lock.withLock { sourceURL } }

    func inject(_ stage: DurableFileWriter.FaultStage) throws {
        guard stage == .beforeValidation else { return }
        let temporary = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.contains(".supra-tmp-") }
        )
        let retained = root.appendingPathComponent("retained-temporary-\(UUID().uuidString)")
        try FileManager.default.linkItem(at: temporary, to: retained)
        lock.withLock {
            self.retained = retained
            self.sourceURL = temporary
        }
        throw InjectedFailure.beforeValidation
    }

    func synchronize(_ directory: URL) throws {
        let state = lock.withLock { () -> (URL, URL)? in
            guard !replaced,
                  let retained,
                  let sourceURL,
                  !FileManager.default.fileExists(atPath: sourceURL.path) else {
                return nil
            }
            replaced = true
            return (retained, sourceURL)
        }
        guard let (retained, source) = state else { return }
        try FileManager.default.moveItem(at: parent, to: preservedParent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: retained, to: source)
    }
}

private final class TemporaryCleanupSyncFailureInjector: @unchecked Sendable {
    private enum InjectedFailure: Error {
        case beforeValidation
        case cleanupSynchronization
    }

    private let lock = NSLock()
    private var cleanupStarted = false

    func inject(_ stage: DurableFileWriter.FaultStage) throws {
        guard stage == .beforeValidation else { return }
        lock.withLock { cleanupStarted = true }
        throw InjectedFailure.beforeValidation
    }

    func synchronize(_ directory: URL) throws {
        if lock.withLock({ cleanupStarted }) {
            throw InjectedFailure.cleanupSynchronization
        }
    }
}
