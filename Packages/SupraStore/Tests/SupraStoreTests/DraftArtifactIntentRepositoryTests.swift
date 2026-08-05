import Foundation
@testable import SupraStore
import XCTest

final class DraftArtifactIntentRepositoryTests: XCTestCase {
    func testTDAI02FinalizationHashesInstalledBytesAndIsIdempotent() throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic artifact matter")
        let expected = Data("expected bytes".utf8)
        let intent = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Synthetic-draft.md",
            output: expected,
            id: "synthetic-artifact-intent"
        )

        // Expected RED follow-on: completed idempotence returned before checking
        // retry bytes or the deterministic audit row.
        XCTAssertThrowsError(
            try store.draftArtifacts.finalizeIntent(
                id: intent.id,
                installedOutput: Data("replaced bytes".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? DraftArtifactIntentError, .installedArtifactMismatch)
        }
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
        XCTAssertEqual(
            try store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.prepared.rawValue
        )

        try store.draftArtifacts.finalizeIntent(id: intent.id, installedOutput: expected)
        try store.draftArtifacts.finalizeIntent(id: intent.id, installedOutput: expected)
        XCTAssertEqual(
            try store.auditEvents.fetchEvents(matterID: matter.id)
                .filter { $0.eventType == "draft_generated" }.count,
            1
        )

        XCTAssertThrowsError(
            try store.draftArtifacts.finalizeIntent(
                id: intent.id,
                installedOutput: Data("wrong completed retry".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? DraftArtifactIntentError, .installedArtifactMismatch)
        }
        try store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE audit_events SET summary = ? WHERE id = ?",
                arguments: ["tampered completed audit", "draft-artifact-\(intent.id)"]
            )
        }
        XCTAssertThrowsError(
            try store.draftArtifacts.finalizeIntent(id: intent.id, installedOutput: expected)
        ) { error in
            XCTAssertEqual(error as? DraftArtifactIntentError, .intentIntegrityInvalid)
        }
    }

    func testTDAI03OnlyPreparedIntentReservesFileName() throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic reservation matter")
        let output = Data("draft".utf8)
        let first = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Reusable.md",
            output: output,
            id: "first-reservation"
        )
        XCTAssertThrowsError(
            try store.draftArtifacts.prepareGenericIntent(
                matterID: matter.id,
                artifactKind: .customDescription,
                format: .markdown,
                fileName: "Reusable.md",
                output: output,
                id: "competing-reservation"
            )
        ) { error in
            XCTAssertEqual(error as? DraftArtifactIntentError, .fileNameReserved)
        }

        try store.draftArtifacts.abortIntent(id: first.id)
        let replacement = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Reusable.md",
            output: output,
            id: "replacement-reservation"
        )
        XCTAssertEqual(replacement.status, DraftArtifactIntentStatus.prepared.rawValue)
    }

    func testTDAI04FinalizationRejectsConflictingDeterministicAuditID() throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic audit collision matter")
        let output = Data("# Expected draft\n".utf8)
        let intent = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Audit-collision.md",
            output: output,
            id: "synthetic-audit-collision"
        )
        var conflicting = try store.draftArtifacts.auditEventPreview(intentID: intent.id)
        conflicting.summary = "Forged event occupying the deterministic identifier"
        try store.auditEvents.recordEvent(conflicting)

        XCTAssertThrowsError(
            try store.draftArtifacts.finalizeIntent(id: intent.id, installedOutput: output)
        ) { error in
            XCTAssertEqual(error as? DraftArtifactIntentError, .intentIntegrityInvalid)
        }
        XCTAssertEqual(
            try store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.prepared.rawValue
        )
        let stored = try XCTUnwrap(
            store.auditEvents.fetchEvents(matterID: matter.id).first { $0.id == conflicting.id }
        )
        XCTAssertEqual(stored.summary, conflicting.summary)
        XCTAssertNotEqual(stored.summary, "Generated customDescription draft (Audit-collision.md)")
    }

    func testTDAI05FinalizationRejectsEvenExactPreexistingDeterministicAuditID() throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Exact audit collision matter")
        let output = Data("# Expected draft\n".utf8)
        let intent = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Exact-audit-collision.md",
            output: output,
            id: "exact-audit-collision"
        )
        let exact = try store.draftArtifacts.auditEventPreview(intentID: intent.id)
        try store.auditEvents.recordEvent(exact)

        XCTAssertThrowsError(
            try store.draftArtifacts.finalizeIntent(id: intent.id, installedOutput: output)
        ) { error in
            XCTAssertEqual(error as? DraftArtifactIntentError, .intentIntegrityInvalid)
        }
        XCTAssertEqual(
            try store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.prepared.rawValue
        )
    }

    // Expected RED: the intent cascaded but its logical recovery row survived
    // with a NULL matter and an unresolvable related ID.
    func testTDAI06PermanentMatterDeletionLeavesNoDanglingInterruptedRecoveryItem() throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Deleted recovery matter")
        let intent = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Preserved-recovery.md",
            output: Data("# Preserved recovery\n".utf8),
            id: "deleted-matter-recovery-intent"
        )
        try store.draftArtifacts.markRecoveryRequired(id: intent.id)
        XCTAssertNotNil(
            try store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )

        _ = try store.matters.permanentlyDeleteMatter(id: matter.id)

        XCTAssertNil(try store.draftArtifacts.intent(id: intent.id))
        XCTAssertNil(
            try store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            ),
            "permanent deletion must not strand an unresolvable pending recovery row"
        )
    }

    // Expected RED: recovery UI could only read the raw row and would derive a
    // managed URL from a file_name that terminal recovery may have flagged as corrupt.
    func testTDAI07RecoveryDescriptorRejectsTamperedTerminalFileName() throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Tampered descriptor matter")
        let intent = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Original-recovery.md",
            output: Data("# Original\n".utf8),
            id: "tampered-recovery-descriptor"
        )
        try store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE draft_artifact_intents SET file_name = ? WHERE id = ?",
                arguments: ["Tampered-recovery.md", intent.id]
            )
        }
        try store.draftArtifacts.markRecoveryRequired(id: intent.id)

        XCTAssertThrowsError(
            try store.draftArtifacts.recoveryDescriptor(id: intent.id)
        ) { error in
            XCTAssertEqual(error as? DraftArtifactIntentError, .intentIntegrityInvalid)
        }
    }

    // Expected RED: generic lineage did not bind the originating matter, so a
    // terminal row rebound to another active matter yielded a revealable path.
    func testTDAI08RecoveryDescriptorRejectsGenericMatterRebind() throws {
        let store = try SupraStore.inMemory()
        let originalMatter = try store.matters.createMatter(name: "Original recovery matter")
        let reboundMatter = try store.matters.createMatter(name: "Rebound recovery matter")
        let intent = try store.draftArtifacts.prepareGenericIntent(
            matterID: originalMatter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Matter-bound-recovery.md",
            output: Data("# Matter-bound recovery\n".utf8),
            id: "generic-matter-rebind-recovery"
        )
        try store.draftArtifacts.markRecoveryRequired(id: intent.id)
        try store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE draft_artifact_intents SET matter_id = ? WHERE id = ?",
                arguments: [reboundMatter.id, intent.id]
            )
        }

        XCTAssertThrowsError(
            try store.draftArtifacts.recoveryDescriptor(id: intent.id)
        ) { error in
            XCTAssertEqual(error as? DraftArtifactIntentError, .intentIntegrityInvalid)
        }
    }
}
