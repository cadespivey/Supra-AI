import Foundation
import GRDB
@testable import SupraStore
import XCTest

/// T-DATA-COURT-03 — every migrated legacy court string that lacks canonical
/// identity must appear exactly once in a deterministic resolution queue. Applying
/// a reviewed decision is atomic, append-only, idempotent for an exact retry, and
/// durable across reopen.
///
/// SupraStore deliberately receives only primitive, version-bound catalog evidence.
/// Alias interpretation remains frozen in the migration or owned by SupraResearch;
/// this test adds no Research dependency and cannot make Store guess a court.
///
/// Expected RED: `MattersRepository` does not yet expose
/// `fetchUnresolvedCourtResolutionQueue()`, `resolveCourtIdentity(...)`, or
/// `fetchCourtIdentityResolutionReceipts(matterID:)`, and the resolution value
/// types do not exist. The selected Store test must fail to compile on those
/// missing production APIs before the repository implementation lands.
final class ArchitectureUXTDataCourt03Tests: XCTestCase {
    private let unresolvedMatter731 = "matter-731"
    private let unresolvedMatter733 = "matter-733"
    private let explicitAliasMatter739 = "matter-739"

    private let legacyCourt731 = "S.D. Fla. 731 Tribunal"
    private let legacyCourt733 = "Synthetic Maritime Tribunal 733"
    private let explicitAliasCourt739 = "S.D. Fla."

    private let eleventhCircuitJurisdictionID =
        "federal-united-states-court-of-appeals-for-the-eleventh-circuit"
    private let districtCourtID =
        "federal-florida-united-states-district-court-for-the-southern-district-of-florida"
    private let bankruptcyCourtID =
        "federal-florida-united-states-bankruptcy-court-for-the-southern-district-of-florida"
    private let catalogVersion = "jurisdiction-courts-v1"
    private let catalogSemanticDigest =
        "0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3"

    private let decisionID = "decision-743"
    private let decisionActor = "synthetic-attorney-751"
    private let decisionDate = Date(timeIntervalSince1970: 1_946_160_743)

    func testUnresolvedQueueResolutionReceiptRetryConflictAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("T-DATA-COURT-03-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("SupraAI.sqlite")

        // Start at the actual pre-v074 endpoint. The queue is for migrated legacy
        // identity, not a catch-all for malformed records inserted after v074.
        let preV074 = try DatabaseQueue(path: databaseURL.path)
        let migrator = SupraMigrator.makeMigrator()
        try migrator.migrate(preV074, upTo: "v073_create_case_file_review_projects")
        try seedLegacyMatters(in: preV074)

        do {
            let store = try SupraStore(url: databaseURL)

            let initialQueue: [CourtIdentityResolutionQueueItem] = try store.matters
                .fetchUnresolvedCourtResolutionQueue()
            XCTAssertEqual(initialQueue.map(\.matterID), [unresolvedMatter731, unresolvedMatter733])
            XCTAssertEqual(initialQueue.map(\.legacyCourtText), [legacyCourt731, legacyCourt733])
            XCTAssertEqual(initialQueue.map(\.identityRevision), [1, 1])
            XCTAssertEqual(Set(initialQueue.map(\.matterID)).count, initialQueue.count)
            XCTAssertEqual(
                Set(initialQueue.map(\.conversionReceiptID)).count,
                initialQueue.count,
                "each queue row must bind one distinct immutable conversion receipt"
            )
            XCTAssertFalse(initialQueue.map(\.matterID).contains(explicitAliasMatter739))
            XCTAssertFalse(initialQueue.map(\.legacyCourtText).contains("Unspecified"))

            let matterBeforeDecision = try XCTUnwrap(
                store.matters.fetchMatter(id: unresolvedMatter731)
            )
            let receipt: CourtIdentityResolutionReceipt = try store.matters.resolveCourtIdentity(
                matterID: unresolvedMatter731,
                decisionID: decisionID,
                sourceConversionReceiptID: initialQueue[0].conversionReceiptID,
                expectedIdentityRevision: initialQueue[0].identityRevision,
                canonicalJurisdictionID: eleventhCircuitJurisdictionID,
                canonicalCourtID: districtCourtID,
                resolutionSource: "manual_choice",
                actor: decisionActor,
                purpose: "legacy_court_resolution",
                catalogVersion: catalogVersion,
                catalogSemanticDigest: catalogSemanticDigest,
                decidedAt: decisionDate
            )
            assertExactManualReceipt(receipt)
            XCTAssertNotEqual(receipt.canonicalCourtID, bankruptcyCourtID)
            XCTAssertNotEqual(receipt.actor, "system")
            XCTAssertNotEqual(receipt.requestDigestSHA256, String(repeating: "0", count: 64))
            XCTAssertEqual(receipt.requestDigestSHA256.count, 64)

            let storedAfterFirstDecision: [CourtIdentityResolutionReceipt] = try store.matters
                .fetchCourtIdentityResolutionReceipts(matterID: unresolvedMatter731)
            XCTAssertEqual(storedAfterFirstDecision, [receipt])
            let queueAfterFirstDecision: [CourtIdentityResolutionQueueItem] = try store.matters
                .fetchUnresolvedCourtResolutionQueue()
            XCTAssertEqual(queueAfterFirstDecision.map(\.matterID), [unresolvedMatter733])
            let matterAfterFirstDecision = try XCTUnwrap(
                store.matters.fetchMatter(id: unresolvedMatter731)
            )
            XCTAssertGreaterThan(matterAfterFirstDecision.updatedAt, matterBeforeDecision.updatedAt)

            let retried: CourtIdentityResolutionReceipt = try store.matters.resolveCourtIdentity(
                matterID: unresolvedMatter731,
                decisionID: decisionID,
                sourceConversionReceiptID: initialQueue[0].conversionReceiptID,
                expectedIdentityRevision: initialQueue[0].identityRevision,
                canonicalJurisdictionID: eleventhCircuitJurisdictionID,
                canonicalCourtID: districtCourtID,
                resolutionSource: "manual_choice",
                actor: decisionActor,
                purpose: "legacy_court_resolution",
                catalogVersion: catalogVersion,
                catalogSemanticDigest: catalogSemanticDigest,
                decidedAt: decisionDate
            )
            XCTAssertEqual(retried, receipt)
            XCTAssertEqual(
                try store.matters.fetchCourtIdentityResolutionReceipts(
                    matterID: unresolvedMatter731
                ),
                [receipt],
                "an exact retry must not append a second receipt"
            )
            XCTAssertEqual(
                try XCTUnwrap(store.matters.fetchMatter(id: unresolvedMatter731)).updatedAt,
                matterAfterFirstDecision.updatedAt,
                "an exact retry must not mutate the matter"
            )

            XCTAssertThrowsError(
                try store.matters.resolveCourtIdentity(
                    matterID: unresolvedMatter731,
                    decisionID: decisionID,
                    sourceConversionReceiptID: initialQueue[0].conversionReceiptID,
                    expectedIdentityRevision: initialQueue[0].identityRevision,
                    canonicalJurisdictionID: eleventhCircuitJurisdictionID,
                    canonicalCourtID: bankruptcyCourtID,
                    resolutionSource: "manual_choice",
                    actor: decisionActor,
                    purpose: "legacy_court_resolution",
                    catalogVersion: catalogVersion,
                    catalogSemanticDigest: catalogSemanticDigest,
                    decidedAt: decisionDate
                )
            ) { error in
                XCTAssertEqual(error as? CourtIdentityResolutionError, .conflictingDecision)
            }
            XCTAssertEqual(
                try store.matters.fetchCourtIdentityResolutionReceipts(
                    matterID: unresolvedMatter731
                ),
                [receipt],
                "a conflicting retry must not append or replace the original receipt"
            )
            XCTAssertEqual(
                try store.matters.fetchUnresolvedCourtResolutionQueue().map(\.matterID),
                [unresolvedMatter733]
            )
        }

        let reopened = try SupraStore(url: databaseURL)
        let reopenedQueue: [CourtIdentityResolutionQueueItem] = try reopened.matters
            .fetchUnresolvedCourtResolutionQueue()
        XCTAssertEqual(reopenedQueue.map(\.matterID), [unresolvedMatter733])
        let reopenedReceipts: [CourtIdentityResolutionReceipt] = try reopened.matters
            .fetchCourtIdentityResolutionReceipts(matterID: unresolvedMatter731)
        XCTAssertEqual(reopenedReceipts.count, 1)
        assertExactManualReceipt(try XCTUnwrap(reopenedReceipts.first))
    }

