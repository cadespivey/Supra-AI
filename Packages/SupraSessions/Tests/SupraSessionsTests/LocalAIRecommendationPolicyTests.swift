import Foundation
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
            (95, .gb64),
            (96, .gb96),
            (127, .gb96),
            (128, .gb128),
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

    func testEveryApprovedBundleIsRecommendedForItsExactTier() throws {
        // Expected RED: fit assessments do not distinguish the exact approved
        // work/search bundle from another merely compatible catalog pairing.
        for memoryGB in [16, 32, 64, 96, 128] {
            let profile = profile(memoryGB: memoryGB)
            let recommendation = try XCTUnwrap(
                LocalAIRecommendationPolicy.recommendation(for: profile)
            )

            let assessment = LocalAIRecommendationPolicy.fitAssessment(
                textRepoID: recommendation.workModel.repoID,
                embeddingRepoID: recommendation.embeddingModel.repoID,
                profile: profile
            )

            XCTAssertEqual(
                assessment.level,
                .recommended,
                "the exact \(memoryGB) GB bundle must be identified as recommended"
            )
            XCTAssertNotEqual(
                assessment.level,
                .compatible,
                "the recommended result must not collapse to the default compatible label"
            )
        }

        let nonapprovedNinetySixGBBundle = LocalAIRecommendationPolicy.fitAssessment(
            textRepoID: "mlx-community/Qwen3-14B-4bit",
            embeddingRepoID: LocalAIRecommendationPolicy.embeddingRepoID,
            profile: profile(memoryGB: 96)
        )
        XCTAssertEqual(nonapprovedNinetySixGBBundle.level, .compatible)
        XCTAssertNotEqual(
            nonapprovedNinetySixGBBundle.level,
            .recommended,
            "a known but non-policy bundle must not receive the exact recommendation label"
        )
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

        XCTAssertEqual(smallSearch.level, .recommended)
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

    func testReviewTextOnlyFitUsesOnlyTheSelectedTextArtifact() throws {
        // Expected RED: Review has no text-only fit overload, so callers must
        // currently invent an embedding model and overstate the selected model's footprint.
        let profile = profile(memoryGB: 32)
        let assessment = LocalAIRecommendationPolicy.fitAssessment(
            textRepoID: "mlx-community/Qwen3-14B-4bit",
            profile: profile
        )

        XCTAssertEqual(assessment.level, .recommended)
        XCTAssertEqual(
            try XCTUnwrap(assessment.estimatedResidentBytes),
            UInt64(8_000_000_000)
        )
        XCTAssertNotEqual(
            assessment.estimatedResidentBytes,
            UInt64(8_400_000_000),
            "Review must not silently add the default embedding model to its text-only estimate"
        )
    }

    func testReviewTextOnlyFitCautionsForKnownThirtyFiveGBModelOnSixteenGBMac() throws {
        // Expected RED: Review has no typed text-only fit path for a known
        // catalog model whose footprint is materially larger than the machine budget.
        let assessment = LocalAIRecommendationPolicy.fitAssessment(
            textRepoID: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-MLX-8Bit",
            profile: profile(memoryGB: 16)
        )

        XCTAssertEqual(assessment.level, .caution)
        XCTAssertEqual(
            try XCTUnwrap(assessment.estimatedResidentBytes),
            UInt64(35_000_000_000)
        )
        XCTAssertNotEqual(assessment.level, .unknown)
    }

    func testReviewTextOnlyFitKeepsUnknownCustomRepositoryUnknown() {
        // Expected RED: the text-only Review overload and its fail-closed
        // catalog lookup do not exist.
        let assessment = LocalAIRecommendationPolicy.fitAssessment(
            textRepoID: "fictional-firm/Unmeasured-Review-Model",
            profile: profile(memoryGB: 128)
        )

        XCTAssertEqual(assessment.level, .unknown)
        XCTAssertNil(assessment.estimatedResidentBytes)
        XCTAssertEqual(
            assessment.explanation,
            "Fit unknown — this model has no verified hardware metadata."
        )
    }

    func testInjectedHardwareProfileProbePreservesExactNondefaultMeasurements() {
        // Expected RED: the live hardware probe has no value/closure-only
        // injection seam, so exact physical, working-set, and disk inputs cannot be proven.
        let modelsDirectory = URL(fileURLWithPath: "/tmp/hardware-profile-canary-911")
        let physicalBytes = 101 * gibibyte + 911
        let workingSetBytes = 73 * gibibyte + 313
        let diskBytes = Int64(211 * gibibyte + 17)

        let profile = MacHardwareProfileProbe.current(
            modelsDirectory: modelsDirectory,
            physicalMemoryBytes: { physicalBytes },
            recommendedWorkingSetBytes: { workingSetBytes },
            availableModelDiskBytes: { requestedDirectory in
                XCTAssertEqual(requestedDirectory, modelsDirectory)
                return diskBytes
            }
        )

        XCTAssertEqual(profile.physicalMemoryBytes, physicalBytes)
        XCTAssertEqual(profile.recommendedWorkingSetBytes, workingSetBytes)
        XCTAssertEqual(profile.availableModelDiskBytes, diskBytes)
        XCTAssertNotEqual(
            profile.physicalMemoryBytes,
            ProcessInfo.processInfo.physicalMemory,
            "the injected non-default physical-memory canary must reach the exact profile output"
        )
    }

    private func profile(memoryGB: Int) -> MacHardwareProfile {
        MacHardwareProfile(
            physicalMemoryBytes: UInt64(memoryGB) * gibibyte,
            recommendedWorkingSetBytes: UInt64(memoryGB) * gibibyte * 3 / 4,
            availableModelDiskBytes: Int64(512 * gibibyte)
        )
    }
}
