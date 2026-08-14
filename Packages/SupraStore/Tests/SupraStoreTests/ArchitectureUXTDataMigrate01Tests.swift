import CryptoKit
import Foundation
import GRDB
@testable import SupraStore
import XCTest

/// T-DATA-MIGRATE-01 — v074 converts legacy matter identity without rewriting
/// immutable migration history, guessing an ambiguous court, splitting a client
/// name on punctuation, or disturbing matter-owned work products.
///
/// Expected RED: the migration registry still ends at
/// `v073_create_case_file_review_projects`, so the immutable-source test cannot
/// find the v074 anchor and the migration test observes no v074 schema or data.
/// No Research type or post-migration alias endpoint belongs in SupraStore: the
/// immutable v074 closure itself freezes the one approved compatibility mapping.
final class ArchitectureUXTDataMigrate01Tests: XCTestCase {
    func testV074AppendsCanonicalMatterIdentityWithoutRewritingV072OrV073() throws {
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/SupraStore/Database/SupraMigrator.swift")
        let sourceData = try Data(contentsOf: sourceURL)
        let source = try XCTUnwrap(String(data: sourceData, encoding: .utf8))

        let v072Anchor =
            #"        migrator.registerMigration("v072_harden_corpus_review_integrity") { db in"#
        let v073Anchor =
            #"        migrator.registerMigration("v073_create_case_file_review_projects") { db in"#
        let v074Anchor =
            #"        migrator.registerMigration("v074_create_canonical_matter_identity") { db in"#
        let v075Anchor =
            #"        migrator.registerMigration("v075_create_grounded_chat_publications") { db in"#

        let v072Start = try XCTUnwrap(source.range(of: v072Anchor)?.lowerBound)
        let v073Start = try XCTUnwrap(source.range(of: v073Anchor)?.lowerBound)
        let v074Start = try XCTUnwrap(source.range(of: v074Anchor)?.lowerBound)
        let v075Start = try XCTUnwrap(source.range(of: v075Anchor)?.lowerBound)
        XCTAssertLessThan(v072Start, v073Start)
        XCTAssertLessThan(v073Start, v074Start)
        XCTAssertLessThan(v074Start, v075Start)

        let v072WithSeparator = source[v072Start..<v073Start]
        let v073WithSeparator = source[v073Start..<v074Start]
        XCTAssertTrue(v072WithSeparator.hasSuffix("\n\n"))
        XCTAssertTrue(v073WithSeparator.hasSuffix("\n\n"))

        // Include the newline terminating each registration, but not the blank
        // separator line. This is the pre-v074 immutable byte-slice definition.
        let v072 = Data(v072WithSeparator.dropLast().utf8)
        let v073 = Data(v073WithSeparator.dropLast().utf8)
        XCTAssertEqual(v072.count, 110_753)
        XCTAssertEqual(v072.filter { $0 == 0x0a }.count, 1_924)
        XCTAssertEqual(
            sha256(v072),
            "239d5a4a1c6ad610366446c14709682b87ede15b47e4aa7535d0d901851553e6"
        )
        XCTAssertEqual(v073.count, 18_728)
        XCTAssertEqual(v073.filter { $0 == 0x0a }.count, 365)
        XCTAssertEqual(
            sha256(v073),
            "819515bfe405e1459adbbce65288754f241b94239543fe077793c624f4c4d14f"
        )

        let migrations = SupraMigrator.makeMigrator().migrations
        XCTAssertEqual(migrations.count, 77)
        XCTAssertEqual(Array(migrations.suffix(6)), [
            "v072_harden_corpus_review_integrity",
            "v073_create_case_file_review_projects",
            "v074_create_canonical_matter_identity",
            "v075_create_grounded_chat_publications",
            "v076_link_export_publication_intents",
            "v077_create_accepted_research_packets",
        ])
    }

