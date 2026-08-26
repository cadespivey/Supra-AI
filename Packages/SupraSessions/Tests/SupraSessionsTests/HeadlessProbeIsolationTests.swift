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
        XCTAssertEqual(
            HeadlessProbeMode.resolve(arguments: [
                "SupraAI", "-runNativeRAGControl", "-nativeRAGCorpusRoot", "/synthetic/corpus",
            ]),
            .single(.nativeRAGControl)
        )
        XCTAssertEqual(
            HeadlessProbeMode.resolve(arguments: ["SupraAI", "-runScratchPadBillingFidelityProbe"]),
            .single(.scratchPadBillingFidelity)
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
                "-runNativeRAGControl", "-runScratchPadBillingFidelityProbe",
            ]),
            .conflict([.coverageShadow, .capability, .typedProseAB, .nativeRAGControl, .scratchPadBillingFidelity])
        )
    }

    /// T-PROBE-04. The model-dependent probes must run on an isolated throwaway
    /// store; the coverage probe is the one justified real-store diagnostic (it
    /// replays the store's own chat history, read-only) and says so explicitly.
    func testIsolationRequirementIsExplicitPerMode() {
        XCTAssertTrue(HeadlessProbeMode.capability.requiresIsolatedStore)
        XCTAssertTrue(HeadlessProbeMode.typedProseAB.requiresIsolatedStore)
        XCTAssertTrue(HeadlessProbeMode.nativeRAGControl.requiresIsolatedStore)
        XCTAssertTrue(HeadlessProbeMode.scratchPadBillingFidelity.requiresIsolatedStore)
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
        XCTAssertFalse(HeadlessProbeMode.Resolution.single(.nativeRAGControl).permitsNormalBootstrap)
        XCTAssertFalse(HeadlessProbeMode.Resolution.single(.scratchPadBillingFidelity).permitsNormalBootstrap)
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
        XCTAssertFalse(HeadlessProbeMode.Resolution.single(.nativeRAGControl).permitsUserStoreOpen)
        XCTAssertFalse(HeadlessProbeMode.Resolution.single(.scratchPadBillingFidelity).permitsUserStoreOpen)
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

    /// T-PROBE-11. The native RAG control reconstructs an embedding-model row from
    /// the exact manifest-verified disk artifact without reading the user's Store.
    /// Registration itself must not claim a successful runtime load or select the
    /// model; the control runner may do those only after a real embed succeeds.
    func testManifestVerifiedEmbeddingFolderRegistersUnverifiedInIsolatedStore() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeVerifiedModelFolder(
            named: "embedding-control",
            under: root,
            repositoryID: "synthetic/embedding-control",
            hiddenSize: 384
        )
        let store = try SupraStore.inMemory()

        let record = try DiskEmbeddingModelRegistrar.registerVerifiedModel(
            into: store,
            root: root,
            repositoryID: "synthetic/embedding-control"
        )

        XCTAssertEqual(record.repoID, "synthetic/embedding-control")
        XCTAssertEqual(record.dimension, 384)
        XCTAssertEqual(record.runtimeFamily, "synthetic")
        XCTAssertEqual(record.revision, String(repeating: "a", count: 40))
        XCTAssertNil(record.lastTestLoadAt)
        XCTAssertNil(record.lastTestLoadResult)
        XCTAssertFalse(record.isSelected)
        let persisted = try XCTUnwrap(store.documentSettings.fetchEmbeddingModels().only)
        XCTAssertEqual(persisted.id, record.id)
        XCTAssertEqual(persisted.repoID, record.repoID)
        XCTAssertEqual(persisted.dimension, record.dimension)
        XCTAssertNil(try store.documentSettings.fetchSelectedEmbeddingModel())
    }

    /// T-PROBE-12. A preferred repository cannot fall through to another valid
    /// downloaded artifact, and unverified/malformed folders never create rows.
    func testEmbeddingRegistrationFailsClosedForWrongOrMalformedArtifact() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeVerifiedModelFolder(
            named: "other-embedding",
            under: root,
            repositoryID: "synthetic/other-embedding",
            hiddenSize: 256
        )
        let malformed = root.appendingPathComponent("preferred-malformed", isDirectory: true)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Data(#"{"model_type":"synthetic","hidden_size":768}"#.utf8)
            .write(to: malformed.appendingPathComponent("config.json"))
        let store = try SupraStore.inMemory()

        XCTAssertThrowsError(
            try DiskEmbeddingModelRegistrar.registerVerifiedModel(
                into: store,
                root: root,
                repositoryID: "synthetic/preferred-embedding"
            )
        ) { error in
            XCTAssertEqual(
                error as? DiskEmbeddingModelRegistrationError,
                .verifiedArtifactNotFound("synthetic/preferred-embedding")
            )
        }
        XCTAssertTrue(try store.documentSettings.fetchEmbeddingModels().isEmpty)
    }

    @MainActor
    func testExactChatModelRegistrationRejectsFolderNameManifestMismatch() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let requested = "synthetic/requested-model"
        try writeVerifiedModelFolder(
            named: ManagedModelStorage.folderName(forRepoID: requested),
            under: root,
            repositoryID: "synthetic/different-model"
        )
        let library = try makeIsolatedLibrary()

        let model = DiskModelRegistrar.registerVerifiedModel(
            into: library,
            root: root,
            repositoryID: requested
        )

        XCTAssertNil(model)
        XCTAssertTrue(library.models.isEmpty)
    }

    @MainActor
    func testExactChatModelRegistrationReturnsVerifiedArtifactBinding() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repositoryID = "synthetic/bound-model"
        let folderName = ManagedModelStorage.folderName(forRepoID: repositoryID)
        try writeVerifiedModelFolder(
            named: folderName,
            under: root,
            repositoryID: repositoryID
        )
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        let manifest = try ManagedModelStorage.loadVerifiedManifest(at: folder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let expectedDigest = ModelArtifactIntegrity.sha256Hex(try encoder.encode(manifest.canonicalized()))
        let expectedContentBinding = try SignedReleaseModelAuthorization.inspectContentBinding(
            modelDirectory: folder,
            managedRoot: root
        )
        let library = try makeIsolatedLibrary()

        let binding = DiskModelRegistrar.registerVerifiedModelBinding(
            into: library,
            root: root,
            repositoryID: repositoryID
        )

        XCTAssertEqual(
            binding.map { URL(fileURLWithPath: $0.model.path).lastPathComponent },
            folder.lastPathComponent
        )
        XCTAssertEqual(binding?.repositoryID, repositoryID)
        XCTAssertEqual(binding?.revision, String(repeating: "a", count: 40))
        XCTAssertEqual(binding?.manifestSHA256, expectedDigest)
        XCTAssertEqual(
            binding?.artifactFingerprintSHA256,
            expectedContentBinding.fingerprintSHA256
        )
        XCTAssertEqual(binding?.contentBindingAlgorithm, expectedContentBinding.algorithm)
        XCTAssertEqual(
            binding?.contentBindingSchemaVersion,
            expectedContentBinding.schemaVersion
        )
    }

    @MainActor
    func testExactChatModelBindingMustStillVerifyImmediatelyBeforeExecution() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repositoryID = "synthetic/reverified-model"
        let folderName = ManagedModelStorage.folderName(forRepoID: repositoryID)
        try writeVerifiedModelFolder(
            named: folderName,
            under: root,
            repositoryID: repositoryID
        )
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        let library = try makeIsolatedLibrary()
        let binding = try XCTUnwrap(DiskModelRegistrar.registerVerifiedModelBinding(
            into: library,
            root: root,
            repositoryID: repositoryID
        ))

        XCTAssertTrue(DiskModelRegistrar.bindingStillVerified(
            binding,
            root: root
        ))
        try Data("{}".utf8).write(to: ManagedModelStorage.manifestURL(in: folder))
        XCTAssertFalse(DiskModelRegistrar.bindingStillVerified(
            binding,
            root: root
        ))
    }

    @MainActor
    func testExactChatModelRegistrationRejectsRootOutsideConfinement() throws {
        let confinement = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: confinement) }
        let outside = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let repositoryID = "synthetic/outside-model"
        try writeVerifiedModelFolder(
            named: ManagedModelStorage.folderName(forRepoID: repositoryID),
            under: outside,
            repositoryID: repositoryID
        )
        let linkedRoot = confinement.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        let library = try makeIsolatedLibrary()

        let binding = DiskModelRegistrar.registerVerifiedModelBinding(
            into: library,
            root: linkedRoot,
            repositoryID: repositoryID,
            confinedTo: confinement
        )

        XCTAssertNil(binding)
        XCTAssertTrue(library.models.isEmpty)
    }

    func testBillingReportWriterRefusesFinalSymlinkRace() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        let output = root.appendingPathComponent("billing-report.json")
        let invocation = try ScratchPadBillingFidelityInvocation.resolve(
            arguments: ["SupraAI", "-scratchPadBillingFidelityOutput", output.path],
            environment: [
                "SUPRA_BILLING_CHAT_REPOSITORY": "synthetic/model",
                "SUPRA_BILLING_SOURCE_SHA": String(repeating: "a", count: 40),
            ],
            temporaryDirectory: root,
            compiledSourceCommitSHA: String(repeating: "a", count: 40)
        )
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: outside)

        XCTAssertThrowsError(try invocation.writeReport(Data("{}".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testBillingReportWriterRefusesParentDirectorySwapRace() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let outside = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let output = parent.appendingPathComponent("billing-report.json")
        let invocation = try ScratchPadBillingFidelityInvocation.resolve(
            arguments: ["SupraAI", "-scratchPadBillingFidelityOutput", output.path],
            environment: [
                "SUPRA_BILLING_CHAT_REPOSITORY": "synthetic/model",
                "SUPRA_BILLING_SOURCE_SHA": String(repeating: "a", count: 40),
            ],
            temporaryDirectory: root,
            compiledSourceCommitSHA: String(repeating: "a", count: 40)
        )
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)

        XCTAssertThrowsError(try invocation.writeReport(Data("{}".utf8)))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("billing-report.json").path
            )
        )
    }

    func testBillingReportWriterRefusesIntermediateDirectorySwapRace() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reports = root.appendingPathComponent("reports", isDirectory: true)
        let parent = reports.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let outside = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        let output = parent.appendingPathComponent("billing-report.json")
        let invocation = try ScratchPadBillingFidelityInvocation.resolve(
            arguments: ["SupraAI", "-scratchPadBillingFidelityOutput", output.path],
            environment: [
                "SUPRA_BILLING_CHAT_REPOSITORY": "synthetic/model",
                "SUPRA_BILLING_SOURCE_SHA": String(repeating: "a", count: 40),
            ],
            temporaryDirectory: root,
            compiledSourceCommitSHA: String(repeating: "a", count: 40)
        )
        try FileManager.default.removeItem(at: reports)
        try FileManager.default.createSymbolicLink(at: reports, withDestinationURL: outside)

        XCTAssertThrowsError(try invocation.writeReport(Data("{}".utf8)))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("nested/billing-report.json").path
            )
        )
    }

    func testBillingReportWriterRejectsRootRenameBeforeFileCreation() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let moved = outside.appendingPathComponent("moved-root", isDirectory: true)

        XCTAssertThrowsError(try ScratchPadBillingFidelityReportWriter.write(
            Data("{}".utf8),
            rootURL: root,
            expectedRootIdentity: ScratchPadBillingFidelityReportWriter.rootIdentity(at: root),
            relativeParentComponents: [],
            fileName: "billing-report.json",
            beforeFileCreation: {
                try FileManager.default.moveItem(at: root, to: moved)
            }
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: moved.appendingPathComponent("billing-report.json").path
        ))
    }

    func testBillingReportWriterRejectsParentRenameBeforeFileCreation() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let reports = root.appendingPathComponent("reports", isDirectory: true)
        let nested = reports.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let moved = outside.appendingPathComponent("moved", isDirectory: true)

        XCTAssertThrowsError(try ScratchPadBillingFidelityReportWriter.write(
            Data("{}".utf8),
            rootURL: root,
            expectedRootIdentity: ScratchPadBillingFidelityReportWriter.rootIdentity(at: root),
            relativeParentComponents: ["reports", "nested"],
            fileName: "billing-report.json",
            beforeFileCreation: {
                try FileManager.default.moveItem(at: reports, to: moved)
            }
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: moved.appendingPathComponent("nested/billing-report.json").path
        ))
    }

    func testBillingReportWriterCleansFileAfterParentRenameFollowingCreation() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let reports = root.appendingPathComponent("reports", isDirectory: true)
        let nested = reports.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let moved = outside.appendingPathComponent("moved", isDirectory: true)

        XCTAssertThrowsError(try ScratchPadBillingFidelityReportWriter.write(
            Data("{}".utf8),
            rootURL: root,
            expectedRootIdentity: ScratchPadBillingFidelityReportWriter.rootIdentity(at: root),
            relativeParentComponents: ["reports", "nested"],
            fileName: "billing-report.json",
            afterFileCreation: {
                try FileManager.default.moveItem(at: reports, to: moved)
            }
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: moved.appendingPathComponent("nested/billing-report.json").path
        ))
    }

    func testBillingReportWriterRejectsLeafRenameBeforeWritingAndPreservesReplacement() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let fileName = "billing-report.json"
        let output = root.appendingPathComponent(fileName)
        let moved = outside.appendingPathComponent("moved-report.json")
        let replacement = Data("attacker replacement".utf8)

        XCTAssertThrowsError(try ScratchPadBillingFidelityReportWriter.write(
            Data("confidential report".utf8),
            rootURL: root,
            expectedRootIdentity: ScratchPadBillingFidelityReportWriter.rootIdentity(at: root),
            relativeParentComponents: [],
            fileName: fileName,
            afterFileCreation: {
                try FileManager.default.moveItem(at: output, to: moved)
                try replacement.write(to: output)
            }
        ))
        XCTAssertEqual(try Data(contentsOf: moved), Data())
        XCTAssertEqual(try Data(contentsOf: output), replacement)
    }

    func testBillingReportWriterTruncatesRenamedLeafAfterWriteAndPreservesReplacement() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let fileName = "billing-report.json"
        let output = root.appendingPathComponent(fileName)
        let moved = outside.appendingPathComponent("moved-report.json")
        let replacement = Data("attacker replacement".utf8)

        XCTAssertThrowsError(try ScratchPadBillingFidelityReportWriter.write(
            Data("confidential report".utf8),
            rootURL: root,
            expectedRootIdentity: ScratchPadBillingFidelityReportWriter.rootIdentity(at: root),
            relativeParentComponents: [],
            fileName: fileName,
            afterDataWrite: {
                try FileManager.default.moveItem(at: output, to: moved)
                try replacement.write(to: output)
            }
        ))
        XCTAssertEqual(try Data(contentsOf: moved), Data())
        XCTAssertEqual(try Data(contentsOf: output), replacement)
    }

    func testScratchPadBillingInvocationBindsCommitModelAndTemporaryOutput() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("billing-report.json")
        let sha = String(repeating: "a", count: 40)

        let invocation = try ScratchPadBillingFidelityInvocation.resolve(
            arguments: ["SupraAI", "-scratchPadBillingFidelityOutput", output.path],
            environment: [
                "SUPRA_BILLING_SOURCE_SHA": sha,
                "SUPRA_BILLING_CHAT_REPOSITORY": "synthetic/drafting-model",
            ],
            temporaryDirectory: root,
            compiledSourceCommitSHA: String(repeating: "a", count: 40)
        )

        XCTAssertEqual(invocation.outputURL, output.standardizedFileURL)
        XCTAssertEqual(invocation.sourceCommitSHA, sha)
        XCTAssertEqual(invocation.chatRepositoryID, "synthetic/drafting-model")

        let outside = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let escape = root.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        XCTAssertThrowsError(try ScratchPadBillingFidelityInvocation.resolve(
            arguments: ["SupraAI", "-scratchPadBillingFidelityOutput", escape.appendingPathComponent("report.json").path],
            environment: [
                "SUPRA_BILLING_SOURCE_SHA": sha,
                "SUPRA_BILLING_CHAT_REPOSITORY": "synthetic/drafting-model",
            ],
            temporaryDirectory: root,
            compiledSourceCommitSHA: String(repeating: "a", count: 40)
        ))

        try Data().write(to: output)
        XCTAssertThrowsError(try ScratchPadBillingFidelityInvocation.resolve(
            arguments: ["SupraAI", "-scratchPadBillingFidelityOutput", output.path],
            environment: [
                "SUPRA_BILLING_SOURCE_SHA": sha,
                "SUPRA_BILLING_CHAT_REPOSITORY": "synthetic/drafting-model",
            ],
            temporaryDirectory: root,
            compiledSourceCommitSHA: String(repeating: "a", count: 40)
        ))

        XCTAssertThrowsError(try ScratchPadBillingFidelityInvocation.resolve(
            arguments: ["SupraAI", "-scratchPadBillingFidelityOutput", "/private/outside.json"],
            environment: [
                "SUPRA_BILLING_SOURCE_SHA": sha,
                "SUPRA_BILLING_CHAT_REPOSITORY": "synthetic/drafting-model",
            ],
            temporaryDirectory: root,
            compiledSourceCommitSHA: String(repeating: "a", count: 40)
        ))
    }

    func testScratchPadBillingInvocationRejectsMissingOrMismatchedSignedSourceSHA() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("billing-report.json")
        let requested = String(repeating: "a", count: 40)
        let environment = [
            "SUPRA_BILLING_SOURCE_SHA": requested,
            "SUPRA_BILLING_CHAT_REPOSITORY": "synthetic/drafting-model",
        ]
        let arguments = ["SupraAI", "-scratchPadBillingFidelityOutput", output.path]

        XCTAssertThrowsError(try ScratchPadBillingFidelityInvocation.resolve(
            arguments: arguments,
            environment: environment,
            temporaryDirectory: root,
            compiledSourceCommitSHA: nil
        ))
        XCTAssertThrowsError(try ScratchPadBillingFidelityInvocation.resolve(
            arguments: arguments,
            environment: environment,
            temporaryDirectory: root,
            compiledSourceCommitSHA: String(repeating: "b", count: 40)
        )) { error in
            XCTAssertEqual(
                error as? ScratchPadBillingFidelityInvocationError,
                .sourceCommitMismatch(
                    requested: requested,
                    compiled: String(repeating: "b", count: 40)
                )
            )
        }
    }

    func testScratchPadBillingInvocationCannotOverwriteOutputCreatedAfterResolution() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("billing-report.json")
        let invocation = try ScratchPadBillingFidelityInvocation.resolve(
            arguments: ["SupraAI", "-scratchPadBillingFidelityOutput", output.path],
            environment: [
                "SUPRA_BILLING_SOURCE_SHA": String(repeating: "a", count: 40),
                "SUPRA_BILLING_CHAT_REPOSITORY": "synthetic/drafting-model",
            ],
            temporaryDirectory: root,
            compiledSourceCommitSHA: String(repeating: "a", count: 40)
        )
        let existing = Data("existing".utf8)
        try existing.write(to: output)

        XCTAssertThrowsError(try invocation.writeReport(Data("replacement".utf8)))
        XCTAssertEqual(try Data(contentsOf: output), existing)
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
        corruptWeightsSize: Bool = false,
        hiddenSize: Int? = nil
    ) throws {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = Data(
            (hiddenSize.map { #"{"model_type":"synthetic","hidden_size":\#($0)}"# }
                ?? #"{"model_type": "synthetic"}"#).utf8
        )
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

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
