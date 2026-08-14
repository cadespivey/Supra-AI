import CryptoKit
import Foundation
import SupraCore
@testable import SupraRuntimeInterface
import XCTest

/// T-XPC-BUDGET-05 embedding-profile refinement.
///
/// Expected RED: bound embedding loads still use a one-layer/dimension heuristic,
/// and the MLX embedding controller loads the mutable source directory without
/// retaining an independently copied and verified content snapshot.
final class ArchitectureUXTRuntimeEmbeddingProfileTests: XCTestCase {
    private static let forbiddenDefault = "DEFAULT-000"
    private static let modelID = ModelID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000733")!
    )

    func testExactBoundConfigBuildsEveryNonDefaultEmbeddingResourceField() throws {
        let fixture = try makeFixture()
        let builder = RuntimeModelResourceProfileBuilder(
            calibration: RuntimeModelResourceCalibration(
                nonWeightOverheadBytes: 43,
                activationWorkingSetMultiplier: 2
            )
        )

        let profile = try builder.buildEmbeddingProfile(
            profileID: "T_RUNTIME_EMBEDDING_PROFILE_01_WIRE_731",
            modelID: Self.modelID,
            binding: fixture.binding,
            configData: fixture.configData,
            expectedDimension: 105
        )

        XCTAssertEqual(profile.profileID, "T_RUNTIME_EMBEDDING_PROFILE_01_WIRE_731")
        XCTAssertEqual(profile.modelID, Self.modelID)
        XCTAssertEqual(profile.modelArtifactID, "synthetic/runtime-embedding-wire-733")
        XCTAssertEqual(profile.modelRevision, String(repeating: "8", count: 40))
        XCTAssertEqual(profile.contentFingerprintSHA256, fixture.binding.fingerprintSHA256)
        XCTAssertEqual(profile.weightBytes, 1_472)
        XCTAssertEqual(profile.layerCount, 7)
        XCTAssertEqual(profile.keyValueHeadCount, 15)
        XCTAssertEqual(profile.headDimension, 7)
        XCTAssertEqual(profile.scalarBytes, 4)
        XCTAssertEqual(profile.supportedContextTokens, 719)
        XCTAssertEqual(profile.nonWeightOverheadBytes, 43)
        XCTAssertEqual(profile.activationBytesPerToken, 840)
        XCTAssertFalse(String(describing: profile).contains(Self.forbiddenDefault))
    }

    func testExpectedEmbeddingDimensionMustMatchTheExactConfiguredHiddenSize() throws {
        let fixture = try makeFixture()
        let builder = RuntimeModelResourceProfileBuilder(
            calibration: RuntimeModelResourceCalibration(
                nonWeightOverheadBytes: 47,
                activationWorkingSetMultiplier: 3
            )
        )

        XCTAssertThrowsError(try builder.buildEmbeddingProfile(
            profileID: "T_RUNTIME_EMBEDDING_PROFILE_DIMENSION_739",
            modelID: Self.modelID,
            binding: fixture.binding,
            configData: fixture.configData,
            expectedDimension: 106
        )) { error in
            XCTAssertEqual(
                error as? RuntimeModelResourceProfileError,
                .embeddingDimensionMismatch(expected: 106, configured: 105)
            )
        }
        XCTAssertFalse(fixture.binding.repositoryID.contains(Self.forbiddenDefault))
    }

    func testShippingHostRequiresExactEmbeddingConfigAndNoFixedShapeFallback() throws {
        let host = try source(
            "Apps/SupraAI/SupraRuntimeService/SupraRuntimeService.swift"
        )
        let profileStart = try XCTUnwrap(
            host.range(of: "private static func embeddingResourceProfile(")
        )
        let profileEnd = try XCTUnwrap(
            host.range(
                of: "private static func productionMemoryEnvelope()",
                range: profileStart.upperBound..<host.endIndex
            )
        )
        let profileSource = String(host[profileStart.lowerBound..<profileEnd.lowerBound])

        XCTAssertTrue(host.contains("verifiedEmbeddingModelConfigData(for: request)"))
        XCTAssertTrue(host.contains("buildEmbeddingProfile("))
        XCTAssertTrue(profileSource.contains("guard let binding = request.contentBinding"))
        XCTAssertFalse(profileSource.contains("let dimension = request.expectedDimension ?? 384"))
        XCTAssertFalse(profileSource.contains("layerCount: 1"))
        XCTAssertFalse(profileSource.contains("supportedContextTokens: 32_768"))
        XCTAssertFalse(host.contains(Self.forbiddenDefault))
    }

    func testEmbeddingControllerLoadsAndRetainsAnExactVerifiedSnapshot() throws {
        let controller = try source(
            "Apps/SupraAI/SupraRuntimeService/MLXEmbeddingModelController.swift"
        )

        XCTAssertTrue(controller.contains("contentBinding: RuntimeModelContentBinding"))
        XCTAssertTrue(controller.contains("private var modelSnapshot: RuntimeModelSnapshot?"))
        XCTAssertTrue(controller.contains("RuntimeModelSnapshot("))
        XCTAssertTrue(controller.contains("pendingSnapshot.snapshotURL"))
        XCTAssertTrue(controller.contains("try pendingSnapshot.reverify()"))
        XCTAssertTrue(controller.contains("modelSnapshot = pendingSnapshot"))
        XCTAssertFalse(controller.contains(Self.forbiddenDefault))
    }

    private func makeFixture() throws -> EmbeddingProfileFixture {
        let configData = try JSONSerialization.data(
            withJSONObject: [
                "hidden_size": 105,
                "max_position_embeddings": 719,
                "model_type": "synthetic-runtime-embedding-wire-733",
                "num_attention_heads": 15,
                "num_hidden_layers": 7,
                "torch_dtype": "float32",
            ],
            options: [.sortedKeys]
        )
        let files = [
            RuntimeModelContentBinding.File(
                path: "config.json",
                size: Int64(configData.count),
                declaredDigestAlgorithm: "sha256",
                declaredDigest: Self.sha256(configData),
                actualSHA256: Self.sha256(configData)
            ),
            RuntimeModelContentBinding.File(
                path: "model-00001-of-00002.safetensors",
                size: 733,
                declaredDigestAlgorithm: "sha256",
                declaredDigest: String(repeating: "1", count: 64),
                actualSHA256: String(repeating: "2", count: 64)
            ),
            RuntimeModelContentBinding.File(
                path: "model-00002-of-00002.safetensors",
                size: 739,
                declaredDigestAlgorithm: "sha256",
                declaredDigest: String(repeating: "3", count: 64),
                actualSHA256: String(repeating: "4", count: 64)
            ),
            RuntimeModelContentBinding.File(
                path: "tokenizer.json",
                size: 23,
                declaredDigestAlgorithm: "sha256",
                declaredDigest: String(repeating: "5", count: 64),
                actualSHA256: String(repeating: "6", count: 64)
            ),
        ]
        let revision = String(repeating: "8", count: 40)
        let fingerprint = try RuntimeModelContentBinding.canonicalFingerprintSHA256(
            algorithm: RuntimeModelContentBinding.fingerprintAlgorithm,
            schemaVersion: RuntimeModelContentBinding.supportedManifestSchemaVersion,
            repositoryID: "synthetic/runtime-embedding-wire-733",
            revision: revision,
            files: files
        )
        return EmbeddingProfileFixture(
            configData: configData,
            binding: try RuntimeModelContentBinding(
                algorithm: RuntimeModelContentBinding.fingerprintAlgorithm,
                schemaVersion: RuntimeModelContentBinding.supportedManifestSchemaVersion,
                repositoryID: "synthetic/runtime-embedding-wire-733",
                revision: revision,
                files: files,
                fingerprintSHA256: fingerprint
            )
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func source(_ relativePath: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private struct EmbeddingProfileFixture {
    let configData: Data
    let binding: RuntimeModelContentBinding
}
