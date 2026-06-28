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

    func testCuratedCatalogUsesOnlyLoadableFamiliesAndDropsFailedOriginals() {
        // Only families MLXEmbedders reliably loads are offered. xlm-roberta is still a
        // supported registry family in principle, but the raw BGE-M3 original failed to
        // load, so it (and the raw Nomic original) were removed.
        let supportedFamilies: Set<String> = ["bert", "roberta", "xlm-roberta", "distilbert", "nomic_bert", "qwen3", "gemma3", "gemma3_text", "gemma3n"]
        for model in EmbeddingModelCatalog.curated {
            XCTAssertTrue(supportedFamilies.contains(model.runtimeFamily),
                          "\(model.repoID) uses unsupported runtimeFamily \(model.runtimeFamily)")
        }
        // Every offered family is one of the two reliably-loadable ones.
        for model in EmbeddingModelCatalog.curated {
            XCTAssertTrue(["bert", "qwen3"].contains(model.runtimeFamily),
                          "\(model.repoID) is not in a verified-loadable family")
        }
        let ids = Set(EmbeddingModelCatalog.curated.map(\.repoID))
        XCTAssertTrue(ids.contains("mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"))
        XCTAssertTrue(ids.contains("mlx-community/Qwen3-Embedding-8B-4bit-DWQ"))
        XCTAssertTrue(ids.contains("mlx-community/mxbai-embed-large-v1"))
        XCTAssertTrue(ids.contains("BAAI/bge-large-en-v1.5"))
        // The raw xlm-roberta (BGE-M3) and nomic_bert (Nomic) originals failed to load
        // and were removed.
        XCTAssertFalse(ids.contains("BAAI/bge-m3"))
        XCTAssertFalse(ids.contains("nomic-ai/nomic-embed-text-v1.5"))
        // Default is the MLX-native Qwen3-Embedding 0.6B.
        XCTAssertEqual(EmbeddingModelCatalog.defaultModel.repoID, "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ")
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
