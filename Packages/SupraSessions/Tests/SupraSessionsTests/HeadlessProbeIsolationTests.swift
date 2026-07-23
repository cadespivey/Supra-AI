import Foundation
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// Measurement-qualification gate for headless probes (review finding #5): the
/// `-runCapabilityProbe` / `-runTypedProseABProbe` launch flags currently execute
/// inside the shipping `AppEnvironment` initialization against whatever store the app
/// opened — the USER'S real app-support store — and leave through `exit(0)`.
///
/// The corrective contract, whose app-side glue consumes the two types gated here:
///
/// - `HeadlessProbeMode` resolves the launch arguments to at most ONE probe mode —
///   multiple probe flags are a `.conflict`, and nothing runs. Model-dependent modes
///   declare `requiresIsolatedStore`, so the store factory opens a throwaway
///   temporary store and the user's normal store is never opened or migrated.
/// - `DiskModelRegistrar` rebuilds a model registry on that ISOLATED store from the
///   managed model directory's verified manifests — disk truth — so the probes keep
///   answering "which models are downloaded / can they hold the schema" without
///   reading the user's database or touching the user's active-model selection.
///
/// Expected RED for this file: `HeadlessProbeMode` and `DiskModelRegistrar` do not
/// exist, so the file does not compile. The app-side glue (isolated store choice,
/// normal termination instead of `exit(0)`, side-effect gating) is app-target code
/// verified by build and inspection; the decision logic it consumes is gated here.
final class HeadlessProbeIsolationTests: XCTestCase {

    // MARK: - Mode resolution is mutually exclusive

    /// T-PROBE-01. No probe flags → no probe mode; ordinary launches are untouched.
    func testNoProbeFlagsResolvesToNone() {
        XCTAssertEqual(
            HeadlessProbeMode.resolve(arguments: ["SupraAI", "-NSDocumentRevisionsDebugMode", "YES"]),
            .none
        )
    }

    /// T-PROBE-02. Each probe flag resolves to exactly its mode.
    func testEachProbeFlagResolvesToItsMode() {
        XCTAssertEqual(
            HeadlessProbeMode.resolve(arguments: ["SupraAI", "-runCapabilityProbe"]),
            .single(.capability)
        )
        XCTAssertEqual(
            HeadlessProbeMode.resolve(arguments: ["SupraAI", "-runTypedProseABProbe", "-abRepeats", "3"]),
            .single(.typedProseAB)
        )
        XCTAssertEqual(
            HeadlessProbeMode.resolve(arguments: ["SupraAI", "-runCoverageShadowProbe"]),
            .single(.coverageShadow)
        )
    }

    /// T-PROBE-03. Probe modes are mutually exclusive: several probe flags resolve to
    /// a conflict carrying every requested mode, and the caller runs NONE of them.
    func testMultipleProbeFlagsAreAConflict() {
        XCTAssertEqual(
            HeadlessProbeMode.resolve(arguments: ["SupraAI", "-runCapabilityProbe", "-runTypedProseABProbe"]),
            .conflict([.capability, .typedProseAB])
        )
        XCTAssertEqual(
            HeadlessProbeMode.resolve(arguments: [
                "SupraAI", "-runCoverageShadowProbe", "-runCapabilityProbe", "-runTypedProseABProbe",
            ]),
            .conflict([.coverageShadow, .capability, .typedProseAB])
        )
    }

    /// T-PROBE-04. The model-dependent probes must run on an isolated throwaway
    /// store; the coverage probe is the one justified real-store diagnostic (it
    /// replays the store's own chat history, read-only) and says so explicitly.
    func testIsolationRequirementIsExplicitPerMode() {
        XCTAssertTrue(HeadlessProbeMode.capability.requiresIsolatedStore)
        XCTAssertTrue(HeadlessProbeMode.typedProseAB.requiresIsolatedStore)
        XCTAssertFalse(HeadlessProbeMode.coverageShadow.requiresIsolatedStore)
    }

