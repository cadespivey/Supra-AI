import Foundation
import SupraDiagnostics
import SupraStore
@testable import SupraSessions
import XCTest

/// T-PROBE-13 freezes the content-complete, re-scorable raw record emitted by
/// the installed-model RAG control before app-target orchestration is added.
final class NativeRAGControlRecordTests: XCTestCase {
    func testRawControlRecordRoundTripsEveryEvidenceAndResourceFact() throws {
        let record = NativeRAGControlRunRecord(
            controlID: "native-rag-control-v1",
            sourceCommitSHA: String(repeating: "a", count: 40),
            corpusManifestSHA256: String(repeating: "b", count: 64),
            corpusID: "synthetic-legal",
            corpusVersion: "1.0.0",
            chatModel: .init(
                repositoryID: "synthetic/chat",
                revision: String(repeating: "c", count: 40),
                artifactIdentitySHA256: String(repeating: "d", count: 64)
            ),
            embeddingModel: .init(
                repositoryID: "synthetic/embed",
                revision: String(repeating: "e", count: 40),
                artifactIdentitySHA256: String(repeating: "f", count: 64)
            ),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_010),
            importSummary: .init(discovered: 1, imported: 1, failed: 0, indexedDocuments: 1),
            queries: [
                NativeRAGControlQueryRecord(
                    queryID: "query-1",
                    scopeArtifactIDs: ["artifact-1"],
                    coldRetrievalMilliseconds: 17,
                    warmRetrievalMilliseconds: 3,
                    coldExecutionReceipt: nil,
                    warmExecutionReceipt: nil,
                    coldCandidates: [
                        .init(
                            artifactID: "artifact-1", documentName: "evidence.txt",
                            locator: "characters 0-21", excerpt: "Synthetic evidence only.",
                            rank: 1, score: 0.031, ftsMatched: true,
                            semanticBucket: "high"
                        ),
                    ],
                    warmCandidates: [],
                    totalLatencyMilliseconds: 91,
                    timeToFirstTokenMilliseconds: 41,
                    answerMarkdown: "Supported [S1].",
                    status: "complete",
                    unsupported: false,
                    failure: nil,
                    warnings: [],
                    citationLabels: ["S1"],
                    packedSources: [
                        .init(
                            artifactID: "artifact-1", citationLabel: "S1",
                            locator: "characters 0-21", excerpt: "Synthetic evidence only."
                        ),
                    ]
                ),
            ],
            memory: .init(
                appCurrentPhysFootprintBytes: 10,
                appPeakPhysFootprintBytes: 20,
                xpcCurrentPhysFootprintBytes: 30,
                xpcPeakPhysFootprintBytes: 40,
                combinedCurrentPhysFootprintBytes: 40,
                combinedPeakPhysFootprintBytes: 60,
                maximumLiveSemanticCacheBytes: 50
            )
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(NativeRAGControlRunRecord.self, from: data)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.queries.only?.coldCandidates.only?.artifactID, "artifact-1")
        XCTAssertEqual(decoded.queries.only?.packedSources.only?.citationLabel, "S1")
        XCTAssertEqual(decoded.queries.only?.unsupported, false)
        XCTAssertEqual(decoded.memory.combinedPeakPhysFootprintBytes, 60)
        XCTAssertEqual(decoded.memory.maximumLiveSemanticCacheBytes, 50)
    }

    func testControlTelemetryReportsLiveSemanticCacheBytes() throws {
        let cache = RAGSemanticCandidateCache(maximumBytes: 4_096)
        let key = RAGDerivedCacheKey(
            querySHA256: String(repeating: "7", count: 64),
            matterID: "native-control-matter",
            documentIDs: ["native-control-document"],
            readinessReceiptIDs: ["native-control-readiness"],
            embeddingModel: DocumentReadinessEmbeddingModelIdentity(
                id: "native-control-model",
                repoID: "synthetic/native-control-model",
                revision: "revision-1",
                dimension: 3
            ),
            artifactIdentitySHA256: String(repeating: "a", count: 64),
            pageSize: 3,
            candidateLimit: 2,
            minimumSimilarity: 0.5,
            retrievalDepth: "deep",
            algorithmVersion: 1
        )
        let access = RAGDerivedCacheAccess(
            readinessReceiptIDs: ["native-control-readiness"],
            allDocumentsBaseReady: true,
            policyAllowsUse: true
        )
        try cache.store(
            RAGSemanticCandidateCacheValue(candidates: [
                RAGCachedSemanticCandidate(
                    chunkID: "native-control-chunk",
                    documentID: "native-control-document",
                    similarity: 0.9
                ),
            ]),
            for: key,
            access: access
        )

        XCTAssertGreaterThan(RAGSemanticCandidateCacheMetrics.liveBytes, 0)
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
