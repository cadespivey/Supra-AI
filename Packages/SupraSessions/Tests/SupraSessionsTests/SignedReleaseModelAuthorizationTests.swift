import Foundation
import SupraCore
import SupraRuntimeInterface
@testable import SupraSessions
import XCTest

final class SignedReleaseModelAuthorizationTests: XCTestCase {
    private let expectedFingerprint = "9403244220818d3139ea6d154268eb9395647d8513617be7f403569a90999489"

    func testAuthorizeBindsVerifiedExclusiveManifestTree() throws {
        let fixture = try makeFixture()

        let authorization = try SignedReleaseModelAuthorization.authorize(
            modelDirectory: fixture.modelDirectory,
            managedRoot: fixture.managedRoot,
            expectedSHA256: expectedFingerprint
        )

        XCTAssertEqual(authorization.modelSHA256, expectedFingerprint)
        XCTAssertEqual(authorization.manifest.repositoryID, "mlx-community/Release-Smoke-4bit")
        XCTAssertEqual(authorization.manifest.revision, String(repeating: "a", count: 40))

        let modelID = ModelID()
        let request = try authorization.makeLoadRequest(
            modelID: modelID,
            displayName: "Protected release smoke model"
        )
        XCTAssertEqual(request.modelID, modelID)
        XCTAssertEqual(request.modelPath, fixture.modelDirectory.path)
        XCTAssertEqual(request.managedRootPath, fixture.managedRoot.path)
        XCTAssertFalse(request.modelBookmark?.isEmpty ?? true)
        XCTAssertNotNil(request.modelDirectoryIdentity)
        let binding = try XCTUnwrap(request.contentBinding)
        XCTAssertEqual(binding.algorithm, SignedReleaseModelAuthorization.fingerprintAlgorithm)
        XCTAssertEqual(binding.schemaVersion, 1)
        XCTAssertEqual(binding.repositoryID, "mlx-community/Release-Smoke-4bit")
        XCTAssertEqual(binding.revision, String(repeating: "a", count: 40))
        XCTAssertEqual(binding.files.map(\.path), ["config.json", "model.safetensors"])
        XCTAssertEqual(binding.files.map(\.size), [22, 31])
        XCTAssertEqual(
            binding.files.map(\.declaredDigestAlgorithm),
            ["sha256", "sha256"]
        )
        XCTAssertEqual(
            binding.files.map(\.actualSHA256),
            binding.files.map(\.declaredDigest)
        )
        XCTAssertEqual(binding.fingerprintSHA256, expectedFingerprint)
        XCTAssertNoThrow(try authorization.reverify())
    }

