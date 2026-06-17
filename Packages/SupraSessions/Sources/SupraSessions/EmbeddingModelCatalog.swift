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

    public init(
        repoID: String,
        displayName: String,
        dimension: Int,
        runtimeFamily: String,
        approxSizeMB: Int,
        isDefault: Bool = false,
        notes: String
    ) {
        self.repoID = repoID
        self.displayName = displayName
        self.dimension = dimension
        self.runtimeFamily = runtimeFamily
        self.approxSizeMB = approxSizeMB
        self.isDefault = isDefault
        self.notes = notes
    }
}

/// Curated embedding models offered in Document Intelligence setup. All are
/// supported by MLXEmbedders and run fully locally after download. Quality is
/// favored over speed/disk size (plan §2.2), so the default is a strong English
/// model and larger options are offered.
public enum EmbeddingModelCatalog {
    public static let curated: [CatalogEmbeddingModel] = [
        CatalogEmbeddingModel(
            repoID: "BAAI/bge-base-en-v1.5",
            displayName: "BGE Base EN v1.5",
            dimension: 768,
            runtimeFamily: "bert",
            approxSizeMB: 210,
            isDefault: true,
            notes: "Curated default. Strong English retrieval quality at a moderate size."
        ),
        CatalogEmbeddingModel(
            repoID: "BAAI/bge-large-en-v1.5",
            displayName: "BGE Large EN v1.5",
            dimension: 1024,
            runtimeFamily: "bert",
            approxSizeMB: 1300,
            notes: "Highest English quality; larger on disk and slower to embed."
        ),
        CatalogEmbeddingModel(
            repoID: "mixedbread-ai/mxbai-embed-large-v1",
            displayName: "mxbai Embed Large v1",
            dimension: 1024,
            runtimeFamily: "bert",
            approxSizeMB: 640,
            notes: "Top-tier retrieval quality."
        ),
        CatalogEmbeddingModel(
            repoID: "nomic-ai/nomic-embed-text-v1.5",
            displayName: "Nomic Embed Text v1.5",
            dimension: 768,
            runtimeFamily: "nomic_bert",
            approxSizeMB: 550,
            notes: "Longer context and Matryoshka dimensions."
        ),
        CatalogEmbeddingModel(
            repoID: "BAAI/bge-small-en-v1.5",
            displayName: "BGE Small EN v1.5",
            dimension: 384,
            runtimeFamily: "bert",
            approxSizeMB: 130,
            notes: "Faster, smaller; lower quality than the base/large models."
        )
    ]

    public static var defaultModel: CatalogEmbeddingModel {
        curated.first { $0.isDefault } ?? curated[0]
    }

    public static func model(repoID: String) -> CatalogEmbeddingModel? {
        curated.first { $0.repoID == repoID }
    }
}
