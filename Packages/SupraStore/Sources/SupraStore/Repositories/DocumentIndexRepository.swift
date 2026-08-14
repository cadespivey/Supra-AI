import Foundation
import GRDB
import SupraCore

/// Owns extraction parts, chunks, the FTS5 chunk index, and chunk embeddings
/// (Milestone 3). Re-chunking replaces parts/chunks transactionally and keeps
/// the FTS index and (via cascade) embeddings consistent.
public final class DocumentIndexRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: - Pages / parts

    /// Replaces all parts for a document in one transaction.
    public func replaceParts(documentID: String, parts: [DocumentPagePartRecord]) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM document_pages_parts WHERE document_id = ?", arguments: [documentID])
            for part in parts {
                try part.insert(db)
            }
        }
    }

    /// Replaces the normalized text of a single part (user edit, plan §6.2).
    public func updatePartText(partID: String, text: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE document_pages_parts SET normalized_text = ?, char_count = ?, updated_at = ? WHERE id = ?",
                arguments: [text, text.count, Date(), partID]
            )
        }
    }

    public func fetchParts(documentID: String) throws -> [DocumentPagePartRecord] {
        try writer.read { db in
            try DocumentPagePartRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_pages_parts WHERE document_id = ? ORDER BY part_index ASC",
                arguments: [documentID]
            )
        }
    }

    /// Total extracted characters per document (SUM of the parts' `char_count`),
    /// keyed by document id and scoped to one matter. A single GROUP BY so callers
    /// that gate on text volume — e.g. the classification-floor check behind the
    /// Documents tab's "not yet classified" prompt — don't fetch parts per document.
    /// Documents with no parts are absent from the result (treat as 0).
    public func fetchTotalCharCounts(matterID: String) throws -> [String: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT p.document_id AS document_id, SUM(p.char_count) AS total_char_count
                FROM document_pages_parts p
                JOIN matter_documents d ON d.id = p.document_id
                WHERE d.matter_id = ?
                GROUP BY p.document_id
                """,
                arguments: [matterID]
            )
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["document_id"] as String, row["total_char_count"] as Int)
            })
        }
    }

    // MARK: - Chunks + FTS

    /// Replaces all chunks for a document and rebuilds its FTS rows in one
    /// transaction. Deleting old chunks cascades to remove now-stale embeddings.
    public func replaceChunks(documentID: String, chunks: [DocumentChunkRecord]) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM document_chunks WHERE document_id = ?", arguments: [documentID])
            try db.execute(sql: "DELETE FROM document_chunk_fts WHERE document_id = ?", arguments: [documentID])
            for chunk in chunks {
                try chunk.insert(db)
                try db.execute(
                    sql: "INSERT INTO document_chunk_fts (text, chunk_id, document_id) VALUES (?, ?, ?)",
                    arguments: [chunk.normalizedText, chunk.id, documentID]
                )
            }
        }
    }

    /// Replaces chunks and their exact FTS projection, then marks the text index
    /// complete, only while the selected part lineage and configured chunker
    /// still match the producer's observed snapshot.
    public func commitTextIndex(
        _ command: DocumentTextIndexCommitCommand
    ) throws -> DocumentTextIndexCommitReceipt {
        try writer.write { database in
            guard try MatterDocumentRecord.fetchOne(database, key: command.documentID) != nil else {
                throw DocumentReadinessTransitionError.documentNotFound(command.documentID)
            }
            let parts = try DocumentPagePartRecord.fetchAll(
                database,
                sql: """
                    SELECT *
                    FROM document_pages_parts
                    WHERE document_id = ?
                    ORDER BY part_index, id
                    """,
                arguments: [command.documentID]
            )
            let currentBindings = parts.map {
                DocumentReadinessPartBinding(
                    partIndex: $0.partIndex,
                    partID: $0.id,
                    currentRevisionID: $0.currentRevisionID,
                    currentSelectionID: $0.currentSelectionID
                )
            }
            guard currentBindings == command.expectedPartBindings else {
                throw DocumentReadinessTransitionError.partBindingsChanged(command.documentID)
            }
            guard let settings = try DocumentIntelligenceSettingsRecord.fetchOne(
                database,
                key: DocumentIntelligenceSettingsRecord.singletonID
            ) else {
                throw DocumentReadinessTransitionError.settingsNotFound
            }
            guard settings.chunkerVersion == command.expectedChunkerVersion else {
                throw DocumentReadinessTransitionError.chunkerVersionChanged(
                    expected: command.expectedChunkerVersion,
                    actual: settings.chunkerVersion
                )
            }

            let chunks = command.chunks.sorted {
                ($0.chunkIndex, $0.id) < ($1.chunkIndex, $1.id)
            }
            try Self.validateTextIndexBatch(
                chunks,
                documentID: command.documentID,
                expectedBindings: currentBindings,
                chunkerVersion: command.expectedChunkerVersion
            )

            try database.execute(
                sql: "DELETE FROM document_chunks WHERE document_id = ?",
                arguments: [command.documentID]
            )
            try database.execute(
                sql: "DELETE FROM document_chunk_fts WHERE document_id = ?",
                arguments: [command.documentID]
            )
            for chunk in chunks {
                try chunk.insert(database)
                try database.execute(
                    sql: """
                        INSERT INTO document_chunk_fts (text, chunk_id, document_id)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [chunk.normalizedText, chunk.id, command.documentID]
                )
            }
            try database.execute(
                sql: """
                    UPDATE matter_documents
                    SET index_status = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    DocumentIndexStatus.textIndexed.rawValue,
                    Date(),
                    command.documentID,
                ]
            )

            guard let document = try MatterDocumentRecord.fetchOne(
                database,
                key: command.documentID
            ) else {
                throw DocumentReadinessTransitionError.documentNotFound(command.documentID)
            }
            let readiness = try DocumentReadinessRepository.deriveReceipt(
                for: document,
                in: database
            )
            guard readiness.partBindings == currentBindings,
                  readiness.chunkerVersion == command.expectedChunkerVersion,
                  readiness.chunkIDs == chunks.map(\.id),
                  !readiness.exclusions.contains(.staleRevision),
                  !readiness.exclusions.contains(.textIndexIncomplete),
                  readiness.textIndexedChunkCount == chunks.count else {
                throw DocumentReadinessTransitionError.textIndexPostconditionFailed(
                    command.documentID
                )
            }
            return DocumentTextIndexCommitReceipt(
                documentID: command.documentID,
                partBindings: readiness.partBindings,
                chunkerVersion: readiness.chunkerVersion,
                chunkIDs: readiness.chunkIDs,
                readinessReceipt: readiness
            )
        }
    }

    public func fetchChunks(documentID: String) throws -> [DocumentChunkRecord] {
        try writer.read { db in
            try DocumentChunkRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_chunks WHERE document_id = ? ORDER BY chunk_index ASC",
                arguments: [documentID]
            )
        }
    }

    public func fetchChunk(id: String) throws -> DocumentChunkRecord? {
        try writer.read { db in try DocumentChunkRecord.fetchOne(db, key: id) }
    }

    /// Matter-scoped full-text search over ready chunks, optionally restricted to
    /// a set of document instances (the Q&A/search scope). The user query is
    /// sanitized into a safe FTS5 OR-of-prefixes expression.
    public func searchChunks(
        matterID: String,
        query: String,
        documentIDs: [String]? = nil,
        limit: Int = 50
    ) throws -> [DocumentChunkRecord] {
        guard let ftsQuery = Self.ftsMatchExpression(query) else { return [] }
        return try writer.read { db in
            var sql = """
            SELECT c.* FROM document_chunk_fts fts
            JOIN document_chunks c ON c.id = fts.chunk_id
            JOIN matter_documents d ON d.id = c.document_id
            WHERE d.matter_id = ? AND d.deleted_at IS NULL AND fts.text MATCH ?
            """
            var arguments: [DatabaseValueConvertible] = [matterID, ftsQuery]
            if let documentIDs {
                guard !documentIDs.isEmpty else { return [] }
                sql += " AND d.id IN (\(databaseQuestionMarks(count: documentIDs.count)))"
                arguments.append(contentsOf: documentIDs)
            }
            sql += " ORDER BY fts.rank LIMIT ?"
            arguments.append(limit)
            return try DocumentChunkRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    public func fetchChunks(ids: [String]) throws -> [DocumentChunkRecord] {
        guard !ids.isEmpty else { return [] }
        return try writer.read { db in
            try DocumentChunkRecord.fetchAll(
                db,
                sql: "SELECT * FROM document_chunks WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
                arguments: StatementArguments(ids)
            )
        }
    }

    /// Turns arbitrary user text into a safe FTS5 MATCH expression: alphanumeric
    /// tokens joined by OR as prefix queries. Returns nil when there are no usable
    /// tokens (so callers can skip the search).
    static func ftsMatchExpression(_ query: String) -> String? {
        let tokens = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }

    // MARK: - Embeddings

    /// Inserts or replaces the embedding for a chunk under a given model.
    public func upsertEmbedding(_ embedding: DocumentChunkEmbeddingRecord) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM document_chunk_embeddings WHERE chunk_id = ? AND embedding_model_id = ?",
                arguments: [embedding.chunkID, embedding.embeddingModelID]
            )
            try embedding.insert(db)
        }
    }

    /// Replaces the selected model's vectors for one exact current chunk set and
    /// promotes terminal flags only after the complete, verified batch exists.
    public func commitSemanticIndex(
        _ command: DocumentSemanticIndexCommitCommand
    ) throws -> DocumentSemanticIndexCommitReceipt {
        try writer.write { database in
            guard let document = try MatterDocumentRecord.fetchOne(
                database,
                key: command.documentID
            ) else {
                throw DocumentReadinessTransitionError.documentNotFound(command.documentID)
            }
            let chunks = try DocumentChunkRecord.fetchAll(
                database,
                sql: """
                    SELECT *
                    FROM document_chunks
                    WHERE document_id = ?
                    ORDER BY chunk_index, id
                    """,
                arguments: [command.documentID]
            )
            guard !chunks.isEmpty,
                  chunks.map(\.id) == command.expectedChunkIDs else {
                throw DocumentReadinessTransitionError.chunksChanged(command.documentID)
            }
            guard let settings = try DocumentIntelligenceSettingsRecord.fetchOne(
                database,
                key: DocumentIntelligenceSettingsRecord.singletonID
            ) else {
                throw DocumentReadinessTransitionError.settingsNotFound
            }
            guard settings.selectedEmbeddingModelID == command.expectedActiveModel.id else {
                throw DocumentReadinessTransitionError.modelSelectionInconsistent(
                    command.expectedActiveModel.id
                )
            }
            guard let model = try DocumentEmbeddingModelRecord.fetchOne(
                database,
                key: command.expectedActiveModel.id
            ) else {
                throw DocumentReadinessTransitionError.modelNotFound(
                    command.expectedActiveModel.id
                )
            }
            let persistedIdentity = DocumentReadinessEmbeddingModelIdentity(
                id: model.id,
                repoID: model.repoID,
                revision: model.revision,
                dimension: model.dimension
            )
            guard persistedIdentity == command.expectedActiveModel,
                  model.dimension > 0 else {
                throw DocumentReadinessTransitionError.modelIdentityChanged(model.id)
            }
            guard model.lastTestLoadResult == "passed",
                  model.lastTestLoadAt != nil else {
                throw DocumentReadinessTransitionError.modelNotVerified(model.id)
            }
            guard model.lastTestLoadAt == command.expectedModelVerifiedAt,
                  settings.embeddingModelLastTestedAt == command.expectedModelVerifiedAt else {
                throw DocumentReadinessTransitionError.modelVerificationChanged(model.id)
            }
            let selectedModelIDs = try String.fetchAll(
                database,
                sql: """
                    SELECT id
                    FROM document_embedding_models
                    WHERE is_selected = 1
                    ORDER BY id
                    """
            )
            guard selectedModelIDs == [model.id] else {
                throw DocumentReadinessTransitionError.modelSelectionInconsistent(model.id)
            }

            let before = try DocumentReadinessRepository.deriveReceipt(
                for: document,
                in: database
            )
            guard before.activeEmbeddingModel == persistedIdentity,
                  !before.exclusions.contains(.staleRevision),
                  !before.exclusions.contains(.textIndexIncomplete),
                  !before.exclusions.contains(.selectionInconsistent),
                  !before.exclusions.contains(.unverified) else {
                throw DocumentReadinessTransitionError.chunksChanged(command.documentID)
            }
            try Self.validateSemanticIndexBatch(
                command.embeddings,
                documentID: command.documentID,
                chunks: chunks,
                model: model
            )

            try database.execute(
                sql: """
                    DELETE FROM document_chunk_embeddings
                    WHERE document_id = ? AND embedding_model_id = ?
                    """,
                arguments: [command.documentID, model.id]
            )
            let embeddingsByChunkID = Dictionary(
                uniqueKeysWithValues: command.embeddings.map { ($0.chunkID, $0) }
            )
            let embeddings = try chunks.map { chunk in
                guard let embedding = embeddingsByChunkID[chunk.id] else {
                    throw DocumentReadinessTransitionError.invalidEmbeddingBatch(
                        "one current chunk has no vector"
                    )
                }
                try embedding.insert(database)
                return embedding
            }

            let persistedEmbeddingCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM document_chunk_embeddings
                    WHERE document_id = ? AND embedding_model_id = ?
                    """,
                arguments: [command.documentID, model.id]
            ) ?? 0
            guard persistedEmbeddingCount == chunks.count else {
                throw DocumentReadinessTransitionError.invalidEmbeddingBatch(
                    "the complete current vector set was not persisted"
                )
            }

            try database.execute(
                sql: """
                    UPDATE matter_documents
                    SET index_status = ?,
                        status = CASE
                            WHEN status IN (?, ?) THEN ?
                            ELSE status
                        END,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    DocumentIndexStatus.ready.rawValue,
                    MatterDocumentStatus.indexing.rawValue,
                    MatterDocumentStatus.embedding.rawValue,
                    MatterDocumentStatus.ready.rawValue,
                    Date(),
                    command.documentID,
                ]
            )

            guard let promotedDocument = try MatterDocumentRecord.fetchOne(
                database,
                key: command.documentID
            ) else {
                throw DocumentReadinessTransitionError.documentNotFound(command.documentID)
            }
            let readiness = try DocumentReadinessRepository.deriveReceipt(
                for: promotedDocument,
                in: database
            )
            guard readiness.activeEmbeddingModel == persistedIdentity,
                  readiness.chunkIDs == command.expectedChunkIDs,
                  readiness.semanticIndexedChunkCount == chunks.count,
                  !readiness.exclusions.contains(.semanticIndexIncomplete) else {
                throw DocumentReadinessTransitionError.semanticIndexPostconditionFailed(
                    command.documentID
                )
            }
            return DocumentSemanticIndexCommitReceipt(
                documentID: command.documentID,
                chunkIDs: readiness.chunkIDs,
                activeModel: persistedIdentity,
                verifiedAt: command.expectedModelVerifiedAt,
                embeddingIDs: embeddings.map(\.id),
                readinessReceipt: readiness
            )
        }
    }

    public func fetchEmbeddings(documentID: String, embeddingModelID: String) throws -> [DocumentChunkEmbeddingRecord] {
        try writer.read { db in
            try DocumentChunkEmbeddingRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM document_chunk_embeddings
                WHERE document_id = ? AND embedding_model_id = ?
                """,
                arguments: [documentID, embeddingModelID]
            )
        }
    }

    /// True only when the document has at least one current chunk and every
    /// current chunk has a vector for the requested embedding model. A single
    /// old-model vector or a partial new-model write is never semantic-ready.
    public func hasCompleteEmbeddings(documentID: String, embeddingModelID: String) throws -> Bool {
        try writer.read { db in
            let chunkCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM document_chunks WHERE document_id = ?",
                arguments: [documentID]
            ) ?? 0
            guard chunkCount > 0 else { return false }
            let embeddedChunkCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(DISTINCT e.chunk_id)
                FROM document_chunk_embeddings e
                JOIN document_chunks c ON c.id = e.chunk_id
                WHERE c.document_id = ? AND e.embedding_model_id = ?
                """,
                arguments: [documentID, embeddingModelID]
            ) ?? 0
            return embeddedChunkCount == chunkCount
        }
    }

    /// All embeddings for a matter under a model, for app-side cosine retrieval.
    public func fetchEmbeddings(matterID: String, embeddingModelID: String) throws -> [DocumentChunkEmbeddingRecord] {
        try writer.read { db in
            try DocumentChunkEmbeddingRecord.fetchAll(
                db,
                sql: """
                SELECT e.* FROM document_chunk_embeddings e
                JOIN matter_documents d ON d.id = e.document_id
                WHERE d.matter_id = ? AND d.deleted_at IS NULL AND e.embedding_model_id = ?
                """,
                arguments: [matterID, embeddingModelID]
            )
        }
    }

    private static func validateTextIndexBatch(
        _ chunks: [DocumentChunkRecord],
        documentID: String,
        expectedBindings: [DocumentReadinessPartBinding],
        chunkerVersion: Int
    ) throws {
        guard chunkerVersion > 0,
              !expectedBindings.isEmpty,
              !chunks.isEmpty else {
            throw DocumentReadinessTransitionError.invalidChunkBatch(
                "the part graph, chunker, and chunk set must be nonempty"
            )
        }
        let partIDs = expectedBindings.map(\.partID)
        let partIndexes = expectedBindings.map(\.partIndex)
        let selectedRevisionIDs = expectedBindings.compactMap(\.currentRevisionID)
        guard Set(partIDs).count == expectedBindings.count,
              Set(partIndexes).count == expectedBindings.count,
              selectedRevisionIDs.count == expectedBindings.count,
              expectedBindings.allSatisfy({ $0.currentSelectionID != nil }) else {
            throw DocumentReadinessTransitionError.invalidChunkBatch(
                "the selected part lineage is incomplete or duplicated"
            )
        }
        let revisionByPartID = Dictionary(
            uniqueKeysWithValues: zip(partIDs, selectedRevisionIDs)
        )
        let chunkIDs = chunks.map(\.id)
        let chunkIndexes = chunks.map(\.chunkIndex)
        guard Set(chunkIDs).count == chunks.count,
              Set(chunkIndexes).count == chunks.count,
              chunkIndexes == Array(0 ..< chunks.count),
              chunks.allSatisfy({
                  !$0.id.isEmpty
                      && $0.documentID == documentID
                      && $0.chunkerVersion == chunkerVersion
                      && !$0.normalizedText.isEmpty
              }) else {
            throw DocumentReadinessTransitionError.invalidChunkBatch(
                "chunk identities, order, scope, version, or text are invalid"
            )
        }
        for chunk in chunks {
            guard let partID = chunk.pagePartID,
                  let revisionID = chunk.revisionID,
                  revisionByPartID[partID] == revisionID else {
                throw DocumentReadinessTransitionError.invalidChunkBatch(
                    "a chunk is not bound to its part's current selected revision"
                )
            }
        }
        guard Set(chunks.compactMap(\.pagePartID)) == Set(partIDs),
              Set(chunks.compactMap(\.revisionID)) == Set(selectedRevisionIDs) else {
            throw DocumentReadinessTransitionError.invalidChunkBatch(
                "the chunk batch does not cover the exact selected part lineage"
            )
        }
    }

    private static func validateSemanticIndexBatch(
        _ embeddings: [DocumentChunkEmbeddingRecord],
        documentID: String,
        chunks: [DocumentChunkRecord],
        model: DocumentEmbeddingModelRecord
    ) throws {
        let currentChunkIDs = chunks.map(\.id)
        guard embeddings.count == chunks.count,
              Set(embeddings.map(\.id)).count == embeddings.count,
              Set(embeddings.map(\.chunkID)) == Set(currentChunkIDs) else {
            throw DocumentReadinessTransitionError.invalidEmbeddingBatch(
                "the batch must contain exactly one uniquely identified vector per current chunk"
            )
        }
        for embedding in embeddings {
            guard !embedding.id.isEmpty,
                  embedding.documentID == documentID,
                  embedding.embeddingModelID == model.id,
                  embedding.modelDisplayName == model.displayName,
                  embedding.modelRevision == model.revision,
                  embedding.dimension == model.dimension,
                  embedding.normalized,
                  isFiniteUnitVector(embedding.vector, dimension: model.dimension) else {
                throw DocumentReadinessTransitionError.invalidEmbeddingBatch(
                    "a vector's document, chunk, model, dimension, or normalization proof is invalid"
                )
            }
        }
    }

    private static func isFiniteUnitVector(_ data: Data, dimension: Int) -> Bool {
        guard dimension > 0 else { return false }
        let expectedByteCount = dimension.multipliedReportingOverflow(
            by: MemoryLayout<UInt32>.size
        )
        guard !expectedByteCount.overflow,
              data.count == expectedByteCount.partialValue else {
            return false
        }
        let normSquared = data.withUnsafeBytes { bytes -> Double? in
            var result = 0.0
            for offset in stride(from: 0, to: data.count, by: MemoryLayout<UInt32>.size) {
                let stored = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                let value = Float(bitPattern: UInt32(littleEndian: stored))
                guard value.isFinite else { return nil }
                result += Double(value) * Double(value)
            }
            return result.isFinite ? result : nil
        }
        guard let normSquared else { return false }
        return abs(normSquared - 1) <= 0.001
    }

}