    func testAuthorizeRejectsManagedRootAndOutsideDirectory() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(
            try SignedReleaseModelAuthorization.authorize(
                modelDirectory: fixture.managedRoot,
                managedRoot: fixture.managedRoot,
                expectedSHA256: expectedFingerprint
            )
        )

        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.modelDirectory, to: outside)
        XCTAssertThrowsError(
            try SignedReleaseModelAuthorization.authorize(
                modelDirectory: outside,
                managedRoot: fixture.managedRoot,
                expectedSHA256: expectedFingerprint
            )
        )
    }

    func testAuthorizeRejectsUndeclaredFileAndDirectory() throws {
        let undeclaredFileFixture = try makeFixture()
        try Data("not-declared".utf8).write(
            to: undeclaredFileFixture.modelDirectory.appendingPathComponent("notes.txt")
        )
        XCTAssertThrowsError(
            try authorize(undeclaredFileFixture)
        )

        let undeclaredDirectoryFixture = try makeFixture()
        try FileManager.default.createDirectory(
            at: undeclaredDirectoryFixture.modelDirectory.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: false
        )
        XCTAssertThrowsError(
            try authorize(undeclaredDirectoryFixture)
        )
    }

    func testAuthorizeRejectsModelRootAndNestedSymlinks() throws {
        let modelRootFixture = try makeFixture()
        let modelLink = modelRootFixture.managedRoot.appendingPathComponent("linked-model", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: modelLink,
            withDestinationURL: modelRootFixture.modelDirectory
        )
        XCTAssertThrowsError(
            try SignedReleaseModelAuthorization.authorize(
                modelDirectory: modelLink,
                managedRoot: modelRootFixture.managedRoot,
                expectedSHA256: expectedFingerprint
            )
        )

        let nestedFixture = try makeFixture()
        let outside = nestedFixture.base.appendingPathComponent("outside-tokenizer.json")
        try Data("tokenizer-canary".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: nestedFixture.modelDirectory.appendingPathComponent("tokenizer.json"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(
            try authorize(nestedFixture)
        )
    }

    func testAuthorizeRejectsHardLinkedArtifact() throws {
        let fixture = try makeFixture()
        try FileManager.default.linkItem(
            at: fixture.modelDirectory.appendingPathComponent("model.safetensors"),
            to: fixture.base.appendingPathComponent("outside-hard-link.safetensors")
        )

        XCTAssertThrowsError(try authorize(fixture))
    }

    func testAuthorizeRejectsManifestAndArtifactMutation() throws {
        let manifestFixture = try makeFixture()
        try Data("replaced-manifest".utf8).write(to: manifestFixture.manifestURL)
        XCTAssertThrowsError(
            try authorize(manifestFixture)
        )

        let artifactFixture = try makeFixture()
        let weight = artifactFixture.modelDirectory.appendingPathComponent("model.safetensors")
        let original = try Data(contentsOf: weight)
        try Data(repeating: 0x58, count: original.count).write(to: weight)
        XCTAssertThrowsError(
            try authorize(artifactFixture)
        )
    }

    func testReverifyDetectsInPlaceMutationAfterAuthorization() throws {
        let fixture = try makeFixture()
        let authorization = try authorize(fixture)
        let weight = fixture.modelDirectory.appendingPathComponent("model.safetensors")
        let original = try Data(contentsOf: weight)
        try Data(repeating: 0x59, count: original.count).write(to: weight)

        XCTAssertThrowsError(try authorization.reverify())
    }

    private func authorize(_ fixture: Fixture) throws -> SignedReleaseModelAuthorization {
        try SignedReleaseModelAuthorization.authorize(
            modelDirectory: fixture.modelDirectory,
            managedRoot: fixture.managedRoot,
            expectedSHA256: expectedFingerprint
        )
    }

    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignedReleaseModelAuthorization-\(UUID().uuidString)", isDirectory: true)
        let managedRoot = base.appendingPathComponent("Models", isDirectory: true)
        let modelDirectory = managedRoot.appendingPathComponent("release-smoke", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        let payloads = [
            "config.json": Data(#"{"model_type":"qwen2"}"#.utf8),
            "model.safetensors": Data("protected-release-weight-canary".utf8),
        ]
        for (relativePath, data) in payloads {
            try data.write(to: modelDirectory.appendingPathComponent(relativePath))
        }

        let manifest = ModelArtifactManifest(
            repositoryID: "mlx-community/Release-Smoke-4bit",
            revision: String(repeating: "a", count: 40),
            files: payloads.map { relativePath, data in
                ModelArtifactManifest.File(
                    relativePath: relativePath,
                    size: Int64(data.count),
                    digestAlgorithm: .sha256,
                    digest: ModelArtifactIntegrity.sha256Hex(data)
                )
            }
        )
        let manifestURL = ManagedModelStorage.manifestURL(in: modelDirectory)
        try ManagedModelStorage.writeManifest(manifest, to: manifestURL)
        return Fixture(
            base: base,
            managedRoot: managedRoot,
            modelDirectory: modelDirectory,
            manifestURL: manifestURL
        )
    }

    private struct Fixture {
        let base: URL
        let managedRoot: URL
        let modelDirectory: URL
        let manifestURL: URL
    }
}
