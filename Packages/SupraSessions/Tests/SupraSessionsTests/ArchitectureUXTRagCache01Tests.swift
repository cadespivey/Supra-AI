import CryptoKit
import Foundation
@testable import SupraSessions
import SupraStore
import XCTest

/// T-RAG-CACHE-01
///
/// Expected RED before WP-3.3: there is no content-free, version-bound semantic
/// candidate cache, complete key matrix, or use-bound readiness/policy check.
final class ArchitectureUXTRagCache01Tests: XCTestCase {
    func testExactKeyMatrixMissesAndUseBoundaryRevalidatesAuthority() throws {
        let baseline = makeRAGCacheKey()
        let access = RAGDerivedCacheAccess(
            readinessReceiptIDs: ["readiness-receipt-731"],
            allDocumentsBaseReady: true,
            policyAllowsUse: true
        )
        let value = RAGSemanticCandidateCacheValue(
            candidates: [
                RAGCachedSemanticCandidate(
                    chunkID: "cache-candidate-731",
                    documentID: "cache-document-731",
                    similarity: 0.731
                ),
            ]
        )
        let cache = RAGSemanticCandidateCache(maximumBytes: 4_096)
        try cache.store(value, for: baseline, access: access)

        XCTAssertEqual(try cache.load(for: baseline, access: access), value)

        let variants = [
            makeRAGCacheKey(querySHA256: digest("QUERY_719")),
            makeRAGCacheKey(matterID: "cache-matter-733"),
            makeRAGCacheKey(documentIDs: ["cache-document-739"]),
            makeRAGCacheKey(readinessReceiptIDs: ["readiness-receipt-743"]),
            makeRAGCacheKey(modelID: "cache-model-751"),
            makeRAGCacheKey(modelRepoID: "synthetic/cache-model-757"),
            makeRAGCacheKey(modelRevision: "cache-model-revision-8"),
            makeRAGCacheKey(artifactIdentitySHA256: String(repeating: "b", count: 64)),
            makeRAGCacheKey(modelDimension: 7),
            makeRAGCacheKey(pageSize: 7),
            makeRAGCacheKey(candidateLimit: 7),
            makeRAGCacheKey(minimumSimilarity: 0.719),
            makeRAGCacheKey(retrievalDepth: "fast"),
            makeRAGCacheKey(algorithmVersion: 8),
        ]
        XCTAssertEqual(Set(variants).count, variants.count)
        for variant in variants {
            XCTAssertNil(try cache.load(for: variant, access: access))
        }

        XCTAssertNil(try cache.load(
            for: baseline,
            access: RAGDerivedCacheAccess(
                readinessReceiptIDs: access.readinessReceiptIDs,
                allDocumentsBaseReady: false,
                policyAllowsUse: true
            )
        ))
        XCTAssertNil(try cache.load(
            for: baseline,
            access: RAGDerivedCacheAccess(
                readinessReceiptIDs: access.readinessReceiptIDs,
                allDocumentsBaseReady: true,
                policyAllowsUse: false
            )
        ))
        XCTAssertNil(try cache.load(
            for: baseline,
            access: RAGDerivedCacheAccess(
                readinessReceiptIDs: ["readiness-receipt-761"],
                allDocumentsBaseReady: true,
                policyAllowsUse: true
            )
        ))
        XCTAssertEqual(
            try cache.load(for: baseline, access: access),
            value,
            "an authority denial bypasses but does not rewrite an exact content-bound entry"
        )

        let encoded = String(decoding: try JSONEncoder().encode(
            RAGCacheEncodingProbe(key: baseline, value: value)
        ), as: UTF8.self)
        XCTAssertFalse(encoded.contains("QUERY_713"))
        XCTAssertFalse(encoded.contains("T_RAG_CACHE_01_WIRE_731"))
        XCTAssertFalse(encoded.contains("DEFAULT-000"))
        XCTAssertTrue(encoded.contains(digest("QUERY_713")))
        XCTAssertTrue(encoded.contains("readiness-receipt-731"))
    }

