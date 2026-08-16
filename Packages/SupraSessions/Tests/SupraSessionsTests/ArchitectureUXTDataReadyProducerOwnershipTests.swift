import Foundation
import GRDB
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// WP-1.2 real-producer transition-ownership RED. The Store commands are only
/// authoritative when the services that produce revisions, text indexes,
/// semantic indexes, and active model selections use them as their sole
/// completion boundary.
///
/// Expected RED: `DocumentImportService.updateExtractedText` still commits the
/// user revision before stale invalidation; `DocumentIndexingService` still
/// replaces chunks, writes vectors one at a time, and promotes status in later
/// transactions; setup selection still selects by id before invalidating setup;
/// and the downloader can preselect an unverified artifact. Faults at the
/// N+1 writes therefore leave partial producer state behind.
@MainActor
final class ArchitectureUXTDataReadyProducerOwnershipTests: XCTestCase {
    private enum RevisionBoundary: String, CaseIterable {
        case revision = "revision-761"
        case selection = "selection-761"
        case partProjection = "part-projection-761"
        case staleInvalidation = "stale-invalidation-761"
    }

    private enum TextBoundary: String, CaseIterable {
        case firstChunk = "first-current-chunk-769"
        case secondChunk = "second-current-chunk-769"
        case textIndexedStatus = "text-indexed-status-769"
    }

    private enum SemanticBoundary: String, CaseIterable {
        case firstEmbedding = "first-current-embedding-773"
        case secondEmbedding = "second-current-embedding-773"
        case terminalStatus = "terminal-status-773"
    }

    private enum ModelBoundary: String, CaseIterable {
        case selectedFlags = "selected-flags-787"
        case settingsIdentity = "settings-identity-787"
    }

    func testProductionOwnersUseOnlyTheTransactionalTransitionCommands() throws {
        let importer = try sessionsSource("DocumentImportService.swift")
        let correction = try XCTUnwrap(importer.slice(
            from: "public func updateExtractedText(",
            through: "// MARK: - Reprocess"
        ))
        XCTAssertTrue(
            correction.contains("documentRevisions.commitSelectionAndInvalidateIndex("),
            "the real saved-correction path must publish lineage and stale invalidation with the Store command"
        )
        XCTAssertFalse(
            correction.contains("documentRevisions.appendUserEdit("),
            "the real saved-correction path cannot commit lineage before invalidation"
        )
        XCTAssertFalse(
            correction.contains("documentLibrary.markTextEdited("),
            "the real saved-correction path cannot publish stale flags in a later transaction"
        )

        let indexing = try sessionsSource("DocumentIndexingService.swift")
        XCTAssertTrue(indexing.contains("documentIndex.commitTextIndex("))
        XCTAssertTrue(indexing.contains("documentIndex.commitSemanticIndex("))
        for forbidden in [
            "documentIndex.replaceChunks(",
            "documentIndex.upsertEmbedding(",
            "documentLibrary.updateIndexStatus(",
        ] {
            XCTAssertFalse(
                indexing.contains(forbidden),
                "the real index producer still has a piecemeal completion call: \(forbidden)"
            )
        }

        let setup = try sessionsSource("DocumentIntelligenceSetupController.swift")
        let selection = try XCTUnwrap(setup.slice(
            from: "public func selectEmbeddingModel(id: String)",
            through: "/// Selects an embedding model and immediately verifies it loads."
        ))
        XCTAssertTrue(
            selection.contains("documentSettings.activateVerifiedEmbeddingModel("),
            "the user-selection action must activate one exact verified identity"
        )
        XCTAssertFalse(selection.contains("documentSettings.selectEmbeddingModel(id:"))
        XCTAssertFalse(selection.contains("documentSettings.invalidateSetup(reason:"))

        let downloader = try sessionsSource("EmbeddingModelDownloadController.swift")
        let registration = try XCTUnwrap(downloader.slice(
            from: "private func registerModel(",
            through: "\n    }\n}"
        ))
        XCTAssertFalse(
            registration.contains("documentSettings.selectEmbeddingModel(id:"),
            "a downloaded but unverified model cannot independently become active"
        )
        XCTAssertFalse(indexing.contains(ReadinessProducerFixture.Wire.forbiddenDefault))
    }

