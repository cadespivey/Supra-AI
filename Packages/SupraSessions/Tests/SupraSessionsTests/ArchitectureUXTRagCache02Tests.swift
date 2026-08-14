import Foundation
@testable import SupraSessions
import SupraStore
import XCTest

/// T-RAG-CACHE-02
///
/// Expected RED before WP-3.3: there is no byte-costed RAG LRU, deterministic
/// N/N+1 eviction, pressure purge, corruption/fault fallback, or answer-cache
/// absence contract.
final class ArchitectureUXTRagCache02Tests: XCTestCase {
    func testByteCostedLRUEvictsAtNPlusOneAndPurgesOnPressure() {
        let cache = ByteCostedRAGCache<String, String>(maximumBytes: 17)
        XCTAssertTrue(cache.insert("T_RAG_CACHE_02_WIRE_731-A", for: "a-731", byteCost: 8))
        XCTAssertTrue(cache.insert("T_RAG_CACHE_02_WIRE_731-B", for: "b-731", byteCost: 9))
        XCTAssertEqual(cache.snapshot().totalBytes, 17)
        XCTAssertEqual(cache.snapshot().entryCount, 2)

        XCTAssertEqual(cache.value(for: "a-731"), "T_RAG_CACHE_02_WIRE_731-A")
        XCTAssertTrue(cache.insert("T_RAG_CACHE_02_WIRE_731-C", for: "c-731", byteCost: 1))
        XCTAssertEqual(cache.snapshot().totalBytes, 9)
        XCTAssertEqual(cache.value(for: "a-731"), "T_RAG_CACHE_02_WIRE_731-A")
        XCTAssertEqual(cache.value(for: "c-731"), "T_RAG_CACHE_02_WIRE_731-C")
        XCTAssertNil(cache.value(for: "b-731"), "the untouched 9-byte entry is the exact LRU")

        let beforeOversize = cache.snapshot()
        XCTAssertFalse(cache.insert("oversize-739", for: "oversize-739", byteCost: 18))
        XCTAssertEqual(cache.snapshot(), beforeOversize)

        cache.handleMemoryPressure(.warning)
        XCTAssertEqual(cache.snapshot().entryCount, 0)
        XCTAssertEqual(cache.snapshot().totalBytes, 0)
        XCTAssertEqual(cache.snapshot().maximumBytes, 17)
    }

    func testCorruptionAndCacheFailuresFallBackWithoutAnswerCaching() async throws {
        let raw = ByteCostedRAGCache<String, String>(maximumBytes: 17)
        XCTAssertTrue(raw.insert("corrupt-731", for: "corrupt-key-731", byteCost: 7))
        XCTAssertNil(raw.value(for: "corrupt-key-731") { $0 == "valid-731" })
        XCTAssertEqual(raw.snapshot().entryCount, 0)

        let key = makeRAGCache02Key()
        let access = RAGDerivedCacheAccess(
            readinessReceiptIDs: ["cache-02-readiness-731"],
            allDocumentsBaseReady: true,
            policyAllowsUse: true
        )
        let expected = RAGSemanticCandidateCacheValue(
            candidates: [
                RAGCachedSemanticCandidate(
                    chunkID: "cache-02-candidate-731",
                    documentID: "cache-02-document-731",
                    similarity: 0.731
                ),
            ]
        )

        for fault in [FaultingRAGCacheBackend.Fault.load, .store] {
            let backend = FaultingRAGCacheBackend(fault: fault)
            let resolver = RAGSemanticCandidateCacheResolver(cache: backend)
            let counter = RAGCacheComputeCounter()
            let resolution = try await resolver.resolve(
                key: key,
                access: access
            ) {
                counter.increment()
                return expected
            }
            XCTAssertEqual(resolution.value, expected)
            XCTAssertEqual(resolution.source, .computed)
            XCTAssertEqual(counter.value, 1)
        }

        let corrupt = RAGSemanticCandidateCache(maximumBytes: 1_024)
        try corrupt.store(
            RAGSemanticCandidateCacheValue(
                candidates: [
                    RAGCachedSemanticCandidate(
                        chunkID: "cache-02-corrupt-743",
                        documentID: "foreign-document-743",
                        similarity: .nan
                    ),
                ]
            ),
            for: key,
            access: access
        )
        XCTAssertNil(try corrupt.load(for: key, access: access))
        XCTAssertEqual(corrupt.snapshot().entryCount, 0)

        let labels = Set(Mirror(reflecting: expected).children.compactMap(\.label))
        XCTAssertEqual(labels, ["candidates"])
        let encoded = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        XCTAssertFalse(encoded.contains("ANSWER-CANARY-751"))
        XCTAssertFalse(encoded.contains("QUERY_713"))
        XCTAssertFalse(encoded.contains("T_RAG_CACHE_02_WIRE_731"))
        XCTAssertFalse(encoded.contains("DEFAULT-000"))
    }
}

private final class FaultingRAGCacheBackend: RAGSemanticCandidateCacheBackend, @unchecked Sendable {
    enum Fault {
        case load
        case store
    }

    private let fault: Fault

    init(fault: Fault) {
        self.fault = fault
    }

    func load(
        for key: RAGDerivedCacheKey,
        access: RAGDerivedCacheAccess
    ) throws -> RAGSemanticCandidateCacheValue? {
        if fault == .load { throw FaultError.injected }
        return nil
    }

    func store(
        _ value: RAGSemanticCandidateCacheValue,
        for key: RAGDerivedCacheKey,
        access: RAGDerivedCacheAccess
    ) throws {
        if fault == .store { throw FaultError.injected }
    }

    private enum FaultError: Error {
        case injected
    }
}

private final class RAGCacheComputeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private func makeRAGCache02Key() -> RAGDerivedCacheKey {
    RAGDerivedCacheKey(
        querySHA256: String(repeating: "7", count: 64),
        matterID: "cache-02-matter-731",
        documentIDs: ["cache-02-document-731"],
        readinessReceiptIDs: ["cache-02-readiness-731"],
        embeddingModel: DocumentReadinessEmbeddingModelIdentity(
            id: "cache-02-model-713",
            repoID: "synthetic/cache-02-model-713",
            revision: "cache-02-model-revision-7",
            dimension: 3
        ),
        pageSize: 3,
        candidateLimit: 2,
        minimumSimilarity: 0.713,
        retrievalDepth: "deep",
        algorithmVersion: 7
    )
}
