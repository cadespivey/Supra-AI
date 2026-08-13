import Foundation
@testable import SupraSessions
import SupraStore
import XCTest

/// T-HF-SESS-05
///
/// Guided New Review may describe hardware fit from a registered model's
/// app-managed manifest repository. This is presentation metadata only: it must
/// stay inside the configured managed root, reject malformed manifests, and
/// never load or mutate the runtime. Exact byte verification remains the later
/// Review pinning boundary.
@MainActor
final class ReviewModelHardwareMetadataProjectionTests: XCTestCase {
    private static let managedModelID = "77777777-7777-4777-8777-777777777777"
    private static let externalModelID = "88888888-8888-4888-8888-888888888888"
    private static let invalidModelID = "99999999-9999-4999-8999-999999999999"
    private static let managedRepositoryID = "mlx-community/Qwen3-32B-4bit"

    func testManagedRepositoryProjectionRequiresConfiguredRootAndStructuredManifestWithoutRuntimeLoad() throws {
        // Expected RED: ModelSummary has no managedRepositoryID projection and
        // ModelLibrary.refresh does not read structurally valid managed manifests.
        let fixture = try makeFixture()
        let runtime = StubRuntimeClient()
        let library = ModelLibrary(
            store: fixture.store,
            runtimeClient: runtime,
            managedModelRoots: [fixture.managedRoot]
        )

        library.refresh()

        let managed = try XCTUnwrap(library.models.first { $0.id == Self.managedModelID })
        let external = try XCTUnwrap(library.models.first { $0.id == Self.externalModelID })
        let invalid = try XCTUnwrap(library.models.first { $0.id == Self.invalidModelID })

        XCTAssertEqual(managed.managedRepositoryID, Self.managedRepositoryID)
        XCTAssertNotEqual(
            managed.managedRepositoryID,
            managed.displayName,
            "the repository output must come from the manifest, not display-name parsing"
        )
        XCTAssertNil(
            external.managedRepositoryID,
            "a valid manifest outside the configured managed root must not become fit metadata"
        )
        XCTAssertNil(
            invalid.managedRepositoryID,
            "a known catalog repository in a structurally invalid manifest must remain unavailable"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.managedModelDirectory
                    .appendingPathComponent("config.json")
                    .path
            ),
            "precondition: projection is structural metadata, not artifact-byte verification"
        )
        XCTAssertTrue(
            runtime.loadRequests.isEmpty,
            "refreshing Review fit metadata must never load the runtime"
        )
    }

    private func makeFixture() throws -> ProjectionFixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReviewModelHardwareMetadataProjection-\(UUID().uuidString)",
            isDirectory: true
        )
        let managedRoot = base.appendingPathComponent("Models", isDirectory: true)
        let externalRoot = base.appendingPathComponent("External", isDirectory: true)
        let managedModelDirectory = managedRoot.appendingPathComponent(
            "managed-review-model",
            isDirectory: true
        )
        let invalidModelDirectory = managedRoot.appendingPathComponent(
            "invalid-review-model",
            isDirectory: true
        )
        let externalModelDirectory = externalRoot.appendingPathComponent(
            "external-review-model",
            isDirectory: true
        )
        for directory in [managedModelDirectory, invalidModelDirectory, externalModelDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        try writeStructurallyValidManifest(
            repositoryID: Self.managedRepositoryID,
            to: managedModelDirectory
        )
        try writeStructurallyValidManifest(
            repositoryID: "mlx-community/Qwen3-14B-4bit",
            to: externalModelDirectory
        )
        try writeStructurallyInvalidManifest(
            repositoryID: "mlx-community/Qwen3-8B-4bit",
            to: invalidModelDirectory
        )

        let store = try SupraStore(url: base.appendingPathComponent("test.sqlite"))
        try store.models.upsertModel(ModelRecord(
            id: Self.managedModelID,
            displayName: "Unrelated managed display canary 911",
            path: managedModelDirectory.path,
            validationStatus: "verified"
        ))
        try store.models.upsertModel(ModelRecord(
            id: Self.externalModelID,
            displayName: "mlx-community/Qwen3-14B-4bit",
            path: externalModelDirectory.path,
            validationStatus: "verified"
        ))
        try store.models.upsertModel(ModelRecord(
            id: Self.invalidModelID,
            displayName: "mlx-community/Qwen3-8B-4bit",
            path: invalidModelDirectory.path,
            validationStatus: "verified"
        ))

        return ProjectionFixture(
            managedRoot: managedRoot,
            managedModelDirectory: managedModelDirectory,
            store: store
        )
    }

    private func writeStructurallyValidManifest(
        repositoryID: String,
        to directory: URL
    ) throws {
        let manifest = ModelArtifactManifest(
            repositoryID: repositoryID,
            revision: String(repeating: "a", count: 40),
            files: [
                ModelArtifactManifest.File(
                    relativePath: "config.json",
                    size: 911,
                    digestAlgorithm: .sha256,
                    digest: String(repeating: "b", count: 64)
                ),
                ModelArtifactManifest.File(
                    relativePath: "model.safetensors",
                    size: 313,
                    digestAlgorithm: .sha256,
                    digest: String(repeating: "c", count: 64)
                ),
            ]
        )
        try ManagedModelStorage.writeManifest(
            manifest,
            to: ManagedModelStorage.manifestURL(in: directory)
        )
    }

    private func writeStructurallyInvalidManifest(
        repositoryID: String,
        to directory: URL
    ) throws {
        let invalid = ModelArtifactManifest(
            repositoryID: repositoryID,
            revision: String(repeating: "d", count: 40),
            files: []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(invalid).write(
            to: ManagedModelStorage.manifestURL(in: directory),
            options: .atomic
        )
    }
}

private struct ProjectionFixture {
    var managedRoot: URL
    var managedModelDirectory: URL
    var store: SupraStore
}
