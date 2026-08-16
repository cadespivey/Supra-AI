import CryptoKit
import Foundation
import SupraDiagnostics
@testable import SupraSessions
import SupraStore
import XCTest

/// T-RAG-TRACE-02
///
/// Expected RED before WP-3.3: retrieval publishes no content-free execution
/// receipt, and no typed boundary prevents operational diagnostics from being
/// used as readiness, provenance, egress, authority, or publication evidence.
final class ArchitectureUXTRagTrace02Tests: XCTestCase {
    func testShippingRetrievalPublishesComputedThenCacheHitReceipts() async throws {
        let fixture = try ArchitectureUXRagScanFixture.make(prefix: "trace-02")
        defer { fixture.remove() }
        let rawCandidateID = "T_RAG_TRACE_02_WIRE_731-candidate-731"
        _ = try fixture.addDocument(
            id: "trace-02-document-731",
            vectors: [(rawCandidateID, [1, 0, 0])]
        )
        let service = DocumentRetrievalService(
            store: fixture.store,
            embedder: RAGTraceEmbedder(),
            maxPerDocument: 2,
            minSemanticSimilarity: 0.5,
            semanticCandidateCache: RAGSemanticCandidateCache(maximumBytes: 4_096),
            semanticScanPageSize: 3,
            semanticCandidateLimit: 2
        )

        let first = try await service.retrieve(
            matterID: fixture.matterID,
            query: "QUERY_713",
            scope: .wholeMatter,
            limit: 2
        )
        let retry = try await service.retrieve(
            matterID: fixture.matterID,
            query: "QUERY_713",
            scope: .wholeMatter,
            limit: 2
        )
        let firstReceipt = try XCTUnwrap(first.executionReceipt)
        let retryReceipt = try XCTUnwrap(retry.executionReceipt)
        XCTAssertEqual(firstReceipt.semantic.cacheDisposition, .computed)
        XCTAssertEqual(firstReceipt.semantic.pageSize, 3)
        XCTAssertEqual(firstReceipt.semantic.candidateLimit, 2)
        XCTAssertEqual(firstReceipt.semantic.scannedRows, 1)
        XCTAssertEqual(firstReceipt.ranks.first?.candidateIdentitySHA256, digestTrace(rawCandidateID))
        XCTAssertEqual(retryReceipt.semantic.cacheDisposition, .hit)
        XCTAssertEqual(retryReceipt.semantic.scannedRows, 0)
        XCTAssertNotEqual(firstReceipt.executionID, retryReceipt.executionID)

        let exported = try RAGExecutionReceiptAdvancedExporter().render([
            firstReceipt,
            retryReceipt,
        ])
        let exportText = String(decoding: exported, as: UTF8.self)
        XCTAssertFalse(exportText.contains("QUERY_713"))
        XCTAssertFalse(exportText.contains(rawCandidateID))
        XCTAssertFalse(exportText.contains("DEFAULT-000"))
    }

    func testOperationalReceiptCannotAuthorizeOrCompleteLegalWork() throws {
        let receipt = try RAGExecutionReceipt(
            executionID: "rag-boundary-execution-739",
            retrievalAlgorithmVersion: 7,
            querySHA256: digestTrace("QUERY_713"),
            scopeSHA256: digestTrace("scope-743"),
            readinessReceiptSetSHA256: digestTrace("readiness-751"),
            embeddingArtifactIdentitySHA256: digestTrace("artifact-757"),
            chunkerVersion: 2,
            retrievalDepth: "deep",
            startedAtUnixMilliseconds: 739_713,
            elapsedMilliseconds: 731,
            lexicalCandidateCount: 1,
            semantic: RAGExecutionSemanticFacts(
                pageSize: 3,
                candidateLimit: 2,
                pageCount: 1,
                scannedRows: 1,
                rejectedRows: 0,
                maximumLivePageRows: 1,
                maximumHeapEntries: 1,
                maximumLiveVectorBytes: 12,
                cacheDisposition: .computed
            ),
            ranks: []
        )
        let boundary = RAGExecutionReceiptAuthorityBoundary()
        let counter = RAGTraceSideEffectCounter()
        let prohibited: [RAGExecutionReceiptUse] = [
            .egressAuthorization,
            .documentReadiness,
            .sourceProvenance,
            .legalAuthority,
            .legalAggregateCompletion,
        ]
        for use in prohibited {
            XCTAssertThrowsError(
                try boundary.perform(receipt: receipt, use: use) {
                    counter.increment()
                    return "MUTATED-\(use.rawValue)"
                }
            ) { error in
                XCTAssertEqual(
                    error as? RAGExecutionReceiptAuthorityError,
                    .prohibitedUse(use)
                )
            }
        }
        XCTAssertEqual(counter.value, 0)

        let operational = try boundary.perform(
            receipt: receipt,
            use: .operationalDiagnostics
        ) {
            counter.increment()
            return receipt.receiptID
        }
        XCTAssertEqual(operational, receipt.receiptID)
        XCTAssertEqual(counter.value, 1)

        let structuredOutputSource = try String(
            contentsOf: sourceURL(named: "StructuredOutputController.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(structuredOutputSource.contains("RAGExecutionReceipt"))
        XCTAssertFalse(structuredOutputSource.contains("operationalDiagnostics"))
    }

    private func sourceURL(named name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Sources/SupraSessions/\(name)")
    }
}

private struct RAGTraceEmbedder: TextEmbedder {
    let modelID = ArchitectureUXRagScanFixture.modelID
    let modelRepoID = ArchitectureUXRagScanFixture.modelRepoID
    let modelDisplayName = ArchitectureUXRagScanFixture.modelDisplayName
    let modelRevision: String? = ArchitectureUXRagScanFixture.modelRevision
    let artifactIdentitySHA256: String? = String(repeating: "a", count: 64)
    let dimension = ArchitectureUXRagScanFixture.dimension

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0, 0] }
    }
}

private final class RAGTraceSideEffectCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private func digestTrace(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
