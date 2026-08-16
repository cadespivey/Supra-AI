import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// Adversarial lifecycle gates for v074 canonical matter identity. Conversion
/// evidence is revision-scoped: migration, repository creation, and an identity
/// update each state exactly what legacy input produced the current identity.
///
/// Expected RED: v074 currently permits only one conversion receipt per matter,
/// `createMatter` writes no source receipt, and `updateMatter` leaves a resolved
/// canonical court attached after its legacy jurisdiction/court inputs change.
final class ArchitectureUXTDataMatterLifecycleTests: XCTestCase {
    private let v073 = "v073_create_case_file_review_projects"
    private let v074 = "v074_create_canonical_matter_identity"
    private let catalogVersion = "jurisdiction-courts-v1"
    private let catalogDigest =
        "0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3"
    private let eleventhCircuitJurisdictionID =
        "federal-united-states-court-of-appeals-for-the-eleventh-circuit"
    private let southernDistrictCourtID =
        "federal-florida-united-states-district-court-for-the-southern-district-of-florida"

    /// Expected RED: `source_kind` is absent, `source_migration` is non-null,
    /// and the table's unique key is matter-only instead of matter + revision.
    func testConversionSourceReceiptSchemaSupportsMigrationCreateAndUpdateEvidence() throws {
        let queue = try migratedQueue()

        try queue.read { db in
            let columns = try db.columns(in: "matter_identity_conversion_receipts")
            let columnsByName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })

            if let sourceKind = columnsByName["source_kind"] {
                XCTAssertTrue(sourceKind.isNotNull)
                XCTAssertNil(sourceKind.defaultValueSQL)
            } else {
                XCTFail("Expected RED: conversion source receipts have no typed source_kind")
            }
            let sourceMigration = try XCTUnwrap(columnsByName["source_migration"])
            XCTAssertFalse(
                sourceMigration.isNotNull,
                "create/update evidence must use NULL rather than impersonating a migration"
            )

