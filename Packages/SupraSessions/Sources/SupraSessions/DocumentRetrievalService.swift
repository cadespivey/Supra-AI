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
    public var revisionID: String? = nil
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
    /// Compact document context shown to the model. Classification/date context is
    /// descriptive; operative/draft state is appended only from confirmed relations.
    /// An unreviewed proposal never becomes an implicit ranking instruction.
    public var metadata: String?
    /// Present only for structure-aware v2 chunks. Hidden provenance is resolved
    /// from the primary node and its same-revision ancestors after ranking.
    public var unitKind: String?
    public var hiddenDerived: Bool

    func groundingSource(sourceID: String, label: String, lowConfidence: Bool) -> GroundingSource {
        GroundingSource(
            sourceID: sourceID,
            label: label,
            documentName: documentName,
            locatorDisplay: locator.displayString,
            text: text,
            excerpt: excerpt,
            lowConfidence: lowConfidence,
            metadata: metadata,
            unitKind: unitKind,
            hiddenDerived: hiddenDerived
        )
    }
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

/// How hard a retrieval pass works (spec §3.1). `.fast` keeps the candidate pool
/// small, raises the semantic floor for precision, and callers skip the LLM rerank —
/// a preliminary answer in seconds. `.deep` is the full pass: wide pool + rerank.
public enum RetrievalDepth: String, Sendable, Equatable {
    case fast
    case deep
}

