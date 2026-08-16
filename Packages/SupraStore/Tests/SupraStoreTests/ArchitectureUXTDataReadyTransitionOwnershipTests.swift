import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// WP-1.2 transition-ownership RED. A new selected revision and an active
/// embedding-model identity both change canonical readiness. Their related rows
/// and invalidation flags must therefore cross one Store transaction boundary.
///
/// Expected RED: `DocumentRevisionSelectionTransitionCommand`,
/// `commitSelectionAndInvalidateIndex`,
/// `DocumentVerifiedEmbeddingModelSelectionCommand`, and
/// `activateVerifiedEmbeddingModel` do not exist. Current callers compose these
/// writes across repositories and active-model selection accepts an absent or
/// unverified model.
final class ArchitectureUXTDataReadyTransitionOwnershipTests: XCTestCase {
    private enum RevisionWriteBoundary: String, CaseIterable {
        case revision = "revision-8"
        case selection = "selection-8"
        case partProjection = "part-projection-8"
        case staleInvalidation = "stale-invalidation-8"
    }

    private enum ModelWriteBoundary: String, CaseIterable {
        case selectedFlags = "selected-flags-8"
        case settingsIdentity = "settings-identity-8"
    }

    func testRevisionSelectionAndStaleInvalidationRollbackAtEveryNPlusOneWrite() throws {
        for boundary in RevisionWriteBoundary.allCases {
            let fixture = try ReadinessTransitionFixture.makeReady()
            let before = try fixture.snapshot()
            try installRevisionFailure(boundary, fixture: fixture)

            XCTAssertThrowsError(
                try fixture.store.documentRevisions.commitSelectionAndInvalidateIndex(
                    fixture.revisionTransitionCommand()
                ),
                "the synthetic \(boundary.rawValue) write must fail inside the Store command"
            )

            XCTAssertEqual(
                try fixture.snapshot(),
                before,
                "revision, selection, part projection, stale flags, and old readiness must all roll back at \(boundary.rawValue)"
            )
            XCTAssertNil(
                try fixture.store.documentRevisions.fetchRevision(
                    id: ReadinessTransitionFixture.Wire.revision8ID
                )
            )
            XCTAssertFalse(
                String(decoding: before.persistedGraph, as: UTF8.self)
                    .contains(ReadinessTransitionFixture.Wire.forbiddenDefault)
            )
        }
    }

    func testRevisionSelectionSuccessReturnsTheSameCanonicalStaleReceipt() throws {
        let fixture = try ReadinessTransitionFixture.makeReady()
        let oldReady = try fixture.store.documentReadiness.fetchReceipt(
            documentID: ReadinessTransitionFixture.Wire.documentID
        )

        let transition: DocumentRevisionSelectionTransitionReceipt = try fixture.store
            .documentRevisions.commitSelectionAndInvalidateIndex(
                fixture.revisionTransitionCommand()
            )
        let document = try XCTUnwrap(
            fixture.store.documentLibrary.fetchDocument(
                id: ReadinessTransitionFixture.Wire.documentID
            )
        )
        let part = try XCTUnwrap(
            fixture.store.documentIndex.fetchParts(
                documentID: ReadinessTransitionFixture.Wire.documentID
            ).first { $0.id == ReadinessTransitionFixture.Wire.firstPartID }
        )
        let canonical = try fixture.store.documentReadiness.fetchReceipt(
            documentID: ReadinessTransitionFixture.Wire.documentID
        )

        XCTAssertEqual(transition.documentID, ReadinessTransitionFixture.Wire.documentID)
        XCTAssertEqual(transition.partID, ReadinessTransitionFixture.Wire.firstPartID)
        XCTAssertEqual(transition.revisionID, ReadinessTransitionFixture.Wire.revision8ID)
        XCTAssertEqual(transition.selectionID, ReadinessTransitionFixture.Wire.selection8ID)
        XCTAssertEqual(transition.readinessReceipt, canonical)
        XCTAssertEqual(part.currentRevisionID, ReadinessTransitionFixture.Wire.revision8ID)
        XCTAssertEqual(part.currentSelectionID, ReadinessTransitionFixture.Wire.selection8ID)
        XCTAssertEqual(part.normalizedText, ReadinessTransitionFixture.Wire.firstText8)
        XCTAssertTrue(document.hasUserEditedText)
        XCTAssertEqual(document.extractionStatus, DocumentExtractionStatus.edited.rawValue)
        XCTAssertEqual(document.indexStatus, DocumentIndexStatus.stale.rawValue)
        XCTAssertNil(document.classificationMetadataJSON)
        XCTAssertFalse(canonical.isBaseReady)
        XCTAssertEqual(canonical.primaryExclusion, .staleRevision)
        XCTAssertNotEqual(canonical.receiptID, oldReady.receiptID)
        XCTAssertFalse(canonical.receiptID.contains(ReadinessTransitionFixture.Wire.forbiddenDefault))
    }

