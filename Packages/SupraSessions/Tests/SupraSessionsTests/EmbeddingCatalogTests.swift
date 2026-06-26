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

    func testExpandedCatalogIncludesQwenAndBgeM3WithSupportedFamilies() {
        let supportedFamilies: Set<String> = ["bert", "roberta", "xlm-roberta", "distilbert", "nomic_bert", "qwen3", "gemma3", "gemma3_text", "gemma3n"]
        for model in EmbeddingModelCatalog.curated {
            XCTAssertTrue(supportedFamilies.contains(model.runtimeFamily),
                          "\(model.repoID) uses unsupported runtimeFamily \(model.runtimeFamily)")
        }
        let ids = Set(EmbeddingModelCatalog.curated.map(\.repoID))
        XCTAssertTrue(ids.contains("mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"))
        XCTAssertTrue(ids.contains("mlx-community/Qwen3-Embedding-8B-4bit-DWQ"))
        XCTAssertTrue(ids.contains("BAAI/bge-m3"))
        XCTAssertTrue(ids.contains("nomic-ai/nomic-embed-text-v1.5"))
    }

    func testQwen3QueryGetsInstructionPrefixAndPassagesStayRaw() {
        let q = EmbeddingModelCatalog.queryText("breach of contract elements", forModelID: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ")
        XCTAssertTrue(q.hasPrefix("Instruct:"))
        XCTAssertTrue(q.contains("Query:"))
        XCTAssertTrue(q.hasSuffix("breach of contract elements"))
    }

    func testExactlyOneDefaultModel() {
        XCTAssertEqual(EmbeddingModelCatalog.curated.filter(\.isDefault).count, 1)
    }
}