    /// T-PROBE-08. Normal bootstrap contains write-capable recovery, queue, retention,
    /// backup, and update work. It may run only for an ordinary launch; every probe
    /// resolution, including the real-store coverage diagnostic and a conflict, must
    /// bypass it completely.
    func testOnlyOrdinaryLaunchPermitsNormalBootstrap() {
        XCTAssertTrue(HeadlessProbeMode.Resolution.none.permitsNormalBootstrap)
        XCTAssertFalse(
            HeadlessProbeMode.Resolution.single(.coverageShadow).permitsNormalBootstrap,
            "the real-store coverage probe must remain read-only"
        )
        XCTAssertFalse(HeadlessProbeMode.Resolution.single(.capability).permitsNormalBootstrap)
        XCTAssertFalse(HeadlessProbeMode.Resolution.single(.typedProseAB).permitsNormalBootstrap)
        XCTAssertFalse(
            HeadlessProbeMode.Resolution.conflict([.coverageShadow, .capability]).permitsNormalBootstrap
        )
    }

    /// T-PROBE-09. Failure to create the preferred temporary database cannot widen
    /// authority to the user's Application Support store. Only an ordinary launch or
    /// the intentionally real-store coverage probe may open it.
    func testOnlyUserStoreModesPermitOpeningApplicationSupport() {
        XCTAssertTrue(HeadlessProbeMode.Resolution.none.permitsUserStoreOpen)
        XCTAssertTrue(HeadlessProbeMode.Resolution.single(.coverageShadow).permitsUserStoreOpen)
        XCTAssertFalse(HeadlessProbeMode.Resolution.single(.capability).permitsUserStoreOpen)
        XCTAssertFalse(HeadlessProbeMode.Resolution.single(.typedProseAB).permitsUserStoreOpen)
        XCTAssertFalse(
            HeadlessProbeMode.Resolution.conflict([.coverageShadow, .typedProseAB]).permitsUserStoreOpen
        )
    }

    // MARK: - Coverage probe degraded-store / build-configuration contract

    /// T-PROBE-10. A resolved coverage probe that cannot run must say WHY, so the app
    /// glue can emit the reason and terminate. Before this contract the
    /// fallback/recovery branch silently ran nothing: no probe, no report, no
    /// termination — a headless harness polling for the report delimiters hung
    /// forever. Debug builds are refused outright: the coverage probe is the one
    /// real-store diagnostic, and real data is Release-only (a Debug launch could
    /// migrate the user's live schema on mismatch).
    ///
    /// Expected RED: compile error — `coverageShadowUnavailableReason` does not exist
    /// on `HeadlessProbeMode`.
    func testCoverageShadowUnavailabilityIsExplicit() {
        XCTAssertNil(
            HeadlessProbeMode.coverageShadowUnavailableReason(
                isFallbackStore: false, hasRecoveryState: false, isDebugBuild: false
            ),
            "a healthy store in a Release build runs the probe"
        )
        XCTAssertEqual(
            HeadlessProbeMode.coverageShadowUnavailableReason(
                isFallbackStore: true, hasRecoveryState: false, isDebugBuild: false
            ),
            "coverage_probe_store_is_fallback"
        )
        XCTAssertEqual(
            HeadlessProbeMode.coverageShadowUnavailableReason(
                isFallbackStore: false, hasRecoveryState: true, isDebugBuild: false
            ),
            "coverage_probe_store_in_recovery"
        )
        XCTAssertEqual(
            HeadlessProbeMode.coverageShadowUnavailableReason(
                isFallbackStore: false, hasRecoveryState: false, isDebugBuild: true
            ),
            "coverage_probe_requires_release_build",
            "Debug builds must never open the real store, even for the read-only diagnostic"
        )
        XCTAssertEqual(
            HeadlessProbeMode.coverageShadowUnavailableReason(
                isFallbackStore: true, hasRecoveryState: true, isDebugBuild: true
            ),
            "coverage_probe_requires_release_build",
            "the build-configuration refusal outranks store-state reasons"
        )
    }

    // MARK: - Disk-truth model registry on an isolated store

