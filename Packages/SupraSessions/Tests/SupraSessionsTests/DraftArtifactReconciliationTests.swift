import Foundation
import SupraDocuments
import SupraStore
@testable import SupraSessions
import XCTest

final class DraftArtifactReconciliationTests: XCTestCase {
    func testTDAR01RelaunchFinalizesExactValidatedPublicArtifactOnce() throws {
        let fixture = try makeFixture()
        let output = Data("# Interrupted draft\n\nRecovered on relaunch.\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Interrupted.md",
            output: output,
            id: "interrupted-exact"
        )
        let publicURL = try install(output, intent: intent, storage: fixture.storage)

        let relaunched = DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        )
        let first = try relaunched.reconcilePendingIntents()
        let second = try relaunched.reconcilePendingIntents()

        XCTAssertEqual(first.finalizedCount, 1)
        XCTAssertEqual(second.finalizedCount, 0)
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.completed.rawValue
        )
        XCTAssertEqual(try Data(contentsOf: publicURL), output)
        XCTAssertEqual(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id)
                .filter { $0.eventType == "draft_generated" }.count,
            1
        )
    }

    func testTDAR02RelaunchPreservesMismatchedPublicFileAndRequiresRecovery() throws {
        let fixture = try makeFixture()
        let expected = Data("# Expected\n".utf8)
        let replacement = Data("# Concurrent replacement\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Preserve-replacement.md",
            output: expected,
            id: "interrupted-mismatch"
        )
        let publicURL = try install(replacement, intent: intent, storage: fixture.storage)

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        ).reconcilePendingIntents()

        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertEqual(try Data(contentsOf: publicURL), replacement)
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
        XCTAssertTrue(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).isEmpty)
        XCTAssertNotNil(
            try fixture.store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )
    }

    func testTDAR03RelaunchRejectsExactBytesWithInvalidRecordedFormat() throws {
        let fixture = try makeFixture()
        let invalidUTF8 = Data([0xff, 0xfe, 0xfd])
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Invalid.md",
            output: invalidUTF8,
            id: "interrupted-invalid-format"
        )
        let publicURL = try install(invalidUTF8, intent: intent, storage: fixture.storage)

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        ).reconcilePendingIntents()

        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertEqual(try Data(contentsOf: publicURL), invalidUTF8)
        XCTAssertTrue(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).isEmpty)
    }

    func testTDAR04RelaunchCleansOnlyOwnedTemporaryAndAbortsMissingPublication() throws {
        let fixture = try makeFixture()
        let output = Data("# Never installed\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Missing.md",
            output: output,
            id: "interrupted-missing"
        )
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryUUID = "92B44B91-8C30-45DB-8870-3AB32E0C9797"
        let ownedTemporary = directory.appendingPathComponent(".Missing.md.supra-tmp-\(temporaryUUID)")
        let samePrefixNearMatch = directory.appendingPathComponent(".Missing.md.supra-tmp-user-notes")
        let unrelatedTemporary = directory.appendingPathComponent(".Other.md.supra-tmp-unrelated")
        try output.write(to: ownedTemporary)
        try output.write(to: samePrefixNearMatch)
        try output.write(to: unrelatedTemporary)

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        ).reconcilePendingIntents()

        XCTAssertEqual(summary.removedTemporaryFileCount, 1)
        XCTAssertEqual(summary.abortedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedTemporary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: samePrefixNearMatch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedTemporary.path))
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.aborted.rawValue
        )
        XCTAssertTrue(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).isEmpty)
        XCTAssertNil(
            try fixture.store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )
    }

    func testTDAR05RelaunchNeverFollowsOrDeletesPublicSymlink() throws {
        let fixture = try makeFixture()
        let output = Data("# Expected artifact\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Unsafe-link.md",
            output: output,
            id: "interrupted-symlink"
        )
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = fixture.storage.root.appendingPathComponent("unowned-target.md")
        let publicURL = directory.appendingPathComponent(intent.fileName)
        try output.write(to: target)
        try FileManager.default.createSymbolicLink(at: publicURL, withDestinationURL: target)

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        ).reconcilePendingIntents()

        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: publicURL.path))
        XCTAssertEqual(try Data(contentsOf: target), output)
        XCTAssertTrue(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).isEmpty)
    }

    func testTDAR06RelaunchAbortsMissingPublicationWithoutFalseRecovery() throws {
        let fixture = try makeFixture()
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Never-installed.md",
            output: Data("# Never installed\n".utf8),
            id: "interrupted-no-public-file"
        )

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        ).reconcilePendingIntents()

        XCTAssertEqual(summary.abortedCount, 1)
        XCTAssertEqual(summary.recoveryRequiredCount, 0)
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.aborted.rawValue
        )
        XCTAssertTrue(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).isEmpty)
        XCTAssertNil(
            try fixture.store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )
    }

    func testTDAR07RelaunchRejectsSymlinkedManagedParentWithoutTouchingTarget() throws {
        let fixture = try makeFixture()
        let output = Data("# Outside managed root\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Redirected.md",
            output: output,
            id: "interrupted-parent-symlink"
        )
        let external = fixture.storage.root.deletingLastPathComponent()
            .appendingPathComponent("supra-unowned-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createDirectory(
            at: external.appendingPathComponent(fixture.matter.id, isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: fixture.storage.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.storage.exportsDirectory,
            withDestinationURL: external
        )
        let redirectedPublic = external
            .appendingPathComponent(fixture.matter.id, isDirectory: true)
            .appendingPathComponent(intent.fileName)
        try output.write(to: redirectedPublic)

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        ).reconcilePendingIntents()

        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertEqual(try Data(contentsOf: redirectedPublic), output)
        XCTAssertTrue(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).isEmpty)
    }

    func testTDAR08RelaunchRemovesOnlyExactOwnedRollbackQuarantine() throws {
        let fixture = try makeFixture()
        let output = Data("# Quarantined owned draft\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Quarantined.md",
            output: output,
            id: "interrupted-owned-quarantine"
        )
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identifier = "2da870c1-72b4-47b8-b4e8-8ebd23525a19"
        let exact = directory.appendingPathComponent(
            ".supra-draft-rollback-\(identifier)-\(intent.fileName)"
        )
        let nonUUID = directory.appendingPathComponent(
            ".supra-draft-rollback-user-notes-\(intent.fileName)"
        )
        let malformedNearMatch = directory.appendingPathComponent(
            ".supra-draft-rollback-\(identifier)-\(intent.fileName)-notes"
        )
        try output.write(to: exact)
        try output.write(to: nonUUID)
        try output.write(to: malformedNearMatch)

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        ).reconcilePendingIntents()

        XCTAssertEqual(summary.removedRollbackQuarantineCount, 1)
        XCTAssertEqual(summary.abortedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exact.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonUUID.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformedNearMatch.path))
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.aborted.rawValue
        )
        XCTAssertTrue(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).isEmpty)
        XCTAssertNil(
            try fixture.store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )
    }

    func testTDAR09RelaunchPreservesMismatchedExactRollbackQuarantineForRecovery() throws {
        let fixture = try makeFixture()
        let expected = Data("# Expected owned draft\n".utf8)
        let mismatched = Data("# Changed quarantine\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Changed-quarantine.md",
            output: expected,
            id: "interrupted-changed-quarantine"
        )
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let quarantine = directory.appendingPathComponent(
            ".supra-draft-rollback-bbf231d5-d197-47d5-92ec-78ac7f33e593-\(intent.fileName)"
        )
        try mismatched.write(to: quarantine)

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        ).reconcilePendingIntents()

        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertEqual(try Data(contentsOf: quarantine), mismatched)
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
        XCTAssertTrue(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).isEmpty)
        XCTAssertNotNil(
            try fixture.store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )
    }

    func testTDAR10RelaunchPreservesUnsafeExactWriterTemporaryEntriesForRecovery() throws {
        let fixture = try makeFixture()
        let output = Data("# Expected draft\n".utf8)
        let symlinkIntent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Unsafe-temp-link.md",
            output: output,
            id: "unsafe-writer-temp-symlink"
        )
        let directoryIntent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Unsafe-temp-directory.md",
            output: output,
            id: "unsafe-writer-temp-directory"
        )
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = fixture.storage.root.appendingPathComponent("unowned-temp-target.md")
        try output.write(to: target)
        let symlink = directory.appendingPathComponent(
            ".\(symlinkIntent.fileName).supra-tmp-2da870c1-72b4-47b8-b4e8-8ebd23525a19"
        )
        let nonregular = directory.appendingPathComponent(
            ".\(directoryIntent.fileName).supra-tmp-bbf231d5-d197-47d5-92ec-78ac7f33e593"
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        try FileManager.default.createDirectory(at: nonregular, withIntermediateDirectories: false)

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        ).reconcilePendingIntents()

        XCTAssertEqual(summary.recoveryRequiredCount, 2)
        XCTAssertEqual(summary.abortedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonregular.path))
        XCTAssertEqual(try Data(contentsOf: target), output)
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: symlinkIntent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: directoryIntent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
    }

    func testTDAR11ValidatesPreparedRowBeforeAnyFilesystemMutation() throws {
        let fixture = try makeFixture()
        let output = Data("# Expected draft\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Original.md",
            output: output,
            id: "tampered-path-intent"
        )
        try fixture.store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE draft_artifact_intents SET file_name = ? WHERE id = ?",
                arguments: ["Tampered.md", intent.id]
            )
        }
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exactTemporary = directory.appendingPathComponent(
            ".Tampered.md.supra-tmp-92b44b91-8c30-45db-8870-3ab32e0c9797"
        )
        try output.write(to: exactTemporary)

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        ).reconcilePendingIntents()

        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertEqual(summary.removedTemporaryFileCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exactTemporary.path))
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
    }

    // Expected RED: a swap after the first lstat made path-based reads follow an
    // unowned symlink and finalize it as the prepared artifact.
    func testTDAR12PublicPathSymlinkSwapAfterRegularCheckNeverFinalizes() throws {
        let fixture = try makeFixture()
        let output = Data("# Exact expected draft\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Inspection-race.md",
            output: output,
            id: "public-inspection-race"
        )
        let publicURL = try install(output, intent: intent, storage: fixture.storage)
        let external = fixture.storage.root.appendingPathComponent("unowned-exact-target.md")
        try output.write(to: external)
        let service = DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        )
        service.publicArtifactInspectionCheckpoint = { checkedURL in
            try FileManager.default.removeItem(at: checkedURL)
            try FileManager.default.createSymbolicLink(at: checkedURL, withDestinationURL: external)
        }

        let summary = try service.reconcilePendingIntents()

        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertEqual(summary.finalizedCount, 0)
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
        XCTAssertTrue(try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: publicURL.path), external.path)
        XCTAssertEqual(try Data(contentsOf: external), output)
    }

    // Process-boundary RED proof: an in-memory relaunch simulation cannot prove
    // the prepared row and exact-once audit survive closing and reopening SQLite.
    func testTDAR13ReopensOnDiskStoreAndFinalizesInterruptedIntentExactlyOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("supra-draft-process-boundary-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("supra.sqlite")
        let storage = DocumentStorage(root: root.appendingPathComponent("managed", isDirectory: true))
        let output = Data("# Relaunched exact draft\n".utf8)
        var firstStore: SupraStore? = try SupraStore(url: databaseURL)
        let matter = try XCTUnwrap(firstStore).matters.createMatter(name: "On-disk relaunch matter")
        let intent = try XCTUnwrap(firstStore).draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "On-disk-interrupted.md",
            output: output,
            id: "on-disk-interrupted-intent"
        )
        let publicURL = try install(output, intent: intent, storage: storage)
        try XCTUnwrap(firstStore).database.writer.close()
        firstStore = nil

        let relaunchedStore = try SupraStore(url: databaseURL)
        let service = DraftArtifactReconciliationService(store: relaunchedStore, storage: storage)
        let first = try service.reconcilePendingIntents()
        let second = try service.reconcilePendingIntents()

        XCTAssertEqual(first.finalizedCount, 1)
        XCTAssertEqual(second.finalizedCount, 0)
        XCTAssertEqual(try Data(contentsOf: publicURL), output)
        XCTAssertEqual(
            try relaunchedStore.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.completed.rawValue
        )
        XCTAssertEqual(
            try relaunchedStore.auditEvents.fetchEvents(matterID: matter.id)
                .filter { $0.id == "draft-artifact-\(intent.id)" }.count,
            1
        )
    }

    private struct Fixture {
        let store: SupraStore
        let matter: MatterRecord
        let storage: DocumentStorage
    }

    private func makeFixture() throws -> Fixture {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Artifact reconciliation matter")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("supra-draft-reconciliation-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(store: store, matter: matter, storage: DocumentStorage(root: root))
    }

    private func install(
        _ data: Data,
        intent: DraftArtifactIntentRecord,
        storage: DocumentStorage
    ) throws -> URL {
        let directory = storage.exportsDirectory(forMatterID: intent.matterID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(intent.fileName)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}