    func testSavedCorrectionRollsBackAtEveryNPlusOneReadinessWrite() throws {
        for boundary in RevisionBoundary.allCases {
            let fixture = try ReadinessProducerFixture.make(
                documentStatus: .ready,
                indexStatus: .ready,
                selectedModel: true,
                includeEmbeddings: true
            )
            defer { fixture.removeTemporaryFiles() }
            let before = try fixture.documentGraphSnapshot()
            try installRevisionFailure(boundary, fixture: fixture)
            let service = DocumentImportService(
                store: fixture.store,
                storage: DocumentStorage(root: fixture.root.appendingPathComponent("managed")),
                ocr: nil
            )

            XCTAssertThrowsError(
                try service.updateExtractedText(
                    documentID: ReadinessProducerFixture.Wire.documentID,
                    partID: ReadinessProducerFixture.Wire.firstPartID,
                    text: ReadinessProducerFixture.Wire.correctedFirstText,
                    author: "Synthetic attorney 761",
                    reason: "Synthetic correction 761"
                ),
                "the synthetic \(boundary.rawValue) write must stop the real correction producer"
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains(boundary.rawValue),
                    "the observed RED must be the injected \(boundary.rawValue) boundary, not an earlier fixture failure: \(error)"
                )
            }
            XCTAssertEqual(
                try fixture.documentGraphSnapshot(),
                before,
                "the real correction producer left partial lineage, projection, structure, or stale state at \(boundary.rawValue)"
            )
        }
    }

    func testTextIndexerRollsBackChunksFTSAndStatusAtEveryNPlusOneWrite() async throws {
        for boundary in TextBoundary.allCases {
            let fixture = try ReadinessProducerFixture.make(
                documentStatus: .ready,
                indexStatus: .stale,
                selectedModel: true,
                includeEmbeddings: true
            )
            defer { fixture.removeTemporaryFiles() }
            let before = try fixture.documentGraphSnapshot()
            try installTextFailure(boundary, fixture: fixture)
            let indexer = DocumentIndexingService(
                store: fixture.store,
                chunker: DocumentChunker(version: 2),
                embedder: nil
            )

            let error = await captureError {
                _ = try await indexer.indexDocument(
                    documentID: ReadinessProducerFixture.Wire.documentID
                )
            }
            XCTAssertNotNil(
                error,
                "the synthetic \(boundary.rawValue) write must stop the real text-index producer"
            )
            XCTAssertTrue(
                error?.localizedDescription.contains(boundary.rawValue) == true,
                "the observed RED must be the injected \(boundary.rawValue) boundary, not an earlier fixture failure: \(String(describing: error))"
            )
            XCTAssertEqual(
                try fixture.documentGraphSnapshot(),
                before,
                "old chunks, exact FTS rows, vectors, and stale status must all survive \(boundary.rawValue)"
            )
        }
    }

    func testSemanticIndexerRollsBackWholeVectorBatchAndTerminalStatusAtEveryNPlusOneWrite() async throws {
        for boundary in SemanticBoundary.allCases {
            let fixture = try ReadinessProducerFixture.make(
                documentStatus: .embedding,
                indexStatus: .textIndexed,
                selectedModel: true,
                includeEmbeddings: false
            )
            defer { fixture.removeTemporaryFiles() }
            let before = try fixture.documentGraphSnapshot()
            try installSemanticFailure(boundary, fixture: fixture)
            let indexer = DocumentIndexingService(
                store: fixture.store,
                chunker: DocumentChunker(version: 2),
                embedder: ReadinessProducerEmbedder()
            )

            let error = await captureError {
                _ = try await indexer.indexDocument(
                    documentID: ReadinessProducerFixture.Wire.documentID
                )
            }
            XCTAssertNotNil(
                error,
                "the synthetic \(boundary.rawValue) write must stop the real semantic producer"
            )
            XCTAssertTrue(
                error?.localizedDescription.contains(boundary.rawValue) == true,
                "the observed RED must be the injected \(boundary.rawValue) boundary, not an earlier fixture failure: \(String(describing: error))"
            )
            XCTAssertEqual(
                try fixture.documentGraphSnapshot(),
                before,
                "no vector prefix, semantic-completion audit, or terminal flag may survive \(boundary.rawValue)"
            )
        }
    }

    func testSetupModelActivationRollsBackAtEveryNPlusOneWrite() throws {
        for boundary in ModelBoundary.allCases {
            let fixture = try ReadinessProducerFixture.makeModelSelectionFixture()
            defer { fixture.removeTemporaryFiles() }
            let controller = DocumentIntelligenceSetupController(
                store: fixture.store,
                runtimeClient: ReadinessUnusedRuntimeClient(),
                storage: DocumentStorage(root: fixture.root.appendingPathComponent("managed")),
                capabilitiesProvider: {
                    DocumentToolchainCapabilities(
                        version: "synthetic-toolchain-787",
                        pdfText: true,
                        ocr: true,
                        nativeImageDecoding: true,
                        heicDecoding: true,
                        supportedFamilies: ["text"],
                        ocrLanguages: ["en-US"]
                    )
                }
            )
            let before = try fixture.modelSelectionSnapshot()
            try installModelFailure(boundary, fixture: fixture)

            controller.selectEmbeddingModel(id: ReadinessProducerFixture.Wire.modelBID)

            XCTAssertEqual(
                try fixture.modelSelectionSnapshot(),
                before,
                "active flags, exact settings identity, verification time, and setup state must roll back at \(boundary.rawValue)"
            )
            XCTAssertEqual(
                try fixture.store.documentSettings.fetchSelectedEmbeddingModel()?.id,
                ReadinessProducerFixture.Wire.modelAID
            )
        }
    }

    private func installRevisionFailure(
        _ boundary: RevisionBoundary,
        fixture: ReadinessProducerFixture
    ) throws {
        let timing: String
        let table: String
        let condition: String
        switch boundary {
        case .revision:
            timing = "INSERT"
            table = "document_part_revisions"
            condition = "NEW.document_id = '\(ReadinessProducerFixture.Wire.documentID)' AND NEW.origin = 'user_edit'"
        case .selection:
            timing = "INSERT"
            table = "document_part_selections"
            condition = "NEW.document_id = '\(ReadinessProducerFixture.Wire.documentID)' AND NEW.selected_by = 'user'"
        case .partProjection:
            timing = "UPDATE"
            table = "document_pages_parts"
            condition = "OLD.id = '\(ReadinessProducerFixture.Wire.firstPartID)' AND NEW.current_revision_id <> OLD.current_revision_id"
        case .staleInvalidation:
            timing = "UPDATE"
            table = "matter_documents"
            condition = "OLD.id = '\(ReadinessProducerFixture.Wire.documentID)' AND NEW.index_status = 'stale' AND NEW.extraction_status = 'edited'"
        }
        try installAbortTrigger(
            name: "t_data_ready_producer_revision_\(boundary.rawValue.replacingOccurrences(of: "-", with: "_"))",
            timing: timing,
            table: table,
            condition: condition,
            message: boundary.rawValue,
            store: fixture.store
        )
    }

    private func installTextFailure(
        _ boundary: TextBoundary,
        fixture: ReadinessProducerFixture
    ) throws {
        let timing: String
        let table: String
        let condition: String
        switch boundary {
        case .firstChunk:
            timing = "INSERT"
            table = "document_chunks"
            condition = "NEW.document_id = '\(ReadinessProducerFixture.Wire.documentID)' AND NEW.id LIKE 'chunk-v2-%' AND NEW.chunk_index = 0"
        case .secondChunk:
            timing = "INSERT"
            table = "document_chunks"
            condition = "NEW.document_id = '\(ReadinessProducerFixture.Wire.documentID)' AND NEW.id LIKE 'chunk-v2-%' AND NEW.chunk_index = 1"
        case .textIndexedStatus:
            timing = "UPDATE"
            table = "matter_documents"
            condition = "OLD.id = '\(ReadinessProducerFixture.Wire.documentID)' AND OLD.index_status = 'stale' AND NEW.index_status = 'text_indexed'"
        }
        try installAbortTrigger(
            name: "t_data_ready_producer_text_\(boundary.rawValue.replacingOccurrences(of: "-", with: "_"))",
            timing: timing,
            table: table,
            condition: condition,
            message: boundary.rawValue,
            store: fixture.store
        )
    }

    private func installSemanticFailure(
        _ boundary: SemanticBoundary,
        fixture: ReadinessProducerFixture
    ) throws {
        let timing: String
        let table: String
        let condition: String
        switch boundary {
        case .firstEmbedding:
            timing = "INSERT"
            table = "document_chunk_embeddings"
            condition = "NEW.document_id = '\(ReadinessProducerFixture.Wire.documentID)' AND NEW.embedding_model_id = '\(ReadinessProducerFixture.Wire.modelAID)' AND NEW.chunk_id = '\(ReadinessProducerFixture.Wire.oldFirstChunkID)'"
        case .secondEmbedding:
            timing = "INSERT"
            table = "document_chunk_embeddings"
            condition = "NEW.document_id = '\(ReadinessProducerFixture.Wire.documentID)' AND NEW.embedding_model_id = '\(ReadinessProducerFixture.Wire.modelAID)' AND NEW.chunk_id = '\(ReadinessProducerFixture.Wire.oldSecondChunkID)'"
        case .terminalStatus:
            timing = "UPDATE"
            table = "matter_documents"
            condition = "OLD.id = '\(ReadinessProducerFixture.Wire.documentID)' AND OLD.index_status = 'text_indexed' AND NEW.index_status = 'ready'"
        }
        try installAbortTrigger(
            name: "t_data_ready_producer_semantic_\(boundary.rawValue.replacingOccurrences(of: "-", with: "_"))",
            timing: timing,
            table: table,
            condition: condition,
            message: boundary.rawValue,
            store: fixture.store
        )
    }

    private func installModelFailure(
        _ boundary: ModelBoundary,
        fixture: ReadinessProducerFixture
    ) throws {
        let table: String
        let condition: String
        switch boundary {
        case .selectedFlags:
            table = "document_embedding_models"
            condition = "NEW.id = '\(ReadinessProducerFixture.Wire.modelBID)' AND OLD.is_selected = 0 AND NEW.is_selected = 1"
        case .settingsIdentity:
            table = "document_intelligence_settings"
            condition = "OLD.id = 'default' AND OLD.selected_embedding_model_id = '\(ReadinessProducerFixture.Wire.modelAID)' AND NEW.selected_embedding_model_id = '\(ReadinessProducerFixture.Wire.modelBID)'"
        }
        try installAbortTrigger(
            name: "t_data_ready_producer_model_\(boundary.rawValue.replacingOccurrences(of: "-", with: "_"))",
            timing: "UPDATE",
            table: table,
            condition: condition,
            message: boundary.rawValue,
            store: fixture.store
        )
    }

    private func installAbortTrigger(
        name: String,
        timing: String,
        table: String,
        condition: String,
        message: String,
        store: SupraStore
    ) throws {
        try store.database.writer.write { database in
            try database.execute(sql: """
                CREATE TRIGGER \(name)
                BEFORE \(timing) ON \(table)
                WHEN \(condition)
                BEGIN
                    SELECT RAISE(ABORT, 'T-DATA-READY-PRODUCER \(message)');
                END;
                """)
        }
    }

    private func captureError(
        _ operation: () async throws -> Void
    ) async -> Error? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }

    private func sessionsSource(_ name: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/SupraSessions")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }
}

