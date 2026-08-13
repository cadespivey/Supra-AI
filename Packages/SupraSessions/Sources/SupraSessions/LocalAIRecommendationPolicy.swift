import Foundation
#if canImport(Metal)
import Metal
#endif
import SupraCore

public enum UnifiedMemoryTier: Int, CaseIterable, Sendable {
    case gb16 = 16
    case gb32 = 32
    case gb64 = 64
    case gb96 = 96
    case gb128 = 128

    /// Resolves conservatively: uncommon capacities receive the highest approved
    /// tier that does not exceed installed unified memory, capped at 128 GB.
    public static func resolve(physicalMemoryBytes: UInt64) -> UnifiedMemoryTier? {
        let installedGB = physicalMemoryBytes / 1_073_741_824
        return allCases.last { UInt64($0.rawValue) <= installedGB }
    }
}

public struct MacHardwareProfile: Equatable, Sendable {
    public let physicalMemoryBytes: UInt64
    public let recommendedWorkingSetBytes: UInt64?
    public let availableModelDiskBytes: Int64?

    public init(
        physicalMemoryBytes: UInt64,
        recommendedWorkingSetBytes: UInt64?,
        availableModelDiskBytes: Int64?
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.recommendedWorkingSetBytes = recommendedWorkingSetBytes
        self.availableModelDiskBytes = availableModelDiskBytes
    }
}

public enum MacHardwareProfileProbe {
    public static func current(modelsDirectory: URL) -> MacHardwareProfile {
        current(
            modelsDirectory: modelsDirectory,
            physicalMemoryBytes: { ProcessInfo.processInfo.physicalMemory },
            recommendedWorkingSetBytes: { liveRecommendedWorkingSetBytes() },
            availableModelDiskBytes: { availableCapacity(near: $0) }
        )
    }

    /// Value-provider overload used by deterministic app fixtures and package
    /// tests. It performs no probing beyond the three supplied providers.
    static func current(
        modelsDirectory: URL,
        physicalMemoryBytes: () -> UInt64,
        recommendedWorkingSetBytes: () -> UInt64?,
        availableModelDiskBytes: (URL) -> Int64?
    ) -> MacHardwareProfile {
        MacHardwareProfile(
            physicalMemoryBytes: physicalMemoryBytes(),
            recommendedWorkingSetBytes: recommendedWorkingSetBytes(),
            availableModelDiskBytes: availableModelDiskBytes(modelsDirectory)
        )
    }

    private static func liveRecommendedWorkingSetBytes() -> UInt64? {
#if canImport(Metal)
        guard let bytes = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize,
              bytes > 0 else { return nil }
        return bytes
#else
        return nil
#endif
    }

