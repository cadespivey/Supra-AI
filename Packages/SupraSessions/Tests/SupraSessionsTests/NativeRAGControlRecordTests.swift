import Foundation
import SupraDiagnostics
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
                combinedPeakPhysFootprintBytes: 60
            )
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(NativeRAGControlRunRecord.self, from: data)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.queries.only?.coldCandidates.only?.artifactID, "artifact-1")
        XCTAssertEqual(decoded.queries.only?.packedSources.only?.citationLabel, "S1")
        XCTAssertEqual(decoded.memory.combinedPeakPhysFootprintBytes, 60)
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
