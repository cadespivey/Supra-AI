import CryptoKit
import Foundation
import SupraCore
@testable import SupraRuntimeInterface
import XCTest

/// T-XPC-BUDGET-05 / T-RUNTIME-KV-01 profile refinement.
///
/// Expected RED: the XPC host constructs chat profiles with fixed
/// 32-layer/8-KV-head/128-head-dimension values instead of parsing the exact
/// verified artifact configuration that the content binding names.
final class ArchitectureUXTRuntimeModelProfileTests: XCTestCase {
    private static let forbiddenDefault = "DEFAULT-000"
    private static let modelID = ModelID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000713")!
    )

    func testExactBoundConfigBuildsEveryNonDefaultChatResourceField() throws {
        let fixture = try makeFixture()
        let builder = RuntimeModelResourceProfileBuilder(
            calibration: RuntimeModelResourceCalibration(
                nonWeightOverheadBytes: 37,
                activationWorkingSetMultiplier: 3
            )
        )

        let profile = try builder.buildChatProfile(
            profileID: "T_RUNTIME_PROFILE_01_WIRE_731",
            modelID: Self.modelID,
            binding: fixture.binding,
            configData: fixture.configData
        )

        XCTAssertEqual(profile.profileID, "T_RUNTIME_PROFILE_01_WIRE_731")
        XCTAssertEqual(profile.modelID, Self.modelID)
        XCTAssertEqual(profile.modelArtifactID, "synthetic/runtime-profile-wire-713")
        XCTAssertEqual(profile.modelRevision, String(repeating: "7", count: 40))
        XCTAssertEqual(profile.contentFingerprintSHA256, fixture.binding.fingerprintSHA256)
        XCTAssertEqual(profile.weightBytes, 2_220)
        XCTAssertEqual(profile.layerCount, 7)
        XCTAssertEqual(profile.keyValueHeadCount, 2)
        XCTAssertEqual(profile.headDimension, 7)
        XCTAssertEqual(profile.scalarBytes, 2)
        XCTAssertEqual(profile.supportedContextTokens, 713)
        XCTAssertEqual(profile.nonWeightOverheadBytes, 37)
        XCTAssertEqual(profile.activationBytesPerToken, 588)
        XCTAssertFalse(String(describing: profile).contains(Self.forbiddenDefault))
    }

    func testConfigBytesMustMatchTheExactBoundFileBeforeProfilePublication() throws {
        let fixture = try makeFixture()
        let builder = RuntimeModelResourceProfileBuilder(
            calibration: RuntimeModelResourceCalibration(
                nonWeightOverheadBytes: 41,
                activationWorkingSetMultiplier: 5
            )
        )
        let altered = fixture.configData + Data("\nT_RUNTIME_PROFILE_ALTERED_739".utf8)

        XCTAssertThrowsError(try builder.buildChatProfile(
            profileID: "T_RUNTIME_PROFILE_01_ALTERED_739",
            modelID: Self.modelID,
            binding: fixture.binding,
            configData: altered
        )) { error in
            XCTAssertEqual(
                error as? RuntimeModelResourceProfileError,
                .configBindingMismatch
            )
        }
    }

    func testMissingInvalidAndUnsupportedConfigFieldsFailClosed() throws {
        let fixture = try makeFixture()
        let builder = RuntimeModelResourceProfileBuilder(
            calibration: RuntimeModelResourceCalibration(
                nonWeightOverheadBytes: 43,
                activationWorkingSetMultiplier: 7
            )
        )

        let cases: [(String, [String: Any], RuntimeModelResourceProfileError)] = [
            (
                "missing-layers",
                Self.validConfig(removing: "num_hidden_layers"),
                .missingConfigurationField("num_hidden_layers")
            ),
            (
                "nondivisible-heads",
                Self.validConfig(overrides: ["hidden_size": 99]),
                .invalidConfigurationField("hidden_size")
            ),
            (
                "unsupported-dtype",
                Self.validConfig(overrides: ["torch_dtype": "float713"]),
                .unsupportedScalarType("float713")
            ),
            (
                "zero-context",
                Self.validConfig(overrides: ["max_position_embeddings": 0]),
                .invalidConfigurationField("max_position_embeddings")
            ),
        ]

        for (wire, object, expected) in cases {
            let configData = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            let rebound = try Self.binding(configData: configData)
            XCTAssertThrowsError(try builder.buildChatProfile(
                profileID: "T_RUNTIME_PROFILE_01_\(wire)",
                modelID: Self.modelID,
                binding: rebound,
                configData: configData
            )) { error in
                XCTAssertEqual(error as? RuntimeModelResourceProfileError, expected)
            }
        }

        XCTAssertFalse(String(describing: cases).contains(Self.forbiddenDefault))
        XCTAssertEqual(fixture.binding.files.count, 4)
    }

    func testShippingHostBuildsBoundChatProfileFromVerifiedConfigNotFixedShape() throws {
        let host = try source(
            "Apps/SupraAI/SupraRuntimeService/SupraRuntimeService.swift"
        )

        XCTAssertTrue(host.contains("RuntimeModelResourceProfileBuilder"))
        XCTAssertTrue(host.contains("verifiedModelConfigData("))
        XCTAssertTrue(host.contains("buildChatProfile("))
        XCTAssertFalse(host.contains("layerCount: 32"))
        XCTAssertFalse(host.contains("keyValueHeadCount: 8"))
        XCTAssertFalse(host.contains("headDimension: 128"))
        XCTAssertFalse(host.contains(Self.forbiddenDefault))
    }

    private func makeFixture() throws -> ProfileFixture {
        let configData = try JSONSerialization.data(
            withJSONObject: Self.validConfig(),
            options: [.sortedKeys]
        )
        return ProfileFixture(
            configData: configData,
            binding: try Self.binding(configData: configData)
        )
    }

    private static func validConfig(
        removing removedKey: String? = nil,
        overrides: [String: Any] = [:]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "model_type": "synthetic-runtime-profile-wire-713",
            "num_hidden_layers": 7,
            "num_attention_heads": 14,
            "num_key_value_heads": 2,
            "hidden_size": 98,
            "torch_dtype": "bfloat16",
            "max_position_embeddings": 713,
        ]
        if let removedKey { object.removeValue(forKey: removedKey) }
        for (key, value) in overrides { object[key] = value }
        return object
    }

    private static func binding(
        configData: Data
    ) throws -> RuntimeModelContentBinding {
        let files = [
            RuntimeModelContentBinding.File(
                path: "config.json",
                size: Int64(configData.count),
                declaredDigestAlgorithm: "sha256",
                declaredDigest: sha256(configData),
                actualSHA256: sha256(configData)
            ),
            RuntimeModelContentBinding.File(
                path: "model-00001-of-00002.safetensors",
                size: 1_103,
                declaredDigestAlgorithm: "sha256",
                declaredDigest: String(repeating: "1", count: 64),
                actualSHA256: String(repeating: "2", count: 64)
            ),
            RuntimeModelContentBinding.File(
                path: "model-00002-of-00002.safetensors",
                size: 1_117,
                declaredDigestAlgorithm: "sha256",
                declaredDigest: String(repeating: "3", count: 64),
                actualSHA256: String(repeating: "4", count: 64)
            ),
            RuntimeModelContentBinding.File(
                path: "tokenizer.json",
                size: 17,
                declaredDigestAlgorithm: "sha256",
                declaredDigest: String(repeating: "5", count: 64),
                actualSHA256: String(repeating: "6", count: 64)
            ),
        ]
        let revision = String(repeating: "7", count: 40)
        let fingerprint = try RuntimeModelContentBinding.canonicalFingerprintSHA256(
            algorithm: RuntimeModelContentBinding.fingerprintAlgorithm,
            schemaVersion: RuntimeModelContentBinding.supportedManifestSchemaVersion,
            repositoryID: "synthetic/runtime-profile-wire-713",
            revision: revision,
            files: files
        )
        return try RuntimeModelContentBinding(
            algorithm: RuntimeModelContentBinding.fingerprintAlgorithm,
            schemaVersion: RuntimeModelContentBinding.supportedManifestSchemaVersion,
            repositoryID: "synthetic/runtime-profile-wire-713",
            revision: revision,
            files: files,
            fingerprintSHA256: fingerprint
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

private struct ProfileFixture {
    let configData: Data
    let binding: RuntimeModelContentBinding
}
