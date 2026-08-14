import Foundation
import GRDB
import SupraCore
@testable import SupraStore
import XCTest

/// WP-1.2 indexing transition-ownership RED. Publishing replacement chunks,
/// exact FTS rows, and the text-index status is one Store transition. Publishing
/// a complete vector batch and both terminal statuses is another.
///
/// Expected RED: `DocumentTextIndexCommitCommand`,
/// `DocumentTextIndexCommitReceipt`, `commitTextIndex`,
/// `DocumentSemanticIndexCommitCommand`, `DocumentSemanticIndexCommitReceipt`,
/// and `commitSemanticIndex` do not exist. Current callers replace chunks, write
/// vectors one at a time, and promote flags in separate transactions.
final class ArchitectureUXTDataReadyIndexCommitTests: XCTestCase {
    private enum TextWriteBoundary: String, CaseIterable {
        case firstChunk = "first-current-chunk-8"
        case secondChunk = "second-current-chunk-8"
        case textIndexStatus = "text-index-status-8"
    }

    private enum SemanticWriteBoundary: String, CaseIterable {
        case firstEmbedding = "first-current-embedding-8"
        case secondEmbedding = "second-current-embedding-8"
        case terminalPromotion = "terminal-ready-promotion-8"
    }

    func testTextIndexCommitRollsBackAtEveryNPlusOneWrite() throws {
        for boundary in TextWriteBoundary.allCases {
            let fixture = try ReadinessTransitionFixture.makeReady()
            try fixture.prepareRevision8Stale()
            let before = try fixture.snapshot()
            try installTextFailure(boundary, fixture: fixture)

            XCTAssertThrowsError(
                try fixture.store.documentIndex.commitTextIndex(
                    try fixture.textIndexCommand()
                ),
                "the synthetic \(boundary.rawValue) write must fail inside the Store command"
            )
            XCTAssertEqual(
                try fixture.snapshot(),
                before,
                "old chunks, FTS rows, vectors, flags, and stale receipt must survive \(boundary.rawValue)"
            )
            XCTAssertEqual(
                try fixture.store.documentIndex.fetchChunks(
                    documentID: ReadinessTransitionFixture.Wire.documentID
                ).map(\.id),
                [
                    ReadinessTransitionFixture.Wire.oldFirstChunkID,
                    ReadinessTransitionFixture.Wire.oldSecondChunkID,
                ]
            )
        }
    }

    func testTextIndexCommitRejectsStaleRevisionOrChunkerIdentityWithoutMutation() throws {
        let probes: [(
            String,
            (ReadinessTransitionFixture) throws -> DocumentTextIndexCommitCommand
        )] = [
            (
                "stale selected revision binding",
                { fixture in
                    var bindings = try fixture.currentPartBindings()
                    let current = bindings[0]
                    bindings[0] = DocumentReadinessPartBinding(
                        partIndex: current.partIndex,
                        partID: current.partID,
                        currentRevisionID: "revision-record-713-9",
                        currentSelectionID: current.currentSelectionID
                    )
                    return DocumentTextIndexCommitCommand(
                        documentID: ReadinessTransitionFixture.Wire.documentID,
                        expectedPartBindings: bindings,
                        expectedChunkerVersion: 2,
                        chunks: fixture.newChunks()
                    )
                }
            ),
            (
                "stale chunker setting",
                { fixture in
                    DocumentTextIndexCommitCommand(
                        documentID: ReadinessTransitionFixture.Wire.documentID,
                        expectedPartBindings: try fixture.currentPartBindings(),
                        expectedChunkerVersion: 1,
                        chunks: fixture.newChunks()
                    )
                }
            ),
        ]

        for (label, makeCommand) in probes {
            let fixture = try ReadinessTransitionFixture.makeReady()
            try fixture.prepareRevision8Stale()
            let command = try makeCommand(fixture)
            let before = try fixture.snapshot()

            XCTAssertThrowsError(
                try fixture.store.documentIndex.commitTextIndex(command),
                label
            )
            XCTAssertEqual(try fixture.snapshot(), before, label)
            XCTAssertFalse(
                String(decoding: before.persistedGraph, as: UTF8.self)
                    .contains(ReadinessTransitionFixture.Wire.forbiddenDefault),
                label
            )
        }
    }

