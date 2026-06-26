import Foundation

/// A curated, downloadable embedding model. Distinct from the chat `CatalogModel`
/// so chat and embedding models are never confused (plan §2.2). `runtimeFamily`
/// matches the MLXEmbedders model-type registry key (e.g. "bert", "nomic_bert").
public struct CatalogEmbeddingModel: Identifiable, Sendable, Equatable {
    public var id: String { repoID }
    public let repoID: String
    public let displayName: String
    public let dimension: Int
    public let runtimeFamily: String
    public let approxSizeMB: Int
    public let isDefault: Bool
    public let notes: String
    /// Instruction prepended to a *query* before embedding, for instruction-tuned
    /// models that expect asymmetric query/passage encoding (BGE, mxbai). `nil` for
    /// models that embed queries raw. These families embed *passages* raw, so adding
    /// the query instruction is consistent with existing (raw) passage embeddings —
    /// no re-indexing needed.
    public let queryInstruction: String?

    public init(
        repoID: String,
        displayName: String,
        dimension: Int,
        runtimeFamily: String,
        approxSizeMB: Int,
        isDefault: Bool = false,
        notes: String,
        queryInstruction: String? = nil
    ) {
        self.repoID = repoID
        self.displayName = displayName
        self.dimension = dimension
        self.runtimeFamily = runtimeFamily
        self.approxSizeMB = approxSizeMB
        self.isDefault = isDefault
        self.notes = notes
        self.queryInstruction = queryInstruction
    }
}

/// Curated embedding models offered in Document Intelligence setup. All are
/// supported by MLXEmbedders and run fully locally after download. Quality is
/// favored over speed/disk size (plan §2.2), so the default is a strong English
/// model and larger options are offered.
public enum EmbeddingModelCatalog {
    /// The retrieval query instruction shared by the BGE and mxbai families (both
    /// were trained with this s2p query prompt; passages stay raw).
    private static let bgeQueryInstruction = "Represent this sentence for searching relevant passages:"
    /// Qwen3-Embedding's official query instruction format. The model is trained to
    /// encode a *query* with an `Instruct: …\nQuery: ` preamble while passages are
    /// embedded raw — the same asymmetric s2p scheme as BGE, so prepending it to
    /// queries only (passages stay raw) is consistent with existing vectors.
    private static let qwen3QueryInstruction = "Instruct: Given a legal search query, retrieve relevant passages that answer the query\nQuery:"

    public static let curated: [CatalogEmbeddingModel] = [
        CatalogEmbeddingModel(
            repoID: "BAAI/bge-base-en-v1.5",
            displayName: "BGE Base EN v1.5",
            dimension: 768,
            runtimeFamily: "bert",
            approxSizeMB: 210,
            isDefault: true,
            notes: "Curated default. Strong English retrieval quality at a moderate size.",
            queryInstruction: bgeQueryInstruction
        ),
        CatalogEmbeddingModel(
            repoID: "BAAI/bge-large-en-v1.5",
            displayName: "BGE Large EN v1.5",
            dimension: 1024,
            runtimeFamily: "bert",
            approxSizeMB: 1300,
            notes: "Highest English quality; larger on disk and slower to embed.",
            queryInstruction: bgeQueryInstruction
        ),
        CatalogEmbeddingModel(
            repoID: "BAAI/bge-m3",
            displayName: "BGE-M3 (multilingual)",
            dimension: 1024,
            runtimeFamily: "xlm-roberta",
            approxSizeMB: 2200,
            notes: "Multilingual retrieval across 100+ languages with long-context (8K) support. Larger on disk.",
            queryInstruction: bgeQueryInstruction
        ),
        CatalogEmbeddingModel(
            repoID: "mixedbread-ai/mxbai-embed-large-v1",
            displayName: "mxbai Embed Large v1",
            dimension: 1024,
            runtimeFamily: "bert",
            approxSizeMB: 640,
            notes: "Top-tier retrieval quality.",
            queryInstruction: bgeQueryInstruction
        ),
        CatalogEmbeddingModel(
            repoID: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
            displayName: "Qwen3-Embedding 0.6B",
            dimension: 1024,
            runtimeFamily: "qwen3",
            approxSizeMB: 400,
            notes: "Instruction-tuned, strong multilingual + code retrieval. 4-bit quantized for a small footprint.",
            queryInstruction: qwen3QueryInstruction
        ),
        CatalogEmbeddingModel(
            repoID: "mlx-community/Qwen3-Embedding-8B-4bit-DWQ",
            displayName: "Qwen3-Embedding 8B",
            dimension: 4096,
            runtimeFamily: "qwen3",
            approxSizeMB: 4600,
            notes: "Highest-quality retrieval (MTEB-leading), instruction-tuned. Large: needs ample RAM and disk; slower to embed.",
            queryInstruction: qwen3QueryInstruction
        ),
        CatalogEmbeddingModel(
            repoID: "nomic-ai/nomic-embed-text-v1.5",
            displayName: "Nomic Embed Text v1.5",
            dimension: 768,
            runtimeFamily: "nomic_bert",
            approxSizeMB: 550,
            // Nomic expects symmetric "search_query:"/"search_document:" prefixes on
            // BOTH sides; applying a query prefix without re-embedding passages would
            // mismatch existing (raw) vectors, so leave it raw until a re-index path.
            notes: "Longer context and Matryoshka dimensions."
        ),
        CatalogEmbeddingModel(
            repoID: "BAAI/bge-small-en-v1.5",
            displayName: "BGE Small EN v1.5",
            dimension: 384,
            runtimeFamily: "bert",
            approxSizeMB: 130,
            notes: "Faster, smaller; lower quality than the base/large models.",
            queryInstruction: bgeQueryInstruction
        )
    ]

    public static var defaultModel: CatalogEmbeddingModel {
        curated.first { $0.isDefault } ?? curated[0]
    }

    public static func model(repoID: String) -> CatalogEmbeddingModel? {
        curated.first { $0.repoID == repoID }
    }

    /// Prepends the model's query instruction (if any) to a retrieval query. For a
    /// model without one — or one not in the catalog (e.g. user-registered) — the
    /// query is returned unchanged, preserving existing behavior.
    public static func queryText(_ query: String, forModelID modelID: String) -> String {
        guard let instruction = model(repoID: modelID)?.queryInstruction, !instruction.isEmpty else {
            return query
        }
        return "\(instruction) \(query)"
    }
}