private final class ReadinessProducerFixture {
    enum Wire {
        static let documentID = "T_DATA_READY_PRODUCER_DOCUMENT_761"
        static let firstPartID = "T_DATA_READY_PRODUCER_PART_A_761"
        static let secondPartID = "T_DATA_READY_PRODUCER_PART_B_761"
        static let firstRevisionID = "T_DATA_READY_PRODUCER_REVISION_A_761"
        static let secondRevisionID = "T_DATA_READY_PRODUCER_REVISION_B_761"
        static let firstSelectionID = "T_DATA_READY_PRODUCER_SELECTION_A_761"
        static let secondSelectionID = "T_DATA_READY_PRODUCER_SELECTION_B_761"
        static let firstNodeID = "T_DATA_READY_PRODUCER_NODE_A_761"
        static let secondNodeID = "T_DATA_READY_PRODUCER_NODE_B_761"
        static let rootNodeID = "T_DATA_READY_PRODUCER_ROOT_761"
        static let oldFirstChunkID = "T_DATA_READY_PRODUCER_OLD_CHUNK_A_769"
        static let oldSecondChunkID = "T_DATA_READY_PRODUCER_OLD_CHUNK_B_769"
        static let oldFirstEmbeddingID = "T_DATA_READY_PRODUCER_OLD_VECTOR_A_773"
        static let oldSecondEmbeddingID = "T_DATA_READY_PRODUCER_OLD_VECTOR_B_773"
        static let modelAID = "T_DATA_READY_PRODUCER_MODEL_A_787"
        static let modelBID = "T_DATA_READY_PRODUCER_MODEL_B_787"
        static let modelARepoID = "synthetic/readiness-producer-model-a-787"
        static let modelBRepoID = "synthetic/readiness-producer-model-b-787"
        static let modelARevision = "revision-a-787"
        static let modelBRevision = "revision-b-787"
        static let modelDisplayName = "Synthetic Readiness Producer A 787"
        static let firstText = "T_DATA_READY_PRODUCER_ALPHA_761 remains the selected first passage."
        static let secondText = "T_DATA_READY_PRODUCER_BRAVO_769 remains the selected second passage."
        static let correctedFirstText = "T_DATA_READY_PRODUCER_CORRECTED_ALPHA_773 is the saved attorney text."
        static let forbiddenDefault = "DEFAULT-000"
        static let verifiedAt = Date(timeIntervalSinceReferenceDate: 787_000)
    }