    /// T-PROBE-05. A manifest-verified model folder registers into the isolated
    /// store's library; the registry reflects disk truth without ever opening the
    /// user's database.
    @MainActor
    func testManifestVerifiedModelFolderRegisters() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeVerifiedModelFolder(named: "synthetic-qual-model", under: root)

        let library = try makeIsolatedLibrary()
        let registered = DiskModelRegistrar.registerVerifiedModels(into: library, root: root)

        XCTAssertEqual(registered, ["synthetic/qual-model"])
        XCTAssertEqual(library.models.count, 1)
        XCTAssertEqual(library.models.first?.displayName, "synthetic/qual-model")
    }

    /// T-PROBE-06. Folders that do not verify — no manifest, or a manifest whose
    /// file sizes do not match disk — are skipped, never guessed at.
    @MainActor
    func testUnverifiedFoldersAreSkipped() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // A bare folder with no manifest at all.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("no-manifest"), withIntermediateDirectories: true
        )
        // A folder whose manifest overstates the weights size.
        try writeVerifiedModelFolder(named: "size-mismatch", under: root, corruptWeightsSize: true)

        let library = try makeIsolatedLibrary()
        let registered = DiskModelRegistrar.registerVerifiedModels(into: library, root: root)

        XCTAssertTrue(registered.isEmpty, "unverified folders must not register: \(registered)")
        XCTAssertTrue(library.models.isEmpty)
    }

    /// T-PROBE-07. Registration is deterministic (sorted by folder name) and
    /// idempotent enough for a probe launch: a second scan does not duplicate.
    @MainActor
    func testRegistrationIsDeterministicAndDoesNotDuplicate() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeVerifiedModelFolder(named: "b-model", under: root, repositoryID: "synthetic/b-model")
        try writeVerifiedModelFolder(named: "a-model", under: root, repositoryID: "synthetic/a-model")

        let library = try makeIsolatedLibrary()
        let first = DiskModelRegistrar.registerVerifiedModels(into: library, root: root)
        XCTAssertEqual(first, ["synthetic/a-model", "synthetic/b-model"])
        let second = DiskModelRegistrar.registerVerifiedModels(into: library, root: root)
        XCTAssertEqual(second, [], "a rescan must not re-register already-registered paths")
        XCTAssertEqual(library.models.count, 2)
    }

    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func makeIsolatedLibrary() throws -> ModelLibrary {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-isolation-store-\(UUID().uuidString).sqlite")
        return ModelLibrary(store: try SupraStore(url: storeURL), runtimeClient: StubRuntimeClient())
    }

    /// Writes a synthetic managed-model folder that passes
    /// `ManagedModelStorage.loadVerifiedManifest`: a config.json with a model_type,
    /// a small weights file, and a completion manifest whose sizes AND sha256
    /// digests match disk (verification full-hashes every artifact).
    private func writeVerifiedModelFolder(
        named name: String,
        under root: URL,
        repositoryID: String = "synthetic/qual-model",
        corruptWeightsSize: Bool = false
    ) throws {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = Data(#"{"model_type": "synthetic"}"#.utf8)
        try config.write(to: directory.appendingPathComponent("config.json"))
        let weights = Data("synthetic-weights".utf8)
        try weights.write(to: directory.appendingPathComponent("weights.safetensors"))
        let manifest = ModelArtifactManifest(
            repositoryID: repositoryID,
            revision: String(repeating: "a", count: 40),
            files: [
                ModelArtifactManifest.File(
                    relativePath: "config.json",
                    size: Int64(config.count),
                    digestAlgorithm: .sha256,
                    digest: ModelArtifactIntegrity.sha256Hex(config)
                ),
                ModelArtifactManifest.File(
                    relativePath: "weights.safetensors",
                    size: Int64(weights.count) + (corruptWeightsSize ? 1 : 0),
                    digestAlgorithm: .sha256,
                    digest: ModelArtifactIntegrity.sha256Hex(weights)
                ),
            ]
        )
        try ManagedModelStorage.writeManifest(manifest, to: ManagedModelStorage.manifestURL(in: directory))
    }
}