    func testTextIndexCommitPublishesCurrentGraphAndCanonicalReceipt() throws {
        let fixture = try ReadinessTransitionFixture.makeReady()
        try fixture.prepareRevision8Stale()
        let stale = try fixture.store.documentReadiness.fetchReceipt(
            documentID: ReadinessTransitionFixture.Wire.documentID
        )

        let commit: DocumentTextIndexCommitReceipt = try fixture.store.documentIndex
            .commitTextIndex(try fixture.textIndexCommand())
        let canonical = try fixture.store.documentReadiness.fetchReceipt(
            documentID: ReadinessTransitionFixture.Wire.documentID
        )
        let document = try XCTUnwrap(
            fixture.store.documentLibrary.fetchDocument(
                id: ReadinessTransitionFixture.Wire.documentID
            )
        )
        let chunks = try fixture.store.documentIndex.fetchChunks(
            documentID: ReadinessTransitionFixture.Wire.documentID
        )
        let ftsRows = try fixture.textIndexRows()

        XCTAssertEqual(commit.documentID, ReadinessTransitionFixture.Wire.documentID)
        XCTAssertEqual(commit.partBindings, try fixture.currentPartBindings())
        XCTAssertEqual(commit.chunkerVersion, 2)
        XCTAssertEqual(
            commit.chunkIDs,
            [
                ReadinessTransitionFixture.Wire.newFirstChunkID,
                ReadinessTransitionFixture.Wire.newSecondChunkID,
            ]
        )
        XCTAssertEqual(commit.readinessReceipt, canonical)
        XCTAssertEqual(document.indexStatus, DocumentIndexStatus.textIndexed.rawValue)
        XCTAssertEqual(chunks.map(\.id), commit.chunkIDs)
        XCTAssertEqual(
            chunks.map(\.revisionID),
            [
                ReadinessTransitionFixture.Wire.revision8ID,
                ReadinessTransitionFixture.Wire.secondRevision7ID,
            ]
        )
        XCTAssertEqual(chunks.map(\.chunkerVersion), [2, 2])
        XCTAssertEqual(
            ftsRows,
            [
                "\(ReadinessTransitionFixture.Wire.newFirstChunkID)|\(ReadinessTransitionFixture.Wire.firstText8)",
                "\(ReadinessTransitionFixture.Wire.newSecondChunkID)|\(ReadinessTransitionFixture.Wire.secondText7)",
            ]
        )
        XCTAssertTrue(
            try fixture.store.documentIndex.fetchEmbeddings(
                documentID: ReadinessTransitionFixture.Wire.documentID,
                embeddingModelID: ReadinessTransitionFixture.Wire.modelAID
            ).isEmpty,
            "replacing old chunks must cascade away vectors bound to them"
        )
        XCTAssertFalse(canonical.isBaseReady)
        XCTAssertEqual(canonical.primaryExclusion, .semanticIndexIncomplete)
        XCTAssertFalse(canonical.exclusions.contains(.staleRevision))
        XCTAssertFalse(canonical.exclusions.contains(.textIndexIncomplete))
        XCTAssertNotEqual(canonical.receiptID, stale.receiptID)
        XCTAssertFalse(
            canonical.receiptID.contains(ReadinessTransitionFixture.Wire.forbiddenDefault)
        )
    }

