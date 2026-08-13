import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// Store boundary for T-DATA-READY-01. Every downstream readiness projection
/// must begin with this one snapshot-derived receipt; raw `ready` strings are
/// deliberately insufficient.
///
/// Expected RED: `SupraStore.documentReadiness`,
/// `DocumentReadinessReceipt`, and `DocumentReadinessRepositoryError` do not
/// exist. The selected test must fail to compile on those missing production
/// APIs before the repository implementation lands.
final class ArchitectureUXTDataReadyRepositoryTests: XCTestCase {
    private enum Wire {
        static let documentID = "record-713"
        static let partID = "part-record-713-7"
        static let revisionID = "revision-record-713-7"
        static let selectionID = "selection-record-713-7"
        static let chunkID = "chunk-record-713-7"
        static let text = "T_DATA_READY_01_WIRE_731"
        static let nextText = "T_DATA_READY_01_WIRE_731_N_PLUS_1_8"
        static let displayName = "T_DATA_READY_01_SOURCE_719.txt"
        static let modelID = "T_DATA_READY_01_MODEL_A_731"
        static let modelRevision = "T_DATA_READY_01_MODEL_REVISION_7"
        static let modelDimension = 7
        static let forbiddenDefault = "DEFAULT-000"
        static let timestamp = Date(timeIntervalSince1970: 1_946_160_731)
    }

    private struct ReadyFixture {
        let store: SupraStore
        let matterID: String
        let blobID: String
    }

