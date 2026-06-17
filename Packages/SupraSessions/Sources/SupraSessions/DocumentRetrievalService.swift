import Foundation
import SupraCore
import SupraDocuments
import SupraStore

/// A Q&A/search source scope (plan §8.1). All filters nil → the whole matter.
public struct RetrievalScope: Codable, Sendable, Equatable {
    public var folderIDs: [String]?
    public var documentIDs: [String]?
    public var tagIDs: [String]?
    public var dateStart: Date?
    public var dateEnd: Date?

    public init(folderIDs: [String]? = nil, documentIDs: [String]? = nil, tagIDs: [String]? = nil, dateStart: Date? = nil, dateEnd: Date? = nil) {
        self.folderIDs = folderIDs
        self.documentIDs = documentIDs
        self.tagIDs = tagIDs
        self.dateStart = dateStart
        self.dateEnd = dateEnd
    }

    public static let wholeMatter = RetrievalScope()
}

/// One retrieved source candidate with its locator and why it was selected
/// (plan §7.4).
public struct RetrievedSource: Sendable {
    public var chunkID: String
    public var documentID: String
    public var documentName: String
    public var locator: DocumentSourceLocator
    public var excerpt: String
    public var text: String
    public var score: Double
    public var ftsMatched: Bool
    public var semanticBucket: String?
    public var ocrConfidence: Double?
    public var duplicateLocations: [String]
    public var rank: Int
}

/// Readiness of a scope for Q&A/chronology (plan §8.1). Generation is blocked
/// until the selected scope is fully indexed.
public struct ScopeReadiness: Sendable, Equatable {
    public var totalDocuments: Int
    public var readyDocuments: Int
    public var pendingDocuments: Int
    public var requiresSemanticIndex: Bool
    public var isFullyReady: Bool
}

public struct RetrievalResult: Sendable {
    public var sources: [RetrievedSource]
    public var readiness: ScopeReadiness
    public var incompleteScopeWarning: String?
    public var usedSemantic: Bool
    public var query: String
    public var scopeDocumentIDs: [String]
}

/// Hybrid retrieval over a matter's indexed chunks: FTS keyword ranking +
/// (optional) local semantic similarity, with folder/tag/date/document filters,
/// duplicate collapse, and source diversity (plan §7.4).
public final class DocumentRetrievalService: @unchecked Sendable {
    private let store: SupraStore
    private let embedder: (any TextEmbedder)?
    private let maxPerDocument: Int
    private let minSemanticSimilarity: Double

    public init(
        store: SupraStore,
        embedder: (any TextEmbedder)? = nil,
        maxPerDocument: Int = 4,
        minSemanticSimilarity: Double = 0.15
    ) {
        self.store = store
        self.embedder = embedder
        self.maxPerDocument = maxPerDocument
        self.minSemanticSimilarity = minSemanticSimilarity
    }

    /// Whether the selected scope is fully indexed (text + semantic when an
    /// embedder is configured). Immediate; no model work (plan §13.3).
    public func scopeReadiness(matterID: String, scope: RetrievalScope) throws -> ScopeReadiness {
        let docIDs = Set(try resolveScope(matterID: matterID, scope: scope))
        let documents = try store.documentLibrary.fetchDocuments(matterID: matterID).filter { docIDs.contains($0.id) }
        let requiresSemantic = embedder != nil
        let ready = documents.filter { Self.isReady($0, requiresSemantic: requiresSemantic) }.count
        return ScopeReadiness(
            totalDocuments: documents.count,
            readyDocuments: ready,
            pendingDocuments: documents.count - ready,
            requiresSemanticIndex: requiresSemantic,
            isFullyReady: !documents.isEmpty && ready == documents.count
        )
    }