    let root: URL
    let store: SupraStore

    private init(root: URL, store: SupraStore) {
        self.root = root
        self.store = store
    }

    static func make(
        documentStatus: MatterDocumentStatus,
        indexStatus: DocumentIndexStatus,
        selectedModel: Bool,
        includeEmbeddings: Bool
    ) throws -> ReadinessProducerFixture {
        let fixture = try empty(prefix: "document")
        let matter = try fixture.store.matters.createMatter(
            name: "Synthetic readiness producer matter 761"
        )
        let blob = try fixture.store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                id: "T_DATA_READY_PRODUCER_BLOB_761",
                sha256: "t-data-ready-producer-blob-sha-761",
                byteSize: 761,
                originalExtension: "txt",
                managedRelativePath: "blobs/t-data-ready-producer-761.txt"
            )
        ).blob
        _ = try fixture.store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                id: Wire.documentID,
                matterID: matter.id,
                blobID: blob.id,
                displayName: "Synthetic Readiness Producer 761.txt",
                status: documentStatus.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: indexStatus.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractionMethod: "plain_text@toolchain:synthetic-761",
                extractedTextChecksum: "t-data-ready-producer-checksum-761",
                pagePartCount: 2,
                classificationMetadataJSON: #"{"wire":"T_DATA_READY_PRODUCER_CLASSIFICATION_761"}"#
            )
        )

        let parts = [
            DocumentPagePartRecord(
                id: Wire.firstPartID,
                documentID: Wire.documentID,
                partIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: Wire.firstText,
                charCount: Wire.firstText.count
            ),
            DocumentPagePartRecord(
                id: Wire.secondPartID,
                documentID: Wire.documentID,
                partIndex: 1,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: Wire.secondText,
                charCount: Wire.secondText.count
            ),
        ]
        let revisions = [
            DocumentPartRevisionRecord(
                id: Wire.firstRevisionID,
                documentID: Wire.documentID,
                partIndex: 0,
                derivationKey: "t-data-ready-producer-revision-a-761",
                origin: "synthetic_test",
                method: "plain_text",
                text: Wire.firstText,
                charCount: Wire.firstText.count,
                toolchainVersion: "synthetic-761"
            ),
            DocumentPartRevisionRecord(
                id: Wire.secondRevisionID,
                documentID: Wire.documentID,
                partIndex: 1,
                derivationKey: "t-data-ready-producer-revision-b-761",
                origin: "synthetic_test",
                method: "plain_text",
                text: Wire.secondText,
                charCount: Wire.secondText.count,
                toolchainVersion: "synthetic-761"
            ),
        ]
        let selections = [
            DocumentPartSelectionRecord(
                id: Wire.firstSelectionID,
                documentID: Wire.documentID,
                partIndex: 0,
                selectedRevisionID: Wire.firstRevisionID,
                selectionKey: "t-data-ready-producer-selection-a-761",
                selectedBy: "test",
                policyVersion: 761,
                decisionJSON: #"{"wire":"alpha-761"}"#
            ),
            DocumentPartSelectionRecord(
                id: Wire.secondSelectionID,
                documentID: Wire.documentID,
                partIndex: 1,
                selectedRevisionID: Wire.secondRevisionID,
                selectionKey: "t-data-ready-producer-selection-b-761",
                selectedBy: "test",
                policyVersion: 769,
                decisionJSON: #"{"wire":"bravo-769"}"#
            ),
        ]
        _ = try fixture.store.documentRevisions.replacePartsAndPersistLineage(
            documentID: Wire.documentID,
            parts: parts,
            revisions: revisions,
            selections: selections
        )

        try fixture.store.documentStructure.replaceStructure(
            documentID: Wire.documentID,
            nodes: [
                DocumentStructureNodeRecord(
                    id: Wire.rootNodeID,
                    documentID: Wire.documentID,
                    revisionID: Wire.firstRevisionID,
                    nodeKey: "document",
                    ordinal: 0,
                    kind: DocumentStructureNodeKind.document.rawValue
                ),
                DocumentStructureNodeRecord(
                    id: Wire.firstNodeID,
                    documentID: Wire.documentID,
                    revisionID: Wire.firstRevisionID,
                    nodeKey: "part/0",
                    parentNodeID: Wire.rootNodeID,
                    ordinal: 0,
                    kind: DocumentStructureNodeKind.paragraph.rawValue,
                    charStart: 0,
                    charEnd: Wire.firstText.count
                ),
                DocumentStructureNodeRecord(
                    id: Wire.secondNodeID,
                    documentID: Wire.documentID,
                    revisionID: Wire.secondRevisionID,
                    nodeKey: "part/1",
                    parentNodeID: Wire.rootNodeID,
                    ordinal: 1,
                    kind: DocumentStructureNodeKind.paragraph.rawValue,
                    charStart: 0,
                    charEnd: Wire.secondText.count
                ),
            ],
            edges: []
        )

        let chunks = fixture.oldChunks()
        try fixture.store.documentIndex.replaceChunks(
            documentID: Wire.documentID,
            chunks: chunks
        )
        _ = try fixture.store.documentSettings.loadSettings()
        try fixture.store.documentSettings.updateSettings { settings in
            settings.chunkerVersion = 2
        }
        if selectedModel {
            try fixture.installModelA(selected: true)
        }
        if includeEmbeddings {
            for (id, chunk, vector) in [
                (Wire.oldFirstEmbeddingID, chunks[0], [Float(1), Float(0)]),
                (Wire.oldSecondEmbeddingID, chunks[1], [Float(0), Float(1)]),
            ] {
                try fixture.store.documentIndex.upsertEmbedding(
                    DocumentChunkEmbeddingRecord(
                        id: id,
                        chunkID: chunk.id,
                        documentID: Wire.documentID,
                        embeddingModelID: Wire.modelAID,
                        modelDisplayName: Wire.modelDisplayName,
                        modelRevision: Wire.modelARevision,
                        dimension: 2,
                        normalized: true,
                        vector: VectorMath.encode(vector)
                    )
                )
            }
        }
        return fixture
    }

    static func makeModelSelectionFixture() throws -> ReadinessProducerFixture {
        let fixture = try empty(prefix: "model")
        _ = try fixture.store.documentSettings.loadSettings()
        try fixture.installModelA(selected: true)
        try fixture.store.documentSettings.upsertEmbeddingModel(
            DocumentEmbeddingModelRecord(
                id: Wire.modelBID,
                repoID: Wire.modelBRepoID,
                localPath: "/synthetic/readiness-producer/model-b-787",
                displayName: "Synthetic Readiness Producer B 787",
                dimension: 2,
                runtimeFamily: "synthetic",
                revision: Wire.modelBRevision,
                isSelected: false,
                lastTestLoadAt: Wire.verifiedAt.addingTimeInterval(8),
                lastTestLoadResult: "passed"
            )
        )
        try fixture.store.documentSettings.updateSettings { settings in
            settings.selectedEmbeddingModelID = Wire.modelAID
            settings.embeddingModelLastTestedAt = Wire.verifiedAt
            settings.setupCompletedAt = Date(timeIntervalSinceReferenceDate: 787_761)
            settings.setupInvalidatedReason = nil
        }
        return fixture
    }

    func documentGraphSnapshot() throws -> [String] {
        try store.database.writer.read { database in
            let queries = [
                """
                SELECT 'document|' || id || '|' || status || '|' || extraction_status || '|' ||
                       index_status || '|' || has_user_edited_text || '|' ||
                       COALESCE(classification_metadata_json, 'nil')
                FROM matter_documents WHERE id = ?
                """,
                """
                SELECT 'part|' || id || '|' || part_index || '|' || normalized_text || '|' ||
                       char_count || '|' || COALESCE(current_revision_id, 'nil') || '|' ||
                       COALESCE(current_selection_id, 'nil')
                FROM document_pages_parts WHERE document_id = ? ORDER BY part_index, id
                """,
                """
                SELECT 'revision|' || id || '|' || part_index || '|' || origin || '|' || text || '|' ||
                       COALESCE(supersedes_revision_id, 'nil')
                FROM document_part_revisions WHERE document_id = ? ORDER BY part_index, id
                """,
                """
                SELECT 'selection|' || id || '|' || part_index || '|' || selected_revision_id || '|' ||
                       selected_by || '|' || COALESCE(supersedes_selection_id, 'nil')
                FROM document_part_selections WHERE document_id = ? ORDER BY part_index, id
                """,
                """
                SELECT 'structure|' || id || '|' || revision_id || '|' || node_key || '|' || kind || '|' ||
                       COALESCE(parent_node_id, 'nil')
                FROM document_structure_nodes WHERE document_id = ? ORDER BY node_key, id
                """,
                """
                SELECT 'chunk|' || id || '|' || chunk_index || '|' || normalized_text || '|' ||
                       COALESCE(page_part_id, 'nil') || '|' || COALESCE(revision_id, 'nil') || '|' || chunker_version
                FROM document_chunks WHERE document_id = ? ORDER BY chunk_index, id
                """,
                """
                SELECT 'fts|' || chunk_id || '|' || text
                FROM document_chunk_fts WHERE document_id = ? ORDER BY chunk_id
                """,
                """
                SELECT 'embedding|' || id || '|' || chunk_id || '|' || embedding_model_id || '|' ||
                       model_display_name || '|' || COALESCE(model_revision, 'nil') || '|' || dimension
                FROM document_chunk_embeddings WHERE document_id = ? ORDER BY embedding_model_id, chunk_id, id
                """,
                """
                SELECT 'audit|' || id || '|' || event_type || '|' || COALESCE(related_id, 'nil')
                FROM audit_events
                WHERE related_id = ? AND event_type = 'semantic_indexing_completed'
                ORDER BY id
                """,
            ]
            return try queries.flatMap { query in
                try String.fetchAll(database, sql: query, arguments: [Wire.documentID])
            }
        }
    }

    func modelSelectionSnapshot() throws -> [String] {
        try store.database.writer.read { database in
            let models = try String.fetchAll(
                database,
                sql: """
                    SELECT 'model|' || id || '|' || repo_id || '|' || COALESCE(revision, 'nil') || '|' ||
                           dimension || '|' || is_selected || '|' || COALESCE(last_test_load_result, 'nil')
                    FROM document_embedding_models ORDER BY id
                    """
            )
            let settings = try String.fetchAll(
                database,
                sql: """
                    SELECT 'settings|' || id || '|' || COALESCE(selected_embedding_model_id, 'nil') || '|' ||
                           COALESCE(CAST(embedding_model_last_tested_at AS TEXT), 'nil') || '|' ||
                           COALESCE(CAST(setup_completed_at AS TEXT), 'nil') || '|' ||
                           COALESCE(setup_invalidated_reason, 'nil')
                    FROM document_intelligence_settings ORDER BY id
                    """
            )
            return models + settings
        }
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func empty(prefix: String) throws -> ReadinessProducerFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ArchitectureUXTDataReadyProducer-\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ReadinessProducerFixture(
            root: root,
            store: try SupraStore(url: root.appendingPathComponent("test.sqlite"))
        )
    }

    private func installModelA(selected: Bool) throws {
        try store.documentSettings.upsertEmbeddingModel(
            DocumentEmbeddingModelRecord(
                id: Wire.modelAID,
                repoID: Wire.modelARepoID,
                localPath: "/synthetic/readiness-producer/model-a-787",
                displayName: Wire.modelDisplayName,
                dimension: 2,
                runtimeFamily: "synthetic",
                revision: Wire.modelARevision,
                isSelected: selected,
                lastTestLoadAt: Wire.verifiedAt,
                lastTestLoadResult: "passed"
            )
        )
        if selected {
            try store.documentSettings.updateSettings { settings in
                settings.selectedEmbeddingModelID = Wire.modelAID
                settings.embeddingModelLastTestedAt = Wire.verifiedAt
            }
        }
    }

    private func oldChunks() -> [DocumentChunkRecord] {
        [
            DocumentChunkRecord(
                id: Wire.oldFirstChunkID,
                documentID: Wire.documentID,
                pagePartID: Wire.firstPartID,
                revisionID: Wire.firstRevisionID,
                nodeID: Wire.firstNodeID,
                unitKind: DocumentStructureNodeKind.paragraph.rawValue,
                chunkerVersion: 2,
                chunkIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                charStart: 0,
                charEnd: Wire.firstText.count,
                normalizedText: Wire.firstText,
                displayExcerpt: Wire.firstText,
                tokenCount: 17
            ),
            DocumentChunkRecord(
                id: Wire.oldSecondChunkID,
                documentID: Wire.documentID,
                pagePartID: Wire.secondPartID,
                revisionID: Wire.secondRevisionID,
                nodeID: Wire.secondNodeID,
                unitKind: DocumentStructureNodeKind.paragraph.rawValue,
                chunkerVersion: 2,
                chunkIndex: 1,
                sourceKind: DocumentSourceKind.text.rawValue,
                charStart: 0,
                charEnd: Wire.secondText.count,
                normalizedText: Wire.secondText,
                displayExcerpt: Wire.secondText,
                tokenCount: 17
            ),
        ]
    }
}