    func testSyntheticV073GraphConvertsExactlyOnceAndSurvivesReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("T-DATA-MIGRATE-01-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("SupraAI.sqlite")
        let migrator = SupraMigrator.makeMigrator()

        let before: LegacyCanarySnapshot
        do {
            let queue = try DatabaseQueue(path: databaseURL.path)
            try migrator.migrate(queue, upTo: Wire.v073)
            try seedSelectedV073Graph(queue)
            before = try legacyCanarySnapshot(queue)
            try assertNondefaultSeedWires(queue)

            XCTAssertNoThrow(try migrator.migrate(queue))
            guard try migrationIdentifiers(queue).contains(Wire.v074) else {
                XCTFail("Expected RED: v074 canonical matter identity migration is missing")
                return
            }
            try assertV074Conversion(queue)
            XCTAssertEqual(try legacyCanarySnapshot(queue), before)

            let stateAfterFirstConversion = try v074IdentitySnapshot(queue)
            XCTAssertNoThrow(try migrator.migrate(queue))
            XCTAssertEqual(try v074IdentitySnapshot(queue), stateAfterFirstConversion)
            XCTAssertEqual(try legacyCanarySnapshot(queue), before)
        }

        // File-backed reopen must neither replay the data conversion nor mint a
        // second receipt. The migration itself is the idempotent conversion.
        let reopened = try DatabaseQueue(path: databaseURL.path)
        XCTAssertNoThrow(try migrator.migrate(reopened))
        let stateBeforeRetry = try v074IdentitySnapshot(reopened)
        XCTAssertNoThrow(try migrator.migrate(reopened))
        XCTAssertEqual(try v074IdentitySnapshot(reopened), stateBeforeRetry)
        XCTAssertEqual(try legacyCanarySnapshot(reopened), before)
        try assertV074Conversion(reopened)
    }

    // TODO(WP-1.1 shipping migration evidence): this selected RED uses a rich,
    // raw-SQL synthetic v073 graph so it cannot impersonate authenticated release
    // evidence. Before WP-1.1 acceptance, add authenticated rich synthetic v040
    // and public-v069 fixtures to the permanent manifest, plus the separately
    // verified owner-v072 copy. Run each through snapshot, v073, v074, reopen,
    // row-count/content-digest, managed-file, and restore qualification.

    func testLateV074FailureRollsBackAndTheSameFileThenUpgrades() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("T-DATA-MIGRATE-01-ROLLBACK-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("SupraAI.sqlite")
        let migrator = SupraMigrator.makeMigrator()
        let queue = try DatabaseQueue(path: databaseURL.path)
        try migrator.migrate(queue, upTo: Wire.v073)
        try seedSelectedV073Graph(queue)
        let before = try legacyCanarySnapshot(queue)

        // This name is intentionally reserved for a late statement in the real
        // v074 closure. Creating it at v073 forces the shipping migration itself
        // to fail only after its earlier ALTER/CREATE/backfill statements run.
        try queue.write { db in
            try db.execute(sql: "CREATE INDEX idx_matter_identity_decisions_matter ON matters(id)")
        }

        XCTAssertThrowsError(try migrator.migrate(queue))
        XCTAssertEqual(try migrationIdentifiers(queue).last, Wire.v073)
        XCTAssertEqual(try legacyCanarySnapshot(queue), before)
        try queue.read { db in
            XCTAssertFalse(try db.tableExists("matter_identity_conversion_receipts"))
            XCTAssertFalse(try db.tableExists("matter_identity_decision_receipts"))
            XCTAssertFalse(try db.tableExists("matter_parties"))
            XCTAssertFalse(try db.tableExists("matter_representations"))
            XCTAssertFalse(try db.columns(in: "matters").map(\.name).contains("identity_revision"))
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"),
                0
            )
        }

