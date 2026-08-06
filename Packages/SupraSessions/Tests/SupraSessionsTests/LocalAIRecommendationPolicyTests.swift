import SupraCore
@testable import SupraSessions
import XCTest

final class LocalAIRecommendationPolicyTests: XCTestCase {
    private let gibibyte = UInt64(1_073_741_824)

    func testApprovedMemoryBandsChooseExactEverydayArtifacts() throws {
        // Expected RED: MacHardwareProfile and LocalAIRecommendationPolicy do not exist yet.
        let fixtures: [(memoryGB: Int, tier: UnifiedMemoryTier, repoID: String, totalGB: Double)] = [
            (16, .gb16, "mlx-community/Qwen3-8B-4bit", 5.1),
            (32, .gb32, "mlx-community/Qwen3-14B-4bit", 8.4),
            (64, .gb64, "mlx-community/Qwen3-32B-4bit", 18.4),
            (96, .gb96, "mlx-community/Qwen3-32B-4bit", 18.4),
            (128, .gb128, "mlx-community/Qwen3-32B-4bit", 18.4)
        ]

        for fixture in fixtures {
            let profile = profile(memoryGB: fixture.memoryGB)
            let recommendation = try XCTUnwrap(LocalAIRecommendationPolicy.recommendation(for: profile))

            XCTAssertEqual(recommendation.tier, fixture.tier)
            XCTAssertEqual(recommendation.workModel.repoID, fixture.repoID)
            XCTAssertEqual(
                recommendation.embeddingModel.repoID,
                "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
            )
            XCTAssertEqual(recommendation.approximateDownloadGB, fixture.totalGB, accuracy: 0.001)
            XCTAssertEqual(Set(recommendation.textRoles), Set(ModelRole.allCases))
        }
    }

    func testUncommonMemoryRoundsDownAndBelowMinimumDoesNotClaimRecommendation() {
        // Expected RED: no conservative tier resolver exists.
        let fixtures: [(memoryGB: Int, expected: UnifiedMemoryTier?)] = [
            (8, nil),
            (15, nil),
            (16, .gb16),
            (24, .gb16),
            (36, .gb32),
            (48, .gb32),
            (72, .gb64),
            (96, .gb96),
            (192, .gb128)
        ]

        for fixture in fixtures {
            XCTAssertEqual(
                UnifiedMemoryTier.resolve(physicalMemoryBytes: UInt64(fixture.memoryGB) * gibibyte),
                fixture.expected,
                "unexpected tier for \(fixture.memoryGB) GB"
            )
        }
    }

    func testRecommendationUsesOneTextModelForEveryRole() throws {
        // Expected RED: current onboarding defaults to separate reasoning and drafting downloads.
        let recommendation = try XCTUnwrap(
            LocalAIRecommendationPolicy.recommendation(for: profile(memoryGB: 96))
        )

        XCTAssertEqual(recommendation.workModel.repoID, "mlx-community/Qwen3-32B-4bit")
        XCTAssertEqual(recommendation.textRoles.count, ModelRole.allCases.count)
        for role in ModelRole.allCases {
            XCTAssertTrue(recommendation.textRoles.contains(role), "missing role \(role)")
        }
    }

    func testFitAssessmentBudgetsTextAndEmbeddingTogether() throws {
        // Expected RED: current catalogs have no combined resident-memory assessment.
        let profile = MacHardwareProfile(
            physicalMemoryBytes: 32 * gibibyte,
            recommendedWorkingSetBytes: 12 * gibibyte,
            availableModelDiskBytes: Int64(200 * gibibyte)
        )

        let smallSearch = LocalAIRecommendationPolicy.fitAssessment(
            textRepoID: "mlx-community/Qwen3-14B-4bit",
            embeddingRepoID: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
            profile: profile
        )
        let largeSearch = LocalAIRecommendationPolicy.fitAssessment(
            textRepoID: "mlx-community/Qwen3-14B-4bit",
            embeddingRepoID: "mlx-community/Qwen3-Embedding-8B-4bit-DWQ",
            profile: profile
        )

        XCTAssertEqual(smallSearch.level, .compatible)
        XCTAssertEqual(largeSearch.level, .caution)
        XCTAssertEqual(
            try XCTUnwrap(largeSearch.estimatedResidentBytes),
            UInt64(12_600_000_000)
        )
        XCTAssertNotEqual(smallSearch.estimatedResidentBytes, largeSearch.estimatedResidentBytes)
    }

    func testUnknownCustomModelNeverFallsThroughToFirstCatalogEntry() {
        // Expected RED: ModelCatalog.model currently falls back to curated[0] for an unknown ID.
        let assessment = LocalAIRecommendationPolicy.fitAssessment(
            textRepoID: "fictional-firm/Unmeasured-Legal-Model",
            embeddingRepoID: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
            profile: profile(memoryGB: 128)
        )

        XCTAssertEqual(assessment.level, .unknown)
        XCTAssertNil(assessment.estimatedResidentBytes)
        XCTAssertEqual(assessment.explanation, "Fit unknown — this model has no verified hardware metadata.")
    }

    private func profile(memoryGB: Int) -> MacHardwareProfile {
        MacHardwareProfile(
            physicalMemoryBytes: UInt64(memoryGB) * gibibyte,
            recommendedWorkingSetBytes: UInt64(memoryGB) * gibibyte * 3 / 4,
            availableModelDiskBytes: Int64(512 * gibibyte)
        )
    }
}
