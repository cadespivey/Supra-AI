import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

final class DocumentClassificationLineageMigrationTests: XCTestCase {
    func testTMIG10V068CreatesAppendOnlyClassificationHistoryWithoutFabricatingLegacyLineage() throws {
        // T-MIG-10 expected RED: v068 and the append-only classification
        // repository/record do not exist; only the legacy mutable JSON exists.
        let migrator = SupraMigrator.makeMigrator()
        XCTAssertTrue(migrator.migrations.contains("v068_add_document_classification_lineage"))
        let queue = try DatabaseQueue()
        try migrator.migrate(queue, upTo: "v067_add_output_generation_lineage")

        let matters = MattersRepository(writer: queue)
        let library = DocumentLibraryRepository(writer: queue)
        let index = DocumentIndexRepository(writer: queue)
        let revisions = DocumentRevisionRepository(writer: queue)
        let matter = try matters.createMatter(name: "Synthetic v068 classification matter")
        let blob = try library.upsertBlob(DocumentBlobRecord(
            sha256: "classification-v068-sha",
            byteSize: 67,
            originalExtension: "txt",
            managedRelativePath: "classification/v068.txt"
        )).blob
        let document = try library.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "legacy-classification.txt",
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        ))
        let legacyJSON = #"{"primary_tag":"correspondence","confidence":0.67}"#
        try library.updateClassification(
            documentID: document.id,
            classificationMetadataJSON: legacyJSON
        )
        let tag = try library.createTag(matterID: matter.id, name: "User-authored tag", color: "#675849")
        try library.assignTag(tagID: tag.id, documentID: document.id)
        try index.replaceParts(documentID: document.id, parts: [
            DocumentPagePartRecord(
                documentID: document.id,
                partIndex: 0,
                sourceKind: "text",
                normalizedText: "CLASSIFICATION-REVISION-NONDEFAULT",
                charCount: 34
            ),
        ])
        let revision = try revisions.appendRevision(DocumentPartRevisionRecord(
            documentID: document.id,
            partIndex: 0,
            derivationKey: "classification-v068-revision",
            origin: "parser",
            method: "synthetic",
            text: "CLASSIFICATION-REVISION-NONDEFAULT",
            charCount: 34
        ))

        try migrator.migrate(queue)
        try queue.read { db in
            XCTAssertEqual(
                try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").last,
                "v069_add_verification_dimensions"
            )
            XCTAssertEqual(Set(try db.columns(in: "document_classifications").map(\.name)), Set([
                "id", "matter_id", "document_id", "classification_key",
                "input_revision_ids_json", "input_checksum", "model_repository",
                "model_revision", "prompt_version", "sampling_strategy", "sampling_version",
                "primary_category", "secondary_categories_json", "confidence_json",
                "calibration_version", "abstained", "abstention_reason",
                "evidence_spans_json", "warnings_json", "created_at",
            ]))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document_classifications"), 0)
            XCTAssertNotNil(try db.indexes(on: "document_classifications").first {
                $0.name == "idx_document_classifications_identity" && $0.isUnique
            })
            XCTAssertNotNil(try db.indexes(on: "document_classifications").first {
                $0.name == "idx_document_classifications_latest"
            })
        }

        XCTAssertEqual(try library.fetchDocument(id: document.id)?.classificationMetadataJSON, legacyJSON)
        XCTAssertEqual(try library.fetchTags(documentID: document.id).map(\.id), [tag.id])

        let classifications = DocumentClassificationRepository(writer: queue)
        let first = DocumentClassificationRecord(
            matterID: matter.id,
            documentID: document.id,
            classificationKey: "classification-attempt-nondefault",
            inputRevisionIDsJSON: try JSONCoding.encode([revision.id]),
            inputChecksum: "classification-input-checksum-nondefault",
            modelRepository: "synthetic/classifier",
            modelRevision: "classifier-revision-17",
            promptVersion: "classification-prompt-v2",
            samplingStrategy: "head_tail_per_part",
            samplingVersion: 2,
            primaryCategory: "financial_records",
            secondaryCategoriesJSON: try JSONCoding.encode(["evidence_and_exhibits"]),
            confidenceJSON: #"{"raw_confidence":0.91,"abstention_floor":0.67,"raw_suggested_primary_category":"financial_records"}"#,
            calibrationVersion: "classification-calibration-v2",
            abstained: false,
            evidenceSpansJSON: "[{\"revision_id\":\"\(revision.id)\",\"char_start\":0,\"char_end\":14,\"excerpt\":\"CLASSIFICATION\"}]",
            warningsJSON: try JSONCoding.encode(["SYNTHETIC-WARNING-NONDEFAULT"])
        )
        let inserted = try classifications.append(first)
        XCTAssertEqual(try classifications.fetchLatest(matterID: matter.id, documentID: document.id)?.id, inserted.id)
        XCTAssertEqual(try classifications.fetchHistory(matterID: matter.id, documentID: document.id).map(\.id), [inserted.id])

        let retried = try classifications.append(first)
        XCTAssertEqual(retried.id, inserted.id, "the same stable attempt key is idempotent")
        var collision = first
        collision.inputChecksum = "DIFFERENT-IMMUTABLE-CHECKSUM"
        XCTAssertThrowsError(try classifications.append(collision)) { error in
            XCTAssertEqual(
                error as? DocumentClassificationRepositoryError,
                .classificationKeyCollision(first.classificationKey)
            )
        }
        XCTAssertThrowsError(try queue.write { db in
            try db.execute(
                sql: "UPDATE document_classifications SET warnings_json = '[]' WHERE id = ?",
                arguments: [inserted.id]
            )
        })
        XCTAssertEqual(try library.fetchTags(documentID: document.id).map(\.id), [tag.id])
    }
}