/// Hybrid retrieval over a matter's indexed chunks: FTS keyword ranking +
/// (optional) local semantic similarity, with folder/tag/date/document filters,
/// duplicate collapse, and source diversity (plan §7.4).
public final class DocumentRetrievalService: @unchecked Sendable {
    static let defaultMaxPerDocument = 4
    static let defaultMinSemanticSimilarity = 0.15
    static let fastMinSemanticSimilarity = 0.25
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
        // Terminally-failed/unsupported documents can never be indexed, so they
        // are excluded from the readiness denominator rather than blocking forever.
        let documents = try store.documentLibrary.fetchDocuments(matterID: matterID)
            .filter { docIDs.contains($0.id) }
            .filter { $0.extractionStatus != DocumentExtractionStatus.failed.rawValue && $0.status != MatterDocumentStatus.failed.rawValue }
        let requiresSemantic = embedder != nil
        var ready = 0
        for document in documents {
            guard Self.isTextReady(document) else { continue }
            guard document.extractionMethod?.hasPrefix("converted_lossy@toolchain:") != true else { continue }
            if let embedder {
                guard try store.documentIndex.hasCompleteEmbeddings(
                    documentID: document.id,
                    embeddingModelID: embedder.modelID
                ) else { continue }
            }
            ready += 1
        }
        return ScopeReadiness(
            totalDocuments: documents.count,
            readyDocuments: ready,
            pendingDocuments: documents.count - ready,
            requiresSemanticIndex: requiresSemantic,
            isFullyReady: !documents.isEmpty && ready == documents.count
        )
    }

    public func retrieve(matterID: String, query: String, scope: RetrievalScope, limit: Int = 12, depth: RetrievalDepth = .deep) async throws -> RetrievalResult {
        // The fast tier trades recall for precision: a higher semantic floor keeps
        // marginally-similar chunks out of the small preliminary packet (spec §3.1).
        let semanticFloor = depth == .fast
            ? max(minSemanticSimilarity, Self.fastMinSemanticSimilarity)
            : minSemanticSimilarity
        let scopeIDs = try resolveScope(matterID: matterID, scope: scope)
        let readiness = try scopeReadiness(matterID: matterID, scope: scope)
        let documents = try store.documentLibrary.fetchDocuments(matterID: matterID)
        let nameByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.displayName) })
        let relations = try store.documentRelations.fetchAll(matterID: matterID)
        let relationMetadataByID = DocumentRelationDownstreamPolicy
            .confirmedMetadataByDocumentID(relations: relations)
        let metadataByID = Dictionary(uniqueKeysWithValues: documents.map { document in
            let parts = [
                Self.contextMetadata(for: document),
                relationMetadataByID[document.id],
            ].compactMap { $0 }
            return (document.id, parts.isEmpty ? nil : parts.joined(separator: " · "))
        })

        // FTS candidates (keyword). Fused with the semantic list by Reciprocal Rank
        // Fusion (RRF): each list contributes 1/(k + rank), summed per chunk. RRF is
        // scale-robust (it ignores raw FTS/cosine magnitudes) and rewards chunks that
        // rank well in BOTH lists — better top-k precision than a length-sensitive
        // linear blend of normalized positions.
        let ftsHits = try store.documentIndex.searchChunks(matterID: matterID, query: query, documentIDs: scopeIDs, limit: 60)
        var scores: [String: Double] = [:]          // chunkID -> combined RRF score
        var ftsMatched: Set<String> = []
        var chunkByID: [String: DocumentChunkRecord] = [:]
        for (position, chunk) in ftsHits.enumerated() {
            scores[chunk.id, default: 0] += Self.rrfContribution(rank: position + 1)
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
                if similarity >= semanticFloor {
                    ranked.append((embedding.chunkID, similarity))
                }
            }
            ranked.sort { $0.score > $1.score }
            for (position, entry) in ranked.prefix(60).enumerated() {
                scores[entry.chunkID, default: 0] += Self.rrfContribution(rank: position + 1)
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
        var structureContextByChunkID: [String: DocumentStructureRetrievalContext] = [:]
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
            let structureContext: DocumentStructureRetrievalContext?
            if chunk.chunkerVersion == 2, let nodeID = chunk.nodeID {
                structureContext = try store.documentStructure.retrievalContext(nodeID: nodeID)
                if let structureContext { structureContextByChunkID[chunk.id] = structureContext }
            } else {
                structureContext = nil
            }
            seenText[textKey] = sources.count
            sources.append(RetrievedSource(
                chunkID: chunk.id,
                revisionID: chunk.revisionID,
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
                rank: 0,
                metadata: metadataByID[chunk.documentID] ?? nil,
                unitKind: chunk.chunkerVersion == 2 ? (chunk.unitKind ?? structureContext?.unitKind) : nil,
                hiddenDerived: structureContext?.hiddenDerived ?? false
            ))
            if sources.count >= limit { break }
        }
        for index in sources.indices { sources[index].rank = index }

        // Expand each selected chunk with its immediate neighbors (same page/part) so
        // an answer that straddles a chunk boundary stays groundable. Skip a neighbor
        // that is itself a selected source to avoid duplicating it in the packet. When
        // neighbors are folded in, widen the locator's char span to cover them so a
        // [S#] cite to content that lives in a neighbor still resolves to a verifiable
        // range, not just the original chunk's narrower span.
        let selectedChunkIDs = Set(sources.map(\.chunkID))
        var chunksByDocument: [String: [DocumentChunkRecord]] = [:]
        for index in sources.indices {
            guard let current = chunkByID[sources[index].chunkID] else { continue }
            let docChunks: [DocumentChunkRecord]
            if let cached = chunksByDocument[current.documentID] {
                docChunks = cached
            } else {
                docChunks = (try? store.documentIndex.fetchChunks(documentID: current.documentID)) ?? []
                chunksByDocument[current.documentID] = docChunks
            }
            let expanded: (text: String, charStart: Int?, charEnd: Int?)
            if current.chunkerVersion == 2,
               let parent = structureContextByChunkID[current.id]?.parent {
                expanded = (parent.text, parent.charStart, parent.charEnd)
            } else {
                expanded = Self.expandedChunk(
                    current: current, inDocumentChunks: docChunks, excluding: selectedChunkIDs
                )
            }
            sources[index].text = expanded.text
            if expanded.text != current.normalizedText {
                if let start = expanded.charStart { sources[index].locator.charStart = start }
                if let end = expanded.charEnd { sources[index].locator.charEnd = end }
            }
        }

        let hasLossyLegacyDocument = documents.contains { document in
            scopeIDs.contains(document.id)
                && document.extractionMethod?.hasPrefix("converted_lossy@toolchain:") == true
        }
        var warnings: [String] = []
        if hasLossyLegacyDocument {
            warnings.append("This scope includes converted_lossy legacy .doc content. Convert the file to .docx or PDF and review the extracted text before making completeness or negative claims.")
        } else if !readiness.isFullyReady {
            warnings.append("Search scope is still indexing: \(readiness.readyDocuments)/\(readiness.totalDocuments) documents ready.")
        }
        let relationWarnings = DocumentRelationDownstreamPolicy.unreviewedReasons(
            relations: relations,
            documents: documents,
            inScopeDocumentIDs: Set(scopeIDs)
        )
        if !relationWarnings.isEmpty {
            warnings.append("Preliminary retrieval warning: " + relationWarnings.joined(separator: " "))
        }
        let warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")

        return RetrievalResult(
            sources: sources, readiness: readiness, incompleteScopeWarning: warning,
            usedSemantic: usedSemantic, query: query, scopeDocumentIDs: scopeIDs
        )
    }

    /// A compact "type · date" descriptor for a document, drawn from the classifier's
    /// primary category and the document's own content date. Surfaced to the model so
    /// it can weigh document type and recency when sources conflict. `nil` when
    /// neither is available.
    static func contextMetadata(for document: MatterDocumentRecord) -> String? {
        var parts: [String] = []
        if let json = document.classificationMetadataJSON,
           let data = json.data(using: .utf8),
           let classification = try? JSONDecoder().decode(DocumentClassification.self, from: data),
           !classification.abstained {
            parts.append(classification.primaryCategory.displayName)
        }
        if let date = document.metadataModifiedAt ?? document.metadataCreatedAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            parts.append(formatter.string(from: date))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Reciprocal Rank Fusion damping constant. 60 is the value from the original
    /// RRF paper and a robust default — large enough that top ranks aren't winner-take-
    /// all, small enough that deep ranks contribute little.
    static let rrfK = 60.0

    /// One ranked list's RRF contribution for a 1-based rank: `1 / (k + rank)`.
    static func rrfContribution(rank: Int) -> Double { 1.0 / (rrfK + Double(rank)) }

    static func expandedChunkText(
        current: DocumentChunkRecord,
        inDocumentChunks docChunks: [DocumentChunkRecord],
        excluding excluded: Set<String> = []
    ) -> String {
        expandedChunk(current: current, inDocumentChunks: docChunks, excluding: excluded).text
    }

    /// The chunk's text expanded with its immediate same-part neighbors (reading
    /// order), plus the char span covered by the included chunks. Neighbors in
    /// `excluding` (already selected as their own source) are skipped so the packet
    /// doesn't repeat them. Returns the chunk alone when it has no eligible neighbors.
    static func expandedChunk(
        current: DocumentChunkRecord,
        inDocumentChunks docChunks: [DocumentChunkRecord],
        excluding excluded: Set<String> = []
    ) -> (text: String, charStart: Int?, charEnd: Int?) {
        let part = docChunks
            .filter { $0.pagePartID == current.pagePartID }
            .sorted { $0.chunkIndex < $1.chunkIndex }
        guard let pos = part.firstIndex(where: { $0.id == current.id }) else {
            return (current.normalizedText, current.charStart, current.charEnd)
        }
        let previous = (pos > 0 && !excluded.contains(part[pos - 1].id)) ? part[pos - 1] : nil
        let next = (pos < part.count - 1 && !excluded.contains(part[pos + 1].id)) ? part[pos + 1] : nil
        let included = [previous, current, next].compactMap { $0 }
        let text = included.map(\.normalizedText).joined(separator: "\n\n")
        return (text, included.compactMap(\.charStart).min(), included.compactMap(\.charEnd).max())
    }

    private func embedQuery(_ query: String, embedder: any TextEmbedder) async throws -> [Float]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Instruction-tuned models (BGE, mxbai) embed queries with an asymmetric
        // prompt; passages stay raw, so this aligns with existing chunk embeddings
        // without re-indexing. Raw for models without one.
        let prepared = EmbeddingModelCatalog.queryText(trimmed, forModelID: embedder.modelRepoID)
        guard let vector = try await embedder.embed([prepared]).first else { return nil }
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

    private static func isTextReady(_ document: MatterDocumentRecord) -> Bool {
        switch DocumentIndexStatus(rawValue: document.indexStatus) {
        case .ready:
            return true
        case .textIndexed:
            return true
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
