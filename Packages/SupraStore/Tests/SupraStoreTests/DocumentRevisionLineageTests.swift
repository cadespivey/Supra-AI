import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class DocumentRevisionLineageTests: XCTestCase {
    private func makeStore() throws -> SupraStore {
        try SupraStore.inMemory()
    }

    func testTREV01RevisionCandidatesAreAppendOnlyAndRetryIdempotent() throws {
        // T-REV-01 expected RED: DocumentPartRevisionRecord and the
        // documentRevisions repository do not exist before v060.
        let store = try makeStore()
        let fixture = try makePartFixture(store: store, edited: false)

        let embedded = DocumentPartRevisionRecord(
            id: "revision-embedded-alpha",
            documentID: fixture.document.id,
            partIndex: fixture.part.partIndex,
            derivationKey: "embedded-key-alpha",
            origin: "embedded_pdf",
            method: "pdfkit",
            text: "EMBEDDED-ALPHA",
            charCount: "EMBEDDED-ALPHA".count,
            toolchainVersion: "test-toolchain-alpha"
        )
        let first = try store.documentRevisions.appendRevision(embedded)
        let replay = try store.documentRevisions.appendRevision(embedded)
        XCTAssertEqual(replay.id, first.id, "a retry with the same derivation key must reuse the immutable row")

        _ = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            id: "revision-ocr-beta",
            documentID: fixture.document.id,
            partIndex: fixture.part.partIndex,
            derivationKey: "ocr-key-beta",
            origin: "ocr",
            method: "vision-ocr-pdf",
            text: "OCR-BETA-DISTINCT",
            charCount: "OCR-BETA-DISTINCT".count,
            ocrConfidence: 0.91,
            boundingBoxesJSON: #"[{"token":"OCR-BETA"}]"#,
            toolchainVersion: "test-toolchain-alpha"
        ))

        var revisions = try store.documentRevisions.fetchRevisions(
            documentID: fixture.document.id,
            partIndex: fixture.part.partIndex
        )
        XCTAssertEqual(revisions.map(\.text), ["EMBEDDED-ALPHA", "OCR-BETA-DISTINCT"])
        XCTAssertEqual(Set(revisions.map(\.origin)), ["embedded_pdf", "ocr"])

        _ = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            id: "revision-parser-gamma",
            documentID: fixture.document.id,
            partIndex: fixture.part.partIndex,
            derivationKey: "parser-key-gamma",
            origin: "parser",
            method: "pdfkit-retry",
            text: "PARSER-GAMMA-NEW-CANDIDATE",
            charCount: "PARSER-GAMMA-NEW-CANDIDATE".count
        ))
        revisions = try store.documentRevisions.fetchRevisions(
            documentID: fixture.document.id,
            partIndex: fixture.part.partIndex
        )
        XCTAssertEqual(revisions.count, 3, "a genuinely new derivation key must append")

        XCTAssertThrowsError(try store.database.writer.write { db in
            try db.execute(
                sql: "UPDATE document_part_revisions SET text = 'MUTATED' WHERE id = ?",
                arguments: [embedded.id]
            )
        }, "revision rows must reject in-place updates")
        XCTAssertThrowsError(try store.database.writer.write { db in
            try db.execute(sql: "DELETE FROM document_part_revisions WHERE id = ?", arguments: [embedded.id])
        }, "revision rows must reject deletion while their document exists")
        XCTAssertEqual(
            try store.documentRevisions.fetchRevisions(
                documentID: fixture.document.id,
                partIndex: fixture.part.partIndex
            ).first?.text,
            "EMBEDDED-ALPHA"
        )
    }

    func testTREV02SelectionsAppendAndMaterializeTheLatestRevision() throws {
        // T-REV-02 expected RED: selection history, current pointers, and chunk
        // revision bindings are all absent before v060.
        let store = try makeStore()
        let fixture = try makePartFixture(store: store, edited: false)
        let parser = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            id: "revision-parser-default",
            documentID: fixture.document.id,
            partIndex: 0,
            derivationKey: "parser-default-key",
            origin: "parser",
            method: "plain-text",
            text: "PARSER-DEFAULT-TEXT",
            charCount: "PARSER-DEFAULT-TEXT".count
        ))
        let ocr = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            id: "revision-ocr-nondefault",
            documentID: fixture.document.id,
            partIndex: 0,
            derivationKey: "ocr-nondefault-key",
            origin: "ocr",
            method: "vision-ocr-pdf",
            text: "OCR-NONDEFAULT-TEXT",
            charCount: "OCR-NONDEFAULT-TEXT".count,
            ocrConfidence: 0.88
        ))

        let firstSelection = try store.documentRevisions.appendSelection(DocumentPartSelectionRecord(
            id: "selection-ocr-first",
            documentID: fixture.document.id,
            partIndex: 0,
            selectedRevisionID: ocr.id,
            selectionKey: "selection-key-ocr",
            selectedBy: "policy",
            policyVersion: 0,
            decisionJSON: #"{"rule":"nondefault-ocr-first"}"#
        ))
        _ = try store.documentRevisions.appendSelection(firstSelection)
        let secondSelection = try store.documentRevisions.appendSelection(DocumentPartSelectionRecord(
            id: "selection-parser-second",
            documentID: fixture.document.id,
            partIndex: 0,
            selectedRevisionID: parser.id,
            selectionKey: "selection-key-parser",
            selectedBy: "user",
            decisionJSON: #"{"rule":"explicit-parser-reselection"}"#,
            supersedesSelectionID: firstSelection.id
        ))

        let selections = try store.documentRevisions.fetchSelections(
            documentID: fixture.document.id,
            partIndex: 0
        )
        XCTAssertEqual(selections.map(\.id), [firstSelection.id, secondSelection.id])
        XCTAssertEqual(selections.last?.supersedesSelectionID, firstSelection.id)

        let selectedPart = try XCTUnwrap(store.documentIndex.fetchParts(documentID: fixture.document.id).first)
        XCTAssertEqual(selectedPart.currentRevisionID, parser.id)
        XCTAssertEqual(selectedPart.currentSelectionID, secondSelection.id)
        XCTAssertEqual(selectedPart.normalizedText, "PARSER-DEFAULT-TEXT")
        XCTAssertEqual(selectedPart.charCount, "PARSER-DEFAULT-TEXT".count)

        try store.documentIndex.replaceChunks(documentID: fixture.document.id, chunks: [
            DocumentChunkRecord(
                id: "chunk-bound-to-parser-revision",
                documentID: fixture.document.id,
                pagePartID: selectedPart.id,
                revisionID: selectedPart.currentRevisionID,
                chunkIndex: 0,
                sourceKind: selectedPart.sourceKind,
                normalizedText: selectedPart.normalizedText
            )
        ])
        XCTAssertEqual(
            try store.documentIndex.fetchChunks(documentID: fixture.document.id).first?.revisionID,
            parser.id
        )
    }

    func testTMIG02V060BackfillsLegacyAndEditedPartsWithoutChangingText() throws {
        // T-MIG-02 expected RED: v060 is not registered, so neither lineage
        // table nor the part/chunk pointers exist after upgrading v059.
        let queue = try DatabaseQueue()
        let migrator = SupraMigrator.makeMigrator()
        try migrator.migrate(queue, upTo: "v059_create_document_import_sources")

        let matter = try MattersRepository(writer: queue).createMatter(name: "Synthetic v060 lineage upgrade")
        let library = DocumentLibraryRepository(writer: queue)
        let legacyBlob = try library.upsertBlob(DocumentBlobRecord(
            sha256: "legacy-lineage-blob",
            byteSize: 1,
            originalExtension: "txt",
            managedRelativePath: "blobs/legacy-lineage.txt"
        )).blob
        let editedBlob = try library.upsertBlob(DocumentBlobRecord(
            sha256: "edited-lineage-blob",
            byteSize: 1,
            originalExtension: "txt",
            managedRelativePath: "blobs/edited-lineage.txt"
        )).blob
        let legacyDocument = try library.insertDocument(MatterDocumentRecord(
            id: "legacy-lineage-document",
            matterID: matter.id,
            blobID: legacyBlob.id,
            displayName: "legacy.txt",
            extractionMethod: "plain-text@toolchain:legacy-v1"
        ))
        let editedDocument = try library.insertDocument(MatterDocumentRecord(
            id: "edited-lineage-document",
            matterID: matter.id,
            blobID: editedBlob.id,
            displayName: "edited.txt",
            extractionMethod: "plain-text@toolchain:legacy-v1",
            hasUserEditedText: true
        ))
        let fixedDate = Date(timeIntervalSinceReferenceDate: 4242)
        try queue.write { db in
            for (partID, documentID, text) in [
                ("legacy-part", legacyDocument.id, "LEGACY-BYTES-UNCHANGED"),
                ("edited-part", editedDocument.id, "EDITED-BYTES-UNCHANGED"),
            ] {
                try db.execute(
                    sql: """
                    INSERT INTO document_pages_parts (
                        id, document_id, part_index, source_kind, normalized_text,
                        char_count, created_at, updated_at
                    ) VALUES (?, ?, 0, 'text', ?, ?, ?, ?)
                    """,
                    arguments: [partID, documentID, text, text.count, fixedDate, fixedDate]
                )
                try db.execute(
                    sql: """
                    INSERT INTO document_chunks (
                        id, document_id, page_part_id, chunk_index, source_kind,
                        normalized_text, created_at, updated_at
                    ) VALUES (?, ?, ?, 0, 'text', ?, ?, ?)
                    """,
                    arguments: ["chunk-\(partID)", documentID, partID, text, fixedDate, fixedDate]
                )
            }
        }

        try migrator.migrate(queue)
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("document_part_revisions"))
            XCTAssertTrue(try db.tableExists("document_part_selections"))
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT p.id, p.normalized_text, p.current_revision_id, p.current_selection_id,
                       r.origin, r.text AS revision_text, s.selected_by,
                       c.revision_id AS chunk_revision_id
                FROM document_pages_parts p
                JOIN document_part_revisions r ON r.id = p.current_revision_id
                JOIN document_part_selections s ON s.id = p.current_selection_id
                JOIN document_chunks c ON c.page_part_id = p.id
                ORDER BY p.id
                """
            )
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.map { $0["normalized_text"] as String }, ["EDITED-BYTES-UNCHANGED", "LEGACY-BYTES-UNCHANGED"])
            XCTAssertEqual(rows.map { $0["revision_text"] as String }, ["EDITED-BYTES-UNCHANGED", "LEGACY-BYTES-UNCHANGED"])
            XCTAssertEqual(rows.map { $0["origin"] as String }, ["user_edit", "legacy_import"])
            XCTAssertEqual(Set(rows.map { $0["selected_by"] as String }), ["migration"])
            XCTAssertTrue(rows.allSatisfy { ($0["current_revision_id"] as String?) == ($0["chunk_revision_id"] as String?) })
            XCTAssertTrue(rows.allSatisfy { ($0["current_selection_id"] as String?).map { !$0.isEmpty } ?? false })
        }

        try migrator.migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document_part_revisions"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document_part_selections"), 2)
        }
    }

    private func makePartFixture(
        store: SupraStore,
        edited: Bool
    ) throws -> (document: MatterDocumentRecord, part: DocumentPagePartRecord) {
        let matter = try store.matters.createMatter(name: "Synthetic immutable lineage")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: UUID().uuidString,
            byteSize: 1,
            originalExtension: "txt",
            managedRelativePath: "blobs/\(UUID().uuidString).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "lineage.txt",
            hasUserEditedText: edited
        ))
        let part = DocumentPagePartRecord(
            id: "fixture-part-0",
            documentID: document.id,
            partIndex: 0,
            sourceKind: "text",
            normalizedText: "PRE-LINEAGE-MATERIALIZED",
            charCount: "PRE-LINEAGE-MATERIALIZED".count
        )
        try store.documentIndex.replaceParts(documentID: document.id, parts: [part])
        return (document, part)
    }
}
