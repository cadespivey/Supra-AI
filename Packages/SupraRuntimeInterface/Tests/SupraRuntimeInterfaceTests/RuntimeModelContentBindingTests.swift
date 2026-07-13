import CryptoKit
import Foundation
import SupraCore
@testable import SupraRuntimeInterface
import XCTest

/// RED: the runtime transport must carry the complete canonical document whose
/// SHA-256 was authorized by the app. A path/bookmark alone does not bind the
/// bytes that the XPC service ultimately loads.
final class RuntimeModelContentBindingTests: XCTestCase {
    private static let algorithm = "supra-release-model-sha256-v1"
    private static let expectedFingerprint =
        "9403244220818d3139ea6d154268eb9395647d8513617be7f403569a90999489"
    private static let revision = String(repeating: "a", count: 40)
    private static let configSHA256 =
        "3ea011c96fbc6ca4f0bd3efa020370e6fd34dda1c1dfd67c39c9fb559aa07d20"
    private static let weightsSHA256 =
        "8023d7f0339cacea2f9e2ef43d5bc49b0053821632d8af370c90ae1bab61cb50"

    func testBindingEncodesTheFrozenCanonicalFingerprintDocument() throws {
        let binding = try makeBinding()

        XCTAssertEqual(binding.algorithm, Self.algorithm)
        XCTAssertEqual(binding.schemaVersion, 1)
        XCTAssertEqual(binding.repositoryID, "mlx-community/Release-Smoke-4bit")
        XCTAssertEqual(binding.revision, Self.revision)
        XCTAssertEqual(binding.files.map(\.path), ["config.json", "model.safetensors"])
        XCTAssertEqual(binding.files.map(\.size), [22, 31])
        XCTAssertEqual(binding.fingerprintSHA256, Self.expectedFingerprint)

        let encoded = try RuntimeXPCCodec.encode(binding)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "algorithm",
                "schemaVersion",
                "repositoryID",
                "revision",
                "files",
                "fingerprintSHA256",
            ])
        )
        let encodedFiles = try XCTUnwrap(object["files"] as? [[String: Any]])
        XCTAssertEqual(encodedFiles.count, 2)
        for file in encodedFiles {
            XCTAssertEqual(
                Set(file.keys),
                Set([
                    "path",
                    "size",
                    "declaredDigestAlgorithm",
                    "declaredDigest",
                    "actualSHA256",
                ])
            )
        }

        // The binding's fingerprint is the hash of these fields only. In
        // particular, fingerprintSHA256 is not part of its own hash input.
        let canonical = CanonicalFingerprintDocument(
            algorithm: binding.algorithm,
            schemaVersion: binding.schemaVersion,
            repositoryID: binding.repositoryID,
            revision: binding.revision,
            files: binding.files.map {
                CanonicalFingerprintDocument.File(
                    path: $0.path,
                    size: $0.size,
                    declaredDigestAlgorithm: $0.declaredDigestAlgorithm,
                    declaredDigest: $0.declaredDigest,
                    actualSHA256: $0.actualSHA256
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonicalData = try encoder.encode(canonical)

        XCTAssertEqual(sha256(canonicalData), Self.expectedFingerprint)
        XCTAssertEqual(binding.fingerprintSHA256, sha256(canonicalData))
    }

    func testBindingAcceptsCanonicalGitBlobSHA1DeclaredDigest() throws {
        let gitBlobSHA1 = String(repeating: "b", count: 40)
        let files = [
            RuntimeModelContentBinding.File(
                path: "config.json",
                size: 22,
                declaredDigestAlgorithm: "git-blob-sha1",
                declaredDigest: gitBlobSHA1,
                actualSHA256: Self.configSHA256
            ),
            RuntimeModelContentBinding.File(
                path: "model.safetensors",
                size: 31,
                declaredDigestAlgorithm: "sha256",
                declaredDigest: Self.weightsSHA256,
                actualSHA256: Self.weightsSHA256
            ),
        ]
        let fingerprint = try canonicalFingerprint(files: files)

        let binding = try RuntimeModelContentBinding(
            algorithm: Self.algorithm,
            schemaVersion: 1,
            repositoryID: "mlx-community/Release-Smoke-4bit",
            revision: Self.revision,
            files: files,
            fingerprintSHA256: fingerprint
        )

        XCTAssertEqual(binding.files[0].declaredDigestAlgorithm, "git-blob-sha1")
        XCTAssertEqual(binding.files[0].declaredDigest, gitBlobSHA1)
        XCTAssertEqual(binding.fingerprintSHA256, fingerprint)
    }

    func testLoadModelRequestRoundTripsContentBinding() throws {
        let binding = try makeBinding()
        let request = LoadModelRequest(
            modelID: ModelID(),
            modelPath: "/models/release-smoke",
            displayName: "Release smoke",
            modelBookmark: Data([0x01, 0x02]),
            managedRootPath: "/models",
            modelDirectoryIdentity: ModelDirectoryIdentity(deviceID: 12, inode: 34),
            contentBinding: binding
        )

        let decoded = try RuntimeXPCCodec.decode(
            LoadModelRequest.self,
            from: RuntimeXPCCodec.encode(request)
        )

        XCTAssertEqual(decoded.contentBinding, binding)
    }

    func testLoadModelRequestDecodesLegacyPayloadWithoutContentBinding() throws {
        let legacy = LegacyLoadModelRequest(
            modelID: ModelID(),
            modelPath: "/models/legacy",
            displayName: "Legacy",
            modelBookmark: Data([0xAA]),
            managedRootPath: "/models",
            modelDirectoryIdentity: ModelDirectoryIdentity(deviceID: 56, inode: 78)
        )

        let decoded = try RuntimeXPCCodec.decode(
            LoadModelRequest.self,
            from: RuntimeXPCCodec.encode(legacy)
        )

        XCTAssertNil(decoded.contentBinding)
    }

    func testLoadModelResponseRoundTripsVerifiedModelSHA256() throws {
        let modelID = ModelID()
        let response = LoadModelResponse(
            status: .loaded,
            modelID: modelID,
            metrics: RuntimeMetrics(loadTimeMs: 123),
            verifiedModelSHA256: Self.expectedFingerprint
        )

        let decoded = try RuntimeXPCCodec.decode(
            LoadModelResponse.self,
            from: RuntimeXPCCodec.encode(response)
        )

        XCTAssertEqual(decoded.status, .loaded)
        XCTAssertEqual(decoded.modelID, modelID)
        XCTAssertEqual(decoded.verifiedModelSHA256, Self.expectedFingerprint)
    }

    func testLoadModelResponseDecodesLegacyPayloadWithoutVerifiedModelSHA256() throws {
        let legacy = LegacyLoadModelResponse(
            status: .loaded,
            modelID: ModelID(),
            metrics: RuntimeMetrics(loadTimeMs: 123),
            error: nil
        )

        let decoded = try RuntimeXPCCodec.decode(
            LoadModelResponse.self,
            from: RuntimeXPCCodec.encode(legacy)
        )

        XCTAssertNil(decoded.verifiedModelSHA256)
    }

    func testBindingDecoderRejectsMalformedOrNoncanonicalDocuments() throws {
        try assertBindingDecodeRejected("unknown algorithm") { object in
            object["algorithm"] = "supra-release-model-sha256-v2"
        }
        try assertBindingDecodeRejected("invalid schema version") { object in
            object["schemaVersion"] = 0
        }
        try assertBindingDecodeRejected("invalid repository ID") { object in
            object["repositoryID"] = "../release-smoke"
        }
        try assertBindingDecodeRejected("uppercase revision") { object in
            object["revision"] = Self.revision.uppercased()
        }
        try assertBindingDecodeRejected("short revision") { object in
            object["revision"] = String(Self.revision.dropLast())
        }
        try assertBindingDecodeRejected("empty file list") { object in
            object["files"] = []
        }
        try assertBindingDecodeRejected("unsorted files") { object in
            object["files"] = Array(try self.files(in: object).reversed())
        }
        try assertBindingDecodeRejected("duplicate path") { object in
            let files = try self.files(in: object)
            object["files"] = [files[0], files[0]]
        }
        try assertBindingDecodeRejected("unsafe path") { object in
            var files = try self.files(in: object)
            files[0]["path"] = "../config.json"
            object["files"] = files
        }
        try assertBindingDecodeRejected("negative size") { object in
            var files = try self.files(in: object)
            files[0]["size"] = -1
            object["files"] = files
        }
        try assertBindingDecodeRejected("unknown declared digest algorithm") { object in
            var files = try self.files(in: object)
            files[0]["declaredDigestAlgorithm"] = "md5"
            object["files"] = files
        }
        try assertBindingDecodeRejected("short declared digest") { object in
            var files = try self.files(in: object)
            files[0]["declaredDigest"] = String(Self.configSHA256.dropLast())
            object["files"] = files
        }
        try assertBindingDecodeRejected("short Git blob SHA-1") { object in
            var files = try self.files(in: object)
            files[0]["declaredDigestAlgorithm"] = "git-blob-sha1"
            files[0]["declaredDigest"] = String(repeating: "b", count: 39)
            object["files"] = files
        }
        try assertBindingDecodeRejected("uppercase declared digest") { object in
            var files = try self.files(in: object)
            files[0]["declaredDigest"] = Self.configSHA256.uppercased()
            object["files"] = files
        }
        try assertBindingDecodeRejected("short actual SHA-256") { object in
            var files = try self.files(in: object)
            files[0]["actualSHA256"] = String(Self.configSHA256.dropLast())
            object["files"] = files
        }
        try assertBindingDecodeRejected("uppercase actual SHA-256") { object in
            var files = try self.files(in: object)
            files[0]["actualSHA256"] = Self.configSHA256.uppercased()
            object["files"] = files
        }
        try assertBindingDecodeRejected(
            "uppercase fingerprint",
            repairCanonicalFingerprint: false
        ) { object in
            object["fingerprintSHA256"] = Self.expectedFingerprint.uppercased()
        }
        try assertBindingDecodeRejected(
            "well-formed but wrong fingerprint",
            repairCanonicalFingerprint: false
        ) { object in
            object["fingerprintSHA256"] = String(repeating: "0", count: 64)
        }
    }

    private func makeBinding() throws -> RuntimeModelContentBinding {
        try RuntimeModelContentBinding(
            algorithm: Self.algorithm,
            schemaVersion: 1,
            repositoryID: "mlx-community/Release-Smoke-4bit",
            revision: Self.revision,
            files: [
                RuntimeModelContentBinding.File(
                    path: "config.json",
                    size: 22,
                    declaredDigestAlgorithm: "sha256",
                    declaredDigest: Self.configSHA256,
                    actualSHA256: Self.configSHA256
                ),
                RuntimeModelContentBinding.File(
                    path: "model.safetensors",
                    size: 31,
                    declaredDigestAlgorithm: "sha256",
                    declaredDigest: Self.weightsSHA256,
                    actualSHA256: Self.weightsSHA256
                ),
            ],
            fingerprintSHA256: Self.expectedFingerprint
        )
    }

    private func canonicalFingerprint(
        files: [RuntimeModelContentBinding.File]
    ) throws -> String {
        let document = CanonicalFingerprintDocument(
            algorithm: Self.algorithm,
            schemaVersion: 1,
            repositoryID: "mlx-community/Release-Smoke-4bit",
            revision: Self.revision,
            files: files.map {
                CanonicalFingerprintDocument.File(
                    path: $0.path,
                    size: $0.size,
                    declaredDigestAlgorithm: $0.declaredDigestAlgorithm,
                    declaredDigest: $0.declaredDigest,
                    actualSHA256: $0.actualSHA256
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(document))
    }

    private func assertBindingDecodeRejected(
        _ reason: String,
        repairCanonicalFingerprint: Bool = true,
        mutate: (inout [String: Any]) throws -> Void
    ) throws {
        let validData = try RuntimeXPCCodec.encode(makeBinding())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        try mutate(&object)
        if repairCanonicalFingerprint {
            var canonical = object
            canonical.removeValue(forKey: "fingerprintSHA256")
            let canonicalData = try JSONSerialization.data(
                withJSONObject: canonical,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            object["fingerprintSHA256"] = sha256(canonicalData)
        }
        let malformedData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try RuntimeXPCCodec.decode(RuntimeModelContentBinding.self, from: malformedData),
            reason
        )
    }

    private func files(in object: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(object["files"] as? [[String: Any]])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct CanonicalFingerprintDocument: Encodable {
        let algorithm: String
        let schemaVersion: Int
        let repositoryID: String
        let revision: String
        let files: [File]

        struct File: Encodable {
            let path: String
            let size: Int64
            let declaredDigestAlgorithm: String
            let declaredDigest: String
            let actualSHA256: String
        }
    }

    private struct LegacyLoadModelRequest: Encodable {
        let modelID: ModelID
        let modelPath: String
        let displayName: String
        let modelBookmark: Data?
        let managedRootPath: String?
        let modelDirectoryIdentity: ModelDirectoryIdentity?
    }

    private struct LegacyLoadModelResponse: Encodable {
        let status: LoadModelStatus
        let modelID: ModelID?
        let metrics: RuntimeMetrics?
        let error: RuntimeError?
    }
}
