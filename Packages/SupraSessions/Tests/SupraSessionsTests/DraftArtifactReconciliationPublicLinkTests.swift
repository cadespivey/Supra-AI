import Foundation
@testable import SupraDocuments
import SupraStore
@testable import SupraSessions
import XCTest

final class DraftArtifactReconciliationPublicLinkTests: XCTestCase {
    // T-DAR-21. The final cleanup observer can hard-link the exact owned
    // rollback quarantine back to its public name. Reconciliation must preserve
    // the quarantine and require recovery rather than deleting one name and
    // marking the intent aborted while the same inode remains public.
    func testTDAR21RollbackCleanupRejectsExactPublicHardLink() throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Rollback hard-link matter")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "supra-draft-reconciliation-public-link-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = DocumentStorage(root: root)
        let output = Data("# Prepared rollback hard link\n".utf8)
        let intent = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Rollback-hard-link.md",
            output: output,
            id: "rollback-public-hard-link"
        )
        let directory = storage.exportsDirectory(forMatterID: matter.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let publicURL = directory.appendingPathComponent(intent.fileName)
        let quarantine = directory.appendingPathComponent(
            ".supra-draft-rollback-571fc32f-29bc-4a30-a871-dcae99b8ef24-\(intent.fileName)"
        )
        try output.write(to: quarantine)
        let service = DraftArtifactReconciliationService(store: store, storage: storage)
        service.cleanupPreUnlinkCheckpoint = { candidate in
            XCTAssertEqual(candidate.standardizedFileURL, quarantine.standardizedFileURL)
            try FileManager.default.linkItem(at: candidate, to: publicURL)
        }

        let summary = try service.reconcilePendingIntents()

        XCTAssertEqual(summary.removedRollbackQuarantineCount, 0)
        XCTAssertEqual(summary.abortedCount, 0)
        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertEqual(try Data(contentsOf: quarantine), output)
        XCTAssertEqual(try Data(contentsOf: publicURL), output)
        XCTAssertEqual(
            try store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
    }
}