    func testVerifiedModelActivationRejectsBadIdentityWithoutChangingOldReadyState() throws {
        let probes: [(String, (ReadinessTransitionFixture) throws -> DocumentVerifiedEmbeddingModelSelectionCommand)] = [
            (
                "missing model",
                { fixture in
                    fixture.modelSelectionCommand(
                        identity: DocumentReadinessEmbeddingModelIdentity(
                            id: "T_DATA_READY_TRANSITION_MISSING_MODEL_743",
                            repoID: "synthetic/T_DATA_READY_TRANSITION_MISSING_MODEL_743",
                            revision: ReadinessTransitionFixture.Wire.modelBRevision,
                            dimension: ReadinessTransitionFixture.Wire.modelBDimension
                        )
                    )
                }
            ),
            (
                "wrong immutable revision",
                { fixture in
                    fixture.modelSelectionCommand(
                        identity: DocumentReadinessEmbeddingModelIdentity(
                            id: ReadinessTransitionFixture.Wire.modelBID,
                            repoID: ReadinessTransitionFixture.Wire.modelBRepoID,
                            revision: "T_DATA_READY_TRANSITION_MODEL_B_REVISION_9",
                            dimension: ReadinessTransitionFixture.Wire.modelBDimension
                        )
                    )
                }
            ),
            (
                "failed verification",
                { fixture in
                    var model = try XCTUnwrap(
                        fixture.store.documentSettings.fetchEmbeddingModel(
                            id: ReadinessTransitionFixture.Wire.modelBID
                        )
                    )
                    model.lastTestLoadResult = "failed: T_DATA_READY_TRANSITION_MODEL_B_747"
                    try fixture.store.documentSettings.upsertEmbeddingModel(model)
                    return fixture.modelSelectionCommand()
                }
            ),
        ]

        for (label, makeCommand) in probes {
            let fixture = try ReadinessTransitionFixture.makeReady()
            let command = try makeCommand(fixture)
            let before = try fixture.snapshot()

            XCTAssertThrowsError(
                try fixture.store.documentSettings.activateVerifiedEmbeddingModel(command),
                label
            )
            XCTAssertEqual(try fixture.snapshot(), before, label)
            XCTAssertEqual(
                try fixture.store.documentSettings.fetchSelectedEmbeddingModel()?.id,
                ReadinessTransitionFixture.Wire.modelAID,
                label
            )
        }
    }

    func testVerifiedModelActivationRollsBackFlagsAndSettingsAtEveryNPlusOneWrite() throws {
        for boundary in ModelWriteBoundary.allCases {
            let fixture = try ReadinessTransitionFixture.makeReady()
            let before = try fixture.snapshot()
            try installModelFailure(boundary, fixture: fixture)

            XCTAssertThrowsError(
                try fixture.store.documentSettings.activateVerifiedEmbeddingModel(
                    fixture.modelSelectionCommand()
                )
            )
            XCTAssertEqual(
                try fixture.snapshot(),
                before,
                "model flags, settings identity, verification time, and old ready receipt must roll back at \(boundary.rawValue)"
            )
        }
    }

