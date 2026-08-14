import CryptoKit
import Foundation
@testable import SupraDiagnostics
import XCTest

/// T-RAG-TRACE-01
///
/// Expected RED before WP-3.3: Diagnostics has no whitelist-encoded,
/// content-free RAG execution receipt or redacted Advanced export.
final class ArchitectureUXTRagTrace01Tests: XCTestCase {
    func testReceiptWhitelistsOpaqueVersionRankTimingAndResourceFacts() throws {
        let query = "QUERY_713_PRIVILEGED_TRACE_CANARY"
        let source = "T_RAG_TRACE_01_WIRE_731-source-file.pdf"
        let receipt = try RAGExecutionReceipt(
            executionID: "rag-execution-731",
            retrievalAlgorithmVersion: 7,
            querySHA256: digest(query),
            scopeSHA256: digest("scope-719"),
            readinessReceiptSetSHA256: digest("readiness-727"),
            embeddingArtifactIdentitySHA256: digest("artifact-733"),
            chunkerVersion: 2,
            retrievalDepth: "deep",
            startedAtUnixMilliseconds: 731_713,
            elapsedMilliseconds: 719,
            lexicalCandidateCount: 7,
            semantic: RAGExecutionSemanticFacts(
                pageSize: 3,
                candidateLimit: 2,
                pageCount: 7,
                scannedRows: 31,
                rejectedRows: 1,
                maximumLivePageRows: 3,
                maximumHeapEntries: 2,
                maximumLiveVectorBytes: 36,
                cacheDisposition: .computed
            ),
            ranks: [
                RAGExecutionRankFact(
                    candidateIdentitySHA256: digest(source),
                    rank: 1,
                    scoreBucket: .high,
                    selected: true
                ),
                RAGExecutionRankFact(
                    candidateIdentitySHA256: digest("candidate-739"),
                    rank: 2,
                    scoreBucket: .medium,
                    selected: false
                ),
            ]
        )

        let encoded = try JSONEncoder().encode(receipt)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(Set(root.keys), [
            "receipt_id",
            "schema_version",
            "execution_id",
            "retrieval_algorithm_version",
            "query_sha256",
            "scope_sha256",
            "readiness_receipt_set_sha256",
            "embedding_artifact_identity_sha256",
            "chunker_version",
            "retrieval_depth",
            "started_at_unix_milliseconds",
            "elapsed_milliseconds",
            "lexical_candidate_count",
            "semantic",
            "ranks",
        ])
        XCTAssertEqual(receipt.schemaVersion, 1)
        XCTAssertEqual(receipt.retrievalAlgorithmVersion, 7)
        XCTAssertEqual(receipt.semantic.pageSize, 3)
        XCTAssertEqual(receipt.semantic.candidateLimit, 2)
        XCTAssertEqual(receipt.semantic.maximumLiveVectorBytes, 36)
        XCTAssertEqual(receipt.ranks.map(\.rank), [1, 2])
        XCTAssertEqual(receipt.ranks.first?.candidateIdentitySHA256, digest(source))
        XCTAssertEqual(receipt.receiptID.count, 64)

        let text = String(decoding: encoded, as: UTF8.self)
        for canary in [
            query,
            source,
            "PROMPT-CANARY-743",
            "ANSWER-CANARY-751",
            "CREDENTIAL-CANARY-757",
            "/Users/synthetic-client/T_RAG_TRACE_01_WIRE_731.pdf",
            "DEFAULT-000",
        ] {
            XCTAssertFalse(text.contains(canary))
        }
        XCTAssertTrue(text.contains(digest(query)))
        XCTAssertTrue(text.contains(digest(source)))
    }

    func testAdvancedExportIsContentFreeAndDeterministic() throws {
        let receipt = try RAGExecutionReceipt(
            executionID: "rag-export-execution-761",
            retrievalAlgorithmVersion: 8,
            querySHA256: digest("QUERY_713"),
            scopeSHA256: digest("scope-769"),
            readinessReceiptSetSHA256: digest("readiness-773"),
            embeddingArtifactIdentitySHA256: nil,
            chunkerVersion: 2,
            retrievalDepth: "fast",
            startedAtUnixMilliseconds: 761_713,
            elapsedMilliseconds: 727,
            lexicalCandidateCount: 1,
            semantic: RAGExecutionSemanticFacts(
                pageSize: 3,
                candidateLimit: 2,
                pageCount: 0,
                scannedRows: 0,
                rejectedRows: 0,
                maximumLivePageRows: 0,
                maximumHeapEntries: 0,
                maximumLiveVectorBytes: 0,
                cacheDisposition: .bypassed
            ),
            ranks: []
        )
        let exporter = RAGExecutionReceiptAdvancedExporter()
        let first = try exporter.render([receipt])
        let second = try exporter.render([receipt])
        XCTAssertEqual(first, second)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: first) as? [String: Any]
        )
        XCTAssertEqual(Set(root.keys), ["export_schema_version", "redaction", "receipts"])
        XCTAssertEqual(root["redaction"] as? String, "content_free_v1")
        XCTAssertEqual((root["receipts"] as? [[String: Any]])?.count, 1)
        let text = String(decoding: first, as: UTF8.self)
        XCTAssertFalse(text.contains("QUERY_713"))
        XCTAssertFalse(text.contains("T_RAG_TRACE_01_WIRE_731"))
        XCTAssertFalse(text.contains("DEFAULT-000"))
    }
}

private func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
