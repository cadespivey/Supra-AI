import Foundation
@testable import SupraSessions
import XCTest

/// T-RAG-SCAN-01
///
/// Expected RED before WP-3.3: semantic retrieval fetches every vector for a
/// matter/model, materializes decoded arrays, and fully sorts them in memory.
final class ArchitectureUXTRagScan01Tests: XCTestCase {
    func testScopedPagedHeapMatchesReferenceAndRejectsInvalidRows() throws {
        let fixture = try ArchitectureUXRagScanFixture.make(prefix: "scan-01")
        defer { fixture.remove() }

        let primary = try fixture.addDocument(
            id: "t-rag-scan-primary-731",
            vectors: [
                ("candidate-a-731", [0.8, 0.6, 0]),
                ("candidate-b-731", [0.8, 0, 0.6]),
                ("candidate-c-731", [0.6, 0.8, 0]),
                ("candidate-low-731", [0.2, 0.9797959, 0]),
            ]
        )
        _ = try fixture.addDocument(
            id: "t-rag-scan-deleted-739",
            vectors: [("candidate-deleted-739", [1, 0, 0])],
            deleted: true
        )
        _ = try fixture.addDocument(
            id: "t-rag-scan-foreign-743",
            matterID: fixture.foreignMatterID,
            vectors: [("candidate-foreign-743", [1, 0, 0])]
        )
        _ = try fixture.addDocument(
            id: "t-rag-scan-stale-751",
            vectors: [("candidate-stale-751", [1, 0, 0])],
            advanceSelectionAfterIndex: true
        )
        _ = try fixture.addDocument(
            id: "t-rag-scan-wrong-model-757",
            vectors: [("candidate-wrong-model-757", [1, 0, 0])],
            embeddingModelID: "wrong-model-757"
        )
        _ = try fixture.addDocument(
            id: "t-rag-scan-malformed-761",
            vectors: [("candidate-malformed-761", [1, 0, 0])],
            malformedVectorData: Data([0x01, 0x02, 0x03, 0x04])
        )
        _ = try fixture.addDocument(
            id: "t-rag-scan-outside-scope-769",
            vectors: [("candidate-outside-scope-769", [1, 0, 0])]
        )

        let instrumentation = BoundedSemanticScanInstrumentation()
        let scanner = BoundedSemanticScanner(
            store: fixture.store,
            instrumentation: instrumentation
        )
        let result = try scanner.scan(
            matterID: fixture.matterID,
            documentIDs: [
                primary,
                "t-rag-scan-deleted-739",
                "t-rag-scan-stale-751",
                "t-rag-scan-wrong-model-757",
                "t-rag-scan-malformed-761",
            ],
            queryVector: [1, 0, 0],
            activeModel: fixture.activeModel,
            configuration: BoundedSemanticScanConfiguration(
                pageSize: ArchitectureUXRagScanFixture.pageSize,
                candidateLimit: ArchitectureUXRagScanFixture.candidateK,
                minimumSimilarity: 0.5
            )
        )

        let reference = [
            (chunkID: "candidate-a-731", documentID: primary, similarity: Double(Float(0.8))),
            (chunkID: "candidate-b-731", documentID: primary, similarity: Double(Float(0.8))),
            (chunkID: "candidate-c-731", documentID: primary, similarity: Double(Float(0.6))),
        ].sorted {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            return $0.chunkID < $1.chunkID
        }.prefix(ArchitectureUXRagScanFixture.candidateK)

        XCTAssertEqual(result.candidates.map(\.chunkID), reference.map(\.chunkID))
        XCTAssertEqual(result.candidates.map(\.documentID), reference.map(\.documentID))
        XCTAssertEqual(result.candidates.map(\.similarity), reference.map(\.similarity))
        XCTAssertEqual(result.metrics.pageSize, 3)
        XCTAssertLessThanOrEqual(result.metrics.maximumLivePageRows, 3)
        XCTAssertLessThanOrEqual(result.metrics.maximumHeapEntries, 2)
        XCTAssertLessThanOrEqual(
            result.metrics.maximumLiveVectorBytes,
            3 * 3 * MemoryLayout<Float>.size
        )
        XCTAssertFalse(result.candidates.map(\.chunkID).contains("candidate-deleted-739"))
        XCTAssertFalse(result.candidates.map(\.chunkID).contains("candidate-foreign-743"))
        XCTAssertFalse(result.candidates.map(\.chunkID).contains("candidate-stale-751"))
        XCTAssertFalse(result.candidates.map(\.chunkID).contains("candidate-wrong-model-757"))
        XCTAssertFalse(result.candidates.map(\.chunkID).contains("candidate-malformed-761"))
        XCTAssertFalse(result.candidates.map(\.chunkID).contains("candidate-outside-scope-769"))
        XCTAssertFalse(result.candidates.map(\.chunkID).contains(ArchitectureUXRagScanFixture.forbiddenDefault))
        XCTAssertNotEqual(result.metrics.candidateLimit, 60)

        let source = try String(contentsOf: retrievalSourceURL(), encoding: .utf8)
        XCTAssertTrue(source.contains("BoundedSemanticScanner"))
        XCTAssertFalse(
            source.contains("fetchEmbeddings(matterID:"),
            "the shipping retriever cannot materialize the matter-wide vector table"
        )
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
