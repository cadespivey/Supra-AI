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

/// The curated list of MLX models offered in the guided download, **sorted by general
/// quality (largest/highest-quality first, fastest/smallest last)** so the size/speed
/// tradeoff reads top-to-bottom. Every repo ID is verified to exist on Hugging Face with
/// MLX-format weights. Most are `mlx-community` builds; the Qwen3 Thinking 6/8-bit
/// higher-precision quants are published under `lmstudio-community`.
///
/// The three role-default models (legal reasoning / drafting / critique from the
/// local-legal-model-setup plan) are exposed by name via `defaultReasoningModel` etc.
/// (not by list position), so this list can be reordered freely; once downloaded their
/// repo name auto-resolves to the matching chat route.
public enum ModelCatalog {
    public static let curated: [CatalogModel] = [
        // MARK: 32–35B · highest quality (need substantial free unified memory)
        CatalogModel(
            repoID: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-MLX-8Bit",
            displayName: "DeepSeek-R1 Distill Qwen 32B (8-bit)",
            approxSizeGB: 35,
            notes: "Highest-precision reasoning/critique. Best factual & citation recall; needs ~48 GB+ free RAM. Assign to the critique or legal-reasoning role."
        ),
        CatalogModel(
            repoID: "mlx-community/Qwen2.5-32B-Instruct-8bit",
            displayName: "Qwen2.5 32B Instruct (8-bit)",
            approxSizeGB: 34,
            notes: "Highest-precision general 32B instruct. Strong drafting/extraction; needs ~48 GB+ free RAM."
        ),
        CatalogModel(
            repoID: "lmstudio-community/Qwen3-30B-A3B-Thinking-2507-MLX-8bit",
            displayName: "Qwen3 30B A3B Thinking 2507 (8-bit)",
            approxSizeGB: 32,
            notes: "Highest-precision legal reasoning (assign to the legal-reasoning role). MoE, ~3B active; fewer 4-bit recall errors on citations/holdings. Needs ~48 GB+ free RAM."
        ),
        CatalogModel(
            repoID: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-6bit",
            displayName: "DeepSeek-R1 Distill Qwen 32B (6-bit)",
            approxSizeGB: 26,
            notes: "Higher-precision reasoning/critique (assign to the critique role). Needs ~40 GB+ free RAM."
        ),
        CatalogModel(
            repoID: "lmstudio-community/Qwen3-30B-A3B-Thinking-2507-MLX-6bit",
            displayName: "Qwen3 30B A3B Thinking 2507 (6-bit)",
            approxSizeGB: 24,
            notes: "Higher-precision legal reasoning (assign to the legal-reasoning role). MoE, ~3B active. Needs ~40 GB+ free RAM."
        ),
        // MARK: ~32B · 4-bit (the role-default tier)
        CatalogModel(
            repoID: "mlx-community/Qwen3-32B-4bit",
            displayName: "Qwen3 32B (4-bit)",
            approxSizeGB: 18,
            notes: "Dense 32B reasoning model. Strong all-rounder; needs ~24 GB+ free RAM."
        ),
        CatalogModel(
            repoID: "mlx-community/Qwen2.5-32B-Instruct-4bit",
            displayName: "Qwen2.5 32B Instruct (4-bit)",
            approxSizeGB: 18,
            notes: "General-purpose 32B instruct. Needs ~24 GB+ free RAM."
        ),
        CatalogModel(
            repoID: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit",
            displayName: "DeepSeek-R1 Distill Qwen 32B (4-bit)",
            approxSizeGB: 18,
            notes: "Critique route default (/critique second-pass review). Needs ~24 GB+ free RAM."
        ),
        CatalogModel(
            repoID: "mlx-community/Qwen3-30B-A3B-Thinking-2507-4bit",
            displayName: "Qwen3 30B A3B Thinking 2507 (4-bit)",
            approxSizeGB: 17,
            notes: "Legal-reasoning route default (/legal and /research). MoE, ~3B active. Needs ~32 GB+ free RAM."
        ),
        CatalogModel(
            repoID: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
            displayName: "Qwen3 30B A3B Instruct 2507 (4-bit)",
            approxSizeGB: 17,
            notes: "Drafting route default (/draft and ordinary drafting). MoE, ~3B active."
        ),
        // MARK: 24–27B · strong, lighter on RAM
        CatalogModel(
            repoID: "mlx-community/gemma-2-27b-it-4bit",
            displayName: "Gemma 2 27B Instruct (4-bit)",
            approxSizeGB: 16,
            notes: "Google's 27B instruct. Strong general drafting; needs ~20 GB+ free RAM."
        ),
        CatalogModel(
            repoID: "mlx-community/Mistral-Small-24B-Instruct-2501-4bit",
            displayName: "Mistral Small 24B Instruct (4-bit)",
            approxSizeGB: 13,
            notes: "Efficient 24B; excellent drafting quality for its size. Needs ~16 GB+ free RAM."
        ),
        // MARK: ~14B · mid-size
        CatalogModel(
            repoID: "mlx-community/Qwen3-14B-4bit",
            displayName: "Qwen3 14B (4-bit)",
            approxSizeGB: 8,
            notes: "Dense 14B reasoning model. Strong mid-size option."
        ),
        CatalogModel(
            repoID: "mlx-community/phi-4-4bit",
            displayName: "Phi-4 14B (4-bit)",
            approxSizeGB: 8,
            notes: "Microsoft's 14B; strong reasoning and math for its size."
        ),
        CatalogModel(
            repoID: "mlx-community/Qwen2.5-14B-Instruct-4bit",
            displayName: "Qwen2.5 14B Instruct (4-bit)",
            approxSizeGB: 8,
            notes: "Strong, well-rounded mid-size instruct model."
        ),
        CatalogModel(
            repoID: "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit",
            displayName: "DeepSeek-R1 Distill Qwen 14B (4-bit)",
            approxSizeGB: 8,
            notes: "Reasoning at a mid-size footprint — lighter alternative to the 32B distill."
        ),
        // MARK: 7–8B · fast, light
        CatalogModel(
            repoID: "mlx-community/Qwen3-8B-4bit",
            displayName: "Qwen3 8B (4-bit)",
            approxSizeGB: 4.7,
            notes: "Fast dense 8B reasoning model; good on memory-constrained Macs."
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

    /// The plan's role-default models, addressed by repo ID (not list position) so the
    /// catalog above can be sorted freely without changing onboarding defaults.
    public static var defaultReasoningModel: CatalogModel { model("mlx-community/Qwen3-30B-A3B-Thinking-2507-4bit") }
    public static var defaultDraftingModel: CatalogModel { model("mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit") }
    public static var defaultCritiqueModel: CatalogModel { model("mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit") }

    public static func model(_ repoID: String) -> CatalogModel {
        curated.first { $0.repoID == repoID } ?? curated[0]
    }
}
