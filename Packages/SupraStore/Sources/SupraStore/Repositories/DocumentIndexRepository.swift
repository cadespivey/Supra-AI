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

}
