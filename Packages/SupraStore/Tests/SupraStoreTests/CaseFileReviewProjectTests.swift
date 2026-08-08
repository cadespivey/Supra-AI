import CryptoKit
import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class CaseFileReviewProjectTests: XCTestCase {
    func testTRPSTORE01V073CreatesNormalizedEmptyReviewSchema() throws {
        // T-RP-STORE-01 expected RED: v073 and the seven Review Project tables do not exist.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertEqual(migrator.migrations.last, "v073_create_case_file_review_projects")
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v072_harden_corpus_review_integrity")
        let matter = try MattersRepository(writer: queue).createMatter(name: "Synthetic pre-v073 review history")

        try migrator.migrate(queue)
        try migrator.migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try appliedMigrations(db).last, "v073_create_case_file_review_projects")
            XCTAssertEqual(Set(try db.columns(in: "case_file_review_projects").map(\.name)), Set([
                "id", "matter_id", "title", "status", "stale_reason", "source_run_id",
                "source_output_id", "source_output_version_id", "source_request_digest",
                "frozen_scope_json", "frozen_corpus_snapshot_json", "frozen_reconciliation_json",
                "active_table_id", "created_at", "updated_at",
            ]))
            XCTAssertEqual(Set(try db.columns(in: "case_file_review_tables").map(\.name)), Set([
                "id", "project_id", "title", "version_index", "created_at", "updated_at",
            ]))
            XCTAssertEqual(Set(try db.columns(in: "case_file_review_columns").map(\.name)), Set([
                "id", "table_id", "column_key", "title", "ordinal", "created_at",
            ]))
            XCTAssertEqual(Set(try db.columns(in: "case_file_review_rows").map(\.name)), Set([
                "id", "table_id", "row_key", "ordinal", "created_at",
            ]))
            XCTAssertEqual(Set(try db.columns(in: "case_file_review_cells").map(\.name)), Set([
                "id", "table_id", "row_id", "column_id", "current_generation_id",
                "attorney_value", "review_state", "value_state", "support_state",
                "reviewed_by", "reviewed_at", "created_at", "updated_at",
            ]))
            XCTAssertEqual(Set(try db.columns(in: "case_file_review_cell_generations").map(\.name)), Set([
                "id", "cell_id", "generation_index", "source_run_id",
                "generated_values_json", "created_at",
            ]))
            XCTAssertEqual(Set(try db.columns(in: "case_file_review_evidence_edges").map(\.name)), Set([
                "id", "generation_id", "kind", "ordinal", "frozen_output_source_id",
                "frozen_document_id", "frozen_revision_id", "frozen_document_name",
                "citation_label", "char_start", "char_end", "locator_json", "excerpt",
                "excerpt_sha256", "live_output_source_id", "live_document_id",
                "live_revision_id", "availability", "unavailable_reason", "created_at", "updated_at",
            ]))

            XCTAssertEqual(try foreignKeys(db, table: "case_file_review_projects"), Set([
                "matter_id->matters:id:CASCADE",
                "active_table_id->case_file_review_tables:id:SET NULL",
            ]))
            XCTAssertEqual(try foreignKeys(db, table: "case_file_review_tables"), Set([
                "project_id->case_file_review_projects:id:CASCADE",
            ]))
            XCTAssertEqual(try foreignKeys(db, table: "case_file_review_columns"), Set([
                "table_id->case_file_review_tables:id:CASCADE",
            ]))
            XCTAssertEqual(try foreignKeys(db, table: "case_file_review_rows"), Set([
                "table_id->case_file_review_tables:id:CASCADE",
            ]))
            XCTAssertEqual(try foreignKeys(db, table: "case_file_review_cells"), Set([
                "table_id->case_file_review_tables:id:CASCADE",
                "row_id,table_id->case_file_review_rows:id,table_id:CASCADE",
                "column_id,table_id->case_file_review_columns:id,table_id:CASCADE",
            ]))
            XCTAssertEqual(try foreignKeys(db, table: "case_file_review_cell_generations"), Set([
                "cell_id->case_file_review_cells:id:CASCADE",
            ]))
            XCTAssertEqual(try foreignKeys(db, table: "case_file_review_evidence_edges"), Set([
                "generation_id->case_file_review_cell_generations:id:CASCADE",
                "live_output_source_id->document_output_sources:id:SET NULL",
                "live_document_id->matter_documents:id:SET NULL",
                "live_revision_id->document_part_revisions:id:SET NULL",
            ]))

            XCTAssertTrue(try uniqueIndexes(db, table: "case_file_review_projects").contains(["source_output_version_id"]))
            XCTAssertTrue(try uniqueIndexes(db, table: "case_file_review_tables").contains(["project_id", "version_index"]))
            XCTAssertTrue(try uniqueIndexes(db, table: "case_file_review_columns").isSuperset(of: [
                ["table_id", "column_key"], ["table_id", "ordinal"], ["id", "table_id"],
            ]))
            XCTAssertTrue(try uniqueIndexes(db, table: "case_file_review_rows").isSuperset(of: [
                ["table_id", "row_key"], ["table_id", "ordinal"], ["id", "table_id"],
            ]))
            XCTAssertTrue(try uniqueIndexes(db, table: "case_file_review_cells").contains(["row_id", "column_id"]))
            XCTAssertTrue(try uniqueIndexes(db, table: "case_file_review_cell_generations").contains(["cell_id", "generation_index"]))
            XCTAssertTrue(try uniqueIndexes(db, table: "case_file_review_evidence_edges").contains(["generation_id", "kind", "ordinal"]))

            for table in reviewTables {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"), 0,
                    "v073 is create-only and must not fabricate a Review Project for matter \(matter.id)")
            }
        }
    }

    func testTRPSTORE02CreatesExactCanaryGraphAtomicallyAndIdempotently() throws {
        // T-RP-STORE-02 expected RED: no atomic Review repository or persisted graph exists.
        let store = try SupraStore.inMemory()
        let fixture = try makeExactFixture(store: store, marker: "431")
        let createdAt = Date(timeIntervalSince1970: 1_799_000_431)

        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_review_project_audit
                BEFORE INSERT ON audit_events
                WHEN NEW.event_type = 'case_file_review_project_created'
                BEGIN SELECT RAISE(ABORT, 'synthetic review audit failure'); END
                """)
        }
        XCTAssertThrowsError(try store.caseFileReviews.createOrFetchProject(
            matterID: fixture.matterID,
            sourceRunID: fixture.runID,
            title: "Canary Review 431",
            actor: "attorney:431",
            at: createdAt
        ))
        try assertReviewCounts(store, allEqual: 0)
        try store.database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER fail_review_project_audit")
        }

        let graph = try store.caseFileReviews.createOrFetchProject(
            matterID: fixture.matterID,
            sourceRunID: fixture.runID,
            title: "Canary Review 431",
            actor: "attorney:431",
            at: createdAt
        )
        let replay = try store.caseFileReviews.createOrFetchProject(
            matterID: fixture.matterID,
            sourceRunID: fixture.runID,
            title: "Canary Review 431",
            actor: "attorney:431",
            at: createdAt
        )
        XCTAssertEqual(replay.project.id, graph.project.id)
        XCTAssertEqual(try store.caseFileReviews.fetchProjects(matterID: fixture.matterID).map(\.id), [graph.project.id])
        XCTAssertNotNil(try store.caseFileReviews.fetchProjectGraph(
            matterID: fixture.matterID, projectID: graph.project.id))

        try store.database.writer.read { db in
            let project = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM case_file_review_projects WHERE id = ?", arguments: [graph.project.id]))
            XCTAssertEqual(project["matter_id"] as String, fixture.matterID)
            XCTAssertEqual(project["source_run_id"] as String, fixture.runID)
            XCTAssertEqual(project["source_output_id"] as String, fixture.outputID)
            XCTAssertEqual(project["source_output_version_id"] as String, fixture.versionID)
            XCTAssertEqual(project["frozen_reconciliation_json"] as String, fixture.reconciliationJSON)

            let columns = try Row.fetchAll(db, sql: """
                SELECT column_key, title, ordinal FROM case_file_review_columns
                WHERE table_id = ? ORDER BY ordinal
                """, arguments: [graph.table.id])
            XCTAssertEqual(columns.map { $0["column_key"] as String }, ["finding", "generated_value", "sources", "review"])
            XCTAssertEqual(columns.map { $0["title"] as String }, ["Finding", "Generated value", "Sources", "Review"])
            XCTAssertEqual(columns.map { $0["ordinal"] as Int }, [0, 1, 2, 3])

            let rows = try Row.fetchAll(db, sql: "SELECT row_key, ordinal FROM case_file_review_rows WHERE table_id = ? ORDER BY ordinal", arguments: [graph.table.id])
            XCTAssertEqual(rows.map { $0["row_key"] as String }, [fixture.alphaKey, fixture.betaKey])
            XCTAssertEqual(rows.map { $0["ordinal"] as Int }, [0, 1])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM case_file_review_cells WHERE table_id = ?", arguments: [graph.table.id]), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM case_file_review_cell_generations"), 2)

            let values = try String.fetchAll(db, sql: "SELECT generated_values_json FROM case_file_review_cell_generations ORDER BY generation_index, id")
            XCTAssertEqual(Set(values), Set([try json([fixture.alphaValue]), try json([fixture.betaValue])]))
            XCTAssertFalse(values.contains(try json(["Generated value"])),
                "the exact generated-value projection must not silently fall back to the column label")

            let edges = try Row.fetchAll(db, sql: """
                SELECT edge.kind, edge.ordinal, edge.frozen_output_source_id, edge.citation_label,
                       edge.excerpt, edge.excerpt_sha256, edge.availability
                FROM case_file_review_evidence_edges AS edge
                JOIN case_file_review_cell_generations AS generation ON generation.id = edge.generation_id
                JOIN case_file_review_cells AS cell ON cell.id = generation.cell_id
                JOIN case_file_review_rows AS row ON row.id = cell.row_id
                ORDER BY row.ordinal, CASE edge.kind WHEN 'supporting' THEN 0 ELSE 1 END, edge.ordinal
                """)
            XCTAssertEqual(edges.map { $0["frozen_output_source_id"] as String }, fixture.sourceIDs)
            XCTAssertEqual(edges.map { $0["kind"] as String }, ["supporting", "supporting", "contrary"])
            XCTAssertEqual(edges.map { $0["excerpt"] as String }, fixture.excerpts)
            XCTAssertEqual(edges.map { $0["excerpt_sha256"] as String }, fixture.excerpts.map(sha256))
            XCTAssertEqual(edges.map { $0["availability"] as String }, ["available", "available", "available"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit_events WHERE event_type = 'case_file_review_project_created' AND related_id = ?", arguments: [graph.project.id]), 1)
        }

        let betaCellID = try valueCellID(store, projectID: graph.project.id, rowKey: fixture.betaKey)
        let betaEdges = try store.caseFileReviews.fetchCurrentEvidence(
            matterID: fixture.matterID, projectID: graph.project.id, cellID: betaCellID)
        XCTAssertEqual(betaEdges.map(\.frozenOutputSourceID), Array(fixture.sourceIDs.suffix(2)))
        XCTAssertFalse(betaEdges.map(\.frozenOutputSourceID).contains(fixture.sourceIDs[0]),
            "selecting the second cell must never leak the first cell's source")

        try store.database.writer.write { db in
            let generationID = try XCTUnwrap(String.fetchOne(db, sql: "SELECT current_generation_id FROM case_file_review_cells WHERE id = ?", arguments: [betaCellID]))
            XCTAssertThrowsError(try db.execute(sql: "UPDATE case_file_review_cell_generations SET generated_values_json = '[\"FORGED\"]' WHERE id = ?", arguments: [generationID]))
            XCTAssertThrowsError(try db.execute(sql: "DELETE FROM case_file_review_cell_generations WHERE id = ?", arguments: [generationID]))
            let edgeID = try XCTUnwrap(String.fetchOne(db, sql: "SELECT id FROM case_file_review_evidence_edges WHERE generation_id = ? LIMIT 1", arguments: [generationID]))
            XCTAssertThrowsError(try db.execute(sql: "UPDATE case_file_review_evidence_edges SET excerpt = 'FORGED' WHERE id = ?", arguments: [edgeID]))
            XCTAssertThrowsError(try db.execute(sql: "DELETE FROM case_file_review_evidence_edges WHERE id = ?", arguments: [edgeID]))
        }

        let otherMatter = try store.matters.createMatter(name: "Synthetic cross-matter review")
        let before = try reviewCounts(store)
        XCTAssertThrowsError(try store.caseFileReviews.createOrFetchProject(
            matterID: otherMatter.id, sourceRunID: fixture.runID, title: "Cross matter",
            actor: "attorney:cross", at: createdAt))
        XCTAssertEqual(try reviewCounts(store), before)

        let malformed = try makeExactFixture(store: store, marker: "malformed-433", reconciliationJSON: "{not-json")
        let beforeMalformed = try reviewCounts(store)
        XCTAssertThrowsError(try store.caseFileReviews.createOrFetchProject(
            matterID: malformed.matterID, sourceRunID: malformed.runID, title: "Malformed",
            actor: "attorney:433", at: createdAt))
        XCTAssertEqual(try reviewCounts(store), beforeMalformed)
    }

    func testTRPSTORE03MarkReviewedIsNarrowAndAuditAtomic() throws {
        // T-RP-STORE-03 expected RED: no mutable Review cell action or atomic review audit exists.
        let store = try SupraStore.inMemory()
        let fixture = try makeExactFixture(store: store, marker: "977")
        let graph = try store.caseFileReviews.createOrFetchProject(
            matterID: fixture.matterID, sourceRunID: fixture.runID, title: "Review 977",
            actor: "attorney:977", at: Date(timeIntervalSince1970: 1_799_000_977))
        let alphaCellID = try valueCellID(store, projectID: graph.project.id, rowKey: fixture.alphaKey)
        let betaCellID = try valueCellID(store, projectID: graph.project.id, rowKey: fixture.betaKey)
        let frozenBefore = try frozenPayload(store, cellID: alphaCellID)
        let reviewedAt = Date(timeIntervalSince1970: 1_799_001_013)

        let reviewed = try store.caseFileReviews.markCellReviewed(
            matterID: fixture.matterID, projectID: graph.project.id, cellID: alphaCellID,
            reviewedBy: "attorney:casey", reviewedAt: reviewedAt)
        XCTAssertEqual(reviewed.reviewState, "reviewed")
        XCTAssertEqual(reviewed.valueState, "generated")
        XCTAssertEqual(reviewed.supportState, "supported")
        XCTAssertEqual(reviewed.reviewedBy, "attorney:casey")
        XCTAssertEqual(reviewed.reviewedAt, reviewedAt)
        XCTAssertEqual(try frozenPayload(store, cellID: alphaCellID), frozenBefore)

        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_review_cell_audit
                BEFORE INSERT ON audit_events
                WHEN NEW.event_type = 'case_file_review_cell_reviewed'
                BEGIN SELECT RAISE(ABORT, 'synthetic reviewed audit failure'); END
                """)
        }
        XCTAssertThrowsError(try store.caseFileReviews.markCellReviewed(
            matterID: fixture.matterID, projectID: graph.project.id, cellID: betaCellID,
            reviewedBy: "attorney:rollback", reviewedAt: reviewedAt))
        try store.database.writer.read { db in
            let beta = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT review_state, reviewed_by, reviewed_at FROM case_file_review_cells WHERE id = ?", arguments: [betaCellID]))
            XCTAssertEqual(beta["review_state"] as String, "needs_review")
            XCTAssertNil(beta["reviewed_by"] as String?)
            XCTAssertNil(beta["reviewed_at"] as Date?)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit_events WHERE event_type = 'case_file_review_cell_reviewed' AND related_id = ?", arguments: [alphaCellID]), 1)
        }

        // Independent axes keep attorney review intact when support later becomes stale.
        try store.database.writer.write { db in
            try db.execute(sql: "UPDATE case_file_review_cells SET support_state = 'stale' WHERE id = ?", arguments: [alphaCellID])
            let axes = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT review_state, value_state, support_state FROM case_file_review_cells WHERE id = ?", arguments: [alphaCellID]))
            XCTAssertEqual(axes["review_state"] as String, "reviewed")
            XCTAssertEqual(axes["value_state"] as String, "generated")
            XCTAssertEqual(axes["support_state"] as String, "stale")
        }
    }

    func testTRPSTORE04PermanentDeletionDegradesOnlyDependentReviewEvidence() throws {
        // T-RP-STORE-04 expected RED: permanent deletion does not invalidate dependent Review evidence.
        let store = try SupraStore.inMemory()
        let dependent = try makeExactFixture(store: store, marker: "1201")
        let unrelated = try makeExactFixture(store: store, marker: "1213")
        let dependentGraph = try store.caseFileReviews.createOrFetchProject(
            matterID: dependent.matterID, sourceRunID: dependent.runID, title: "Dependent 1201",
            actor: "attorney:1201", at: Date(timeIntervalSince1970: 1_799_001_201))
        let unrelatedGraph = try store.caseFileReviews.createOrFetchProject(
            matterID: unrelated.matterID, sourceRunID: unrelated.runID, title: "Unrelated 1213",
            actor: "attorney:1213", at: Date(timeIntervalSince1970: 1_799_001_213))
        let dependentCellID = try valueCellID(store, projectID: dependentGraph.project.id, rowKey: dependent.alphaKey)
        let unrelatedCellID = try valueCellID(store, projectID: unrelatedGraph.project.id, rowKey: unrelated.alphaKey)
        let dependentFrozen = try frozenPayload(store, cellID: dependentCellID)
        let unrelatedFrozen = try frozenPayload(store, cellID: unrelatedCellID)

        _ = try store.documentLibrary.permanentlyDeleteDocument(
            id: dependent.documentID, actor: "attorney:delete", at: Date(timeIntervalSince1970: 1_799_001_237))

        try store.database.writer.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM case_file_review_projects WHERE id = ?", arguments: [dependentGraph.project.id]), "stale")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT support_state FROM case_file_review_cells WHERE id = ?", arguments: [dependentCellID]), "stale")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM case_file_review_evidence_edges AS edge
                JOIN case_file_review_cell_generations AS generation ON generation.id = edge.generation_id
                WHERE generation.cell_id = ? AND edge.availability = 'unavailable'
                  AND edge.live_document_id IS NULL AND edge.live_revision_id IS NULL
                """, arguments: [dependentCellID]), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM case_file_review_projects WHERE id = ?", arguments: [unrelatedGraph.project.id]), "active")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT support_state FROM case_file_review_cells WHERE id = ?", arguments: [unrelatedCellID]), "supported")
        }
        XCTAssertEqual(try frozenPayload(store, cellID: dependentCellID), dependentFrozen,
            "deletion may change availability/live pointers but must retain frozen review evidence")
        XCTAssertEqual(try frozenPayload(store, cellID: unrelatedCellID), unrelatedFrozen)
    }

    func testTRPSTORE05ReviewedProjectGraphSurvivesFileBackedReopen() throws {
        // T-RP-STORE-05 expected RED: no durable Review Project graph exists to reconstruct
        // after closing and reopening the file-backed Store.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("T-RP-STORE-05-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("SupraAI.sqlite")
        let reviewedAt = Date(timeIntervalSince1970: 1_799_001_307)

        let expected: ReviewReopenExpectation
        do {
            let store = try SupraStore(url: databaseURL)
            let fixture = try makeExactFixture(store: store, marker: "1307")
            let graph = try store.caseFileReviews.createOrFetchProject(
                matterID: fixture.matterID,
                sourceRunID: fixture.runID,
                title: "Reopen Review 1307",
                actor: "attorney:1307",
                at: Date(timeIntervalSince1970: 1_799_001_301)
            )
            let cellID = try valueCellID(
                store,
                projectID: graph.project.id,
                rowKey: fixture.betaKey
            )
            _ = try store.caseFileReviews.markCellReviewed(
                matterID: fixture.matterID,
                projectID: graph.project.id,
                cellID: cellID,
                reviewedBy: "attorney:reopen-1307",
                reviewedAt: reviewedAt
            )
            expected = ReviewReopenExpectation(
                matterID: fixture.matterID,
                projectID: graph.project.id,
                tableID: graph.table.id,
                cellID: cellID,
                generatedValues: Set([try json([fixture.alphaValue]), try json([fixture.betaValue])]),
                evidenceSourceIDs: Array(fixture.sourceIDs.suffix(2)),
                frozenPayload: try frozenPayload(store, cellID: cellID)
            )
        }

        let reopened = try SupraStore(url: databaseURL)
        let graph = try XCTUnwrap(reopened.caseFileReviews.fetchProjectGraph(
            matterID: expected.matterID,
            projectID: expected.projectID
        ))
        XCTAssertEqual(graph.project.id, expected.projectID)
        XCTAssertEqual(graph.table.id, expected.tableID)

        try reopened.database.writer.read { db in
            let cell = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                    SELECT review_state, value_state, support_state, reviewed_by, reviewed_at
                    FROM case_file_review_cells WHERE id = ?
                    """,
                arguments: [expected.cellID]
            ))
            XCTAssertEqual(cell["review_state"] as String, "reviewed")
            XCTAssertEqual(cell["value_state"] as String, "generated")
            XCTAssertEqual(cell["support_state"] as String, "supported")
            XCTAssertEqual(cell["reviewed_by"] as String, "attorney:reopen-1307")
            XCTAssertEqual(cell["reviewed_at"] as Date, reviewedAt)

            let generatedValues = try String.fetchAll(
                db,
                sql: """
                    SELECT generation.generated_values_json
                    FROM case_file_review_cell_generations AS generation
                    JOIN case_file_review_cells AS cell ON cell.id = generation.cell_id
                    JOIN case_file_review_tables AS review_table ON review_table.id = cell.table_id
                    WHERE review_table.project_id = ?
                    ORDER BY generation.id
                    """,
                arguments: [expected.projectID]
            )
            XCTAssertEqual(Set(generatedValues), expected.generatedValues)
        }

        let evidence = try reopened.caseFileReviews.fetchCurrentEvidence(
            matterID: expected.matterID,
            projectID: expected.projectID,
            cellID: expected.cellID
        )
        XCTAssertEqual(evidence.map(\.frozenOutputSourceID), expected.evidenceSourceIDs)
        XCTAssertEqual(evidence.map(\.kind), ["supporting", "contrary"])
        XCTAssertEqual(evidence.map(\.availability), ["available", "available"])
        XCTAssertEqual(try frozenPayload(reopened, cellID: expected.cellID), expected.frozenPayload)
    }

    private let reviewTables = [
        "case_file_review_projects", "case_file_review_tables", "case_file_review_columns",
        "case_file_review_rows", "case_file_review_cells", "case_file_review_cell_generations",
        "case_file_review_evidence_edges",
    ]

    private func makeExactFixture(
        store: SupraStore,
        marker: String,
        reconciliationJSON override: String? = nil
    ) throws -> ReviewFixture {
        let matter = try store.matters.createMatter(name: "Synthetic Review \(marker)")
        let text = "ALPHA-EVIDENCE-\(marker)-NONDEFAULT. BETA-SUPPORT-\(marker)-NONDEFAULT. BETA-CONTRARY-\(marker)-NONDEFAULT."
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: sha256(text), byteSize: text.utf8.count, originalExtension: "txt",
            managedRelativePath: "blobs/review-\(marker).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id, blobID: blob.id, displayName: "Review-\(marker).txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.textIndexed.rawValue,
            sourceKind: DocumentSourceKind.text.rawValue
        ))
        let revision = DocumentPartRevisionRecord(
            id: "review-revision-\(marker)", documentID: document.id, partIndex: 0,
            derivationKey: "review-\(marker)", origin: "synthetic_test", method: "plain-text",
            text: text, charCount: text.count
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [DocumentPagePartRecord(
                id: "review-part-\(marker)", documentID: document.id, partIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue, normalizedText: text, charCount: text.count)],
            revisions: [revision],
            selections: [DocumentPartSelectionRecord(
                id: "review-selection-\(marker)", documentID: document.id, partIndex: 0,
                selectedRevisionID: revision.id, selectionKey: "review-\(marker)", selectedBy: "test",
                decisionJSON: #"{"rule":"review-fixture"}"#)]
        )

        let runID = "review-run-\(marker)"
        let partitionID = "review-partition-\(marker)"
        let memberKey = "document:\(document.id)"
        let sliceLocator = "{\"source_kind\":\"text\",\"char_start\":0,\"char_end\":\(text.count)}"
        let snapshot = CorpusAnalysisSnapshot(schemaVersion: 2, members: [CorpusAnalysisSnapshotMember(
            memberKey: memberKey, documentID: document.id, displayName: document.displayName,
            revisionIDs: [revision.id], indexState: document.indexStatus, disposition: .eligible)])
        let run = CorpusAnalysisRunRecord(
            id: runID, runKey: "review-key-\(marker)", matterID: matter.id,
            taskKind: CorpusAnalysisTaskKind.exhaustiveList.rawValue,
            scopeJSON: try json(["schema_version": 2, "document_ids": [document.id]]),
            corpusSnapshotJSON: try json(snapshot),
            partitionStrategy: "exact_revision_slice:characters=\(text.count)", partitionStrategyVersion: 2,
            modelLineageJSON: #"{"artifact_fingerprint_sha256":"7777777777777777777777777777777777777777777777777777777777777777","content_binding_algorithm":"supra-release-model-sha256-v1","content_binding_schema_version":1,"model_repository":"synthetic/review","model_revision":"0123456789abcdef0123456789abcdef01234567"}"#,
            status: CorpusAnalysisRunStatus.planning.rawValue, requestSchemaVersion: 2,
            requestDigest: sha256("request-\(marker)")
        )
        let partition = CorpusAnalysisPartitionRecord(
            id: partitionID, runID: runID,
            partitionKey: "000000|\(memberKey)#revision:\(revision.id)#chars:0-\(text.count)",
            inputRevisionIDsJSON: try json([revision.id])
        )
        let slice = CorpusAnalysisPartitionSliceRecord(
            id: "review-slice-\(marker)", runID: runID, partitionID: partitionID, ordinal: 0,
            memberKey: memberKey, documentID: document.id, partIndex: 0, revisionID: revision.id,
            charStart: 0, charEnd: text.count, revisionCharCount: text.count,
            textSHA256: sha256(text), locatorJSON: sliceLocator
        )
        _ = try store.corpusAnalysis.createOrFetchPreparedRun(run: run, partitions: [partition], slices: [slice])

        let excerpts = ["ALPHA-EVIDENCE-\(marker)-NONDEFAULT.", "BETA-SUPPORT-\(marker)-NONDEFAULT.", "BETA-CONTRARY-\(marker)-NONDEFAULT."]
        let ranges = excerpts.map { excerpt -> Range<Int> in
            let range = text.range(of: excerpt)!
            return text.distance(from: text.startIndex, to: range.lowerBound)..<text.distance(from: text.startIndex, to: range.upperBound)
        }
        func evidence(_ index: Int) -> [String: Any] {
            ["document_id": document.id, "revision_id": revision.id, "locator_json": sliceLocator,
             "quote": excerpts[index], "char_start": ranges[index].lowerBound, "char_end": ranges[index].upperBound]
        }
        let findings: [[String: Any]] = [
            ["id": "alpha-\(marker)", "value": "ALPHA-VALUE-\(marker)-NONDEFAULT", "evidence": [evidence(0)], "contrary_evidence": []],
            ["id": "beta-\(marker)", "value": "BETA-VALUE-\(marker)-NONDEFAULT", "evidence": [evidence(1)], "contrary_evidence": [evidence(2)]],
        ]
        _ = try store.corpusAnalysis.beginAttempt(matterID: matter.id, runID: runID, partitionID: partitionID)
        try store.corpusAnalysis.completeAttemptSucceeded(
            matterID: matter.id, runID: runID, partitionID: partitionID, findingsJSON: try json(findings))

        let alphaKey = "finding-alpha-\(marker)"
        let betaKey = "finding-beta-\(marker)"
        let alphaValue = "ALPHA-VALUE-\(marker)-NONDEFAULT"
        let betaValue = "BETA-VALUE-\(marker)-NONDEFAULT"
        let reconciliation = try json([
            "schema_version": 1,
            "items": [
                ["item_key": alphaKey, "values": [alphaValue], "evidence": [evidence(0)], "contrary_evidence": []],
                ["item_key": betaKey, "values": [betaValue], "evidence": [evidence(1)], "contrary_evidence": [evidence(2)]],
            ],
            "omissions": [],
            "metrics": ["expected_count": 2, "emitted_count": 2, "true_positive_count": 2,
                        "recall": 1.0, "precision": 1.0, "duplicate_count": 0,
                        "conflict_count": 0, "unexpected_item_keys": []],
            "failed_partitions": [], "excluded_members": [],
        ] as [String: Any])
        _ = try store.corpusAnalysis.saveReconciliation(
            matterID: matter.id, runID: runID, reconciliationJSON: override ?? reconciliation)
        _ = try store.corpusAnalysis.finalizeRun(
            matterID: matter.id, runID: runID, assuranceState: .corpusComplete,
            assuranceReasons: ["synthetic review fixture"], exclusionsDisclosed: true)

        let sourceSetID = "review-source-set-\(marker)"
        let sourceIDs = ["review-source-alpha-\(marker)", "review-source-beta-\(marker)", "review-source-contrary-\(marker)"]
        let outputSources = zip(sourceIDs.indices, sourceIDs).map { index, id in
            DocumentOutputSourceRecord(
                id: id, sourceSetID: sourceSetID, documentID: document.id, revisionID: revision.id,
                citationLabel: index == 0 ? "S431" : (index == 1 ? "S977" : "C983"),
                locatorJSON: "{\"source_kind\":\"text\",\"char_start\":\(ranges[index].lowerBound),\"char_end\":\(ranges[index].upperBound)}",
                excerpt: excerpts[index], rank: index
            )
        }
        let lineageHash = try store.database.writer.read { db in
            try XCTUnwrap(CorpusAnalysisProofIdentity.frozenCorpusLineageHash(db: db, runID: runID))
        }
        let outputID = "review-output-\(marker)"
        let version = try store.structuredOutputs.createVersionWithSourceSetAtomically(
            structuredOutputID: outputID,
            newOutput: StructuredOutputRecord(
                id: outputID, matterID: matter.id, title: "Synthetic output \(marker)",
                outputType: StructuredOutputType.documentExhaustiveList.rawValue),
            sourceSet: DocumentSourceSetRecord(
                id: sourceSetID, matterID: matter.id, mode: DocumentSourceSetMode.exhaustive.rawValue,
                scopeJSON: run.scopeJSON, retrievalQuery: "Synthetic review \(marker)",
                corpusSnapshotHash: lineageHash),
            outputSources: outputSources,
            contentMarkdown: "# Synthetic Review \(marker)\n\n\(alphaValue) [S431]\n\n\(betaValue) [S977].",
            verificationStatus: .allSupported, verificationVersion: "review-verifier/1",
            verificationResults: [try supportedResult(sourceID: sourceIDs[0])],
            verificationDimensions: supportedDimensions(), outputStatus: .complete,
            corpusAnalysisRunID: runID, promptBuilderVersion: "review-prompt/1",
            assuranceState: .corpusComplete
        )
        return ReviewFixture(
            matterID: matter.id, documentID: document.id, runID: runID, outputID: outputID,
            versionID: version.id, reconciliationJSON: override ?? reconciliation,
            alphaKey: alphaKey, betaKey: betaKey, alphaValue: alphaValue, betaValue: betaValue,
            sourceIDs: sourceIDs, excerpts: excerpts
        )
    }

    private func supportedResult(sourceID: String) throws -> PropositionSupportResult {
        try PropositionSupportResult(
            propositionID: "review-proposition", status: .supported, reasons: ["synthetic_support"],
            evidence: [SupportEvidence(
                sourceID: sourceID, sourceLabel: "S431", locator: "Synthetic review source",
                retainedExcerpt: "Synthetic retained review evidence.", verifierName: "ReviewFixture",
                verifierVersion: "review-fixture/1")],
            timestamp: Date(timeIntervalSince1970: 1_799_000_000))
    }

    private func supportedDimensions() -> VerificationDimensions {
        .complete(overrides: [
            .init(dimension: .propositionSupport, status: .satisfied),
            .init(dimension: .citationResolution, status: .satisfied),
            .init(dimension: .criticalValueFidelity, status: .satisfied),
            .init(dimension: .lowConfidenceHandling, status: .satisfied),
        ])
    }

    private func valueCellID(_ store: SupraStore, projectID: String, rowKey: String) throws -> String {
        try store.database.writer.read { db in
            try XCTUnwrap(String.fetchOne(db, sql: """
                SELECT cell.id FROM case_file_review_cells AS cell
                JOIN case_file_review_rows AS row ON row.id = cell.row_id
                JOIN case_file_review_tables AS review_table ON review_table.id = cell.table_id
                JOIN case_file_review_columns AS column ON column.id = cell.column_id
                WHERE review_table.project_id = ? AND row.row_key = ?
                  AND column.column_key = 'generated_value'
                """, arguments: [projectID, rowKey]))
        }
    }

    private func frozenPayload(_ store: SupraStore, cellID: String) throws -> [String] {
        try store.database.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT generation.generated_values_json || '|' || edge.kind || '|' ||
                       edge.frozen_output_source_id || '|' || edge.frozen_document_id || '|' ||
                       edge.frozen_revision_id || '|' || edge.frozen_document_name || '|' ||
                       edge.citation_label || '|' || edge.locator_json || '|' || edge.excerpt || '|' ||
                       edge.excerpt_sha256
                FROM case_file_review_cell_generations AS generation
                JOIN case_file_review_evidence_edges AS edge ON edge.generation_id = generation.id
                WHERE generation.cell_id = ?
                ORDER BY CASE edge.kind WHEN 'supporting' THEN 0 ELSE 1 END, edge.ordinal
                """, arguments: [cellID])
        }
    }

    private func assertReviewCounts(_ store: SupraStore, allEqual expected: Int) throws {
        XCTAssertTrue(try reviewCounts(store).values.allSatisfy { $0 == expected })
    }

    private func reviewCounts(_ store: SupraStore) throws -> [String: Int] {
        try store.database.writer.read { db in
            try Dictionary(uniqueKeysWithValues: reviewTables.map { table in
                (table, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1)
            })
        }
    }

    private func appliedMigrations(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
    }

    private func foreignKeys(_ db: Database, table: String) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
        return Set(Dictionary(grouping: rows) { $0["id"] as Int }.values.map { group in
            let ordered = group.sorted { ($0["seq"] as Int) < ($1["seq"] as Int) }
            return "\(ordered.map { $0["from"] as String }.joined(separator: ","))->\(ordered[0]["table"] as String):\(ordered.map { $0["to"] as String }.joined(separator: ",")):\(ordered[0]["on_delete"] as String)"
        })
    }

    private func uniqueIndexes(_ db: Database, table: String) throws -> Set<[String]> {
        var result = Set<[String]>()
        for index in try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))") where (index["unique"] as Int) == 1 {
            let name = index["name"] as String
            result.insert(try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))")
                .sorted { ($0["seqno"] as Int) < ($1["seqno"] as Int) }
                .map { $0["name"] as String })
        }
        return result
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ReviewFixture {
    let matterID: String
    let documentID: String
    let runID: String
    let outputID: String
    let versionID: String
    let reconciliationJSON: String
    let alphaKey: String
    let betaKey: String
    let alphaValue: String
    let betaValue: String
    let sourceIDs: [String]
    let excerpts: [String]
}

private struct ReviewReopenExpectation {
    let matterID: String
    let projectID: String
    let tableID: String
    let cellID: String
    let generatedValues: Set<String>
    let evidenceSourceIDs: [String]
    let frozenPayload: [String]
}