private struct ReadinessProducerEmbedder: TextEmbedder {
    let modelID = ReadinessProducerFixture.Wire.modelAID
    let modelRepoID = ReadinessProducerFixture.Wire.modelARepoID
    let modelDisplayName = ReadinessProducerFixture.Wire.modelDisplayName
    let modelRevision: String? = ReadinessProducerFixture.Wire.modelARevision
    let dimension = 2

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.enumerated().map { index, _ in
            index.isMultiple(of: 2) ? [1, 0] : [0, 1]
        }
    }
}

private final class ReadinessUnusedRuntimeClient: RuntimeClientProtocol, @unchecked Sendable {
    private let modelID = ModelID()

    func connect() async throws {}

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded, modelID: request.modelID)
    }

    func generate(_ request: GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func cancelGeneration(_ generationID: GenerationID) async throws -> CancelGenerationResponse {
        CancelGenerationResponse(status: .cancelled, generationID: generationID)
    }

    func recentEvents(
        for generationID: GenerationID,
        after sequenceNumber: Int
    ) async throws -> [GenerationEvent] {
        []
    }

    func unloadModel() async throws -> UnloadModelResponse {
        UnloadModelResponse(status: .unloaded)
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        LoadModelResponse(status: .loaded, modelID: modelID)
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        RuntimeStatus(
            state: .modelLoaded,
            loadedModelID: modelID,
            activeGenerationID: nil,
            message: nil,
            metrics: nil
        )
    }

    func restartRuntimeService() async throws {}
}

private extension String {
    func slice(from start: String, through end: String) -> String? {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.lowerBound ..< endIndex) else {
            return nil
        }
        return String(self[startRange.lowerBound ..< endRange.upperBound])
    }
}