    func testReadyReceiptBindsExactPersistedGraphAndInvalidatesOnNewSelection() throws {
        let fixture = try makeReadyFixture()

        let ready: DocumentReadinessReceipt = try fixture.store.documentReadiness
            .fetchReceipt(documentID: Wire.documentID)
        XCTAssertEqual(
            try fixture.store.documentReadiness.fetchReceipt(documentID: Wire.documentID),
            ready,
            "an unchanged persisted graph must derive the same receipt"
        )
        XCTAssertEqual(ready.documentID, Wire.documentID)
        XCTAssertEqual(ready.matterID, fixture.matterID)
        XCTAssertTrue(ready.isBaseReady)
        XCTAssertNil(ready.primaryExclusion)
        XCTAssertEqual(ready.exclusions, [])
        XCTAssertEqual(ready.selectedRevisionIDs, [Wire.revisionID])
        XCTAssertEqual(ready.selectionIDs, [Wire.selectionID])
        XCTAssertEqual(ready.indexedRevisionIDs, [Wire.revisionID])
        XCTAssertEqual(ready.chunkIDs, [Wire.chunkID])
        XCTAssertEqual(ready.chunkerVersion, 2)
        XCTAssertEqual(ready.activeEmbeddingModelID, Wire.modelID)
        XCTAssertEqual(ready.activeEmbeddingModelRevision, Wire.modelRevision)
        XCTAssertEqual(ready.activeEmbeddingDimension, Wire.modelDimension)
        XCTAssertEqual(ready.chunkCount, 1)
        XCTAssertEqual(ready.textIndexedChunkCount, 1)
        XCTAssertEqual(ready.semanticIndexedChunkCount, 1)

        XCTAssertEqual(ready.receiptID.count, 64)
        XCTAssertEqual(ready.receiptID, ready.receiptID.lowercased())
        XCTAssertTrue(ready.receiptID.allSatisfy { $0.isHexDigit })
        for forbiddenContent in [
            Wire.text,
            Wire.displayName,
            Wire.forbiddenDefault,
        ] {
            XCTAssertFalse(
                ready.receiptID.contains(forbiddenContent),
                "the receipt identity must be content-free"
            )
        }

        let revision8 = try fixture.store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: "revision-record-713-8",
                documentID: Wire.documentID,
                partIndex: 0,
                derivationKey: "T_DATA_READY_01_DERIVATION_8",
                origin: "user_edit",
                method: "synthetic_manual",
                text: Wire.nextText,
                charCount: Wire.nextText.count,
                toolchainVersion: "T_DATA_READY_01_TOOLCHAIN_8",
                author: "synthetic-attorney-733",
                reason: "T-DATA-READY-01 N+1 invalidation",
                supersedesRevisionID: Wire.revisionID,
                createdAt: Wire.timestamp.addingTimeInterval(8)
            )
        )
        _ = try fixture.store.documentRevisions.appendSelection(
            DocumentPartSelectionRecord(
                id: "selection-record-713-8",
                documentID: Wire.documentID,
                partIndex: 0,
                selectedRevisionID: revision8.id,
                selectionKey: "T_DATA_READY_01_SELECTION_8",
                selectedBy: "synthetic_attorney",
                decisionJSON: #"{"wire":"T_DATA_READY_01_SELECTION_DECISION_8"}"#,
                supersedesSelectionID: Wire.selectionID,
                createdAt: Wire.timestamp.addingTimeInterval(9)
            )
        )

        // The compatible projection now carries N+1 while the old chunk, FTS,
        // and vector remain. Raw flags intentionally stay green to prove the
        // repository derives freshness from immutable bindings instead.
        let rawDocument = try XCTUnwrap(
            fixture.store.documentLibrary.fetchDocument(id: Wire.documentID)
        )
        let materializedPart = try XCTUnwrap(
            fixture.store.documentIndex.fetchParts(documentID: Wire.documentID).first
        )
        XCTAssertEqual(rawDocument.status, MatterDocumentStatus.ready.rawValue)
        XCTAssertEqual(rawDocument.extractionStatus, DocumentExtractionStatus.extracted.rawValue)
        XCTAssertEqual(rawDocument.indexStatus, DocumentIndexStatus.ready.rawValue)
        XCTAssertEqual(materializedPart.currentRevisionID, revision8.id)
        XCTAssertEqual(materializedPart.normalizedText, Wire.nextText)
        XCTAssertEqual(
            try fixture.store.documentIndex.fetchChunks(documentID: Wire.documentID)
                .map(\.revisionID),
            [Wire.revisionID]
        )

        let stale: DocumentReadinessReceipt = try fixture.store.documentReadiness
            .fetchReceipt(documentID: Wire.documentID)
        XCTAssertFalse(stale.isBaseReady)
        XCTAssertEqual(stale.primaryExclusion, .staleRevision)
        XCTAssertTrue(stale.exclusions.contains(.staleRevision))
        XCTAssertEqual(stale.selectedRevisionIDs, [revision8.id])
        XCTAssertEqual(stale.selectionIDs, ["selection-record-713-8"])
        XCTAssertEqual(stale.indexedRevisionIDs, [Wire.revisionID])
        XCTAssertNotEqual(stale.receiptID, ready.receiptID)
        XCTAssertFalse(stale.receiptID.contains(Wire.nextText))
        XCTAssertFalse(stale.receiptID.contains(Wire.forbiddenDefault))
    }

    func testBatchReadinessUsesTheSameReceiptsAndFailsClosedForMissingOrForeignRows() throws {
        let fixture = try makeReadyFixture()
        let single = try fixture.store.documentReadiness.fetchReceipt(documentID: Wire.documentID)
        XCTAssertEqual(
            try fixture.store.documentReadiness.fetchReceipts(
                matterID: fixture.matterID,
                documentIDs: [Wire.documentID]
            ),
            [single]
        )

        let foreignMatter = try fixture.store.matters.createMatter(
            name: "T-DATA-READY-01 foreign matter 733"
        )
        _ = try fixture.store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                id: "record-733",
                matterID: foreignMatter.id,
                blobID: fixture.blobID,
                displayName: "T_DATA_READY_01_FOREIGN_733.txt",
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.ready.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                importedAt: Wire.timestamp,
                createdAt: Wire.timestamp,
                updatedAt: Wire.timestamp
            )
        )

        XCTAssertThrowsError(
            try fixture.store.documentReadiness.fetchReceipts(
                matterID: fixture.matterID,
                documentIDs: [Wire.documentID, "record-719", "record-733"]
            )
        ) { error in
            XCTAssertEqual(
                error as? DocumentReadinessRepositoryError,
                .batchScopeMismatch(
                    matterID: fixture.matterID,
                    missingDocumentIDs: ["record-719"],
                    foreignDocumentIDs: ["record-733"]
                )
            )
        }
    }

    func testTextIndexRequiresAnExactFTSRowForEveryCurrentChunk() throws {
        let corruptions: [(String, (ReadyFixture) throws -> Void)] = [
            (
                "missing row",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "DELETE FROM document_chunk_fts WHERE chunk_id = ?",
                            arguments: [Wire.chunkID]
                        )
                    }
                }
            ),
            (
                "wrong indexed text",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_chunk_fts SET text = ? WHERE chunk_id = ?",
                            arguments: ["T_DATA_READY_01_WRONG_FTS_733", Wire.chunkID]
                        )
                    }
                }
            ),
        ]

        for (label, corrupt) in corruptions {
            let fixture = try makeReadyFixture()
            try corrupt(fixture)
            let receipt = try fixture.store.documentReadiness.fetchReceipt(
                documentID: Wire.documentID
            )
            XCTAssertFalse(receipt.isBaseReady, label)
            XCTAssertEqual(receipt.primaryExclusion, .textIndexIncomplete, label)
            XCTAssertEqual(receipt.textIndexedChunkCount, 0, label)
        }
    }

    func testSemanticIndexRejectsEveryWrongOrCorruptArtifactBinding() throws {
        let corruptions: [(String, (ReadyFixture) throws -> Void)] = [
            (
                "redundant document id",
                { fixture in
                    _ = try fixture.store.documentLibrary.insertDocument(
                        MatterDocumentRecord(
                            id: "record-737",
                            matterID: fixture.matterID,
                            blobID: fixture.blobID,
                            displayName: "T_DATA_READY_01_REDUNDANT_737.txt",
                            status: MatterDocumentStatus.ready.rawValue,
                            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                            indexStatus: DocumentIndexStatus.ready.rawValue,
                            sourceKind: DocumentSourceKind.text.rawValue,
                            importedAt: Wire.timestamp,
                            createdAt: Wire.timestamp,
                            updatedAt: Wire.timestamp
                        )
                    )
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_chunk_embeddings SET document_id = 'record-737' WHERE chunk_id = ?",
                            arguments: [Wire.chunkID]
                        )
                    }
                }
            ),
            (
                "wrong model id",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_chunk_embeddings SET embedding_model_id = 'T_DATA_READY_01_MODEL_B_733' WHERE chunk_id = ?",
                            arguments: [Wire.chunkID]
                        )
                    }
                }
            ),
            (
                "wrong model revision",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_chunk_embeddings SET model_revision = 'T_DATA_READY_01_MODEL_REVISION_8' WHERE chunk_id = ?",
                            arguments: [Wire.chunkID]
                        )
                    }
                }
            ),
            (
                "wrong dimension",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_chunk_embeddings SET dimension = 8 WHERE chunk_id = ?",
                            arguments: [Wire.chunkID]
                        )
                    }
                }
            ),
            (
                "normalization flag false",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_chunk_embeddings SET normalized = 0 WHERE chunk_id = ?",
                            arguments: [Wire.chunkID]
                        )
                    }
                }
            ),
            (
                "wrong vector byte length",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_chunk_embeddings SET vector = ? WHERE chunk_id = ?",
                            arguments: [Self.floatBlob([1, 0, 0, 0, 0, 0]), Wire.chunkID]
                        )
                    }
                }
            ),
            (
                "nonfinite vector",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_chunk_embeddings SET vector = ? WHERE chunk_id = ?",
                            arguments: [Self.floatBlob([.nan, 0, 0, 0, 0, 0, 0]), Wire.chunkID]
                        )
                    }
                }
            ),
            (
                "non-unit vector",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_chunk_embeddings SET vector = ? WHERE chunk_id = ?",
                            arguments: [Self.floatBlob([0.5, 0, 0, 0, 0, 0, 0]), Wire.chunkID]
                        )
                    }
                }
            ),
        ]

        for (label, corrupt) in corruptions {
            let fixture = try makeReadyFixture()
            try corrupt(fixture)
            let receipt = try fixture.store.documentReadiness.fetchReceipt(
                documentID: Wire.documentID
            )
            XCTAssertFalse(receipt.isBaseReady, label)
            XCTAssertEqual(receipt.primaryExclusion, .semanticIndexIncomplete, label)
            XCTAssertEqual(receipt.semanticIndexedChunkCount, 0, label)
        }
    }

    func testActiveEmbeddingAuthorityRequiresSettingsFlagAgreementAndVerification() throws {
        let cases: [(String, (ReadyFixture) throws -> Void, DocumentReadinessExclusionReason)] = [
            (
                "settings do not identify an active model",
                { fixture in
                    try fixture.store.documentSettings.updateSettings {
                        $0.selectedEmbeddingModelID = nil
                    }
                },
                .activeEmbeddingModelMissing
            ),
            (
                "settings identify a missing model",
                { fixture in
                    try fixture.store.documentSettings.updateSettings {
                        $0.selectedEmbeddingModelID = "T_DATA_READY_01_MISSING_MODEL_739"
                    }
                },
                .activeEmbeddingModelMissing
            ),
            (
                "selected flag disagrees with settings",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_embedding_models SET is_selected = 0 WHERE id = ?",
                            arguments: [Wire.modelID]
                        )
                    }
                },
                .selectionInconsistent
            ),
            (
                "more than one model carries the selected flag",
                { fixture in
                    try fixture.store.documentSettings.upsertEmbeddingModel(
                        DocumentEmbeddingModelRecord(
                            id: "T_DATA_READY_01_MODEL_B_743",
                            repoID: "synthetic/T_DATA_READY_01_MODEL_B_743",
                            localPath: "/synthetic/T_DATA_READY_01_MODEL_B_743",
                            displayName: "T-DATA-READY-01 Model B 743",
                            dimension: Wire.modelDimension,
                            runtimeFamily: "synthetic-wire-7",
                            revision: "T_DATA_READY_01_MODEL_B_REVISION_7",
                            isSelected: true,
                            lastTestLoadAt: Wire.timestamp,
                            lastTestLoadResult: "passed",
                            createdAt: Wire.timestamp,
                            updatedAt: Wire.timestamp
                        )
                    )
                },
                .selectionInconsistent
            ),
            (
                "model verification failed",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_embedding_models SET last_test_load_result = 'failed: T_DATA_READY_01_747' WHERE id = ?",
                            arguments: [Wire.modelID]
                        )
                    }
                },
                .unverified
            ),
            (
                "settings verification time is absent",
                { fixture in
                    try fixture.store.documentSettings.updateSettings {
                        $0.embeddingModelLastTestedAt = nil
                    }
                },
                .unverified
            ),
        ]

        for (label, mutate, expectedReason) in cases {
            let fixture = try makeReadyFixture()
            try mutate(fixture)
            let receipt = try fixture.store.documentReadiness.fetchReceipt(
                documentID: Wire.documentID
            )
            XCTAssertFalse(receipt.isBaseReady, label)
            XCTAssertEqual(receipt.primaryExclusion, expectedReason, label)
        }
    }

    func testPrimaryExclusionUsesDeterministicSafetyPrecedence() throws {
        let cases: [(String, (ReadyFixture) throws -> Void, DocumentReadinessExclusionReason)] = [
            (
                "deleted before extraction failure",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE matter_documents SET deleted_at = ?, status = 'deleted', extraction_status = 'failed' WHERE id = ?",
                            arguments: [Wire.timestamp, Wire.documentID]
                        )
                    }
                },
                .deleted
            ),
            (
                "extraction failure before processing failure",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE matter_documents SET extraction_status = 'failed', status = 'failed' WHERE id = ?",
                            arguments: [Wire.documentID]
                        )
                    }
                },
                .extractionFailed
            ),
            (
                "review before incomplete extraction",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE matter_documents SET status = 'needs_review', extraction_status = 'pending' WHERE id = ?",
                            arguments: [Wire.documentID]
                        )
                    }
                },
                .reviewRequired
            ),
            (
                "incomplete extraction before incoherent selection",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE matter_documents SET extraction_status = 'pending' WHERE id = ?",
                            arguments: [Wire.documentID]
                        )
                        try database.execute(
                            sql: "UPDATE document_pages_parts SET current_selection_id = NULL WHERE id = ?",
                            arguments: [Wire.partID]
                        )
                    }
                },
                .extractionIncomplete
            ),
            (
                "incoherent selection before failed text index",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_pages_parts SET current_selection_id = NULL WHERE id = ?",
                            arguments: [Wire.partID]
                        )
                        try database.execute(
                            sql: "UPDATE matter_documents SET index_status = 'failed' WHERE id = ?",
                            arguments: [Wire.documentID]
                        )
                    }
                },
                .selectedRevisionIncoherent
            ),
            (
                "failed text index before stale revision",
                { fixture in
                    try Self.appendNextSelection(fixture)
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE matter_documents SET index_status = 'failed' WHERE id = ?",
                            arguments: [Wire.documentID]
                        )
                    }
                },
                .textIndexFailed
            ),
            (
                "stale revision before incomplete text index",
                { fixture in
                    try Self.appendNextSelection(fixture)
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "DELETE FROM document_chunk_fts WHERE chunk_id = ?",
                            arguments: [Wire.chunkID]
                        )
                    }
                },
                .staleRevision
            ),
            (
                "incomplete text index before missing active model",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "DELETE FROM document_chunk_fts WHERE chunk_id = ?",
                            arguments: [Wire.chunkID]
                        )
                        try database.execute(
                            sql: "UPDATE document_intelligence_settings SET selected_embedding_model_id = NULL WHERE id = 'default'"
                        )
                    }
                },
                .textIndexIncomplete
            ),
            (
                "missing active model before selected-flag drift",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_intelligence_settings SET selected_embedding_model_id = 'T_DATA_READY_01_MISSING_MODEL_751' WHERE id = 'default'"
                        )
                        try database.execute(
                            sql: "UPDATE document_embedding_models SET is_selected = 0 WHERE id = ?",
                            arguments: [Wire.modelID]
                        )
                    }
                },
                .activeEmbeddingModelMissing
            ),
            (
                "selected-flag drift before failed verification",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_embedding_models SET is_selected = 0, last_test_load_result = 'failed: T_DATA_READY_01_757' WHERE id = ?",
                            arguments: [Wire.modelID]
                        )
                    }
                },
                .selectionInconsistent
            ),
            (
                "failed verification before corrupt semantic vector",
                { fixture in
                    try fixture.store.database.writer.write { database in
                        try database.execute(
                            sql: "UPDATE document_embedding_models SET last_test_load_result = 'failed: T_DATA_READY_01_761' WHERE id = ?",
                            arguments: [Wire.modelID]
                        )
                        try database.execute(
                            sql: "UPDATE document_chunk_embeddings SET vector = ? WHERE chunk_id = ?",
                            arguments: [Self.floatBlob([0.5, 0, 0, 0, 0, 0, 0]), Wire.chunkID]
                        )
                    }
                },
                .unverified
            ),
        ]

        for (label, mutate, expectedReason) in cases {
            let fixture = try makeReadyFixture()
            try mutate(fixture)
            let receipt = try fixture.store.documentReadiness.fetchReceipt(
                documentID: Wire.documentID
            )
            XCTAssertEqual(receipt.primaryExclusion, expectedReason, label)
        }
    }

    private func makeReadyFixture() throws -> ReadyFixture {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "T-DATA-READY-01 matter 709")
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                id: "blob-record-713",
                sha256: String(repeating: "7", count: 64),
                byteSize: Wire.text.utf8.count,
                originalExtension: "txt",
                managedRelativePath: "blobs/T_DATA_READY_01_WIRE_731.txt",
                mimeType: "text/plain",
                integrityStatus: DocumentBlobIntegrityStatus.verified.rawValue,
                verifiedAt: Wire.timestamp,
                createdAt: Wire.timestamp
            )
        ).blob
        _ = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                id: Wire.documentID,
                matterID: matter.id,
                blobID: blob.id,
                displayName: Wire.displayName,
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.ready.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractionMethod: "T_DATA_READY_01_EXTRACTOR_7",
                extractedTextChecksum: String(repeating: "3", count: 64),
                pagePartCount: 1,
                importedAt: Wire.timestamp,
                createdAt: Wire.timestamp,
                updatedAt: Wire.timestamp
            )
        )
        try store.documentIndex.replaceParts(
            documentID: Wire.documentID,
            parts: [
                DocumentPagePartRecord(
                    id: Wire.partID,
                    documentID: Wire.documentID,
                    partIndex: 0,
                    sourceKind: DocumentSourceKind.text.rawValue,
                    normalizedText: Wire.text,
                    charCount: Wire.text.count,
                    createdAt: Wire.timestamp,
                    updatedAt: Wire.timestamp
                ),
            ]
        )
        _ = try store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: Wire.revisionID,
                documentID: Wire.documentID,
                partIndex: 0,
                derivationKey: "T_DATA_READY_01_DERIVATION_7",
                origin: "parser",
                method: "synthetic_exact_text",
                text: Wire.text,
                charCount: Wire.text.count,
                toolchainVersion: "T_DATA_READY_01_TOOLCHAIN_7",
                createdAt: Wire.timestamp
            )
        )
        _ = try store.documentRevisions.appendSelection(
            DocumentPartSelectionRecord(
                id: Wire.selectionID,
                documentID: Wire.documentID,
                partIndex: 0,
                selectedRevisionID: Wire.revisionID,
                selectionKey: "T_DATA_READY_01_SELECTION_7",
                selectedBy: "synthetic_policy",
                policyVersion: 7,
                decisionJSON: #"{"wire":"T_DATA_READY_01_SELECTION_DECISION_7"}"#,
                createdAt: Wire.timestamp
            )
        )
        try store.documentIndex.replaceChunks(
            documentID: Wire.documentID,
            chunks: [
                DocumentChunkRecord(
                    id: Wire.chunkID,
                    documentID: Wire.documentID,
                    pagePartID: Wire.partID,
                    revisionID: Wire.revisionID,
                    chunkerVersion: 2,
                    chunkIndex: 0,
                    sourceKind: DocumentSourceKind.text.rawValue,
                    charStart: 0,
                    charEnd: Wire.text.count,
                    normalizedText: Wire.text,
                    displayExcerpt: Wire.text,
                    tokenCount: 7,
                    createdAt: Wire.timestamp,
                    updatedAt: Wire.timestamp
                ),
            ]
        )

        _ = try store.documentSettings.loadSettings()
        try store.documentSettings.upsertEmbeddingModel(
            DocumentEmbeddingModelRecord(
                id: Wire.modelID,
                repoID: "synthetic/T_DATA_READY_01_MODEL_A_731",
                localPath: "/synthetic/T_DATA_READY_01_MODEL_A_731",
                displayName: "T-DATA-READY-01 Model A 731",
                dimension: Wire.modelDimension,
                runtimeFamily: "synthetic-wire-7",
                revision: Wire.modelRevision,
                isDefault: false,
                isSelected: false,
                lastTestLoadAt: Wire.timestamp,
                lastTestLoadResult: "passed",
                createdAt: Wire.timestamp,
                updatedAt: Wire.timestamp
            )
        )
        try store.documentSettings.selectEmbeddingModel(id: Wire.modelID)
        try store.documentSettings.updateSettings {
            $0.embeddingModelLastTestedAt = Wire.timestamp
            $0.chunkerVersion = 2
        }

        let unitVector = Self.floatBlob([1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(unitVector.count, 28)
        try store.documentIndex.upsertEmbedding(
            DocumentChunkEmbeddingRecord(
                id: "embedding-record-713-7",
                chunkID: Wire.chunkID,
                documentID: Wire.documentID,
                embeddingModelID: Wire.modelID,
                modelDisplayName: "T-DATA-READY-01 Model A 731",
                modelRevision: Wire.modelRevision,
                dimension: Wire.modelDimension,
                normalized: true,
                vector: unitVector,
                createdAt: Wire.timestamp
            )
        )
        return ReadyFixture(store: store, matterID: matter.id, blobID: blob.id)
    }

    private static func appendNextSelection(_ fixture: ReadyFixture) throws {
        _ = try fixture.store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: "revision-record-713-8",
                documentID: Wire.documentID,
                partIndex: 0,
                derivationKey: "T_DATA_READY_01_DERIVATION_8",
                origin: "user_edit",
                method: "synthetic_manual",
                text: Wire.nextText,
                charCount: Wire.nextText.count,
                toolchainVersion: "T_DATA_READY_01_TOOLCHAIN_8",
                author: "synthetic-attorney-733",
                reason: "T-DATA-READY-01 precedence probe",
                supersedesRevisionID: Wire.revisionID,
                createdAt: Wire.timestamp.addingTimeInterval(8)
            )
        )
        _ = try fixture.store.documentRevisions.appendSelection(
            DocumentPartSelectionRecord(
                id: "selection-record-713-8",
                documentID: Wire.documentID,
                partIndex: 0,
                selectedRevisionID: "revision-record-713-8",
                selectionKey: "T_DATA_READY_01_SELECTION_8",
                selectedBy: "synthetic_attorney",
                decisionJSON: #"{"wire":"T_DATA_READY_01_SELECTION_DECISION_8"}"#,
                supersedesSelectionID: Wire.selectionID,
                createdAt: Wire.timestamp.addingTimeInterval(9)
            )
        )
    }

    private static func floatBlob(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * MemoryLayout<Float>.size)
        for value in values {
            var littleEndianBits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndianBits) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }
}