    private func seedLegacyMatters(in queue: DatabaseQueue) throws {
        let matters = [
            (
                unresolvedMatter731,
                "Synthetic unresolved court matter 731",
                "Federal synthetic 731",
                legacyCourt731,
                "2026-08-13T20:31:17.731Z"
            ),
            (
                unresolvedMatter733,
                "Synthetic unresolved court matter 733",
                "Federal synthetic 733",
                legacyCourt733,
                "2026-08-13T20:31:17.733Z"
            ),
            (
                explicitAliasMatter739,
                "Synthetic explicit alias matter 739",
                "Florida",
                explicitAliasCourt739,
                "2026-08-13T20:31:17.739Z"
            ),
        ]

        try queue.write { database in
            for matter in matters {
                try database.execute(
                    sql: """
                        INSERT INTO matters (
                            id, name, jurisdiction, party_perspective, court,
                            created_at, updated_at
                        ) VALUES (?, ?, ?, 'neutral', ?, ?, ?)
                        """,
                    arguments: [matter.0, matter.1, matter.2, matter.3, matter.4, matter.4]
                )
            }
        }
    }

    private func assertExactManualReceipt(
        _ receipt: CourtIdentityResolutionReceipt,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(receipt.decisionID, decisionID, file: file, line: line)
        XCTAssertEqual(receipt.matterID, unresolvedMatter731, file: file, line: line)
        XCTAssertEqual(receipt.legacyCourtText, legacyCourt731, file: file, line: line)
        XCTAssertEqual(receipt.priorIdentityRevision, 1, file: file, line: line)
        XCTAssertEqual(receipt.resultIdentityRevision, 2, file: file, line: line)
        XCTAssertEqual(
            receipt.canonicalJurisdictionID,
            eleventhCircuitJurisdictionID,
            file: file,
            line: line
        )
        XCTAssertEqual(receipt.canonicalCourtID, districtCourtID, file: file, line: line)
        XCTAssertEqual(receipt.resolutionSource, "manual_choice", file: file, line: line)
        XCTAssertEqual(receipt.actor, decisionActor, file: file, line: line)
        XCTAssertEqual(receipt.purpose, "legacy_court_resolution", file: file, line: line)
        XCTAssertEqual(receipt.catalogVersion, catalogVersion, file: file, line: line)
        XCTAssertEqual(
            receipt.catalogSemanticDigest,
            catalogSemanticDigest,
            file: file,
            line: line
        )
        XCTAssertEqual(receipt.decidedAt, decisionDate, file: file, line: line)
    }
}
