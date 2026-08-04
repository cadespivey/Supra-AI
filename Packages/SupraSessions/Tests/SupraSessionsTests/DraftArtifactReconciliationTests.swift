import Foundation
@testable import SupraDocuments
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

    // T-DAR-14. Expected RED: cleanup validates an exact writer temporary and
    // then calls recursive FileManager removal with no deterministic pre-unlink
    // checkpoint or identity recheck.
    func testTDAR14TemporaryCleanupPreservesDirectorySwappedImmediatelyBeforeUnlink() throws {
        let fixture = try makeFixture()
        let output = Data("# Prepared temporary\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Temporary-swap.md",
            output: output,
            id: "temporary-pre-unlink-swap"
        )
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(intent.fileName).supra-tmp-92b44b91-8c30-45db-8870-3ab32e0c9797"
        )
        let preservedOriginal = directory.appendingPathComponent("preserved-writer-temporary.md")
        let canary = Data("directory owner canary".utf8)
        try output.write(to: temporary)
        let service = DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        )
        service.cleanupPreUnlinkCheckpoint = { candidate in
            XCTAssertEqual(candidate.standardizedFileURL, temporary.standardizedFileURL)
            try FileManager.default.moveItem(at: candidate, to: preservedOriginal)
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
            try canary.write(to: candidate.appendingPathComponent("owner-canary.txt"))
        }

        let summary = try service.reconcilePendingIntents()

        XCTAssertEqual(summary.removedTemporaryFileCount, 0)
        XCTAssertEqual(summary.abortedCount, 0)
        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertEqual(try Data(contentsOf: preservedOriginal), output)
        XCTAssertEqual(
            try Data(contentsOf: temporary.appendingPathComponent("owner-canary.txt")),
            canary
        )
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
    }

    // T-DAR-15. Expected RED: exact rollback-quarantine cleanup has the same
    // validation-to-recursive-removal window as writer-temporary cleanup.
    func testTDAR15RollbackCleanupPreservesDirectorySwappedImmediatelyBeforeUnlink() throws {
        let fixture = try makeFixture()
        let output = Data("# Prepared rollback quarantine\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Rollback-swap.md",
            output: output,
            id: "rollback-pre-unlink-swap"
        )
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let quarantine = directory.appendingPathComponent(
            ".supra-draft-rollback-bbf231d5-d197-47d5-92ec-78ac7f33e593-\(intent.fileName)"
        )
        let preservedOriginal = directory.appendingPathComponent("preserved-rollback-quarantine.md")
        let canary = Data("rollback directory owner canary".utf8)
        try output.write(to: quarantine)
        let service = DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        )
        service.cleanupPreUnlinkCheckpoint = { candidate in
            XCTAssertEqual(candidate.standardizedFileURL, quarantine.standardizedFileURL)
            try FileManager.default.moveItem(at: candidate, to: preservedOriginal)
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
            try canary.write(to: candidate.appendingPathComponent("owner-canary.txt"))
        }

        let summary = try service.reconcilePendingIntents()

        XCTAssertEqual(summary.removedRollbackQuarantineCount, 0)
        XCTAssertEqual(summary.abortedCount, 0)
        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertEqual(try Data(contentsOf: preservedOriginal), output)
        XCTAssertEqual(
            try Data(contentsOf: quarantine.appendingPathComponent("owner-canary.txt")),
            canary
        )
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
    }

    // T-DAR-16. Expected RED: the rollback artifact has passed byte and format
    // validation, but a managed-parent substitution inside the final unlink
    // window must not redirect cleanup into a foreign directory.
    func testTDAR16ValidatedRollbackCleanupRejectsManagedParentSubstitutionAtUnlink() throws {
        let fixture = try makeFixture()
        let output = Data("# Prepared rollback quarantine\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Rollback-parent-swap.md",
            output: output,
            id: "rollback-parent-substitution"
        )
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let quarantineName = ".supra-draft-rollback-bbf231d5-d197-47d5-92ec-78ac7f33e593-\(intent.fileName)"
        let quarantine = directory.appendingPathComponent(quarantineName)
        try output.write(to: quarantine)

        let preservedParent = fixture.storage.root
            .appendingPathComponent("preserved-matter-parent", isDirectory: true)
        let externalParent = fixture.storage.root.deletingLastPathComponent()
            .appendingPathComponent("Supra-Reconciliation-Foreign-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: externalParent) }
        try FileManager.default.createDirectory(at: externalParent, withIntermediateDirectories: true)
        let externalCandidate = externalParent.appendingPathComponent(quarantineName)
        let foreignBytes = Data("foreign-parent-substitution-canary".utf8)
        try foreignBytes.write(to: externalCandidate)

        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { _ in },
            fileUnlinkCheckpoint: { observedCandidate in
                guard observedCandidate.standardizedFileURL == quarantine.standardizedFileURL else {
                    throw InjectedParentSubstitutionFailure.unexpectedCandidate
                }
                try FileManager.default.moveItem(at: directory, to: preservedParent)
                try FileManager.default.createSymbolicLink(
                    at: directory,
                    withDestinationURL: externalParent
                )
            }
        )
        let service = DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage,
            fileWriter: writer
        )

        let summary = try service.reconcilePendingIntents()

        XCTAssertEqual(summary.removedRollbackQuarantineCount, 0)
        XCTAssertEqual(summary.abortedCount, 0)
        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertEqual(
            try Data(contentsOf: preservedParent.appendingPathComponent(quarantineName)),
            output
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalCandidate.path))
        if FileManager.default.fileExists(atPath: externalCandidate.path) {
            XCTAssertEqual(try Data(contentsOf: externalCandidate), foreignBytes)
        }
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
    }

    // T-DAR-17. A retained root descriptor keeps a renamed tree usable, but
    // relaunch cleanup must prove that tree is still reachable through the
    // configured managed-root pathname before deleting anything from it.
    func testTDAR17ValidatedRollbackCleanupRejectsManagedRootSubstitutionAtUnlink() throws {
        let fixture = try makeFixture()
        let output = Data("# Prepared rollback quarantine\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Rollback-root-swap.md",
            output: output,
            id: "rollback-root-substitution"
        )
        let directory = fixture.storage.exportsDirectory(forMatterID: fixture.matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let quarantineName = ".supra-draft-rollback-bbf231d5-d197-47d5-92ec-78ac7f33e593-\(intent.fileName)"
        let quarantine = directory.appendingPathComponent(quarantineName)
        try output.write(to: quarantine)

        let preservedRoot = fixture.storage.root.deletingLastPathComponent()
            .appendingPathComponent("Supra-Reconciliation-Preserved-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: preservedRoot) }
        let foreignBytes = Data("foreign-root-substitution-canary".utf8)
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { _ in },
            fileUnlinkCheckpoint: { observedCandidate in
                guard observedCandidate.standardizedFileURL == quarantine.standardizedFileURL else {
                    throw InjectedParentSubstitutionFailure.unexpectedCandidate
                }
                try FileManager.default.moveItem(at: fixture.storage.root, to: preservedRoot)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try foreignBytes.write(to: quarantine)
            }
        )
        let service = DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage,
            fileWriter: writer
        )

        let summary = try service.reconcilePendingIntents()

        let preservedCandidate = preservedRoot
            .appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent(fixture.matter.id, isDirectory: true)
            .appendingPathComponent(quarantineName)
        XCTAssertEqual(summary.removedRollbackQuarantineCount, 0)
        XCTAssertEqual(summary.abortedCount, 0)
        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertEqual(try Data(contentsOf: preservedCandidate), output)
        XCTAssertEqual(try Data(contentsOf: quarantine), foreignBytes)
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
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

private enum InjectedParentSubstitutionFailure: Error {
    case unexpectedCandidate
}