    func testVerifiedModelActivationPublishesOneExactIdentityAndInvalidatesOldReadiness() throws {
        let fixture = try ReadinessTransitionFixture.makeReady()
        let oldReady = try fixture.store.documentReadiness.fetchReceipt(
            documentID: ReadinessTransitionFixture.Wire.documentID
        )

        let activation: DocumentVerifiedEmbeddingModelSelectionReceipt = try fixture.store
            .documentSettings.activateVerifiedEmbeddingModel(
                fixture.modelSelectionCommand()
            )
        let settings = try fixture.store.documentSettings.loadSettings()
        let selectedFlags = try fixture.store.documentSettings.fetchEmbeddingModels()
            .filter(\.isSelected).map(\.id)
        let current = try fixture.store.documentReadiness.fetchReceipt(
            documentID: ReadinessTransitionFixture.Wire.documentID
        )

        XCTAssertEqual(activation.activeModel, ReadinessTransitionFixture.modelBIdentity)
        XCTAssertEqual(activation.verifiedAt, ReadinessTransitionFixture.Wire.modelBVerifiedAt)
        XCTAssertEqual(
            activation.setupInvalidationReason,
            ReadinessTransitionFixture.Wire.modelChangeReason
        )
        XCTAssertEqual(selectedFlags, [ReadinessTransitionFixture.Wire.modelBID])
        XCTAssertEqual(settings.selectedEmbeddingModelID, ReadinessTransitionFixture.Wire.modelBID)
        XCTAssertEqual(
            settings.embeddingModelLastTestedAt,
            ReadinessTransitionFixture.Wire.modelBVerifiedAt
        )
        XCTAssertNil(settings.setupCompletedAt)
        XCTAssertEqual(
            settings.setupInvalidatedReason,
            ReadinessTransitionFixture.Wire.modelChangeReason
        )
        XCTAssertFalse(current.isBaseReady)
        XCTAssertEqual(current.primaryExclusion, .semanticIndexIncomplete)
        XCTAssertNotEqual(current.receiptID, oldReady.receiptID)
        XCTAssertFalse(current.receiptID.contains(ReadinessTransitionFixture.Wire.forbiddenDefault))
    }

    private func installRevisionFailure(
        _ boundary: RevisionWriteBoundary,
        fixture: ReadinessTransitionFixture
    ) throws {
        let predicate: (timing: String, table: String, condition: String)
        switch boundary {
        case .revision:
            predicate = (
                "INSERT",
                "document_part_revisions",
                "NEW.id = '\(ReadinessTransitionFixture.Wire.revision8ID)'"
            )
        case .selection:
            predicate = (
                "INSERT",
                "document_part_selections",
                "NEW.id = '\(ReadinessTransitionFixture.Wire.selection8ID)'"
            )
        case .partProjection:
            predicate = (
                "UPDATE",
                "document_pages_parts",
                "OLD.id = '\(ReadinessTransitionFixture.Wire.firstPartID)' AND NEW.current_revision_id = '\(ReadinessTransitionFixture.Wire.revision8ID)'"
            )
        case .staleInvalidation:
            predicate = (
                "UPDATE",
                "matter_documents",
                "OLD.id = '\(ReadinessTransitionFixture.Wire.documentID)' AND NEW.index_status = 'stale' AND NEW.extraction_status = 'edited'"
            )
        }
        try installFailureTrigger(
            name: "t_data_ready_transition_\(boundary.rawValue)",
            timing: predicate.timing,
            table: predicate.table,
            condition: predicate.condition,
            fixture: fixture
        )
    }

    private func installModelFailure(
        _ boundary: ModelWriteBoundary,
        fixture: ReadinessTransitionFixture
    ) throws {
        switch boundary {
        case .selectedFlags:
            try installFailureTrigger(
                name: "t_data_ready_transition_\(boundary.rawValue)",
                timing: "UPDATE",
                table: "document_embedding_models",
                condition: "OLD.id = '\(ReadinessTransitionFixture.Wire.modelAID)' AND OLD.is_selected = 1 AND NEW.is_selected = 0",
                fixture: fixture
            )
        case .settingsIdentity:
            try installFailureTrigger(
                name: "t_data_ready_transition_\(boundary.rawValue)",
                timing: "UPDATE",
                table: "document_intelligence_settings",
                condition: "NEW.selected_embedding_model_id = '\(ReadinessTransitionFixture.Wire.modelBID)'",
                fixture: fixture
            )
        }
    }

