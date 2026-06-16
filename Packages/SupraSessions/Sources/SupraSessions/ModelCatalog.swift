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

/// The curated list of MLX 4-bit instruct models offered in the guided download.
/// Sizes are approximate on-disk footprints; all are `mlx-community` 4-bit builds.
public enum ModelCatalog {
    public static let curated: [CatalogModel] = [
        CatalogModel(
            repoID: "mlx-community/Qwen2.5-32B-Instruct-4bit",
            displayName: "Qwen2.5 32B Instruct (4-bit)",
            approxSizeGB: 18,
            notes: "Milestone 1 target. Needs ~24 GB+ free RAM."
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