    public func retrieve(matterID: String, query: String, scope: RetrievalScope, limit: Int = 12) async throws -> RetrievalResult {
        let scopeIDs = try resolveScope(matterID: matterID, scope: scope)
        let readiness = try scopeReadiness(matterID: matterID, scope: scope)
        let documents = try store.documentLibrary.fetchDocuments(matterID: matterID)
        let nameByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.displayName) })

        // FTS candidates (keyword).
        let ftsHits = try store.documentIndex.searchChunks(matterID: matterID, query: query, documentIDs: scopeIDs, limit: 60)
        var scores: [String: Double] = [:]          // chunkID -> combined score
        var ftsMatched: Set<String> = []
        var chunkByID: [String: DocumentChunkRecord] = [:]
        for (position, chunk) in ftsHits.enumerated() {
            let weight = 1.0 - Double(position) / Double(max(ftsHits.count, 1))
            scores[chunk.id, default: 0] += 0.5 * weight
            ftsMatched.insert(chunk.id)
            chunkByID[chunk.id] = chunk
        }

        // Semantic candidates (cosine over normalized vectors == dot product).
        var semanticBucket: [String: String] = [:]
        var usedSemantic = false
        if let embedder, let queryVector = try await embedQuery(query, embedder: embedder) {
            usedSemantic = true
            let scopeSet = Set(scopeIDs)
            let embeddings = try store.documentIndex.fetchEmbeddings(matterID: matterID, embeddingModelID: embedder.modelID)
                .filter { scopeSet.contains($0.documentID) }
            var ranked: [(chunkID: String, score: Double)] = []
            for embedding in embeddings {
                let similarity = Double(VectorMath.dot(queryVector, VectorMath.decode(embedding.vector)))
                // Only relevant chunks count; this keeps off-topic documents out of
                // scope-restricted answers.
                if similarity >= minSemanticSimilarity {
                    ranked.append((embedding.chunkID, similarity))
                }
            }
            ranked.sort { $0.score > $1.score }
            for (position, entry) in ranked.prefix(60).enumerated() {
                let weight = 1.0 - Double(position) / 60.0
                scores[entry.chunkID, default: 0] += 0.5 * weight
                semanticBucket[entry.chunkID] = entry.score > 0.7 ? "high" : (entry.score > 0.45 ? "medium" : "low")
            }
        }

        // Hydrate any chunks only found via semantic search.
        let missingIDs = scores.keys.filter { chunkByID[$0] == nil }
        for chunk in try store.documentIndex.fetchChunks(ids: Array(missingIDs)) {
            chunkByID[chunk.id] = chunk
        }

        // Rank, then collapse duplicates by normalized text, then apply source
        // diversity (cap per document).
        let ordered = scores.sorted { $0.value > $1.value }
        var seenText: [String: Int] = [:]   // text hash -> index in result
        var perDocument: [String: Int] = [:]
        var sources: [RetrievedSource] = []
        for (chunkID, score) in ordered {
            guard let chunk = chunkByID[chunkID] else { continue }
            let textKey = DocumentStorageDigest.key(chunk.normalizedText)
            if let existingIndex = seenText[textKey] {
                // Duplicate content in another instance — note the location, collapse.
                let otherName = nameByID[chunk.documentID] ?? "another document"
                if !sources[existingIndex].duplicateLocations.contains(otherName) {
                    sources[existingIndex].duplicateLocations.append(otherName)
                }
                continue
            }
            if perDocument[chunk.documentID, default: 0] >= maxPerDocument { continue }
            perDocument[chunk.documentID, default: 0] += 1

            let locator = DocumentSourceLocator(
                sourceKind: DocumentSourceKind(rawValue: chunk.sourceKind) ?? .text,
                pageIndex: chunk.pageIndex, pageLabel: chunk.pageLabel,
                sheetName: chunk.sheetName, cellRange: chunk.cellRange,
                emailPartPath: chunk.emailPartPath, charStart: chunk.charStart,
                charEnd: chunk.charEnd, boundingBoxesJSON: chunk.boundingBoxesJSON
            )
            seenText[textKey] = sources.count
            sources.append(RetrievedSource(
                chunkID: chunk.id,
                documentID: chunk.documentID,
                documentName: nameByID[chunk.documentID] ?? "Document",
                locator: locator,
                excerpt: chunk.displayExcerpt ?? DocumentChunker.excerpt(chunk.normalizedText),
                text: chunk.normalizedText,
                score: score,
                ftsMatched: ftsMatched.contains(chunk.id),
                semanticBucket: semanticBucket[chunk.id],
                ocrConfidence: chunk.ocrConfidence,
                duplicateLocations: [],
                rank: 0
            ))
            if sources.count >= limit { break }
        }
        for index in sources.indices { sources[index].rank = index }

        var warning: String?
        if !readiness.isFullyReady {
            warning = "Search scope is still indexing: \(readiness.readyDocuments)/\(readiness.totalDocuments) documents ready."
        }

        return RetrievalResult(
            sources: sources, readiness: readiness, incompleteScopeWarning: warning,
            usedSemantic: usedSemantic, query: query, scopeDocumentIDs: scopeIDs
        )
    }

    private func embedQuery(_ query: String, embedder: any TextEmbedder) async throws -> [Float]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let vector = try await embedder.embed([trimmed]).first else { return nil }
        return VectorMath.normalize(vector)
    }

    private func resolveScope(matterID: String, scope: RetrievalScope) throws -> [String] {
        try store.documentLibrary.resolveScopeDocumentIDs(
            matterID: matterID,
            folderIDs: scope.folderIDs,
            documentIDs: scope.documentIDs,
            tagIDs: scope.tagIDs,
            dateStart: scope.dateStart,
            dateEnd: scope.dateEnd
        )
    }

    private static func isReady(_ document: MatterDocumentRecord, requiresSemantic: Bool) -> Bool {
        switch DocumentIndexStatus(rawValue: document.indexStatus) {
        case .ready:
            return true
        case .semanticIndexed:
            return true
        case .textIndexed:
            return !requiresSemantic
        default:
            return false
        }
    }
}

/// Small stable digest used to collapse duplicate chunk content across instances.
enum DocumentStorageDigest {
    static func key(_ text: String) -> String {
        DocumentStorage.sha256Hex(of: Data(text.utf8))
    }
}