    private func installFailureTrigger(
        name: String,
        timing: String,
        table: String,
        condition: String,
        fixture: ReadinessTransitionFixture
    ) throws {
        let safeName = name.replacingOccurrences(of: "-", with: "_")
        try fixture.store.database.writer.write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER \(safeName)
                    BEFORE \(timing) ON \(table)
                    WHEN \(condition)
                    BEGIN
                        SELECT RAISE(ABORT, 'synthetic T-DATA-READY transition failure');
                    END
                    """
            )
        }
    }
}

struct ReadinessTransitionFixture {
    enum Wire {
        static let recordID = "record-713"
        static let version = 7
        static let nextVersion = 8
        static let documentID = recordID
        static let firstPartID = "part-record-713-7"
        static let secondPartID = "part-record-719-7"
        static let revision7ID = "revision-record-713-7"
        static let secondRevision7ID = "revision-record-719-7"
        static let selection7ID = "selection-record-713-7"
        static let secondSelection7ID = "selection-record-719-7"
        static let revision8ID = "revision-record-713-8"
        static let selection8ID = "selection-record-713-8"
        static let oldFirstChunkID = "chunk-record-713-7"
        static let oldSecondChunkID = "chunk-record-719-7"
        static let newFirstChunkID = "chunk-record-713-8"
        static let newSecondChunkID = "chunk-record-719-8"
        static let firstText7 = "T_DATA_READY_TRANSITION_FIRST_WIRE_731_V7"
        static let firstText8 = "T_DATA_READY_TRANSITION_FIRST_WIRE_731_N_PLUS_1_8"
        static let secondText7 = "T_DATA_READY_TRANSITION_SECOND_WIRE_733_V7"
        static let modelAID = "T_DATA_READY_TRANSITION_MODEL_A_739"
        static let modelARepoID = "synthetic/T_DATA_READY_TRANSITION_MODEL_A_739"
        static let modelARevision = "T_DATA_READY_TRANSITION_MODEL_A_REVISION_7"
        static let modelADimension = 7
        static let modelBID = "T_DATA_READY_TRANSITION_MODEL_B_743"
        static let modelBRepoID = "synthetic/T_DATA_READY_TRANSITION_MODEL_B_743"
        static let modelBRevision = "T_DATA_READY_TRANSITION_MODEL_B_REVISION_8"
        static let modelBDimension = 8
        static let modelChangeReason = "T_DATA_READY_TRANSITION_MODEL_CHANGE_751"
        static let forbiddenDefault = "DEFAULT-000"
        static let timestamp = Date(timeIntervalSince1970: 1_946_339_713)
        static let modelBVerifiedAt = timestamp.addingTimeInterval(8)
    }

    struct Snapshot: Equatable {
        let persistedGraph: Data
        let readinessReceipt: DocumentReadinessReceipt
    }

    private struct PersistedGraph: Codable {
        let document: MatterDocumentRecord
        let parts: [DocumentPagePartRecord]
        let revisions: [DocumentPartRevisionRecord]
        let selections: [DocumentPartSelectionRecord]
        let chunks: [DocumentChunkRecord]
        let ftsRows: [String]
        let embeddings: [DocumentChunkEmbeddingRecord]
        let settings: DocumentIntelligenceSettingsRecord
        let models: [DocumentEmbeddingModelRecord]
    }

    let store: SupraStore
    let matterID: String

    static let modelAIdentity = DocumentReadinessEmbeddingModelIdentity(
        id: Wire.modelAID,
        repoID: Wire.modelARepoID,
        revision: Wire.modelARevision,
        dimension: Wire.modelADimension
    )

    static let modelBIdentity = DocumentReadinessEmbeddingModelIdentity(
        id: Wire.modelBID,
        repoID: Wire.modelBRepoID,
        revision: Wire.modelBRevision,
        dimension: Wire.modelBDimension
    )

    static func makeReady() throws -> ReadinessTransitionFixture {
        XCTAssertEqual(Wire.nextVersion, Wire.version + 1)
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(
            name: "T-DATA-READY transition matter 709"
        )
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                id: "blob-record-713-7",
                sha256: String(repeating: "7", count: 64),
                byteSize: Wire.firstText7.utf8.count + Wire.secondText7.utf8.count,
                originalExtension: "txt",
                managedRelativePath: "blobs/T_DATA_READY_TRANSITION_731.txt",
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
                displayName: "T_DATA_READY_TRANSITION_SOURCE_719.txt",
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.ready.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractionMethod: "T_DATA_READY_TRANSITION_EXTRACTOR_7",
                extractedTextChecksum: String(repeating: "3", count: 64),
                pagePartCount: 2,
                classificationMetadataJSON: #"{"wire":"T_DATA_READY_TRANSITION_CLASSIFICATION_7"}"#,
                importedAt: Wire.timestamp,
                createdAt: Wire.timestamp,
                updatedAt: Wire.timestamp
            )
        )
        try store.documentIndex.replaceParts(
            documentID: Wire.documentID,
            parts: [
                part(id: Wire.firstPartID, index: 0, text: Wire.firstText7),
                part(id: Wire.secondPartID, index: 1, text: Wire.secondText7),
            ]
        )
        try appendInitialLineage(store)
        try store.documentIndex.replaceChunks(
            documentID: Wire.documentID,
            chunks: oldChunks()
        )

        _ = try store.documentSettings.loadSettings()
        try store.documentSettings.upsertEmbeddingModel(modelARecord())
        try store.documentSettings.upsertEmbeddingModel(modelBRecord())
        try store.documentSettings.selectEmbeddingModel(id: Wire.modelAID)
        try store.documentSettings.updateSettings {
            $0.embeddingModelLastTestedAt = Wire.timestamp
            $0.chunkerVersion = 2
            $0.setupCompletedAt = Wire.timestamp
            $0.setupInvalidatedReason = nil
        }
        for embedding in modelAEmbeddings() {
            try store.documentIndex.upsertEmbedding(embedding)
        }

        let fixture = ReadinessTransitionFixture(store: store, matterID: matter.id)
        let receipt = try store.documentReadiness.fetchReceipt(documentID: Wire.documentID)
        XCTAssertTrue(receipt.isBaseReady)
        XCTAssertFalse(
            String(decoding: try fixture.snapshot().persistedGraph, as: UTF8.self)
                .contains(Wire.forbiddenDefault)
        )
        return fixture
    }

    func revisionTransitionCommand() -> DocumentRevisionSelectionTransitionCommand {
        DocumentRevisionSelectionTransitionCommand(
            documentID: Wire.documentID,
            partID: Wire.firstPartID,
            expectedCurrentRevisionID: Wire.revision7ID,
            expectedCurrentSelectionID: Wire.selection7ID,
            revision: revision8(),
            selection: selection8()
        )
    }

    func modelSelectionCommand(
        identity: DocumentReadinessEmbeddingModelIdentity = Self.modelBIdentity
    ) -> DocumentVerifiedEmbeddingModelSelectionCommand {
        DocumentVerifiedEmbeddingModelSelectionCommand(
            expectedModel: identity,
            verifiedAt: Wire.modelBVerifiedAt,
            setupInvalidationReason: Wire.modelChangeReason
        )
    }

    func prepareRevision8Stale() throws {
        _ = try store.documentRevisions.appendRevision(revision8())
        _ = try store.documentRevisions.appendSelection(selection8())
        try store.documentLibrary.markTextEdited(documentID: Wire.documentID)
    }

    func prepareTextIndexedForModelB() throws {
        try prepareRevision8Stale()
        try store.documentIndex.replaceChunks(
            documentID: Wire.documentID,
            chunks: newChunks()
        )
        try store.documentLibrary.updateIndexStatus(
            documentID: Wire.documentID,
            indexStatus: .textIndexed
        )
        try store.documentLibrary.updateStatus(
            documentID: Wire.documentID,
            status: .embedding
        )
        try store.documentSettings.selectEmbeddingModel(id: Wire.modelBID)
        try store.documentSettings.updateSettings {
            $0.embeddingModelLastTestedAt = Wire.modelBVerifiedAt
            $0.setupCompletedAt = nil
            $0.setupInvalidatedReason = Wire.modelChangeReason
        }
        let receipt = try store.documentReadiness.fetchReceipt(documentID: Wire.documentID)
        XCTAssertEqual(receipt.primaryExclusion, .semanticIndexIncomplete)
    }

    func currentPartBindings() throws -> [DocumentReadinessPartBinding] {
        try store.documentIndex.fetchParts(documentID: Wire.documentID).map {
            DocumentReadinessPartBinding(
                partIndex: $0.partIndex,
                partID: $0.id,
                currentRevisionID: $0.currentRevisionID,
                currentSelectionID: $0.currentSelectionID
            )
        }
    }

    func revision8() -> DocumentPartRevisionRecord {
        DocumentPartRevisionRecord(
            id: Wire.revision8ID,
            documentID: Wire.documentID,
            partIndex: 0,
            derivationKey: "T_DATA_READY_TRANSITION_DERIVATION_8",
            origin: "user_edit",
            method: "synthetic_manual",
            text: Wire.firstText8,
            charCount: Wire.firstText8.count,
            toolchainVersion: "T_DATA_READY_TRANSITION_TOOLCHAIN_8",
            author: "synthetic-attorney-733",
            reason: "T-DATA-READY transition N+1",
            supersedesRevisionID: Wire.revision7ID,
            createdAt: Wire.timestamp.addingTimeInterval(8)
        )
    }

    func selection8() -> DocumentPartSelectionRecord {
        DocumentPartSelectionRecord(
            id: Wire.selection8ID,
            documentID: Wire.documentID,
            partIndex: 0,
            selectedRevisionID: Wire.revision8ID,
            selectionKey: "T_DATA_READY_TRANSITION_SELECTION_8",
            selectedBy: "synthetic_attorney",
            policyVersion: 8,
            decisionJSON: #"{"wire":"T_DATA_READY_TRANSITION_DECISION_8"}"#,
            supersedesSelectionID: Wire.selection7ID,
            createdAt: Wire.timestamp.addingTimeInterval(9)
        )
    }

    func newChunks() -> [DocumentChunkRecord] {
        [
            Self.chunk(
                id: Wire.newFirstChunkID,
                partID: Wire.firstPartID,
                revisionID: Wire.revision8ID,
                index: 0,
                text: Wire.firstText8
            ),
            Self.chunk(
                id: Wire.newSecondChunkID,
                partID: Wire.secondPartID,
                revisionID: Wire.secondRevision7ID,
                index: 1,
                text: Wire.secondText7
            ),
        ]
    }

    func modelBEmbeddings() -> [DocumentChunkEmbeddingRecord] {
        [
            Self.embedding(
                id: "embedding-record-713-8",
                chunkID: Wire.newFirstChunkID,
                modelID: Wire.modelBID,
                displayName: "T-DATA-READY Transition Model B 743",
                revision: Wire.modelBRevision,
                vector: [1, 0, 0, 0, 0, 0, 0, 0]
            ),
            Self.embedding(
                id: "embedding-record-719-8",
                chunkID: Wire.newSecondChunkID,
                modelID: Wire.modelBID,
                displayName: "T-DATA-READY Transition Model B 743",
                revision: Wire.modelBRevision,
                vector: [0, 1, 0, 0, 0, 0, 0, 0]
            ),
        ]
    }

    func snapshot() throws -> Snapshot {
        let persisted = try store.database.writer.read { database in
            let graph = PersistedGraph(
                document: try XCTUnwrap(
                    MatterDocumentRecord.fetchOne(database, key: Wire.documentID)
                ),
                parts: try DocumentPagePartRecord.fetchAll(
                    database,
                    sql: "SELECT * FROM document_pages_parts WHERE document_id = ? ORDER BY part_index, id",
                    arguments: [Wire.documentID]
                ),
                revisions: try DocumentPartRevisionRecord.fetchAll(
                    database,
                    sql: "SELECT * FROM document_part_revisions WHERE document_id = ? ORDER BY part_index, created_at, id",
                    arguments: [Wire.documentID]
                ),
                selections: try DocumentPartSelectionRecord.fetchAll(
                    database,
                    sql: "SELECT * FROM document_part_selections WHERE document_id = ? ORDER BY part_index, created_at, id",
                    arguments: [Wire.documentID]
                ),
                chunks: try DocumentChunkRecord.fetchAll(
                    database,
                    sql: "SELECT * FROM document_chunks WHERE document_id = ? ORDER BY chunk_index, id",
                    arguments: [Wire.documentID]
                ),
                ftsRows: try String.fetchAll(
                    database,
                    sql: """
                        SELECT CAST(rowid AS TEXT) || '|' || COALESCE(chunk_id, '<nil>') || '|'
                            || COALESCE(document_id, '<nil>') || '|' || text
                        FROM document_chunk_fts
                        WHERE document_id = ?
                        ORDER BY rowid
                        """,
                    arguments: [Wire.documentID]
                ),
                embeddings: try DocumentChunkEmbeddingRecord.fetchAll(
                    database,
                    sql: "SELECT * FROM document_chunk_embeddings WHERE document_id = ? ORDER BY embedding_model_id, chunk_id, id",
                    arguments: [Wire.documentID]
                ),
                settings: try XCTUnwrap(
                    DocumentIntelligenceSettingsRecord.fetchOne(
                        database,
                        key: DocumentIntelligenceSettingsRecord.singletonID
                    )
                ),
                models: try DocumentEmbeddingModelRecord.fetchAll(
                    database,
                    sql: "SELECT * FROM document_embedding_models ORDER BY id"
                )
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(graph)
        }
        return Snapshot(
            persistedGraph: persisted,
            readinessReceipt: try store.documentReadiness.fetchReceipt(
                documentID: Wire.documentID
            )
        )
    }

    private static func appendInitialLineage(_ store: SupraStore) throws {
        let lineage: [(String, String, String, String, Int, String)] = [
            (
                Wire.revision7ID,
                Wire.selection7ID,
                Wire.firstText7,
                Wire.firstPartID,
                0,
                "713"
            ),
            (
                Wire.secondRevision7ID,
                Wire.secondSelection7ID,
                Wire.secondText7,
                Wire.secondPartID,
                1,
                "719"
            ),
        ]
        for (revisionID, selectionID, text, _, partIndex, suffix) in lineage {
            _ = try store.documentRevisions.appendRevision(
                DocumentPartRevisionRecord(
                    id: revisionID,
                    documentID: Wire.documentID,
                    partIndex: partIndex,
                    derivationKey: "T_DATA_READY_TRANSITION_DERIVATION_\(suffix)_7",
                    origin: "parser",
                    method: "synthetic_exact_text",
                    text: text,
                    charCount: text.count,
                    toolchainVersion: "T_DATA_READY_TRANSITION_TOOLCHAIN_7",
                    createdAt: Wire.timestamp
                )
            )
            _ = try store.documentRevisions.appendSelection(
                DocumentPartSelectionRecord(
                    id: selectionID,
                    documentID: Wire.documentID,
                    partIndex: partIndex,
                    selectedRevisionID: revisionID,
                    selectionKey: "T_DATA_READY_TRANSITION_SELECTION_\(suffix)_7",
                    selectedBy: "synthetic_policy",
                    policyVersion: 7,
                    decisionJSON: "{\"wire\":\"T_DATA_READY_TRANSITION_DECISION_\(suffix)_7\"}",
                    createdAt: Wire.timestamp
                )
            )
        }
    }

    private static func part(id: String, index: Int, text: String) -> DocumentPagePartRecord {
        DocumentPagePartRecord(
            id: id,
            documentID: Wire.documentID,
            partIndex: index,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count,
            createdAt: Wire.timestamp,
            updatedAt: Wire.timestamp
        )
    }

    private static func oldChunks() -> [DocumentChunkRecord] {
        [
            chunk(
                id: Wire.oldFirstChunkID,
                partID: Wire.firstPartID,
                revisionID: Wire.revision7ID,
                index: 0,
                text: Wire.firstText7
            ),
            chunk(
                id: Wire.oldSecondChunkID,
                partID: Wire.secondPartID,
                revisionID: Wire.secondRevision7ID,
                index: 1,
                text: Wire.secondText7
            ),
        ]
    }

    private static func chunk(
        id: String,
        partID: String,
        revisionID: String,
        index: Int,
        text: String
    ) -> DocumentChunkRecord {
        DocumentChunkRecord(
            id: id,
            documentID: Wire.documentID,
            pagePartID: partID,
            revisionID: revisionID,
            chunkerVersion: 2,
            chunkIndex: index,
            sourceKind: DocumentSourceKind.text.rawValue,
            charStart: 0,
            charEnd: text.count,
            normalizedText: text,
            displayExcerpt: text,
            tokenCount: Wire.version,
            createdAt: Wire.timestamp,
            updatedAt: Wire.timestamp
        )
    }

    private static func modelARecord() -> DocumentEmbeddingModelRecord {
        DocumentEmbeddingModelRecord(
            id: Wire.modelAID,
            repoID: Wire.modelARepoID,
            localPath: "/synthetic/T_DATA_READY_TRANSITION_MODEL_A_739",
            displayName: "T-DATA-READY Transition Model A 739",
            dimension: Wire.modelADimension,
            runtimeFamily: "synthetic-transition-wire-7",
            revision: Wire.modelARevision,
            isDefault: false,
            isSelected: false,
            lastTestLoadAt: Wire.timestamp,
            lastTestLoadResult: "passed",
            createdAt: Wire.timestamp,
            updatedAt: Wire.timestamp
        )
    }

    private static func modelBRecord() -> DocumentEmbeddingModelRecord {
        DocumentEmbeddingModelRecord(
            id: Wire.modelBID,
            repoID: Wire.modelBRepoID,
            localPath: "/synthetic/T_DATA_READY_TRANSITION_MODEL_B_743",
            displayName: "T-DATA-READY Transition Model B 743",
            dimension: Wire.modelBDimension,
            runtimeFamily: "synthetic-transition-wire-8",
            revision: Wire.modelBRevision,
            isDefault: false,
            isSelected: false,
            lastTestLoadAt: Wire.modelBVerifiedAt,
            lastTestLoadResult: "passed",
            createdAt: Wire.timestamp,
            updatedAt: Wire.modelBVerifiedAt
        )
    }

    private static func modelAEmbeddings() -> [DocumentChunkEmbeddingRecord] {
        [
            embedding(
                id: "embedding-record-713-7",
                chunkID: Wire.oldFirstChunkID,
                modelID: Wire.modelAID,
                displayName: "T-DATA-READY Transition Model A 739",
                revision: Wire.modelARevision,
                vector: [1, 0, 0, 0, 0, 0, 0]
            ),
            embedding(
                id: "embedding-record-719-7",
                chunkID: Wire.oldSecondChunkID,
                modelID: Wire.modelAID,
                displayName: "T-DATA-READY Transition Model A 739",
                revision: Wire.modelARevision,
                vector: [0, 1, 0, 0, 0, 0, 0]
            ),
        ]
    }

    private static func embedding(
        id: String,
        chunkID: String,
        modelID: String,
        displayName: String,
        revision: String,
        vector: [Float]
    ) -> DocumentChunkEmbeddingRecord {
        DocumentChunkEmbeddingRecord(
            id: id,
            chunkID: chunkID,
            documentID: Wire.documentID,
            embeddingModelID: modelID,
            modelDisplayName: displayName,
            modelRevision: revision,
            dimension: vector.count,
            normalized: true,
            vector: floatBlob(vector),
            createdAt: Wire.timestamp
        )
    }

    private static func floatBlob(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * MemoryLayout<Float>.size)
        for value in values {
            var littleEndianBits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndianBits) { data.append(contentsOf: $0) }
        }
        return data
    }
}
