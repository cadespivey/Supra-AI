import Foundation
import GRDB
@testable import SupraStore
import XCTest

@MainActor
final class DocumentOutputRevisionBindingTests: XCTestCase {
    func testTMIG03V061BindsNewSourcesAndLeavesHistoricalRevisionUnknown() throws {
        // T-MIG-03 expected RED: v061 and DocumentOutputSourceRecord.revisionID do
        // not exist, so historical sources cannot remain explicitly unbound while
        // new citation writes carry an immutable revision.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertTrue(migrator.migrations.contains("v061_bind_document_output_source_revisions"))
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("T-MIG-03-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let queue = try DatabaseQueue(path: databaseURL.path)
        try migrator.migrate(queue, upTo: "v060_create_document_part_lineage")

        let matters = MattersRepository(writer: queue)
        let library = DocumentLibraryRepository(writer: queue)
        let index = DocumentIndexRepository(writer: queue)
        let revisions = DocumentRevisionRepository(writer: queue)
        let sources = DocumentSourceRepository(writer: queue)
        let matter = try matters.createMatter(name: "Synthetic citation lineage")
        let blob = try library.upsertBlob(DocumentBlobRecord(
            sha256: "citation-lineage-sha",
            byteSize: 1,
            originalExtension: "txt",
            managedRelativePath: "blobs/citation-lineage.txt"
        )).blob
        let document = try library.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "citation-lineage.txt"
        ))
        try index.replaceParts(documentID: document.id, parts: [
            DocumentPagePartRecord(
                documentID: document.id,
                partIndex: 0,
                sourceKind: "text",
                normalizedText: "REVISION-A repeated anchor",
                charCount: 26
            ),
        ])
        let revisionA = try revisions.appendRevision(DocumentPartRevisionRecord(
            documentID: document.id,
            partIndex: 0,
            derivationKey: "citation-revision-a",
            origin: "parser",
            method: "synthetic",
            text: "REVISION-A repeated anchor",
            charCount: 26
        ))
        let historicalSetID = "historical-pre-lineage-set"
        let historicalID = "historical-pre-lineage-source"
        try queue.write { db in
            // Use the v060 column contract directly: the current record type
            // intentionally includes later nullable v066 lineage columns.
            try db.execute(
                sql: """
                INSERT INTO document_source_sets (
                    id, matter_id, status, mode, scope_json, created_at
                ) VALUES (?, ?, 'pending', 'auto_source', '{}', ?)
                """,
                arguments: [historicalSetID, matter.id, Date()]
            )
            try db.execute(
                sql: """
                INSERT INTO document_output_sources (
                    id, source_set_id, document_id, citation_label,
                    locator_json, excerpt, rank, created_at
                ) VALUES (?, ?, ?, 'S1', ?, ?, 0, ?)
                """,
                arguments: [
                    historicalID,
                    historicalSetID,
                    document.id,
                    #"{"source_kind":"text","char_start":0,"char_end":10}"#,
                    "REVISION-A",
                    Date(),
                ]
            )
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let column = try XCTUnwrap(
                db.columns(in: "document_output_sources").first { $0.name == "revision_id" }
            )
            XCTAssertFalse(column.isNotNull)
            let foreignKeys = try Row.fetchAll(
                db,
                sql: "PRAGMA foreign_key_list(document_output_sources)"
            )
            XCTAssertTrue(foreignKeys.contains { row in
                (row["from"] as String) == "revision_id"
                    && (row["table"] as String) == "document_part_revisions"
                    && (row["on_delete"] as String) == "SET NULL"
            })
            let historical = try XCTUnwrap(DocumentOutputSourceRecord.fetchOne(db, key: historicalID))
            XCTAssertNil(historical.revisionID)
            XCTAssertEqual(historical.excerpt, "REVISION-A")
            XCTAssertEqual(
                historical.locatorJSON,
                #"{"source_kind":"text","char_start":0,"char_end":10}"#
            )
        }

        let boundSet = try sources.createSourceSet(matterID: matter.id, mode: .autoSource)
        try sources.addOutputSource(DocumentOutputSourceRecord(
            sourceSetID: boundSet.id,
            documentID: document.id,
            revisionID: revisionA.id,
            citationLabel: "S1",
            locatorJSON: #"{"source_kind":"text","char_start":0,"char_end":10}"#,
            excerpt: "REVISION-A",
            rank: 0
        ))
        XCTAssertEqual(try sources.fetchSources(sourceSetID: boundSet.id).first?.revisionID, revisionA.id)

        let secondBlob = try library.upsertBlob(DocumentBlobRecord(
            sha256: "citation-lineage-sha-2",
            byteSize: 1,
            originalExtension: "txt",
            managedRelativePath: "blobs/citation-lineage-2.txt"
        )).blob
        let secondDocument = try library.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: secondBlob.id,
            displayName: "citation-lineage-2.txt"
        ))
        XCTAssertThrowsError(try sources.addOutputSource(DocumentOutputSourceRecord(
            sourceSetID: boundSet.id,
            documentID: secondDocument.id,
            revisionID: revisionA.id,
            citationLabel: "S2"
        )))

        let otherMatter = try matters.createMatter(name: "Synthetic other matter")
        let otherBlob = try library.upsertBlob(DocumentBlobRecord(
            sha256: "citation-lineage-sha-3",
            byteSize: 1,
            originalExtension: "txt",
            managedRelativePath: "blobs/citation-lineage-3.txt"
        )).blob
        let otherDocument = try library.insertDocument(MatterDocumentRecord(
            matterID: otherMatter.id,
            blobID: otherBlob.id,
            displayName: "citation-lineage-3.txt"
        ))
        XCTAssertThrowsError(try sources.addOutputSource(DocumentOutputSourceRecord(
            sourceSetID: boundSet.id,
            documentID: otherDocument.id,
            citationLabel: "S3"
        )))
    }
}