    private static func availableCapacity(near requestedURL: URL) -> Int64? {
        var candidate = requestedURL.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        let values = try? candidate.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

public struct LocalAIRecommendation: Sendable {
    public let tier: UnifiedMemoryTier
    public let workModel: CatalogModel
    public let embeddingModel: CatalogEmbeddingModel
    public let textRoles: [ModelRole]

    public var approximateDownloadGB: Double {
        workModel.approxSizeGB + Double(embeddingModel.approxSizeMB) / 1_000
    }
}

public enum ModelFitLevel: Equatable, Sendable {
    case recommended
    case compatible
    case caution
    case unknown
}

public struct ModelFitAssessment: Equatable, Sendable {
    public let level: ModelFitLevel
    public let estimatedResidentBytes: UInt64?
    public let diskShortfallBytes: Int64?
    public let explanation: String
}

public enum LocalAIRecommendationPolicy {
    public static let embeddingRepoID = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

    public static func recommendation(for profile: MacHardwareProfile) -> LocalAIRecommendation? {
        guard let tier = UnifiedMemoryTier.resolve(
            physicalMemoryBytes: profile.physicalMemoryBytes
        ), let workModel = ModelCatalog.modelIfPresent(workRepoID(for: tier)),
           let embeddingModel = EmbeddingModelCatalog.model(repoID: embeddingRepoID) else {
            return nil
        }
        return LocalAIRecommendation(
            tier: tier,
            workModel: workModel,
            embeddingModel: embeddingModel,
            textRoles: ModelRole.allCases
        )
    }

    /// Assesses the combined text and retrieval bundle used by Local AI setup.
    public static func fitAssessment(
        textRepoID: String,
        embeddingRepoID: String,
        profile: MacHardwareProfile
    ) -> ModelFitAssessment {
        guard let text = ModelCatalog.modelIfPresent(textRepoID),
              let embedding = EmbeddingModelCatalog.model(repoID: embeddingRepoID) else {
            return unknownAssessment
        }

        let approvedBundle = recommendation(for: profile).map {
            $0.workModel.repoID == textRepoID && $0.embeddingModel.repoID == embeddingRepoID
        } ?? false
        return assessKnownFootprint(
            residentBytes: text.estimatedResidentBytes + embedding.estimatedResidentBytes,
            downloadBytes: text.approximateDownloadBytes + embedding.approximateDownloadBytes,
            isApprovedRecommendation: approvedBundle,
            profile: profile
        )
    }

    /// Review selects one text artifact and does not require an embedding model.
    /// Its fit label therefore accounts only for that exact selected artifact.
    public static func fitAssessment(
        textRepoID: String,
        profile: MacHardwareProfile
    ) -> ModelFitAssessment {
        guard let text = ModelCatalog.modelIfPresent(textRepoID) else {
            return unknownAssessment
        }

        let approvedTextModel = recommendation(for: profile)?.workModel.repoID == textRepoID
        return assessKnownFootprint(
            residentBytes: text.estimatedResidentBytes,
            downloadBytes: text.approximateDownloadBytes,
            isApprovedRecommendation: approvedTextModel,
            profile: profile
        )
    }

    private static var unknownAssessment: ModelFitAssessment {
        ModelFitAssessment(
            level: .unknown,
            estimatedResidentBytes: nil,
            diskShortfallBytes: nil,
            explanation: "Fit unknown — this model has no verified hardware metadata."
        )
    }

    private static func assessKnownFootprint(
        residentBytes: UInt64,
        downloadBytes: UInt64,
        isApprovedRecommendation: Bool,
        profile: MacHardwareProfile
    ) -> ModelFitAssessment {
        let diskShortfall = profile.availableModelDiskBytes.flatMap { available -> Int64? in
            let required = Int64(clamping: downloadBytes)
            return required > available ? required - available : nil
        }
        let physicalPressure = Double(residentBytes)
            / Double(max(profile.physicalMemoryBytes, 1))
        let workingSetPressure = profile.recommendedWorkingSetBytes.map {
            Double(residentBytes) / Double(max($0, 1))
        }
        let isTight = physicalPressure > 0.45
            || (workingSetPressure.map { $0 > 0.90 } ?? false)

        let level: ModelFitLevel = if isTight {
            .caution
        } else if isApprovedRecommendation {
            .recommended
        } else {
            .compatible
        }
        let explanation = switch level {
        case .recommended:
            "Recommended for this Mac based on estimated model footprint."
        case .compatible:
            "Estimated to leave working memory for macOS, context, and other apps."
        case .caution:
            "May slow other apps or fail to load at longer context on this Mac."
        case .unknown:
            "Fit unknown — this model has no verified hardware metadata."
        }

        return ModelFitAssessment(
            level: level,
            estimatedResidentBytes: residentBytes,
            diskShortfallBytes: diskShortfall,
            explanation: explanation
        )
    }

    private static func workRepoID(for tier: UnifiedMemoryTier) -> String {
        switch tier {
        case .gb16:
            "mlx-community/Qwen3-8B-4bit"
        case .gb32:
            "mlx-community/Qwen3-14B-4bit"
        case .gb64, .gb96, .gb128:
            "mlx-community/Qwen3-32B-4bit"
        }
    }
}
