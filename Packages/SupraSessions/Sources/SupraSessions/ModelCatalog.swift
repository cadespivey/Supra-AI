import Foundation

/// A curated, downloadable MLX model from Hugging Face.
public struct CatalogModel: Identifiable, Sendable, Equatable {
    public var id: String { repoID }
    public let repoID: String
    public let displayName: String
    public let approxSizeGB: Double
    public let notes: String

    public init(repoID: String, displayName: String, approxSizeGB: Double, notes: String) {
        self.repoID = repoID
        self.displayName = displayName
        self.approxSizeGB = approxSizeGB
        self.notes = notes
    }
}

/// The curated list of MLX models offered in the guided download. Sizes are
/// approximate on-disk footprints; all are `mlx-community` builds. The first three
/// are the role models from the local-legal-model-setup plan; once downloaded their
/// repo name auto-resolves to the matching chat route (legal reasoning / drafting /
/// critique). The remainder are smaller general-purpose options.
public enum ModelCatalog {
    public static let curated: [CatalogModel] = [
        CatalogModel(
            repoID: "mlx-community/Qwen3-30B-A3B-Thinking-2507-4bit",
            displayName: "Qwen3 30B A3B Thinking 2507 (4-bit)",
            approxSizeGB: 17,
            notes: "Legal reasoning route (default for /legal and /research). MoE, ~3B active. Needs ~32 GB+ free RAM."
        ),
        CatalogModel(
            repoID: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
            displayName: "Qwen3 30B A3B Instruct 2507 (4-bit)",
            approxSizeGB: 17,
            notes: "Drafting route (/draft and ordinary drafting). MoE, ~3B active."
        ),
        CatalogModel(
            repoID: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit",
            displayName: "DeepSeek-R1 Distill Qwen 32B (4-bit)",
            approxSizeGB: 18,
            notes: "Critique route (/critique second-pass review). Needs ~24 GB+ free RAM."
        ),
        // Higher-precision variants of the legal-reasoning and critique role models.
        // 4-bit quantization disproportionately degrades the long-tail factual recall
        // that citations, holdings, and dates depend on; 6/8-bit cut those errors for
        // users with RAM headroom. They do NOT auto-assign to a role (the quant differs
        // from the default) — assign them to the matching role in the Models tab.
        CatalogModel(
            repoID: "mlx-community/Qwen3-30B-A3B-Thinking-2507-6bit",
            displayName: "Qwen3 30B A3B Thinking 2507 (6-bit)",
            approxSizeGB: 24,
            notes: "Higher-precision legal-reasoning option (assign to the legal reasoning role). Fewer 4-bit recall errors on citations/holdings; needs ~40 GB+ free RAM."
        ),
        CatalogModel(
            repoID: "mlx-community/Qwen3-30B-A3B-Thinking-2507-8bit",
            displayName: "Qwen3 30B A3B Thinking 2507 (8-bit)",
            approxSizeGB: 32,
            notes: "Highest-precision legal-reasoning option (assign to the legal reasoning role). Best factual/citation recall; needs ~48 GB+ free RAM."
        ),
        CatalogModel(
            repoID: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-6bit",
            displayName: "DeepSeek-R1 Distill Qwen 32B (6-bit)",
            approxSizeGB: 26,
            notes: "Higher-precision critique/high-quality-reasoning option (assign to the critique role). Needs ~40 GB+ free RAM."
        ),
        CatalogModel(
            repoID: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-8bit",
            displayName: "DeepSeek-R1 Distill Qwen 32B (8-bit)",
            approxSizeGB: 35,
            notes: "Highest-precision critique/high-quality-reasoning option (assign to the critique role). Needs ~48 GB+ free RAM."
        ),
        CatalogModel(
            repoID: "mlx-community/Qwen2.5-32B-Instruct-4bit",
            displayName: "Qwen2.5 32B Instruct (4-bit)",
            approxSizeGB: 18,
            notes: "General-purpose 32B. Needs ~24 GB+ free RAM."
        ),
        CatalogModel(
            repoID: "mlx-community/Qwen2.5-14B-Instruct-4bit",
            displayName: "Qwen2.5 14B Instruct (4-bit)",
            approxSizeGB: 8,
            notes: "Strong mid-size option."
        ),
        CatalogModel(
            repoID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            displayName: "Qwen2.5 7B Instruct (4-bit)",
            approxSizeGB: 4.3,
            notes: "Fast; good for testing the pipeline."
        ),
        CatalogModel(
            repoID: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
            displayName: "Llama 3.1 8B Instruct (4-bit)",
            approxSizeGB: 4.5,
            notes: "Popular general-purpose model."
        )
    ]
}
