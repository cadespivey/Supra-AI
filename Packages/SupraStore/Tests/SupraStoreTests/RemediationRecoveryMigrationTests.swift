import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class RemediationRecoveryMigrationTests: XCTestCase {
    func testACRRECOVERY001V057CreatesReviewItemsWithoutChangingUserContent() throws {
        // Expected RED: v057 and remediation_recovery_items do not exist.
        let queue = try DatabaseQueue()
        let migrator = SupraMigrator.makeMigrator()
        try migrator.migrate(queue, upTo: "v056_add_document_blob_integrity")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try queue.write { db in
            for matter in [
                MatterRecord(id: "matter-a", name: "Synthetic Matter A", createdAt: now, updatedAt: now),
                MatterRecord(id: "matter-b", name: "Synthetic Matter B", createdAt: now, updatedAt: now),
            ] { try matter.insert(db) }
            try StructuredOutputRecord(
                id: "output-legacy", matterID: "matter-a", title: "Legacy output",
                outputType: StructuredOutputType.documentQA.rawValue,
                activeVersionID: "version-legacy", status: StructuredOutputStatus.needsReview.rawValue,
                createdAt: now, updatedAt: now
            ).insert(db)
            try StructuredOutputVersionRecord(
                id: "version-legacy", structuredOutputID: "output-legacy", versionIndex: 1,
                contentMarkdown: "# Original synthetic content\n\nPreserve this exactly.",
                requiredSectionsJSON: "[]", presentSectionsJSON: "[]", missingSectionsJSON: "[]",
                verificationStatus: OutputVerificationStatus.legacyUnverified.rawValue,
                createdAt: now, updatedAt: now
            ).insert(db)
            try AuditEventRecord(
                id: "draft-event", matterID: "matter-a", timestamp: now,
                eventType: "draft_generated", actor: "runtime",
                summary: "Generated legacy synthetic draft"
            ).insert(db)
            try ScratchPadDayRecord(id: "day", day: "2026-07-01", createdAt: now, updatedAt: now).insert(db)
            try BillingDraftRecord(
                id: "billing-legacy", dayID: "day", version: 1,
                status: .draft, createdAt: now, updatedAt: now
            ).insert(db)
            try BillingLineItemRecord(
                id: "line-a", draftID: "billing-legacy", seq: 1, matterID: "matter-a",
                narrative: "Synthetic work A", hours: 0.5, workDate: "2026-07-01",
                createdAt: now, updatedAt: now
            ).insert(db)
            try BillingLineItemRecord(
                id: "line-b", draftID: "billing-legacy", seq: 2, matterID: "matter-b",
                narrative: "Synthetic work B", hours: 0.6, workDate: "2026-07-01",
                createdAt: now, updatedAt: now
            ).insert(db)
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let items = try RemediationRecoveryItemRecord.fetchAll(db)
            XCTAssertEqual(Set(items.map(\.kind)), Set([
                RemediationRecoveryKind.legacyStructuredOutput.rawValue,
                RemediationRecoveryKind.legacyDraftArtifact.rawValue,
                RemediationRecoveryKind.multiMatterBillingDraft.rawValue,
            ]))
            XCTAssertTrue(items.allSatisfy { $0.status == RemediationRecoveryStatus.pending.rawValue })
            let version = try XCTUnwrap(try StructuredOutputVersionRecord.fetchOne(db, key: "version-legacy"))
            XCTAssertEqual(version.contentMarkdown, "# Original synthetic content\n\nPreserve this exactly.")
            XCTAssertEqual(version.verificationStatus, OutputVerificationStatus.legacyUnverified.rawValue)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM billing_line_items"), 2)
        }
    }

    func testACRRECOVERY002ResolutionIsAuditedWithoutContent() throws {
        // Expected RED: no durable recovery repository or typed resolution exists.
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Synthetic Recovery Matter")
        let item = try store.remediationRecovery.requireReview(
            kind: .legacyStructuredOutput,
            matterID: matter.id,
            relatedTable: "structured_outputs",
            relatedID: "output-canary"
        )

        XCTAssertEqual(try store.remediationRecovery.summary().pendingCount, 1)
        try store.remediationRecovery.resolve(
            id: item.id,
            resolution: .reverified,
            actor: "user"
        )

        XCTAssertEqual(try store.remediationRecovery.summary().pendingCount, 0)
        let events = try store.auditEvents.fetchEvents(matterID: matter.id)
        let event = try XCTUnwrap(events.first { $0.eventType == "remediation_recovery_resolved" })
        XCTAssertEqual(event.relatedID, item.id)
        XCTAssertFalse(event.summary.contains("output-canary"))
        XCTAssertNil(event.metadataJSON)
    }
}
