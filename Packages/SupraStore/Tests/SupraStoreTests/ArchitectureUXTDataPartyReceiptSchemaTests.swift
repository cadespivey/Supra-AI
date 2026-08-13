import GRDB
@testable import SupraStore
import XCTest

/// Store substrate for T-DATA-PARTY-02 — a confirmed party-side override is an
/// append-only, purpose-bound decision at one exact matter identity revision.
/// It cannot impersonate a court-resolution decision or point across matters.
///
/// Expected RED: v074 currently creates a court-only decision receipt table;
/// it has no typed `kind` or canonical/requested party identity columns and
/// requires court/catalog fields for every row.
final class ArchitectureUXTDataPartyReceiptSchemaTests: XCTestCase {
    private let matterID = "matter-831"
    private let canonicalPartyID = "party-813"
    private let requestedPartyID = "party-817"
    private let receiptID = "receipt-827"
    private let purpose = "notice_of_appearance:wire-831"
    private let requestDigest = String(repeating: "8", count: 64)
    private let timestamp = "2031-09-05T20:18:27.827Z"

    func testPartyOverrideReceiptIsTypedSameMatterRevisionBoundAndImmutable() throws {
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)

        try queue.write { db in
            try seedCanonicalMatterAndParties(db)
            try db.execute(
                sql: """
                    INSERT INTO matter_identity_decision_receipts (
                        id, matter_id, kind, source_conversion_receipt_id,
                        prior_identity_revision, result_identity_revision,
                        legacy_court, canonical_jurisdiction_id,
                        canonical_court_id, canonical_represented_party_id,
                        requested_represented_party_id, resolution_source,
                        actor, purpose, canonical_catalog_version,
                        canonical_catalog_digest_sha256, request_digest_sha256,
                        decided_at, created_at
                    ) VALUES (
                        ?, ?, 'party_override', NULL, 7, 7,
                        NULL, NULL, NULL, ?, ?, 'attorney_confirmation',
                        'synthetic-attorney-829', ?, NULL, NULL, ?, ?, ?
                    )
                    """,
                arguments: [
                    receiptID, matterID, canonicalPartyID, requestedPartyID,
                    purpose, requestDigest, timestamp, timestamp,
                ]
            )

            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT * FROM matter_identity_decision_receipts WHERE id = ?",
                arguments: [receiptID]
            ))
            XCTAssertEqual(row["matter_id"] as String, matterID)
            XCTAssertEqual(row["kind"] as String, "party_override")
            XCTAssertEqual(row["prior_identity_revision"] as Int, 7)
            XCTAssertEqual(row["result_identity_revision"] as Int, 7)
            XCTAssertEqual(row["canonical_represented_party_id"] as String, canonicalPartyID)
            XCTAssertEqual(row["requested_represented_party_id"] as String, requestedPartyID)
            XCTAssertEqual(row["purpose"] as String, purpose)
            XCTAssertEqual(row["request_digest_sha256"] as String, requestDigest)
            XCTAssertNil(row["source_conversion_receipt_id"] as String?)
            XCTAssertNil(row["canonical_court_id"] as String?)
            XCTAssertFalse((row["request_digest_sha256"] as String).contains("DEFAULT-000"))

            XCTAssertThrowsError(
                try db.execute(
                    sql: "UPDATE matter_identity_decision_receipts SET actor = 'changed' WHERE id = ?",
                    arguments: [receiptID]
                )
            )

            XCTAssertThrowsError(
                try insertPartyOverride(
                    db,
                    id: "receipt-DEFAULT-000",
                    canonicalPartyID: canonicalPartyID,
                    requestedPartyID: canonicalPartyID,
                    digest: String(repeating: "a", count: 64)
                )
            )
            XCTAssertThrowsError(
                try insertPartyOverride(
                    db,
                    id: "receipt-829",
                    canonicalPartyID: canonicalPartyID,
                    requestedPartyID: "party-other-matter-839",
                    digest: String(repeating: "b", count: 64)
                )
            )

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM matter_identity_decision_receipts"),
                1
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"),
                0
            )
        }
    }

    private func seedCanonicalMatterAndParties(_ db: Database) throws {
        let jurisdictionID =
            "federal-united-states-court-of-appeals-for-the-eleventh-circuit"
        let courtID =
            "federal-florida-united-states-district-court-for-the-southern-district-of-florida"
        try db.execute(
            sql: """
                INSERT INTO matters (
                    id, name, jurisdiction, party_perspective, court,
                    canonical_jurisdiction_id, canonical_court_id,
                    court_resolution_state, identity_revision,
                    created_at, updated_at
                ) VALUES (?, 'Party receipt wire 831', 'Florida', 'defendant',
                          'S.D. Fla.', ?, ?, 'court', 7, ?, ?)
                """,
            arguments: [matterID, jurisdictionID, courtID, timestamp, timestamp]
        )
        for party in [
            (canonicalPartyID, "Harbor Logistics", "HARBOR LOGISTICS, INC.,", "defendant", 1, "represented"),
            (requestedPartyID, "Meridian Fabrication", "MERIDIAN FABRICATION, LLC,", "plaintiff", 0, "not_represented"),
        ] {
            try db.execute(
                sql: """
                    INSERT INTO matter_parties (
                        id, matter_id, display_name, caption_name, base_role,
                        caption_order, client_status, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    party.0, matterID, party.1, party.2, party.3, party.4,
                    party.5, timestamp, timestamp,
                ]
            )
        }
    }

    private func insertPartyOverride(
        _ db: Database,
        id: String,
        canonicalPartyID: String,
        requestedPartyID: String,
        digest: String
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO matter_identity_decision_receipts (
                    id, matter_id, kind, source_conversion_receipt_id,
                    prior_identity_revision, result_identity_revision,
                    legacy_court, canonical_jurisdiction_id,
                    canonical_court_id, canonical_represented_party_id,
                    requested_represented_party_id, resolution_source,
                    actor, purpose, canonical_catalog_version,
                    canonical_catalog_digest_sha256, request_digest_sha256,
                    decided_at, created_at
                ) VALUES (
                    ?, ?, 'party_override', NULL, 7, 7,
                    NULL, NULL, NULL, ?, ?, 'attorney_confirmation',
                    'synthetic-attorney-829', ?, NULL, NULL, ?, ?, ?
                )
                """,
            arguments: [
                id, matterID, canonicalPartyID, requestedPartyID, purpose,
                digest, timestamp, timestamp,
            ]
        )
    }
}
