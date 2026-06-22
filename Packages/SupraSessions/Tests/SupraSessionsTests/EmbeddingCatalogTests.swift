import XCTest
@testable import SupraSessions

final class EmbeddingCatalogTests: XCTestCase {
    func testQueryTextPrependsInstructionForBGEFamily() {
        let prepared = EmbeddingModelCatalog.queryText("contract termination clause", forModelID: "BAAI/bge-base-en-v1.5")
        XCTAssertTrue(prepared.hasPrefix("Represent this sentence for searching relevant passages: "))
        XCTAssertTrue(prepared.hasSuffix("contract termination clause"))
    }

    func testQueryTextLeavesNonInstructionAndUnknownModelsRaw() {
        // Nomic uses symmetric prefixes; we leave it raw to match existing (un-prefixed)
        // passage embeddings until a re-index path exists.
        XCTAssertEqual(EmbeddingModelCatalog.queryText("x", forModelID: "nomic-ai/nomic-embed-text-v1.5"), "x")
        // A model not in the catalog (e.g. user-registered) is returned unchanged.
        XCTAssertEqual(EmbeddingModelCatalog.queryText("x", forModelID: "acme/custom-embedder"), "x")
    }
}