            let uniqueColumnLists = try uniqueIndexColumnLists(
                db,
                table: "matter_identity_conversion_receipts"
            )
            XCTAssertTrue(
                uniqueColumnLists.contains(["matter_id", "identity_revision"]),
                "one source receipt must be unique at each matter identity revision"
            )
            XCTAssertFalse(
                uniqueColumnLists.contains(["matter_id"]),
                "a matter must be able to append evidence for a later identity revision"
            )
        }
    }

    /// Expected RED: `createMatter` currently relies on v074 column defaults and
    /// neither appends source evidence nor makes its unknown court resolvable.
    func testCreateWithUnknownCourtAppendsRevisionOneEvidenceAndQueueItem() throws {
        let queue = try migratedQueue()
        let matters = MattersRepository(writer: queue)
        let legacyCourt = "Fictional Commerce Tribunal 741"
        let legacyJurisdiction = "Federal synthetic jurisdiction 743"
        let clientNames = "Northstar Components 747"

        let matter = try matters.createMatter(
            name: "Northstar Components v. Quayside Freight 739",
            jurisdiction: legacyJurisdiction,
            partyPerspective: .defendant,
            court: legacyCourt,
            clientNames: clientNames,
            notes: "Wire note 749"
        )

        try queue.read { db in
            let identity = try XCTUnwrap(identityRow(db, matterID: matter.id))
            XCTAssertEqual(identity["jurisdiction"] as String, legacyJurisdiction)
            XCTAssertEqual(identity["court"] as String, legacyCourt)
            XCTAssertNil(identity["canonical_jurisdiction_id"] as String?)
            XCTAssertNil(identity["canonical_court_id"] as String?)
            XCTAssertEqual(identity["court_resolution_state"] as String, "unresolved")
            XCTAssertEqual(identity["identity_revision"] as Int, 1)
            XCTAssertFalse((identity["court"] as String).contains("DEFAULT-000"))

            let receipts = try sourceReceipts(db, matterID: matter.id)
            XCTAssertEqual(
                receipts.count,
                1,
                "creation must not leave canonical identity without its source evidence"
            )
            if let receipt = receipts.first {
                assertSourceReceipt(
                    receipt,
                    matterID: matter.id,
                    sourceKind: "create",
                    sourceMigration: nil,
                    revision: 1,
                    state: "unresolved",
                    reason: "unknown",
                    legacyJurisdiction: legacyJurisdiction,
                    legacyCourt: legacyCourt,
                    legacyPerspective: "defendant",
                    legacyClientNames: clientNames
                )
            }
        }

        let queueItems = try matters.fetchUnresolvedCourtResolutionQueue()
        XCTAssertEqual(queueItems.count, 1)
        if let item = queueItems.first {
            XCTAssertEqual(item.matterID, matter.id)
            XCTAssertEqual(item.legacyCourtText, legacyCourt)
            XCTAssertEqual(item.identityRevision, 1)
            XCTAssertFalse(item.conversionReceiptID.isEmpty)
            XCTAssertFalse(try XCTUnwrap(item.legacyCourtText).contains("DEFAULT-000"))
        }
    }

    /// Expected RED: a newly created matter with no court is correctly unresolved,
    /// but the queue silently drops it because there is no court text. Missing is
    /// not the same as the explicit attorney choice `not_applicable`.
    func testCreateWithoutCourtRemainsVisibleAsUnresolvedAndHasSourceEvidence() throws {
        let queue = try migratedQueue()
        let matters = MattersRepository(writer: queue)
        let legacyJurisdiction = "Transactional synthetic scope 751"

        let matter = try matters.createMatter(
            name: "Northstar Asset Purchase 753",
            jurisdiction: legacyJurisdiction,
            partyPerspective: .neutral,
            court: nil,
            clientNames: "Northstar Components 755"
        )

        try queue.read { db in
            let identity = try XCTUnwrap(identityRow(db, matterID: matter.id))
            XCTAssertNil(identity["court"] as String?)
            XCTAssertNil(identity["canonical_jurisdiction_id"] as String?)
            XCTAssertNil(identity["canonical_court_id"] as String?)
            XCTAssertEqual(identity["court_resolution_state"] as String, "unresolved")
            XCTAssertEqual(identity["identity_revision"] as Int, 1)

            let receipts = try sourceReceipts(db, matterID: matter.id)
            XCTAssertEqual(receipts.count, 1)
            if let receipt = receipts.first {
                assertSourceReceipt(
                    receipt,
                    matterID: matter.id,
                    sourceKind: "create",
                    sourceMigration: nil,
                    revision: 1,
                    state: "unresolved",
                    reason: "unknown",
                    legacyJurisdiction: legacyJurisdiction,
                    legacyCourt: nil,
                    legacyPerspective: "neutral",
                    legacyClientNames: "Northstar Components 755"
                )
            }
        }

        let queueItems = try matters.fetchUnresolvedCourtResolutionQueue()
        XCTAssertEqual(queueItems.map(\.matterID), [matter.id])
        XCTAssertEqual(queueItems.first?.legacyCourtText, nil)
        XCTAssertEqual(queueItems.first?.identityRevision, 1)
    }

    /// Expected RED: `updateMatter` changes the legacy court/jurisdiction only;
    /// it leaves the old canonical court and revision attached and appends no
    /// replacement source evidence. The first edit below also pins the inverse:
    /// name/notes-only edits must not churn canonical identity.
    func testIdentityUpdateInvalidatesResolvedCourtButNonidentityEditDoesNotChurnRevision() throws {
        let queue = try DatabaseQueue()
        let migrator = SupraMigrator.makeMigrator()
        try migrator.migrate(queue, upTo: v073)
        let matterID = "matter-lifecycle-757"
        let clientNames = "Meridian Fabrication 759"
        let createdAt = "2031-09-05T20:18:27.757Z"
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO matters (
                        id, name, jurisdiction, party_perspective, court,
                        client_names, notes, created_at, updated_at
                    ) VALUES (?, ?, 'Florida', 'plaintiff', 'S.D. Fla.', ?, ?, ?, ?)
                    """,
                arguments: [
                    matterID, "Meridian Fabrication v. Harbor Logistics 757",
                    clientNames, "Original note 761", createdAt, createdAt,
                ]
            )
        }
        try migrator.migrate(queue)
        let matters = MattersRepository(writer: queue)

        try matters.updateMatter(
            id: matterID,
            name: "Meridian Fabrication v. Harbor Logistics — renamed 763",
            jurisdiction: "Florida",
            partyPerspective: .plaintiff,
            court: "S.D. Fla.",
            clientNames: clientNames,
            notes: "Nonidentity note 767"
        )

        try queue.read { db in
            let afterNonidentityEdit = try XCTUnwrap(identityRow(db, matterID: matterID))
            XCTAssertEqual(afterNonidentityEdit["identity_revision"] as Int, 1)
            XCTAssertEqual(afterNonidentityEdit["court_resolution_state"] as String, "court")
            XCTAssertEqual(
                afterNonidentityEdit["canonical_jurisdiction_id"] as String,
                eleventhCircuitJurisdictionID
            )
            XCTAssertEqual(
                afterNonidentityEdit["canonical_court_id"] as String,
                southernDistrictCourtID
            )
            XCTAssertEqual(try sourceReceipts(db, matterID: matterID).count, 1)
        }

        let replacementJurisdiction = "Federal synthetic jurisdiction 769"
        let replacementCourt = "Fictional Maritime Claims Tribunal 773"
        try matters.updateMatter(
            id: matterID,
            name: "Meridian Fabrication v. Harbor Logistics — renamed 763",
            jurisdiction: replacementJurisdiction,
            partyPerspective: .plaintiff,
            court: replacementCourt,
            clientNames: clientNames,
            notes: "Identity edit note 777"
        )

        var replacementReceiptID: String?
        try queue.read { db in
            let invalidated = try XCTUnwrap(identityRow(db, matterID: matterID))
            XCTAssertEqual(invalidated["jurisdiction"] as String, replacementJurisdiction)
            XCTAssertEqual(invalidated["court"] as String, replacementCourt)
            XCTAssertNil(invalidated["canonical_jurisdiction_id"] as String?)
            XCTAssertNil(invalidated["canonical_court_id"] as String?)
            XCTAssertEqual(invalidated["court_resolution_state"] as String, "unresolved")
            XCTAssertEqual(invalidated["identity_revision"] as Int, 2)
            XCTAssertFalse((invalidated["court"] as String).contains("DEFAULT-000"))

            let receipts = try sourceReceipts(db, matterID: matterID)
            XCTAssertEqual(receipts.count, 2)
            if receipts.count == 2 {
                assertSourceReceipt(
                    receipts[0],
                    matterID: matterID,
                    sourceKind: "migration",
                    sourceMigration: v074,
                    revision: 1,
                    state: "court",
                    reason: "explicit_alias",
                    legacyJurisdiction: "Florida",
                    legacyCourt: "S.D. Fla.",
                    legacyPerspective: "plaintiff",
                    legacyClientNames: clientNames
                )
                assertSourceReceipt(
                    receipts[1],
                    matterID: matterID,
                    sourceKind: "update",
                    sourceMigration: nil,
                    revision: 2,
                    state: "unresolved",
                    reason: "unknown",
                    legacyJurisdiction: replacementJurisdiction,
                    legacyCourt: replacementCourt,
                    legacyPerspective: "plaintiff",
                    legacyClientNames: clientNames
                )
                replacementReceiptID = receipts[1]["id"]
            }
        }

        let queueItems = try matters.fetchUnresolvedCourtResolutionQueue()
        XCTAssertEqual(queueItems.count, 1)
        if let item = queueItems.first {
            XCTAssertEqual(item.matterID, matterID)
            XCTAssertEqual(item.legacyCourtText, replacementCourt)
            XCTAssertEqual(item.identityRevision, 2)
            XCTAssertEqual(item.conversionReceiptID, replacementReceiptID)
            XCTAssertFalse(try XCTUnwrap(item.legacyCourtText).contains("DEFAULT-000"))
        }
    }

    /// Expected RED: v074's update trigger currently checks only that the new
    /// columns form a valid shape. A direct writer can change legal identity and
    /// revision without the source/decision receipt that is supposed to explain
    /// the transition.
    func testDirectCanonicalIdentityTransitionRequiresMatchingReceipt() throws {
        let queue = try DatabaseQueue()
        let migrator = SupraMigrator.makeMigrator()
        try migrator.migrate(queue, upTo: v073)
        let matterID = "matter-transition-guard-779"
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO matters (
                        id, name, jurisdiction, party_perspective, court,
                        created_at, updated_at
                    ) VALUES (?, 'Transition guard wire 779', 'Florida',
                              'plaintiff', 'S.D. Fla.', ?, ?)
                    """,
                arguments: [
                    matterID, "2031-09-05T20:18:27.779Z",
                    "2031-09-05T20:18:27.779Z",
                ]
            )
        }
        try migrator.migrate(queue)

        try queue.write { db in
            XCTAssertThrowsError(
                try db.execute(
                    sql: """
                        UPDATE matters
                        SET canonical_jurisdiction_id = NULL,
                            canonical_court_id = NULL,
                            court_resolution_state = 'unresolved',
                            identity_revision = 2
                        WHERE id = ?
                        """,
                    arguments: [matterID]
                )
            )
            let row = try XCTUnwrap(identityRow(db, matterID: matterID))
            XCTAssertEqual(row["identity_revision"] as Int, 1)
            XCTAssertEqual(row["court_resolution_state"] as String, "court")
            XCTAssertEqual(
                row["canonical_court_id"] as String?,
                southernDistrictCourtID
            )
            XCTAssertEqual(try sourceReceipts(db, matterID: matterID).count, 1)
        }
    }

    /// Standing guard (green before v074): this deliberately opens a database
    /// whose schema stops at v073. Adding nonoptional v074 coding keys directly
    /// to `MatterRecord` would make this existing-database decode fail.
    func testMatterRecordStillDecodesWhenDatabaseStopsAtV073() throws {
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue, upTo: v073)
        let matterID = "matter-v073-decode-787"
        let court = "Fictional Circuit Court 787"
        let notes = "Legacy decode wire 789"
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO matters (
                        id, name, jurisdiction, party_perspective, court, notes,
                        created_at, updated_at
                    ) VALUES (?, 'Legacy matter 787', 'Synthetic state 791',
                              'appellant', ?, ?, ?, ?)
                    """,
                arguments: [
                    matterID, court, notes,
                    "2031-09-05T20:18:27.787Z", "2031-09-05T20:18:27.789Z",
                ]
            )
            XCTAssertFalse(try db.columns(in: "matters").map(\.name).contains("identity_revision"))
        }

        let decoded = try XCTUnwrap(MattersRepository(writer: queue).fetchMatter(id: matterID))
        XCTAssertEqual(decoded.id, matterID)
        XCTAssertEqual(decoded.jurisdiction, "Synthetic state 791")
        XCTAssertEqual(decoded.partyPerspective, "appellant")
        XCTAssertEqual(decoded.court, court)
        XCTAssertEqual(decoded.notes, notes)
        XCTAssertFalse(try XCTUnwrap(decoded.court).contains("DEFAULT-000"))
        XCTAssertFalse(try XCTUnwrap(decoded.notes).contains("DEFAULT-000"))
    }

    private func migratedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try SupraMigrator.makeMigrator().migrate(queue)
        return queue
    }

    private func identityRow(_ db: Database, matterID: String) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT jurisdiction, court, canonical_jurisdiction_id,
                       canonical_court_id, court_resolution_state,
                       canonical_catalog_version,
                       canonical_catalog_digest_sha256, identity_revision
                FROM matters WHERE id = ?
                """,
            arguments: [matterID]
        )
    }

    private func sourceReceipts(_ db: Database, matterID: String) throws -> [Row] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM matter_identity_conversion_receipts
                WHERE matter_id = ?
                ORDER BY identity_revision, id
                """,
            arguments: [matterID]
        )
    }

    private func assertSourceReceipt(
        _ row: Row,
        matterID: String,
        sourceKind: String,
        sourceMigration: String?,
        revision: Int,
        state: String,
        reason: String,
        legacyJurisdiction: String,
        legacyCourt: String?,
        legacyPerspective: String,
        legacyClientNames: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(row["matter_id"] as String, matterID, file: file, line: line)
        if row.hasColumn("source_kind") {
            XCTAssertEqual(row["source_kind"] as String, sourceKind, file: file, line: line)
        } else {
            XCTFail("Expected RED: receipt has no typed source_kind", file: file, line: line)
        }
        XCTAssertEqual(row["source_migration"] as String?, sourceMigration, file: file, line: line)
        XCTAssertEqual(row["identity_revision"] as Int, revision, file: file, line: line)
        XCTAssertEqual(row["court_resolution_state"] as String, state, file: file, line: line)
        XCTAssertEqual(row["resolution_reason"] as String, reason, file: file, line: line)
        XCTAssertEqual(
            row["legacy_jurisdiction"] as String,
            legacyJurisdiction,
            file: file,
            line: line
        )
        XCTAssertEqual(row["legacy_court"] as String?, legacyCourt, file: file, line: line)
        XCTAssertEqual(
            row["legacy_party_perspective"] as String,
            legacyPerspective,
            file: file,
            line: line
        )
        XCTAssertEqual(
            row["legacy_client_names"] as String?,
            legacyClientNames,
            file: file,
            line: line
        )
        XCTAssertEqual(
            row["canonical_catalog_version"] as String,
            catalogVersion,
            file: file,
            line: line
        )
        XCTAssertEqual(
            row["canonical_catalog_digest_sha256"] as String,
            catalogDigest,
            file: file,
            line: line
        )
        if let storedLegacyCourt = row["legacy_court"] as String? {
            XCTAssertFalse(storedLegacyCourt.contains("DEFAULT-000"), file: file, line: line)
        }
    }

    private func uniqueIndexColumnLists(_ db: Database, table: String) throws -> [[String]] {
        let indexes = try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))")
        var result: [[String]] = []
        for index in indexes where index["unique"] as Int == 1 {
            let name: String = index["name"]
            result.append(
                try String.fetchAll(
                    db,
                    sql: "SELECT name FROM pragma_index_info(?) ORDER BY seqno",
                    arguments: [name]
                )
            )
        }
        return result
    }
}
