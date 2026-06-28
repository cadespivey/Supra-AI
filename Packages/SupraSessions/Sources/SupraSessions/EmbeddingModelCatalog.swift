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

/// Curated embedding models offered in Document Intelligence setup, **sorted by general
/// quality (highest first, fastest/smallest last)**. Every repo is verified to exist on
/// Hugging Face and load via MLXEmbedders.
///
/// Only two architecture families are offered because they reliably load with
/// MLXEmbedders: `qwen3` (the MLX-native, instruction-tuned, multilingual Qwen3-Embedding
/// models — the recommended choice) and `bert` (the BGE/mxbai English encoders). The raw
/// `xlm-roberta` (BGE-M3) and `nomic_bert` (Nomic) originals were dropped: their PyTorch
/// weight layouts do not map cleanly to the Swift port and fail to load. Multilingual
/// retrieval is covered by the Qwen3-Embedding models (100+ languages), so no separate
/// multilingual model is needed.
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
        // MARK: Qwen3-Embedding · MLX-native, instruction-tuned, multilingual (recommended)
        CatalogEmbeddingModel(
            repoID: "mlx-community/Qwen3-Embedding-8B-4bit-DWQ",
            displayName: "Qwen3-Embedding 8B",
            dimension: 4096,
            runtimeFamily: "qwen3",
            approxSizeMB: 4600,
            notes: "Highest-quality retrieval (MTEB-leading), instruction-tuned, multilingual. Large: needs ample RAM and disk; slower to embed.",
            queryInstruction: qwen3QueryInstruction
        ),
        CatalogEmbeddingModel(
            repoID: "mlx-community/Qwen3-Embedding-4B-4bit-DWQ",
            displayName: "Qwen3-Embedding 4B",
            dimension: 2560,
            runtimeFamily: "qwen3",
            approxSizeMB: 2400,
            notes: "Excellent instruction-tuned multilingual retrieval; a strong middle option.",
            queryInstruction: qwen3QueryInstruction
        ),
        CatalogEmbeddingModel(
            repoID: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
            displayName: "Qwen3-Embedding 0.6B",
            dimension: 1024,
            runtimeFamily: "qwen3",
            approxSizeMB: 400,
            isDefault: true,
            notes: "Curated default. Instruction-tuned, multilingual, MLX-native — small and fast with strong quality.",
            queryInstruction: qwen3QueryInstruction
        ),
        // MARK: BGE / mxbai · BERT English encoders (proven)
        CatalogEmbeddingModel(
            repoID: "mlx-community/mxbai-embed-large-v1",
            displayName: "mxbai Embed Large v1",
            dimension: 1024,
            runtimeFamily: "bert",
            approxSizeMB: 640,
            notes: "Top-tier English retrieval quality (MLX-community build).",
            queryInstruction: bgeQueryInstruction
        ),
        CatalogEmbeddingModel(
            repoID: "BAAI/bge-large-en-v1.5",
            displayName: "BGE Large EN v1.5",
            dimension: 1024,
            runtimeFamily: "bert",
            approxSizeMB: 1300,
            notes: "Highest BGE English quality; larger on disk and slower to embed.",
            queryInstruction: bgeQueryInstruction
        ),
        CatalogEmbeddingModel(
            repoID: "BAAI/bge-base-en-v1.5",
            displayName: "BGE Base EN v1.5",
            dimension: 768,
            runtimeFamily: "bert",
            approxSizeMB: 210,
            notes: "Solid English retrieval at a small size.",
            queryInstruction: bgeQueryInstruction
        ),
        CatalogEmbeddingModel(
            repoID: "BAAI/bge-small-en-v1.5",
            displayName: "BGE Small EN v1.5",
            dimension: 384,
            runtimeFamily: "bert",
            approxSizeMB: 130,
            notes: "Fastest and smallest; lower quality than the base/large models.",
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
