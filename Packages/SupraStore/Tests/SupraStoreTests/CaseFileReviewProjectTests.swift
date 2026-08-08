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

    func testTRPSTORE06ParentDeletesCannotEraseFrozenReviewGraphAndTopologyFailsClosed() throws {
        // T-RP-STORE-06 expected RED: the generation/evidence DELETE guards
        // inspect owners that SQLite has already removed during a parent cascade.
        // Direct project/table/column/row/cell deletion can therefore erase frozen
        // proof, and aggregate graph checks accept a cell on the wrong column or a
        // current generation swapped from another cell.
        let deleteTables = [
            "case_file_review_projects",
            "case_file_review_tables",
            "case_file_review_columns",
            "case_file_review_rows",
            "case_file_review_cells",
        ]
        for (index, table) in deleteTables.enumerated() {
            let store = try SupraStore.inMemory()
            let marker = "1409-\(index)"
            let fixture = try makeExactFixture(store: store, marker: marker)
            let graph = try store.caseFileReviews.createOrFetchProject(
                matterID: fixture.matterID,
                sourceRunID: fixture.runID,
                title: "Parent guard review \(marker)",
                actor: "attorney:\(marker)"
            )
            let id: String
            switch table {
            case "case_file_review_projects": id = graph.project.id
            case "case_file_review_tables": id = graph.table.id
            case "case_file_review_columns": id = graph.columns[0].id
            case "case_file_review_rows": id = graph.rows[0].id
            case "case_file_review_cells": id = graph.cells[0].id
            default: return XCTFail("unhandled Review parent table \(table)")
            }
            XCTAssertThrowsError(try store.database.writer.write { db in
                try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [id])
            }, "direct deletion from \(table) must not cascade through a live Review Project")
            XCTAssertNotNil(try? store.caseFileReviews.fetchProjectGraph(
                matterID: fixture.matterID,
                projectID: graph.project.id
            ))
        }

        let store = try SupraStore.inMemory()
        let fixture = try makeExactFixture(store: store, marker: "1417")
        let graph = try store.caseFileReviews.createOrFetchProject(
            matterID: fixture.matterID,
            sourceRunID: fixture.runID,
            title: "Topology review 1417",
            actor: "attorney:1417"
        )
        let cells = graph.cells.sorted { $0.id < $1.id }
        let generations = graph.generations.sorted { $0.cellID < $1.cellID }
        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(generations.count, 2)
        let generatedColumn = try XCTUnwrap(graph.columns.first { $0.columnKey == "generated_value" })
        let findingColumn = try XCTUnwrap(graph.columns.first { $0.columnKey == "finding" })
        try store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE case_file_review_cells SET column_id = ? WHERE id = ?",
                arguments: [findingColumn.id, cells[0].id]
            )
        }
        XCTAssertThrowsError(try store.caseFileReviews.fetchProjectGraph(
            matterID: fixture.matterID,
            projectID: graph.project.id
        ))
        try store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE case_file_review_cells SET column_id = ? WHERE id = ?",
                arguments: [generatedColumn.id, cells[0].id]
            )
            try db.execute(
                sql: """
                    UPDATE case_file_review_cells
                    SET current_generation_id = CASE id
                        WHEN ? THEN ?
                        WHEN ? THEN ?
                    END
                    WHERE id IN (?, ?)
                    """,
                arguments: [
                    cells[0].id, generations[1].id,
                    cells[1].id, generations[0].id,
                    cells[0].id, cells[1].id,
                ]
            )
        }
        XCTAssertThrowsError(try store.caseFileReviews.fetchProjectGraph(
            matterID: fixture.matterID,
            projectID: graph.project.id
        ))

        // The direct-delete guards must not turn the owning matter's explicit,
        // audited permanent-delete workflow into an undeletable graph.
        let cascadeStore = try SupraStore.inMemory()
        let cascadeFixture = try makeExactFixture(store: cascadeStore, marker: "1421")
        _ = try cascadeStore.caseFileReviews.createOrFetchProject(
            matterID: cascadeFixture.matterID,
            sourceRunID: cascadeFixture.runID,
            title: "Matter cascade review 1421",
            actor: "attorney:1421"
        )
        try cascadeStore.matters.softDeleteMatter(id: cascadeFixture.matterID)
        _ = try cascadeStore.matters.permanentlyDeleteMatter(
            id: cascadeFixture.matterID,
            actor: "attorney:delete-matter-1421"
        )
        try assertReviewCounts(cascadeStore, allEqual: 0)
    }

    func testTRPSTORE07LatePermanentDeletionFailureRollsBackReviewDegradation() throws {
        // T-RP-STORE-07 standing guard: Review availability, support, project
        // state, and audit must roll back if the enclosing permanent-deletion
        // transaction fails after degradation has begun.
        let store = try SupraStore.inMemory()
        let fixture = try makeExactFixture(store: store, marker: "1423")
        let graph = try store.caseFileReviews.createOrFetchProject(
            matterID: fixture.matterID,
            sourceRunID: fixture.runID,
            title: "Rollback review 1423",
            actor: "attorney:1423"
        )
        let cellID = try valueCellID(store, projectID: graph.project.id, rowKey: fixture.alphaKey)
        let frozenBefore = try frozenPayload(store, cellID: cellID)
        let evidenceBefore = try store.caseFileReviews.fetchCurrentEvidence(
            matterID: fixture.matterID,
            projectID: graph.project.id,
            cellID: cellID
        )
        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_review_document_deletion_audit
                BEFORE INSERT ON audit_events
                WHEN NEW.event_type = 'document_permanently_deleted'
                BEGIN SELECT RAISE(ABORT, 'synthetic late deletion failure'); END
                """)
        }

        XCTAssertThrowsError(try store.documentLibrary.permanentlyDeleteDocument(
            id: fixture.documentID,
            actor: "attorney:rollback-1423"
        ))

        let reopened = try XCTUnwrap(store.caseFileReviews.fetchProjectGraph(
            matterID: fixture.matterID,
            projectID: graph.project.id
        ))
        XCTAssertEqual(reopened.project.status, "active")
        let reopenedCell = try XCTUnwrap(reopened.cells.first { $0.id == cellID })
        XCTAssertEqual(reopenedCell.supportState, "supported")
        XCTAssertEqual(try frozenPayload(store, cellID: cellID), frozenBefore)
        XCTAssertEqual(
            try store.caseFileReviews.fetchCurrentEvidence(
                matterID: fixture.matterID,
                projectID: graph.project.id,
                cellID: cellID
            ),
            evidenceBefore
        )
        try store.database.writer.read { db in
            XCTAssertEqual(try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM audit_events WHERE event_type = 'case_file_review_source_unavailable' AND related_id = ?",
                arguments: [graph.project.id]
            ), 0)
        }
    }

    func testTRPSTORE08ReviewAdmitsCompleteExactContraryOutputWithoutWeakeningExport() throws {
        // T-RP-STORE-08 expected RED: Review reuses the export-only assurance
        // boundary, even though retained contrary evidence intentionally makes an
        // otherwise complete exact exhaustive output corpus_incomplete/needs_review.
        let store = try SupraStore.inMemory()
        let fixture = try makeExactFixture(
            store: store,
            marker: "1439",
            assuranceState: .corpusIncomplete
        )

        XCTAssertNil(try store.corpusAnalysis.fetchExactExportRun(
            matterID: fixture.matterID,
            structuredOutputVersionID: fixture.versionID
        ), "the export boundary must remain strong")
        let graph: CaseFileReviewProjectGraph
        do {
            graph = try store.caseFileReviews.createOrFetchProject(
                matterID: fixture.matterID,
                sourceRunID: fixture.runID,
                title: "Contrary evidence review 1439",
                actor: "attorney:1439"
            )
        } catch {
            XCTFail("a complete exact contrary-evidence run must remain reviewable: \(error)")
            return
        }
        XCTAssertEqual(graph.rows.count, 2)
        let betaCellID = try valueCellID(store, projectID: graph.project.id, rowKey: fixture.betaKey)
        XCTAssertEqual(
            try store.caseFileReviews.fetchCurrentEvidence(
                matterID: fixture.matterID,
                projectID: graph.project.id,
                cellID: betaCellID
            ).map(\.kind),
            ["supporting", "contrary"]
        )

        let forged = try makeExactFixture(
            store: store,
            marker: "1451",
            assuranceState: .corpusIncomplete
        )
        try store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE corpus_analysis_runs SET validation_results_json = ? WHERE id = ?",
                arguments: [#"{"schema_version":1}"#, forged.runID]
            )
        }
        XCTAssertThrowsError(try store.caseFileReviews.createOrFetchProject(
            matterID: forged.matterID,
            sourceRunID: forged.runID,
            title: "Malformed contrary review 1451",
            actor: "attorney:1451"
        ))
    }

    func testTRPSTORE09EditedValueIsScopedAuditedDurableAndExplicitlyRestorable() throws {
        // T-RP-STORE-09 expected RED: Review cells expose no Store-owned edit or
        // explicit restore transition, so an attorney override cannot be
        // persisted, audited, reopened, or returned to its frozen generation.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("T-RP-STORE-09-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("SupraAI.sqlite")
        let editedValue = "105 calendar days after written notice"
        let editedAt = Date(timeIntervalSince1970: 1_799_001_493)
        let restoredAt = Date(timeIntervalSince1970: 1_799_001_517)

        let expected: ReviewEditReopenExpectation
        do {
            let store = try SupraStore(url: databaseURL)
            let fixture = try makeExactFixture(store: store, marker: "1493")
            let graph = try store.caseFileReviews.createOrFetchProject(
                matterID: fixture.matterID,
                sourceRunID: fixture.runID,
                title: "Editable Review 1493",
                actor: "attorney:create-1493",
                at: Date(timeIntervalSince1970: 1_799_001_459)
            )
            let alphaCellID = try valueCellID(
                store,
                projectID: graph.project.id,
                rowKey: fixture.alphaKey
            )
            let betaCellID = try valueCellID(
                store,
                projectID: graph.project.id,
                rowKey: fixture.betaKey
            )
            _ = try store.caseFileReviews.markCellReviewed(
                matterID: fixture.matterID,
                projectID: graph.project.id,
                cellID: alphaCellID,
                reviewedBy: "attorney:prior-review-1493",
                reviewedAt: Date(timeIntervalSince1970: 1_799_001_471)
            )
            try store.database.writer.write { db in
                try db.execute(
                    sql: """
                        UPDATE case_file_review_projects
                        SET status = 'stale', stale_reason = 'synthetic_scope_changed'
                        WHERE id = ?
                        """,
                    arguments: [graph.project.id]
                )
            }
            let alphaBefore = try reviewCell(store, cellID: alphaCellID)
            let betaBefore = try reviewCell(store, cellID: betaCellID)
            let frozenBefore = try frozenPayload(store, cellID: alphaCellID)
            let evidenceBefore = try store.caseFileReviews.fetchCurrentEvidence(
                matterID: fixture.matterID,
                projectID: graph.project.id,
                cellID: alphaCellID
            )
            let generationID = try XCTUnwrap(alphaBefore.currentGenerationID)

            let edited = try store.caseFileReviews.editCellValue(
                matterID: fixture.matterID,
                projectID: graph.project.id,
                cellID: alphaCellID,
                attorneyValue: "  \(editedValue)\n",
                editedBy: "  attorney:editor-1493  ",
                editedAt: editedAt
            )
            XCTAssertEqual(edited.id, alphaCellID)
            XCTAssertEqual(edited.attorneyValue, editedValue)
            XCTAssertEqual(edited.valueState, "edited")
            XCTAssertEqual(edited.reviewState, "needs_review")
            XCTAssertNil(edited.reviewedBy)
            XCTAssertNil(edited.reviewedAt)
            XCTAssertEqual(edited.supportState, alphaBefore.supportState)
            XCTAssertEqual(edited.currentGenerationID, generationID)
            XCTAssertEqual(edited.updatedAt, editedAt)
            XCTAssertEqual(try frozenPayload(store, cellID: alphaCellID), frozenBefore)
            XCTAssertEqual(
                try store.caseFileReviews.fetchCurrentEvidence(
                    matterID: fixture.matterID,
                    projectID: graph.project.id,
                    cellID: alphaCellID
                ),
                evidenceBefore
            )
            XCTAssertEqual(try reviewCell(store, cellID: betaCellID), betaBefore,
                "editing alpha must not mutate the neighboring beta cell")

            let projectAfterEdit = try reviewProject(store, projectID: graph.project.id)
            XCTAssertEqual(projectAfterEdit.status, "stale")
            XCTAssertEqual(projectAfterEdit.staleReason, "synthetic_scope_changed")
            XCTAssertEqual(projectAfterEdit.updatedAt, editedAt)

            let editAudits = try store.auditEvents.fetchEvents(
                relatedTable: CaseFileReviewCellRecord.databaseTableName,
                relatedID: alphaCellID,
                eventType: "case_file_review_cell_value_edited"
            )
            XCTAssertEqual(editAudits.count, 1)
            let editAudit = try XCTUnwrap(editAudits.first)
            XCTAssertEqual(editAudit.matterID, fixture.matterID)
            XCTAssertEqual(editAudit.timestamp, editedAt)
            XCTAssertEqual(editAudit.actor, "attorney:editor-1493")
            XCTAssertEqual(editAudit.relatedID, alphaCellID)
            let editMetadataJSON = try XCTUnwrap(editAudit.metadataJSON)
            let editMetadata = try jsonObject(editMetadataJSON)
            XCTAssertEqual(Set(editMetadata.keys), Set([
                "schema_version", "project_id", "cell_id", "current_generation_id",
                "prior_value_state", "new_value_state", "prior_attorney_value",
                "new_attorney_value", "review_attestation_cleared",
            ]))
            XCTAssertEqual(editMetadata["schema_version"] as? Int, 1)
            XCTAssertEqual(editMetadata["project_id"] as? String, graph.project.id)
            XCTAssertEqual(editMetadata["cell_id"] as? String, alphaCellID)
            XCTAssertEqual(editMetadata["current_generation_id"] as? String, generationID)
            XCTAssertEqual(editMetadata["prior_value_state"] as? String, "generated")
            XCTAssertEqual(editMetadata["new_value_state"] as? String, "edited")
            XCTAssertTrue(editMetadata["prior_attorney_value"] is NSNull)
            XCTAssertEqual(editMetadata["new_attorney_value"] as? String, editedValue)
            XCTAssertEqual(editMetadata["review_attestation_cleared"] as? Bool, true)
            XCTAssertFalse(editMetadataJSON.contains(fixture.alphaValue),
                "the audit may carry the exact override but must not duplicate frozen generated proof")
            XCTAssertFalse(editMetadataJSON.contains(fixture.excerpts[0]),
                "the audit must not duplicate frozen evidence text")

            let idempotent = try store.caseFileReviews.editCellValue(
                matterID: fixture.matterID,
                projectID: graph.project.id,
                cellID: alphaCellID,
                attorneyValue: "\n\(editedValue)  ",
                editedBy: "attorney:retry-must-not-audit",
                editedAt: editedAt.addingTimeInterval(7)
            )
            XCTAssertEqual(idempotent, edited)
            XCTAssertEqual(
                try store.auditEvents.fetchEvents(
                    relatedTable: CaseFileReviewCellRecord.databaseTableName,
                    relatedID: alphaCellID,
                    eventType: "case_file_review_cell_value_edited"
                ).count,
                1
            )
            XCTAssertEqual(
                try reviewProject(store, projectID: graph.project.id).updatedAt,
                editedAt,
                "an exact edit retry must not move the project timestamp"
            )

            expected = ReviewEditReopenExpectation(
                matterID: fixture.matterID,
                projectID: graph.project.id,
                cellID: alphaCellID,
                neighboringCell: betaBefore,
                generatedValue: fixture.alphaValue,
                editedValue: editedValue,
                generationID: generationID,
                supportState: alphaBefore.supportState,
                frozenPayload: frozenBefore,
                evidenceSourceIDs: evidenceBefore.map(\.frozenOutputSourceID)
            )
        }

        let reopened = try SupraStore(url: databaseURL)
        let reopenedGraph = try XCTUnwrap(reopened.caseFileReviews.fetchProjectGraph(
            matterID: expected.matterID,
            projectID: expected.projectID
        ))
        let reopenedCell = try XCTUnwrap(reopenedGraph.cells.first { $0.id == expected.cellID })
        XCTAssertEqual(reopenedCell.attorneyValue, expected.editedValue)
        XCTAssertEqual(reopenedCell.valueState, "edited")
        XCTAssertEqual(reopenedCell.reviewState, "needs_review")
        XCTAssertNil(reopenedCell.reviewedBy)
        XCTAssertNil(reopenedCell.reviewedAt)
        XCTAssertEqual(reopenedCell.currentGenerationID, expected.generationID)
        XCTAssertEqual(reopenedCell.supportState, expected.supportState)
        let reopenedGeneration = try XCTUnwrap(
            reopenedGraph.generations.first { $0.id == expected.generationID }
        )
        XCTAssertEqual(
            reopenedGeneration.generatedValuesJSON,
            try json([expected.generatedValue])
        )
        XCTAssertNotEqual(
            reopenedGeneration.generatedValuesJSON,
            try json([expected.editedValue]),
            "the attorney override must not replace the frozen generated-value element"
        )
        XCTAssertEqual(
            try XCTUnwrap(reopenedGraph.cells.first { $0.id == expected.neighboringCell.id }),
            expected.neighboringCell,
            "the neighboring row must remain exact after file-backed reopen"
        )
        XCTAssertEqual(reopenedGraph.project.status, "stale")
        XCTAssertEqual(reopenedGraph.project.staleReason, "synthetic_scope_changed")
        XCTAssertEqual(try frozenPayload(reopened, cellID: expected.cellID), expected.frozenPayload)
        XCTAssertEqual(
            try reopened.caseFileReviews.fetchCurrentEvidence(
                matterID: expected.matterID,
                projectID: expected.projectID,
                cellID: expected.cellID
            ).map(\.frozenOutputSourceID),
            expected.evidenceSourceIDs
        )

        let reReviewedAt = restoredAt.addingTimeInterval(-5)
        let reviewedEdit = try reopened.caseFileReviews.markCellReviewed(
            matterID: expected.matterID,
            projectID: expected.projectID,
            cellID: expected.cellID,
            reviewedBy: "attorney:review-edited-1493",
            reviewedAt: reReviewedAt
        )
        let editedReviewAudits = try reopened.auditEvents.fetchEvents(
            relatedTable: CaseFileReviewCellRecord.databaseTableName,
            relatedID: expected.cellID,
            eventType: "case_file_review_cell_reviewed"
        )
        let editedReviewAudit = try XCTUnwrap(
            editedReviewAudits.first { $0.timestamp == reReviewedAt }
        )
        XCTAssertEqual(editedReviewAudit.summary, "Marked one edited Review value as reviewed.")
        XCTAssertNotEqual(editedReviewAudit.summary, "Marked one generated Review value as reviewed.",
            "reviewing an override must not describe it as a generated value")
        let editedReviewMetadata = try jsonObject(
            try XCTUnwrap(editedReviewAudit.metadataJSON)
        )
        XCTAssertEqual(Set(editedReviewMetadata.keys), Set([
            "schema_version", "project_id", "cell_id", "value_state",
        ]))
        XCTAssertEqual(editedReviewMetadata["value_state"] as? String, "edited")
        let reviewedNoOp = try reopened.caseFileReviews.editCellValue(
            matterID: expected.matterID,
            projectID: expected.projectID,
            cellID: expected.cellID,
            attorneyValue: "  \(expected.editedValue)  ",
            editedBy: "attorney:reviewed-retry-must-not-clear",
            editedAt: restoredAt.addingTimeInterval(-2)
        )
        XCTAssertEqual(reviewedNoOp, reviewedEdit,
            "an exact edit retry must retain an existing Reviewed attestation")
        XCTAssertEqual(
            try reviewProject(reopened, projectID: expected.projectID).updatedAt,
            reReviewedAt,
            "an exact reviewed-value retry must not move the project timestamp"
        )
        XCTAssertEqual(
            try reopened.auditEvents.fetchEvents(
                relatedTable: CaseFileReviewCellRecord.databaseTableName,
                relatedID: expected.cellID,
                eventType: "case_file_review_cell_value_edited"
            ).count,
            1
        )
        let restored = try reopened.caseFileReviews.restoreGeneratedCellValue(
            matterID: expected.matterID,
            projectID: expected.projectID,
            cellID: expected.cellID,
            actor: "  attorney:restore-1493  ",
            at: restoredAt
        )
        XCTAssertNil(restored.attorneyValue)
        XCTAssertEqual(restored.valueState, "generated")
        XCTAssertEqual(restored.reviewState, "needs_review")
        XCTAssertNil(restored.reviewedBy)
        XCTAssertNil(restored.reviewedAt)
        XCTAssertEqual(restored.currentGenerationID, expected.generationID)
        XCTAssertEqual(restored.supportState, expected.supportState)
        XCTAssertEqual(try frozenPayload(reopened, cellID: expected.cellID), expected.frozenPayload)
        XCTAssertEqual(try reviewCell(reopened, cellID: expected.neighboringCell.id), expected.neighboringCell)
        let restoredProject = try reviewProject(reopened, projectID: expected.projectID)
        XCTAssertEqual(restoredProject.status, "stale")
        XCTAssertEqual(restoredProject.staleReason, "synthetic_scope_changed")
        XCTAssertEqual(restoredProject.updatedAt, restoredAt)

        let restoreAudits = try reopened.auditEvents.fetchEvents(
            relatedTable: CaseFileReviewCellRecord.databaseTableName,
            relatedID: expected.cellID,
            eventType: "case_file_review_cell_value_restored"
        )
        XCTAssertEqual(restoreAudits.count, 1)
        let restoreAudit = try XCTUnwrap(restoreAudits.first)
        XCTAssertEqual(restoreAudit.matterID, expected.matterID)
        XCTAssertEqual(restoreAudit.timestamp, restoredAt)
        XCTAssertEqual(restoreAudit.actor, "attorney:restore-1493")
        let restoreMetadata = try jsonObject(try XCTUnwrap(restoreAudit.metadataJSON))
        XCTAssertEqual(Set(restoreMetadata.keys), Set([
            "schema_version", "project_id", "cell_id", "current_generation_id",
            "prior_value_state", "new_value_state", "prior_attorney_value",
            "new_attorney_value", "review_attestation_cleared",
        ]))
        XCTAssertEqual(restoreMetadata["project_id"] as? String, expected.projectID)
        XCTAssertEqual(restoreMetadata["cell_id"] as? String, expected.cellID)
        XCTAssertEqual(restoreMetadata["current_generation_id"] as? String, expected.generationID)
        XCTAssertEqual(restoreMetadata["prior_value_state"] as? String, "edited")
        XCTAssertEqual(restoreMetadata["new_value_state"] as? String, "generated")
        XCTAssertEqual(restoreMetadata["prior_attorney_value"] as? String, expected.editedValue)
        XCTAssertTrue(restoreMetadata["new_attorney_value"] is NSNull)
        XCTAssertEqual(restoreMetadata["review_attestation_cleared"] as? Bool, true)

        let idempotentRestore = try reopened.caseFileReviews.restoreGeneratedCellValue(
            matterID: expected.matterID,
            projectID: expected.projectID,
            cellID: expected.cellID,
            actor: "attorney:restore-retry-must-not-audit",
            at: restoredAt.addingTimeInterval(11)
        )
        XCTAssertEqual(idempotentRestore, restored)
        XCTAssertEqual(
            try reopened.auditEvents.fetchEvents(
                relatedTable: CaseFileReviewCellRecord.databaseTableName,
                relatedID: expected.cellID,
                eventType: "case_file_review_cell_value_restored"
            ).count,
            1
        )
        XCTAssertEqual(
            try reviewProject(reopened, projectID: expected.projectID).updatedAt,
            restoredAt,
            "an already-generated restore retry must not move the project timestamp"
        )
    }

    func testTRPSTORE10ValueTransitionsRejectInvalidScopeAndRollBackOnAuditFailure() throws {
        // T-RP-STORE-10 expected RED: Review has no fail-closed value-transition
        // boundary that rejects blank/cross-scope input and rolls the cell and
        // project back when either edit or restore audit insertion fails.
        let store = try SupraStore.inMemory()
        let fixture = try makeExactFixture(store: store, marker: "1531")
        let graph = try store.caseFileReviews.createOrFetchProject(
            matterID: fixture.matterID,
            sourceRunID: fixture.runID,
            title: "Scoped Review 1531",
            actor: "attorney:create-1531",
            at: Date(timeIntervalSince1970: 1_799_001_531)
        )
        let cellID = try valueCellID(store, projectID: graph.project.id, rowKey: fixture.alphaKey)
        _ = try store.caseFileReviews.markCellReviewed(
            matterID: fixture.matterID,
            projectID: graph.project.id,
            cellID: cellID,
            reviewedBy: "attorney:prior-review-1531",
            reviewedAt: Date(timeIntervalSince1970: 1_799_001_537)
        )
        let untouchedCell = try reviewCell(store, cellID: cellID)
        let untouchedProject = try reviewProject(store, projectID: graph.project.id)
        let untouchedFrozen = try frozenPayload(store, cellID: cellID)
        let otherMatter = try store.matters.createMatter(name: "Synthetic foreign Review matter 1531")
        let foreignFixture = try makeExactFixture(store: store, marker: "1543")
        let foreignGraph = try store.caseFileReviews.createOrFetchProject(
            matterID: foreignFixture.matterID,
            sourceRunID: foreignFixture.runID,
            title: "Foreign Review 1543",
            actor: "attorney:create-1543"
        )
        let foreignCellID = try valueCellID(
            store,
            projectID: foreignGraph.project.id,
            rowKey: foreignFixture.alphaKey
        )

        XCTAssertThrowsError(try store.caseFileReviews.editCellValue(
            matterID: fixture.matterID,
            projectID: graph.project.id,
            cellID: cellID,
            attorneyValue: " \n\t ",
            editedBy: "attorney:invalid-value"
        ))
        XCTAssertThrowsError(try store.caseFileReviews.editCellValue(
            matterID: fixture.matterID,
            projectID: graph.project.id,
            cellID: cellID,
            attorneyValue: "INVALID-ACTOR-VALUE-1531",
            editedBy: " \n\t "
        ))
        XCTAssertThrowsError(try store.caseFileReviews.restoreGeneratedCellValue(
            matterID: fixture.matterID,
            projectID: graph.project.id,
            cellID: cellID,
            actor: " \n\t "
        ))
        XCTAssertThrowsError(try store.caseFileReviews.editCellValue(
            matterID: otherMatter.id,
            projectID: graph.project.id,
            cellID: cellID,
            attorneyValue: "CROSS-MATTER-VALUE-1531",
            editedBy: "attorney:cross-matter"
        ))
        XCTAssertThrowsError(try store.caseFileReviews.editCellValue(
            matterID: fixture.matterID,
            projectID: "foreign-project-1531",
            cellID: cellID,
            attorneyValue: "CROSS-PROJECT-VALUE-1531",
            editedBy: "attorney:cross-project"
        ))
        XCTAssertThrowsError(try store.caseFileReviews.editCellValue(
            matterID: fixture.matterID,
            projectID: graph.project.id,
            cellID: foreignCellID,
            attorneyValue: "CROSS-CELL-VALUE-1531",
            editedBy: "attorney:cross-cell"
        ))
        XCTAssertThrowsError(try store.caseFileReviews.restoreGeneratedCellValue(
            matterID: otherMatter.id,
            projectID: graph.project.id,
            cellID: cellID,
            actor: "attorney:cross-matter-restore"
        ))
        XCTAssertEqual(try reviewCell(store, cellID: cellID), untouchedCell)
        XCTAssertEqual(try reviewProject(store, projectID: graph.project.id), untouchedProject)
        XCTAssertEqual(try frozenPayload(store, cellID: cellID), untouchedFrozen)
        XCTAssertEqual(
            try valueTransitionAuditCount(store, cellID: cellID),
            0,
            "invalid and cross-scope calls must not emit value-transition audits"
        )

        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_review_value_edit_audit
                BEFORE INSERT ON audit_events
                WHEN NEW.event_type = 'case_file_review_cell_value_edited'
                BEGIN SELECT RAISE(ABORT, 'synthetic Review edit audit failure'); END
                """)
        }
        XCTAssertThrowsError(try store.caseFileReviews.editCellValue(
            matterID: fixture.matterID,
            projectID: graph.project.id,
            cellID: cellID,
            attorneyValue: "AUDIT-ROLLBACK-EDIT-VALUE-1531",
            editedBy: "attorney:rollback-edit-1531",
            editedAt: Date(timeIntervalSince1970: 1_799_001_559)
        ))
        XCTAssertEqual(try reviewCell(store, cellID: cellID), untouchedCell,
            "a failed edit audit must roll the review attestation and value axes back")
        XCTAssertEqual(try reviewProject(store, projectID: graph.project.id), untouchedProject,
            "a failed edit audit must roll the project timestamp back")
        XCTAssertEqual(try frozenPayload(store, cellID: cellID), untouchedFrozen)
        XCTAssertEqual(try valueTransitionAuditCount(store, cellID: cellID), 0)
        try store.database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER fail_review_value_edit_audit")
        }

        let successfulEdit = try store.caseFileReviews.editCellValue(
            matterID: fixture.matterID,
            projectID: graph.project.id,
            cellID: cellID,
            attorneyValue: "RESTORE-ROLLBACK-CANARY-1531",
            editedBy: "attorney:prepare-restore-1531",
            editedAt: Date(timeIntervalSince1970: 1_799_001_563)
        )
        let reviewedEdit = try store.caseFileReviews.markCellReviewed(
            matterID: fixture.matterID,
            projectID: graph.project.id,
            cellID: cellID,
            reviewedBy: "attorney:review-edit-1531",
            reviewedAt: Date(timeIntervalSince1970: 1_799_001_569)
        )
        XCTAssertEqual(successfulEdit.currentGenerationID, reviewedEdit.currentGenerationID)
        let beforeRestoreFailure = try reviewCell(store, cellID: cellID)
        let projectBeforeRestoreFailure = try reviewProject(store, projectID: graph.project.id)
        let frozenBeforeRestoreFailure = try frozenPayload(store, cellID: cellID)
        try store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_review_value_restore_audit
                BEFORE INSERT ON audit_events
                WHEN NEW.event_type = 'case_file_review_cell_value_restored'
                BEGIN SELECT RAISE(ABORT, 'synthetic Review restore audit failure'); END
                """)
        }
        XCTAssertThrowsError(try store.caseFileReviews.restoreGeneratedCellValue(
            matterID: fixture.matterID,
            projectID: graph.project.id,
            cellID: cellID,
            actor: "attorney:rollback-restore-1531",
            at: Date(timeIntervalSince1970: 1_799_001_577)
        ))
        XCTAssertEqual(try reviewCell(store, cellID: cellID), beforeRestoreFailure,
            "a failed restore audit must retain the edited value and its review attestation")
        XCTAssertEqual(
            try reviewProject(store, projectID: graph.project.id),
            projectBeforeRestoreFailure,
            "a failed restore audit must roll the project timestamp back"
        )
        XCTAssertEqual(try frozenPayload(store, cellID: cellID), frozenBeforeRestoreFailure)
        XCTAssertEqual(
            try store.auditEvents.fetchEvents(
                relatedTable: CaseFileReviewCellRecord.databaseTableName,
                relatedID: cellID,
                eventType: "case_file_review_cell_value_restored"
            ).count,
            0
        )
    }

    private let reviewTables = [
        "case_file_review_projects", "case_file_review_tables", "case_file_review_columns",
        "case_file_review_rows", "case_file_review_cells", "case_file_review_cell_generations",
        "case_file_review_evidence_edges",
    ]

    private func makeExactFixture(
        store: SupraStore,
        marker: String,
        reconciliationJSON override: String? = nil,
        assuranceState: OutputAssuranceState = .corpusComplete
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
        let outputLocators = ranges.map { range in
            "{\"source_kind\":\"text\",\"char_start\":\(range.lowerBound),\"char_end\":\(range.upperBound)}"
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
        let contraryDimensions = VerificationDimensions.complete(overrides: [
            .init(dimension: .propositionSupport, status: .satisfied),
            .init(dimension: .citationResolution, status: .satisfied),
            .init(dimension: .criticalValueFidelity, status: .satisfied),
            .init(
                dimension: .contraryEvidence,
                status: .failed,
                reason: "Synthetic retained contrary evidence.",
                evidence: [VerificationDimensionEvidence(
                    sourceID: revision.id,
                    sourceLabel: document.displayName,
                    locator: outputLocators[2],
                    excerpt: excerpts[2]
                )]
            ),
            .init(dimension: .listCompleteness, status: .satisfied),
            .init(dimension: .lowConfidenceHandling, status: .satisfied),
            .init(dimension: .corpusCoverage, status: .satisfied),
        ])
        let contraryDimensionsObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(contraryDimensions)
        )
        let validationJSON = try json([
            "schema_version": 1,
            "schema_invalid_partition_count": 0,
            "metrics": [
                "expected_count": 2,
                "emitted_count": 2,
                "true_positive_count": 2,
                "recall": 1.0,
                "precision": 1.0,
                "duplicate_count": 0,
                "conflict_count": 0,
                "unexpected_item_keys": [],
            ],
            "verification_dimensions": contraryDimensionsObject,
        ] as [String: Any])
        _ = try store.corpusAnalysis.saveReconciliation(
            matterID: matter.id,
            runID: runID,
            reconciliationJSON: override ?? reconciliation,
            validationResultsJSON: assuranceState == .corpusIncomplete ? validationJSON : nil
        )
        _ = try store.corpusAnalysis.finalizeRun(
            matterID: matter.id, runID: runID, assuranceState: assuranceState,
            assuranceReasons: ["synthetic review fixture"], exclusionsDisclosed: true)

        let sourceSetID = "review-source-set-\(marker)"
        let sourceIDs = ["review-source-alpha-\(marker)", "review-source-beta-\(marker)", "review-source-contrary-\(marker)"]
        let outputSources = zip(sourceIDs.indices, sourceIDs).map { index, id in
            DocumentOutputSourceRecord(
                id: id, sourceSetID: sourceSetID, documentID: document.id, revisionID: revision.id,
                citationLabel: index == 0 ? "S431" : (index == 1 ? "S977" : "C983"),
                locatorJSON: outputLocators[index],
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
            verificationStatus: assuranceState == .corpusIncomplete ? .needsReview : .allSupported,
            verificationVersion: "review-verifier/1",
            verificationResults: [try supportedResult(sourceID: sourceIDs[0])],
            verificationDimensions: assuranceState == .corpusIncomplete
                ? contraryDimensions : supportedDimensions(),
            outputStatus: assuranceState == .corpusIncomplete ? .needsReview : .complete,
            corpusAnalysisRunID: runID, promptBuilderVersion: "review-prompt/1",
            assuranceState: assuranceState
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

    private func reviewCell(_ store: SupraStore, cellID: String) throws -> CaseFileReviewCellRecord {
        try store.database.writer.read { db in
            try XCTUnwrap(CaseFileReviewCellRecord.fetchOne(db, key: cellID))
        }
    }

    private func reviewProject(
        _ store: SupraStore,
        projectID: String
    ) throws -> CaseFileReviewProjectRecord {
        try store.database.writer.read { db in
            try XCTUnwrap(CaseFileReviewProjectRecord.fetchOne(db, key: projectID))
        }
    }

    private func valueTransitionAuditCount(_ store: SupraStore, cellID: String) throws -> Int {
        try store.database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM audit_events
                    WHERE related_table = ? AND related_id = ?
                      AND event_type IN (
                        'case_file_review_cell_value_edited',
                        'case_file_review_cell_value_restored'
                      )
                    """,
                arguments: [CaseFileReviewCellRecord.databaseTableName, cellID]
            ) ?? 0
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

    private func jsonObject(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
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

private struct ReviewEditReopenExpectation {
    let matterID: String
    let projectID: String
    let cellID: String
    let neighboringCell: CaseFileReviewCellRecord
    let generatedValue: String
    let editedValue: String
    let generationID: String
    let supportState: String
    let frozenPayload: [String]
    let evidenceSourceIDs: [String]
}
