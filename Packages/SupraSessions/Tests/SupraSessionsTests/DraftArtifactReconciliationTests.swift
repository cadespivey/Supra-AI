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
        let ownedTemporary = directory.appendingPathComponent(".Missing.md.supra-tmp-owned")
        let unrelatedTemporary = directory.appendingPathComponent(".Other.md.supra-tmp-unrelated")
        try output.write(to: ownedTemporary)
        try output.write(to: unrelatedTemporary)

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        ).reconcilePendingIntents()

        XCTAssertEqual(summary.removedTemporaryFileCount, 1)
        XCTAssertEqual(summary.abortedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedTemporary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedTemporary.path))
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.aborted.rawValue
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