    func testStagedTextIndexCommitRollsBackAtEveryNPlusOneWriteWithoutActivatingTarget() throws {
        // Expected RED: the text-index command has no explicit staged-rollout
        // policy, so it rejects target-v2 rows while the fail-safe active
        // default remains v1 and never reaches these exact write boundaries.
        for boundary in TextWriteBoundary.allCases {
            let fixture = try ReadinessTransitionFixture.makeReady()
            try fixture.prepareRevision8Stale()
            try fixture.store.documentSettings.updateSettings {
                $0.chunkerVersion = 1
            }
            let before = try fixture.snapshot()
            try installStagedTextFailure(boundary, fixture: fixture)

            XCTAssertThrowsError(
                try fixture.store.documentIndex.commitTextIndex(
                    try fixture.stagedTextIndexCommand(activeChunkerVersion: 1)
                )
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains(boundary.rawValue),
                    "the staged command must reach \(boundary.rawValue) while v1 remains active: \(error)"
                )
            }
            XCTAssertEqual(
                try fixture.snapshot(),
                before,
                "chunks, FTS, status, vectors, and active v1 must roll back together at \(boundary.rawValue)"
            )
            XCTAssertEqual(
                try fixture.store.documentSettings.loadSettings().chunkerVersion,
                1
            )
        }
    }

    func testStagedTextIndexCommitPublishesTargetProjectionButRemainsFailClosedUntilActivation() throws {
        // Expected RED: there is no explicit command policy that can bind both
        // the observed active v1 default and staged target-v2 projection.
        let fixture = try ReadinessTransitionFixture.makeReady()
        try fixture.prepareRevision8Stale()
        try fixture.store.documentSettings.updateSettings {
            $0.chunkerVersion = 1
        }

        let commit = try fixture.store.documentIndex.commitTextIndex(
            try fixture.stagedTextIndexCommand(activeChunkerVersion: 1)
        )
        let persistedSettings = try fixture.store.documentSettings.loadSettings()
        let stagedReceipt = try fixture.store.documentReadiness.fetchReceipt(
            documentID: ReadinessTransitionFixture.Wire.documentID
        )

        XCTAssertEqual(persistedSettings.chunkerVersion, 1)
        XCTAssertEqual(commit.chunkerVersion, 2)
        XCTAssertEqual(commit.chunkIDs, fixture.newChunks().map(\.id))
        XCTAssertEqual(commit.readinessReceipt, stagedReceipt)
        XCTAssertEqual(stagedReceipt.chunkerVersion, 1)
        XCTAssertTrue(stagedReceipt.exclusions.contains(.staleRevision))
        XCTAssertFalse(stagedReceipt.isBaseReady)
        XCTAssertEqual(
            try fixture.store.documentIndex.fetchChunks(
                documentID: ReadinessTransitionFixture.Wire.documentID
            ).map(\.chunkerVersion),
            [2, 2]
        )
    }

    func testSemanticIndexCommitRollsBackAtEveryNPlusOneWrite() throws {
        for boundary in SemanticWriteBoundary.allCases {
            let fixture = try ReadinessTransitionFixture.makeReady()
            try fixture.prepareTextIndexedForModelB()
            let before = try fixture.snapshot()
            try installSemanticFailure(boundary, fixture: fixture)

            XCTAssertThrowsError(
                try fixture.store.documentIndex.commitSemanticIndex(
                    fixture.semanticIndexCommand()
                ),
                "the synthetic \(boundary.rawValue) write must fail inside the Store command"
            )
            XCTAssertEqual(
                try fixture.snapshot(),
                before,
                "no partial vector batch, terminal flag, or readiness drift is permitted at \(boundary.rawValue)"
            )
            XCTAssertTrue(
                try fixture.store.documentIndex.fetchEmbeddings(
                    documentID: ReadinessTransitionFixture.Wire.documentID,
                    embeddingModelID: ReadinessTransitionFixture.Wire.modelBID
                ).isEmpty
            )
        }
    }

    func testSemanticIndexCommitRejectsStaleModelChunkOrIncompleteBatchWithoutMutation() throws {
        let probes: [(
            String,
            (ReadinessTransitionFixture) -> DocumentSemanticIndexCommitCommand
        )] = [
            (
                "model A is no longer the selected verified identity",
                { fixture in
                    fixture.semanticIndexCommand(
                        expectedActiveModel: ReadinessTransitionFixture.modelAIdentity
                    )
                }
            ),
            (
                "expected chunk identity is stale",
                { fixture in
                    fixture.semanticIndexCommand(
                        expectedChunkIDs: [
                            ReadinessTransitionFixture.Wire.newFirstChunkID,
                            "chunk-record-733-8",
                        ]
                    )
                }
            ),
            (
                "current chunk batch is incomplete",
                { fixture in
                    fixture.semanticIndexCommand(
                        embeddings: [fixture.modelBEmbeddings()[0]]
                    )
                }
            ),
        ]

        for (label, makeCommand) in probes {
            let fixture = try ReadinessTransitionFixture.makeReady()
            try fixture.prepareTextIndexedForModelB()
            let command = makeCommand(fixture)
            let before = try fixture.snapshot()

            XCTAssertThrowsError(
                try fixture.store.documentIndex.commitSemanticIndex(command),
                label
            )
            XCTAssertEqual(try fixture.snapshot(), before, label)
            XCTAssertEqual(
                before.readinessReceipt.primaryExclusion,
                .semanticIndexIncomplete,
                label
            )
        }
    }

    func testSemanticIndexCommitPublishesWholeBatchAndTerminalReadyReceipt() throws {
        let fixture = try ReadinessTransitionFixture.makeReady()
        try fixture.prepareTextIndexedForModelB()
        let incomplete = try fixture.store.documentReadiness.fetchReceipt(
            documentID: ReadinessTransitionFixture.Wire.documentID
        )

        let commit: DocumentSemanticIndexCommitReceipt = try fixture.store.documentIndex
            .commitSemanticIndex(fixture.semanticIndexCommand())
        let canonical = try fixture.store.documentReadiness.fetchReceipt(
            documentID: ReadinessTransitionFixture.Wire.documentID
        )
        let document = try XCTUnwrap(
            fixture.store.documentLibrary.fetchDocument(
                id: ReadinessTransitionFixture.Wire.documentID
            )
        )
        let embeddings = try fixture.store.documentIndex.fetchEmbeddings(
            documentID: ReadinessTransitionFixture.Wire.documentID,
            embeddingModelID: ReadinessTransitionFixture.Wire.modelBID
        ).sorted { $0.chunkID < $1.chunkID }

        XCTAssertEqual(commit.documentID, ReadinessTransitionFixture.Wire.documentID)
        XCTAssertEqual(
            commit.chunkIDs,
            [
                ReadinessTransitionFixture.Wire.newFirstChunkID,
                ReadinessTransitionFixture.Wire.newSecondChunkID,
            ]
        )
        XCTAssertEqual(commit.activeModel, ReadinessTransitionFixture.modelBIdentity)
        XCTAssertEqual(
            commit.verifiedAt,
            ReadinessTransitionFixture.Wire.modelBVerifiedAt
        )
        XCTAssertEqual(
            Set(commit.embeddingIDs),
            Set(["embedding-record-713-8", "embedding-record-719-8"])
        )
        XCTAssertEqual(commit.readinessReceipt, canonical)
        XCTAssertEqual(document.status, MatterDocumentStatus.ready.rawValue)
        XCTAssertEqual(document.indexStatus, DocumentIndexStatus.ready.rawValue)
        XCTAssertEqual(embeddings.count, 2)
        XCTAssertEqual(
            Set(embeddings.map(\.chunkID)),
            Set(commit.chunkIDs)
        )
        XCTAssertTrue(embeddings.allSatisfy(\.normalized))
        XCTAssertTrue(embeddings.allSatisfy {
            $0.dimension == ReadinessTransitionFixture.Wire.modelBDimension
        })
        XCTAssertTrue(canonical.isBaseReady)
        XCTAssertNil(canonical.primaryExclusion)
        XCTAssertEqual(canonical.semanticIndexedChunkCount, 2)
        XCTAssertEqual(canonical.activeEmbeddingModel, ReadinessTransitionFixture.modelBIdentity)
        XCTAssertNotEqual(canonical.receiptID, incomplete.receiptID)
        XCTAssertFalse(
            canonical.receiptID.contains(ReadinessTransitionFixture.Wire.forbiddenDefault)
        )
    }

    private func installTextFailure(
        _ boundary: TextWriteBoundary,
        fixture: ReadinessTransitionFixture
    ) throws {
        switch boundary {
        case .firstChunk:
            try installFailureTrigger(
                name: boundary.rawValue,
                timing: "INSERT",
                table: "document_chunks",
                condition: "NEW.id = '\(ReadinessTransitionFixture.Wire.newFirstChunkID)'",
                fixture: fixture
            )
        case .secondChunk:
            try installFailureTrigger(
                name: boundary.rawValue,
                timing: "INSERT",
                table: "document_chunks",
                condition: "NEW.id = '\(ReadinessTransitionFixture.Wire.newSecondChunkID)'",
                fixture: fixture
            )
        case .textIndexStatus:
            try installFailureTrigger(
                name: boundary.rawValue,
                timing: "UPDATE",
                table: "matter_documents",
                condition: "OLD.id = '\(ReadinessTransitionFixture.Wire.documentID)' AND NEW.index_status = 'text_indexed'",
                fixture: fixture
            )
        }
    }

    private func installStagedTextFailure(
        _ boundary: TextWriteBoundary,
        fixture: ReadinessTransitionFixture
    ) throws {
        let activeV1 = "AND (SELECT chunker_version FROM document_intelligence_settings WHERE id = 'default') = 1"
        switch boundary {
        case .firstChunk:
            try installFailureTrigger(
                name: "staged-\(boundary.rawValue)",
                timing: "INSERT",
                table: "document_chunks",
                condition: "NEW.id = '\(ReadinessTransitionFixture.Wire.newFirstChunkID)' \(activeV1)",
                fixture: fixture,
                message: boundary.rawValue
            )
        case .secondChunk:
            try installFailureTrigger(
                name: "staged-\(boundary.rawValue)",
                timing: "INSERT",
                table: "document_chunks",
                condition: "NEW.id = '\(ReadinessTransitionFixture.Wire.newSecondChunkID)' \(activeV1)",
                fixture: fixture,
                message: boundary.rawValue
            )
        case .textIndexStatus:
            try installFailureTrigger(
                name: "staged-\(boundary.rawValue)",
                timing: "UPDATE",
                table: "matter_documents",
                condition: "OLD.id = '\(ReadinessTransitionFixture.Wire.documentID)' AND NEW.index_status = 'text_indexed' \(activeV1)",
                fixture: fixture,
                message: boundary.rawValue
            )
        }
    }

    private func installSemanticFailure(
        _ boundary: SemanticWriteBoundary,
        fixture: ReadinessTransitionFixture
    ) throws {
        switch boundary {
        case .firstEmbedding:
            try installFailureTrigger(
                name: boundary.rawValue,
                timing: "INSERT",
                table: "document_chunk_embeddings",
                condition: "NEW.id = 'embedding-record-713-8'",
                fixture: fixture
            )
        case .secondEmbedding:
            try installFailureTrigger(
                name: boundary.rawValue,
                timing: "INSERT",
                table: "document_chunk_embeddings",
                condition: "NEW.id = 'embedding-record-719-8'",
                fixture: fixture
            )
        case .terminalPromotion:
            try installFailureTrigger(
                name: boundary.rawValue,
                timing: "UPDATE",
                table: "matter_documents",
                condition: "OLD.id = '\(ReadinessTransitionFixture.Wire.documentID)' AND NEW.status = 'ready' AND NEW.index_status = 'ready'",
                fixture: fixture
            )
        }
    }

    private func installFailureTrigger(
        name: String,
        timing: String,
        table: String,
        condition: String,
        fixture: ReadinessTransitionFixture,
        message: String = "synthetic T-DATA-READY index failure"
    ) throws {
        let safeName = "t_data_ready_index_" + name.replacingOccurrences(of: "-", with: "_")
        try fixture.store.database.writer.write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER \(safeName)
                    BEFORE \(timing) ON \(table)
                    WHEN \(condition)
                    BEGIN
                        SELECT RAISE(ABORT, '\(message)');
                    END
                    """
            )
        }
    }
}

extension ReadinessTransitionFixture {
    func textIndexCommand() throws -> DocumentTextIndexCommitCommand {
        DocumentTextIndexCommitCommand(
            documentID: Wire.documentID,
            expectedPartBindings: try currentPartBindings(),
            expectedChunkerVersion: 2,
            chunks: newChunks()
        )
    }

    func stagedTextIndexCommand(
        activeChunkerVersion: Int
    ) throws -> DocumentTextIndexCommitCommand {
        DocumentTextIndexCommitCommand(
            documentID: Wire.documentID,
            expectedPartBindings: try currentPartBindings(),
            expectedChunkerVersion: 2,
            expectedActiveChunkerVersion: activeChunkerVersion,
            chunks: newChunks()
        )
    }

    func semanticIndexCommand(
        expectedChunkIDs: [String] = [Wire.newFirstChunkID, Wire.newSecondChunkID],
        expectedActiveModel: DocumentReadinessEmbeddingModelIdentity = Self.modelBIdentity,
        embeddings: [DocumentChunkEmbeddingRecord]? = nil
    ) -> DocumentSemanticIndexCommitCommand {
        DocumentSemanticIndexCommitCommand(
            documentID: Wire.documentID,
            expectedChunkIDs: expectedChunkIDs,
            expectedActiveModel: expectedActiveModel,
            expectedModelVerifiedAt: Wire.modelBVerifiedAt,
            embeddings: embeddings ?? modelBEmbeddings()
        )
    }

    func textIndexRows() throws -> [String] {
        try store.database.writer.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT chunk_id || '|' || text
                    FROM document_chunk_fts
                    WHERE document_id = ?
                    ORDER BY chunk_id
                    """,
                arguments: [Wire.documentID]
            )
        }
    }
}