        let reopenedBlocked = try DatabaseQueue(path: databaseURL.path)
        XCTAssertThrowsError(try migrator.migrate(reopenedBlocked))
        XCTAssertEqual(try migrationIdentifiers(reopenedBlocked).last, Wire.v073)
        XCTAssertEqual(try legacyCanarySnapshot(reopenedBlocked), before)

        try reopenedBlocked.write { db in
            try db.execute(sql: "DROP INDEX idx_matter_identity_decisions_matter")
        }
        XCTAssertNoThrow(try migrator.migrate(reopenedBlocked))
        XCTAssertEqual(try legacyCanarySnapshot(reopenedBlocked), before)
        try assertV074Conversion(reopenedBlocked)
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SupraStoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SupraStore
    }

    private func seedSelectedV073Graph(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            for matter in [
                (
                    Wire.aliasMatterID,
                    "Alias Matter 731",
                    "Florida",
                    "plaintiff",
                    Wire.aliasCourtText,
                    Wire.clientName
                ),
                (
                    Wire.unknownMatterID,
                    "Unknown Court Matter 773",
                    "Federal",
                    "neutral",
                    Wire.unknownCourtText,
                    nil
                ),
                (
                    Wire.ambiguousMatterID,
                    "Ambiguous Court Matter 797",
                    "Florida",
                    "defendant",
                    Wire.ambiguousCourtText,
                    nil
                ),
            ] as [(String, String, String, String, String, String?)] {
                try db.execute(
                    sql: """
                        INSERT INTO matters (
                            id, name, jurisdiction, party_perspective, court,
                            client_names, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        matter.0, matter.1, matter.2, matter.3, matter.4,
                        matter.5, Wire.timestamp, Wire.timestamp,
                    ]
                )
            }

            try db.execute(
                sql: """
                    INSERT INTO document_blobs (
                        id, sha256, byte_size, original_extension,
                        managed_relative_path, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    Wire.blobID, Wire.blobSHA256, 739, "pdf",
                    Wire.blobManagedRelativePath, Wire.timestamp,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO matter_documents (
                        id, matter_id, blob_id, display_name,
                        imported_relative_path, source_display_path,
                        status, extraction_status, index_status,
                        imported_at, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    Wire.documentID, Wire.aliasMatterID, Wire.blobID,
                    "Canary Source 743.pdf", "Evidence/Canary Source 743.pdf",
                    "/synthetic/input/Canary Source 743.pdf", "ready", "complete",
                    "indexed", Wire.timestamp, Wire.timestamp, Wire.timestamp,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO structured_outputs (
                        id, matter_id, title, output_type, active_version_id,
                        status, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, NULL, ?, ?, ?)
                    """,
                arguments: [
                    Wire.outputID, Wire.aliasMatterID, "Canary Output 751",
                    "document_qa", "needs_review", Wire.timestamp, Wire.timestamp,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO structured_output_versions (
                        id, structured_output_id, version_index, content_markdown,
                        required_sections_json, present_sections_json,
                        missing_sections_json, verification_status,
                        prompt_builder_version, assurance_state,
                        created_at, updated_at
                    ) VALUES (?, ?, 7, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    Wire.outputVersionID, Wire.outputID,
                    "# Canary 757\n\nPreserve slash/punctuation: A/B; C, D.",
                    #"["Canary 757"]"#, #"["Canary 757"]"#, "[]",
                    "legacy_unverified", "canary-builder-v7", "needs_review",
                    Wire.timestamp, Wire.timestamp,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO corpus_analysis_runs (
                        id, run_key, matter_id, task_kind, scope_json,
                        corpus_snapshot_json, partition_strategy,
                        partition_strategy_version, status,
                        structured_output_version_id, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    Wire.corpusRunID, "canary-run-key-761", Wire.aliasMatterID,
                    "chronology", #"{"schema_version":7,"wire":"scope-763"}"#,
                    #"{"members":[],"schema_version":7,"wire":"snapshot-769"}"#,
                    "document_revision_v1", 7, "pending", Wire.outputVersionID,
                    Wire.timestamp,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO audit_events (
                        id, matter_id, timestamp, event_type, actor, summary,
                        related_table, related_id, metadata_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    Wire.auditID, Wire.aliasMatterID, Wire.timestamp,
                    "canary_event_773", "migration-test",
                    "Preserve canary audit 773 exactly.", "structured_outputs",
                    Wire.outputID, #"{"schema_version":7,"wire":"audit-773"}"#,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO document_exports (
                        id, structured_output_id, structured_output_version_id,
                        matter_id, format, managed_relative_path, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    Wire.exportID, Wire.outputID, Wire.outputVersionID,
                    Wire.aliasMatterID, "docx", Wire.exportManagedRelativePath,
                    Wire.timestamp,
                ]
            )
        }
    }

    private func assertNondefaultSeedWires(_ queue: DatabaseQueue) throws {
        try queue.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT client_names FROM matters WHERE id = ?",
                    arguments: [Wire.aliasMatterID]
                ),
                Wire.clientName
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT managed_relative_path FROM document_blobs WHERE id = ?",
                    arguments: [Wire.blobID]
                ),
                Wire.blobManagedRelativePath
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT managed_relative_path FROM document_exports WHERE id = ?",
                    arguments: [Wire.exportID]
                ),
                Wire.exportManagedRelativePath
            )
            XCTAssertFalse(Wire.clientName.contains("DEFAULT-000"))
            XCTAssertFalse(Wire.blobManagedRelativePath.contains("DEFAULT-000"))
            XCTAssertFalse(Wire.exportManagedRelativePath.contains("DEFAULT-000"))
        }
    }

    private func assertV074Conversion(_ queue: DatabaseQueue) throws {
        try queue.read { db in
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
                ).last,
                Wire.currentMigration
            )
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"),
                0
            )

            let matterColumns = Set(try db.columns(in: "matters").map(\.name))
            XCTAssertTrue(matterColumns.isSuperset(of: [
                "canonical_jurisdiction_id", "canonical_court_id",
                "court_resolution_state", "canonical_catalog_version",
                "canonical_catalog_digest_sha256", "identity_revision",
            ]))
            let receiptColumns = Set(
                try db.columns(in: "matter_identity_conversion_receipts").map(\.name)
            )
            XCTAssertTrue(receiptColumns.isSuperset(of: [
                "id", "matter_id", "source_migration", "identity_revision",
                "court_resolution_state", "resolution_reason",
                "legacy_jurisdiction", "legacy_court", "legacy_party_perspective",
                "legacy_client_names", "canonical_jurisdiction_id",
                "canonical_court_id", "canonical_catalog_version",
                "canonical_catalog_digest_sha256", "created_at",
            ]))

            let partyColumns = Set(try db.columns(in: "matter_parties").map(\.name))
            XCTAssertEqual(partyColumns, Set([
                "id", "matter_id", "display_name", "caption_name", "base_role",
                "caption_order", "client_status", "created_at", "updated_at",
            ]))
            let representationColumns = Set(
                try db.columns(in: "matter_representations").map(\.name)
            )
            XCTAssertEqual(representationColumns, Set([
                "id", "matter_id", "represented_party_id", "relationship_kind",
                "representative_name", "firm_name", "service_address_json",
                "service_emails_json", "service_order", "created_at", "updated_at",
            ]))

            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM matter_identity_conversion_receipts"
                ),
                3
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM (
                            SELECT matter_id
                            FROM matter_identity_conversion_receipts
                            GROUP BY matter_id
                            HAVING COUNT(*) = 1
                        )
                        """
                ),
                3,
                "every migrated matter must own exactly one conversion receipt"
            )

            try assertReceipt(
                db,
                matterID: Wire.aliasMatterID,
                courtResolutionState: "court",
                resolutionReason: "explicit_alias",
                legacyJurisdiction: "Florida",
                legacyCourt: Wire.aliasCourtText,
                legacyPartyPerspective: "plaintiff",
                legacyClientNames: Wire.clientName,
                canonicalJurisdictionID: Wire.eleventhCircuitJurisdictionID,
                canonicalCourtID: Wire.southernDistrictCourtID
            )
            try assertReceipt(
                db,
                matterID: Wire.unknownMatterID,
                courtResolutionState: "unresolved",
                resolutionReason: "unknown",
                legacyJurisdiction: "Federal",
                legacyCourt: Wire.unknownCourtText,
                legacyPartyPerspective: "neutral",
                legacyClientNames: nil,
                canonicalJurisdictionID: nil,
                canonicalCourtID: nil
            )
            try assertReceipt(
                db,
                matterID: Wire.ambiguousMatterID,
                courtResolutionState: "unresolved",
                resolutionReason: "ambiguous",
                legacyJurisdiction: "Florida",
                legacyCourt: Wire.ambiguousCourtText,
                legacyPartyPerspective: "defendant",
                legacyClientNames: nil,
                canonicalJurisdictionID: nil,
                canonicalCourtID: nil
            )

            let aliasMatter = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                    SELECT court, canonical_jurisdiction_id, canonical_court_id,
                           court_resolution_state, canonical_catalog_version,
                           canonical_catalog_digest_sha256, identity_revision
                    FROM matters WHERE id = ?
                    """,
                arguments: [Wire.aliasMatterID]
            ))
            XCTAssertEqual(aliasMatter["court"] as String, Wire.aliasCourtText)
            XCTAssertEqual(
                aliasMatter["canonical_jurisdiction_id"] as String,
                Wire.eleventhCircuitJurisdictionID
            )
            XCTAssertEqual(aliasMatter["canonical_court_id"] as String, Wire.southernDistrictCourtID)
            XCTAssertEqual(aliasMatter["court_resolution_state"] as String, "court")
            XCTAssertEqual(aliasMatter["canonical_catalog_version"] as String, Wire.catalogVersion)
            XCTAssertEqual(
                aliasMatter["canonical_catalog_digest_sha256"] as String,
                Wire.catalogDigestSHA256
            )
            XCTAssertEqual(aliasMatter["identity_revision"] as Int, 1)

            for unresolved in [
                (Wire.unknownMatterID, Wire.unknownCourtText),
                (Wire.ambiguousMatterID, Wire.ambiguousCourtText),
            ] {
                let row = try XCTUnwrap(Row.fetchOne(
                    db,
                    sql: """
                        SELECT court, canonical_jurisdiction_id,
                               canonical_court_id, court_resolution_state,
                               canonical_catalog_version,
                               canonical_catalog_digest_sha256, identity_revision
                        FROM matters WHERE id = ?
                        """,
                    arguments: [unresolved.0]
                ))
                XCTAssertEqual(row["court"] as String, unresolved.1)
                XCTAssertNil(row["canonical_jurisdiction_id"] as String?)
                XCTAssertNil(row["canonical_court_id"] as String?)
                XCTAssertEqual(row["court_resolution_state"] as String, "unresolved")
                XCTAssertEqual(row["canonical_catalog_version"] as String, Wire.catalogVersion)
                XCTAssertEqual(
                    row["canonical_catalog_digest_sha256"] as String,
                    Wire.catalogDigestSHA256
                )
                XCTAssertEqual(row["identity_revision"] as Int, 1)
            }

            XCTAssertTrue(try db.tableExists("matter_parties"))
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM matter_parties"),
                0,
                "v074 must not invent structured parties from legacy client_names"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT client_names FROM matters WHERE id = ?",
                    arguments: [Wire.aliasMatterID]
                ),
                Wire.clientName,
                "punctuation and slash remain one byte-exact unresolved legacy value"
            )
        }
    }

    private func migrationIdentifiers(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    private func assertReceipt(
        _ db: Database,
        matterID: String,
        courtResolutionState: String,
        resolutionReason: String,
        legacyJurisdiction: String,
        legacyCourt: String,
        legacyPartyPerspective: String,
        legacyClientNames: String?,
        canonicalJurisdictionID: String?,
        canonicalCourtID: String?
    ) throws {
        let row = try XCTUnwrap(Row.fetchOne(
            db,
            sql: """
                SELECT source_migration, identity_revision,
                       court_resolution_state, resolution_reason,
                       legacy_jurisdiction, legacy_court,
                       legacy_party_perspective, legacy_client_names,
                       canonical_jurisdiction_id, canonical_court_id,
                       canonical_catalog_version,
                       canonical_catalog_digest_sha256
                FROM matter_identity_conversion_receipts
                WHERE matter_id = ?
                """,
            arguments: [matterID]
        ))
        XCTAssertEqual(row["source_migration"] as String, Wire.v074)
        XCTAssertEqual(row["identity_revision"] as Int, 1)
        XCTAssertEqual(row["court_resolution_state"] as String, courtResolutionState)
        XCTAssertEqual(row["resolution_reason"] as String, resolutionReason)
        XCTAssertEqual(row["legacy_jurisdiction"] as String, legacyJurisdiction)
        XCTAssertEqual(row["legacy_court"] as String, legacyCourt)
        XCTAssertEqual(row["legacy_party_perspective"] as String, legacyPartyPerspective)
        XCTAssertEqual(row["legacy_client_names"] as String?, legacyClientNames)
        XCTAssertEqual(row["canonical_jurisdiction_id"] as String?, canonicalJurisdictionID)
        XCTAssertEqual(row["canonical_court_id"] as String?, canonicalCourtID)
        XCTAssertEqual(row["canonical_catalog_version"] as String, Wire.catalogVersion)
        XCTAssertEqual(
            row["canonical_catalog_digest_sha256"] as String,
            Wire.catalogDigestSHA256
        )
    }

    private func legacyCanarySnapshot(_ queue: DatabaseQueue) throws -> LegacyCanarySnapshot {
        try queue.read { db in
            LegacyCanarySnapshot(
                matters: try String.fetchAll(
                    db,
                    sql: """
                        SELECT json_array(
                            id, name, jurisdiction, party_perspective, court,
                            client_names, CAST(created_at AS TEXT), CAST(updated_at AS TEXT)
                        ) FROM matters ORDER BY id
                        """
                ),
                blobs: try String.fetchAll(
                    db,
                    sql: """
                        SELECT json_array(
                            id, sha256, byte_size, original_extension,
                            managed_relative_path, CAST(created_at AS TEXT)
                        ) FROM document_blobs ORDER BY id
                        """
                ),
                documents: try String.fetchAll(
                    db,
                    sql: """
                        SELECT json_array(
                            id, matter_id, blob_id, display_name,
                            imported_relative_path, source_display_path, status,
                            extraction_status, index_status, CAST(created_at AS TEXT)
                        ) FROM matter_documents ORDER BY id
                        """
                ),
                outputs: try String.fetchAll(
                    db,
                    sql: """
                        SELECT json_array(
                            id, matter_id, title, output_type, active_version_id,
                            status, CAST(created_at AS TEXT), CAST(updated_at AS TEXT)
                        ) FROM structured_outputs ORDER BY id
                        """
                ),
                versions: try String.fetchAll(
                    db,
                    sql: """
                        SELECT json_array(
                            id, structured_output_id, version_index, content_markdown,
                            verification_status, prompt_builder_version, assurance_state,
                            CAST(created_at AS TEXT), CAST(updated_at AS TEXT)
                        ) FROM structured_output_versions ORDER BY id
                        """
                ),
                corpusRuns: try String.fetchAll(
                    db,
                    sql: """
                        SELECT json_array(
                            id, run_key, matter_id, task_kind, scope_json,
                            corpus_snapshot_json, partition_strategy,
                            partition_strategy_version, status,
                            structured_output_version_id, CAST(created_at AS TEXT)
                        ) FROM corpus_analysis_runs ORDER BY id
                        """
                ),
                audits: try String.fetchAll(
                    db,
                    sql: """
                        SELECT json_array(
                            id, matter_id, CAST(timestamp AS TEXT), event_type,
                            actor, summary, related_table, related_id, metadata_json
                        ) FROM audit_events ORDER BY id
                        """
                ),
                exports: try String.fetchAll(
                    db,
                    sql: """
                        SELECT json_array(
                            id, structured_output_id, structured_output_version_id,
                            matter_id, format, managed_relative_path,
                            CAST(created_at AS TEXT)
                        ) FROM document_exports ORDER BY id
                        """
                )
            )
        }
    }

    private func v074IdentitySnapshot(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            let receiptAndMatterRows = try String.fetchAll(
                db,
                sql: """
                    SELECT json_array(
                        receipt.id, receipt.matter_id, receipt.source_migration,
                        receipt.identity_revision,
                        receipt.court_resolution_state,
                        receipt.resolution_reason,
                        receipt.legacy_jurisdiction,
                        receipt.legacy_court, receipt.legacy_party_perspective,
                        receipt.legacy_client_names,
                        receipt.canonical_jurisdiction_id,
                        receipt.canonical_court_id,
                        receipt.canonical_catalog_version,
                        receipt.canonical_catalog_digest_sha256,
                        CAST(receipt.created_at AS TEXT),
                        matter.court, matter.canonical_jurisdiction_id,
                        matter.canonical_court_id, matter.court_resolution_state,
                        matter.canonical_catalog_version,
                        matter.canonical_catalog_digest_sha256,
                        matter.identity_revision
                    )
                    FROM matter_identity_conversion_receipts AS receipt
                    JOIN matters AS matter ON matter.id = receipt.matter_id
                    ORDER BY receipt.matter_id
                    """
            )
            let partyCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM matter_parties")
            return receiptAndMatterRows + ["matter_parties_count:\(partyCount ?? -1)"]
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct LegacyCanarySnapshot: Equatable {
    let matters: [String]
    let blobs: [String]
    let documents: [String]
    let outputs: [String]
    let versions: [String]
    let corpusRuns: [String]
    let audits: [String]
    let exports: [String]
}

private enum Wire {
    static let v073 = "v073_create_case_file_review_projects"
    static let v074 = "v074_create_canonical_matter_identity"
    static let currentMigration = "v077_create_accepted_research_packets"
    static let catalogVersion = "jurisdiction-courts-v1"
    static let catalogDigestSHA256 =
        "0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3"

    static let aliasMatterID = "matter-731"
    static let unknownMatterID = "matter-773"
    static let ambiguousMatterID = "matter-797"
    static let aliasCourtText = "S.D. Fla."
    static let unknownCourtText = "Fictional Maritime Claims Tribunal 773"
    static let ambiguousCourtText = "Southern District of Florida"
    static let clientName = "Aster/Vale Holdings, L.P. — Series 731"

    static let eleventhCircuitJurisdictionID =
        "federal-united-states-court-of-appeals-for-the-eleventh-circuit"
    static let southernDistrictCourtID =
        "federal-florida-united-states-district-court-for-the-southern-district-of-florida"

    static let blobID = "blob-733"
    static let blobSHA256 = String(repeating: "73", count: 32)
    static let blobManagedRelativePath = "matters/matter-731/source/Canary 733.pdf"
    static let documentID = "document-743"
    static let outputID = "output-751"
    static let outputVersionID = "version-757"
    static let corpusRunID = "corpus-run-761"
    static let auditID = "audit-773"
    static let exportID = "export-787"
    static let exportManagedRelativePath = "exports/matter-731/Canary Output 787.docx"
    static let timestamp = "2026-08-13T20:31:17.731Z"
}