    func testShippingRetrieverHitsExactRetryAndMissesAfterSourceRevisionChanges() async throws {
        let fixture = try ArchitectureUXRagScanFixture.make(prefix: "cache-01-shipping")
        defer { fixture.remove() }
        let documentID = try fixture.addDocument(
            id: "cache-document-731",
            vectors: [("cache-candidate-731", [1, 0, 0])]
        )
        let embedder = CountingRAGCacheEmbedder()
        let cache = RAGSemanticCandidateCache(maximumBytes: 4_096)
        let service = DocumentRetrievalService(
            store: fixture.store,
            embedder: embedder,
            maxPerDocument: 2,
            minSemanticSimilarity: 0.5,
            semanticCandidateCache: cache,
            semanticScanPageSize: 3,
            semanticCandidateLimit: 2
        )

        let first = try await service.retrieve(
            matterID: fixture.matterID,
            query: "QUERY_713",
            scope: .wholeMatter,
            limit: 2
        )
        let exactRetry = try await service.retrieve(
            matterID: fixture.matterID,
            query: "QUERY_713",
            scope: .wholeMatter,
            limit: 2
        )
        XCTAssertEqual(embedder.callCount, 1)
        XCTAssertEqual(first.sources.map(\.chunkID), exactRetry.sources.map(\.chunkID))
        XCTAssertEqual(first.sources.first?.chunkID, "cache-candidate-731")
        XCTAssertFalse(first.sources.map(\.chunkID).contains("DEFAULT-000"))

        let alteredArtifactEmbedder = CountingRAGCacheEmbedder(
            artifactIdentitySHA256: String(repeating: "b", count: 64)
        )
        let alteredArtifactService = DocumentRetrievalService(
            store: fixture.store,
            embedder: alteredArtifactEmbedder,
            maxPerDocument: 2,
            minSemanticSimilarity: 0.5,
            semanticCandidateCache: cache,
            semanticScanPageSize: 3,
            semanticCandidateLimit: 2
        )
        _ = try await alteredArtifactService.retrieve(
            matterID: fixture.matterID,
            query: "QUERY_713",
            scope: .wholeMatter,
            limit: 2
        )
        XCTAssertEqual(
            alteredArtifactEmbedder.callCount,
            1,
            "the same model metadata with altered artifact identity must miss"
        )

        let nextText = "T_RAG_CACHE_01_WIRE_731 QUERY_713 revision 8"
        let nextRevision = try fixture.store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: "cache-revision-8",
                documentID: documentID,
                partIndex: 0,
                derivationKey: "cache-derivation-8",
                origin: "synthetic_test",
                method: "plain_text",
                text: nextText,
                charCount: nextText.count,
                toolchainVersion: "synthetic-8",
                supersedesRevisionID: "revision-\(documentID)-7"
            )
        )
        _ = try fixture.store.documentRevisions.appendSelection(
            DocumentPartSelectionRecord(
                id: "cache-selection-8",
                documentID: documentID,
                partIndex: 0,
                selectedRevisionID: nextRevision.id,
                selectionKey: "cache-selection-key-8",
                selectedBy: "synthetic_policy",
                policyVersion: 8,
                decisionJSON: #"{"wire":"T_RAG_CACHE_01_WIRE_731_N_PLUS_1_8"}"#,
                supersedesSelectionID: "selection-\(documentID)-7"
            )
        )

        _ = try await service.retrieve(
            matterID: fixture.matterID,
            query: "QUERY_713",
            scope: .wholeMatter,
            limit: 2
        )
        XCTAssertEqual(
            embedder.callCount,
            2,
            "a new Store readiness/source receipt must not reuse the prior semantic result"
        )

        let source = try String(contentsOf: retrievalSourceURL(), encoding: .utf8)
        XCTAssertTrue(source.contains("RAGSemanticCandidateCacheResolver"))
        XCTAssertTrue(source.contains("baseReceiptID"))
        XCTAssertFalse(source.contains("fetchEmbeddings(matterID:"))
    }

    private func retrievalSourceURL() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
            .appendingPathComponent("Sources")
            .appendingPathComponent("SupraSessions")
            .appendingPathComponent("DocumentRetrievalService.swift")
    }
}

private struct RAGCacheEncodingProbe: Codable {
    let key: RAGDerivedCacheKey
    let value: RAGSemanticCandidateCacheValue
}

private final class CountingRAGCacheEmbedder: TextEmbedder, @unchecked Sendable {
    let modelID = ArchitectureUXRagScanFixture.modelID
    let modelRepoID = ArchitectureUXRagScanFixture.modelRepoID
    let modelDisplayName = ArchitectureUXRagScanFixture.modelDisplayName
    let modelRevision: String? = ArchitectureUXRagScanFixture.modelRevision
    let artifactIdentitySHA256: String?
    let dimension = ArchitectureUXRagScanFixture.dimension

    private let lock = NSLock()
    private var calls = 0

    init(artifactIdentitySHA256: String = String(repeating: "a", count: 64)) {
        self.artifactIdentitySHA256 = artifactIdentitySHA256
    }

    var callCount: Int { lock.withLock { calls } }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        lock.withLock { calls += 1 }
        return texts.map { _ in [1, 0, 0] }
    }
}

private func makeRAGCacheKey(
    querySHA256: String = digest("QUERY_713"),
    matterID: String = "cache-matter-731",
    documentIDs: [String] = ["cache-document-731"],
    readinessReceiptIDs: [String] = ["readiness-receipt-731"],
    modelID: String = "cache-model-713",
    modelRepoID: String = "synthetic/cache-model-713",
    modelRevision: String? = "cache-model-revision-7",
    artifactIdentitySHA256: String = String(repeating: "a", count: 64),
    modelDimension: Int = 3,
    pageSize: Int = 3,
    candidateLimit: Int = 2,
    minimumSimilarity: Double = 0.713,
    retrievalDepth: String = "deep",
    algorithmVersion: Int = 7
) -> RAGDerivedCacheKey {
    RAGDerivedCacheKey(
        querySHA256: querySHA256,
        matterID: matterID,
        documentIDs: documentIDs,
        readinessReceiptIDs: readinessReceiptIDs,
        embeddingModel: DocumentReadinessEmbeddingModelIdentity(
            id: modelID,
            repoID: modelRepoID,
            revision: modelRevision,
            dimension: modelDimension
        ),
        artifactIdentitySHA256: artifactIdentitySHA256,
        pageSize: pageSize,
        candidateLimit: candidateLimit,
        minimumSimilarity: minimumSimilarity,
        retrievalDepth: retrievalDepth,
        algorithmVersion: algorithmVersion
    )
}

private func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
