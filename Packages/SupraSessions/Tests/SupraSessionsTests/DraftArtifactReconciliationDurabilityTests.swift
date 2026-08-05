import Darwin
import Foundation
@testable import SupraDocuments
import SupraStore
@testable import SupraSessions
import XCTest

final class DraftArtifactReconciliationDurabilityTests: XCTestCase {
    // T-DAR-DUR-01. Expected RED at 5c4a3a17: relaunch reconciliation never
    // enters the writer's exact-file synchronization boundary, so the injected
    // failure is skipped and Store finalization emits an audit event.
    func testTDARDUR01RelaunchFileSynchronizationFailureRequiresRecoveryWithoutAudit() throws {
        let fixture = try makeFixture()
        let output = Data("# Relaunch file synchronization failure\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Relaunch-file-sync-failure.md",
            output: output,
            id: "relaunch-file-sync-failure"
        )
        let publicURL = try install(output, intent: intent, storage: fixture.storage)
        let probe = RelaunchSynchronizationProbe()
        let store = fixture.store
        let matterID = fixture.matter.id
        let intentID = intent.id
        let writer = DurableFileWriter(
            faultInjector: { stage in
                if stage == .beforeSynchronize {
                    try probe.record(
                        phase: .exactFile,
                        store: store,
                        matterID: matterID,
                        intentID: intentID,
                        artifactURL: publicURL
                    )
                    throw ReconciliationDurabilityInjectedFailure.exactFileSynchronization
                }
            },
            anchoredParentDirectorySynchronizer: { parentURL, parentDescriptor in
                try probe.record(
                    phase: .anchoredParent,
                    store: store,
                    matterID: matterID,
                    intentID: intentID,
                    artifactURL: publicURL,
                    parentURL: parentURL,
                    parentDescriptor: parentDescriptor
                )
                throw ReconciliationDurabilityInjectedFailure.unexpectedParentSynchronization
            }
        )

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage,
            fileWriter: writer
        ).reconcilePendingIntents()

        XCTAssertEqual(
            summary,
            DraftArtifactReconciliationSummary(recoveryRequiredCount: 1)
        )
        XCTAssertEqual(probe.observations.map(\.phase), [.exactFile])
        XCTAssertEqual(
            probe.observations.map(\.intentStatus),
            [DraftArtifactIntentStatus.prepared.rawValue]
        )
        XCTAssertEqual(probe.observations.map(\.auditEventCount), [0])
        XCTAssertEqual(probe.observations.map(\.artifactSHA256), [intent.outputSHA256])
        let preserved = try Data(contentsOf: publicURL)
        XCTAssertEqual(preserved, output)
        XCTAssertEqual(preserved.count, intent.outputByteSize)
        XCTAssertEqual(DocumentStorage.sha256Hex(of: preserved), intent.outputSHA256)
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
        XCTAssertTrue(try fixture.store.auditEvents.fetchEvents(matterID: matterID).isEmpty)
        XCTAssertNotNil(
            try fixture.store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )
    }

    // T-DAR-DUR-02. Expected RED at 5c4a3a17: Store finalization succeeds with
    // an empty synchronization sequence. The exact file and descriptor-anchored
    // parent must both synchronize, in that order, while the row is still
    // prepared and before its exact-once audit exists.
    func testTDARDUR02RelaunchSynchronizesExactFileThenAnchoredParentBeforeStoreFinalize() throws {
        let fixture = try makeFixture()
        let output = Data("# Relaunch synchronization ordering\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Relaunch-sync-order.md",
            output: output,
            id: "relaunch-sync-order"
        )
        let publicURL = try install(output, intent: intent, storage: fixture.storage)
        let expectedParent = publicURL.deletingLastPathComponent().standardizedFileURL
        let probe = RelaunchSynchronizationProbe()
        let store = fixture.store
        let matterID = fixture.matter.id
        let intentID = intent.id
        let writer = DurableFileWriter(
            faultInjector: { stage in
                if stage == .beforeSynchronize {
                    try probe.record(
                        phase: .exactFile,
                        store: store,
                        matterID: matterID,
                        intentID: intentID,
                        artifactURL: publicURL
                    )
                }
            },
            anchoredParentDirectorySynchronizer: { parentURL, parentDescriptor in
                try probe.record(
                    phase: .anchoredParent,
                    store: store,
                    matterID: matterID,
                    intentID: intentID,
                    artifactURL: publicURL,
                    parentURL: parentURL,
                    parentDescriptor: parentDescriptor
                )
                guard Darwin.fsync(parentDescriptor) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        )

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage,
            fileWriter: writer
        ).reconcilePendingIntents()

        XCTAssertEqual(summary, DraftArtifactReconciliationSummary(finalizedCount: 1))
        XCTAssertEqual(probe.observations.map(\.phase), [.exactFile, .anchoredParent])
        XCTAssertEqual(
            probe.observations.map(\.intentStatus),
            [
                DraftArtifactIntentStatus.prepared.rawValue,
                DraftArtifactIntentStatus.prepared.rawValue,
            ]
        )
        XCTAssertEqual(probe.observations.map(\.auditEventCount), [0, 0])
        XCTAssertEqual(
            probe.observations.map(\.artifactSHA256),
            [intent.outputSHA256, intent.outputSHA256]
        )
        let parentObservation = try XCTUnwrap(probe.observations.last)
        XCTAssertEqual(parentObservation.parentURL, expectedParent)
        XCTAssertEqual(
            parentObservation.parentDescriptorIdentity,
            try reconciliationIdentity(at: expectedParent)
        )
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.completed.rawValue
        )
        let installed = try Data(contentsOf: publicURL)
        XCTAssertEqual(installed, output)
        XCTAssertEqual(installed.count, intent.outputByteSize)
        XCTAssertEqual(DocumentStorage.sha256Hex(of: installed), intent.outputSHA256)
        XCTAssertEqual(
            try fixture.store.auditEvents.fetchEvents(matterID: matterID).map(\.eventType),
            ["draft_generated"]
        )
        XCTAssertNil(
            try fixture.store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )
    }

    // T-DAR-DUR-03. Expected RED at 5c4a3a17: an in-place mutation at the
    // writer's final fileUnlinkCheckpoint keeps the quarantine inode but changes
    // its bytes; cleanup currently deletes those changed bytes and aborts the
    // intent instead of preserving the artifact for explicit recovery.
    func testTDARDUR03FinalUnlinkCheckpointMutationPreservesQuarantineForRecovery() throws {
        let fixture = try makeFixture()
        let output = Data("# Original rollback quarantine bytes\n".utf8)
        let changed = Data("# Changed at final unlink checkpoint\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Rollback-final-unlink-mutation.md",
            output: output,
            id: "rollback-final-unlink-mutation"
        )
        let quarantine = try installRollbackQuarantine(
            output,
            intent: intent,
            storage: fixture.storage
        )
        let originalIdentity = try reconciliationIdentity(at: quarantine)
        let mutationProbe = FinalUnlinkMutationProbe(
            expectedURL: quarantine,
            replacement: changed
        )
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            anchoredParentDirectorySynchronizer: { _, descriptor in
                guard Darwin.fsync(descriptor) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            },
            fileUnlinkCheckpoint: { try mutationProbe.mutate($0) }
        )

        let summary = try DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage,
            fileWriter: writer
        ).reconcilePendingIntents()

        XCTAssertEqual(
            summary,
            DraftArtifactReconciliationSummary(recoveryRequiredCount: 1)
        )
        XCTAssertEqual(mutationProbe.observedURLs, [quarantine.standardizedFileURL])
        XCTAssertEqual(mutationProbe.identitiesBeforeMutation, [originalIdentity])
        XCTAssertEqual(mutationProbe.identitiesAfterMutation, [originalIdentity])
        XCTAssertEqual(
            mutationProbe.replacementHashes,
            [DocumentStorage.sha256Hex(of: changed)]
        )
        XCTAssertEqual(try? Data(contentsOf: quarantine), changed)
        XCTAssertEqual(
            (try? Data(contentsOf: quarantine)).map(DocumentStorage.sha256Hex(of:)),
            DocumentStorage.sha256Hex(of: changed)
        )
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).isEmpty
        )
        XCTAssertNotNil(
            try fixture.store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )
    }

    // T-DAR-DUR-04. Standing guard (expected GREEN at 5c4a3a17): after the
    // format validator validates the supplied Data, mutates the same public
    // inode, and returns normally, the writer's stable reread must fail closed
    // before Store finalization. This pins an already-correct race boundary.
    func testTDARDUR04StandingGuardPublicValidatorMutationFailsClosed() throws {
        let fixture = try makeFixture()
        let output = Data("# Public bytes validated before mutation\n".utf8)
        let changed = Data("# Public bytes changed by returning validator\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Public-returning-validator-mutation.md",
            output: output,
            id: "public-returning-validator-mutation"
        )
        let publicURL = try install(output, intent: intent, storage: fixture.storage)
        let originalIdentity = try reconciliationIdentity(at: publicURL)
        let mutationProbe = ReturningValidatorMutationProbe(
            expectedURL: publicURL,
            expectedData: output,
            replacement: changed
        )
        let service = DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        )
        service.artifactFormatValidator = {
            try mutationProbe.validateThenMutate($0, format: $1)
        }

        let summary = try service.reconcilePendingIntents()

        XCTAssertEqual(
            summary,
            DraftArtifactReconciliationSummary(recoveryRequiredCount: 1)
        )
        XCTAssertEqual(mutationProbe.invocationCount, 1)
        XCTAssertEqual(mutationProbe.validatedFormats, [DocumentExportFormat.markdown.rawValue])
        XCTAssertEqual(mutationProbe.validatedHashes, [intent.outputSHA256])
        XCTAssertEqual(mutationProbe.identitiesBeforeMutation, [originalIdentity])
        XCTAssertEqual(mutationProbe.identitiesAfterMutation, [originalIdentity])
        let preserved = try Data(contentsOf: publicURL)
        XCTAssertEqual(preserved, changed)
        XCTAssertEqual(
            DocumentStorage.sha256Hex(of: preserved),
            DocumentStorage.sha256Hex(of: changed)
        )
        XCTAssertNotEqual(DocumentStorage.sha256Hex(of: preserved), intent.outputSHA256)
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).isEmpty
        )
        XCTAssertNotNil(
            try fixture.store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )
    }

    // T-DAR-DUR-05. Standing guard (expected GREEN at 5c4a3a17): rollback
    // cleanup has the same stable-reread obligation. A returning validator's
    // same-inode mutation must leave the exact changed quarantine in place and
    // require recovery without unlinking or aborting the prepared intent.
    func testTDARDUR05StandingGuardQuarantineValidatorMutationFailsClosed() throws {
        let fixture = try makeFixture()
        let output = Data("# Quarantine bytes validated before mutation\n".utf8)
        let changed = Data("# Quarantine changed by returning validator\n".utf8)
        let intent = try fixture.store.draftArtifacts.prepareGenericIntent(
            matterID: fixture.matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Quarantine-returning-validator-mutation.md",
            output: output,
            id: "quarantine-returning-validator-mutation"
        )
        let quarantine = try installRollbackQuarantine(
            output,
            intent: intent,
            storage: fixture.storage
        )
        let publicURL = fixture.storage.exportsDirectory(forMatterID: intent.matterID)
            .appendingPathComponent(intent.fileName, isDirectory: false)
        let originalIdentity = try reconciliationIdentity(at: quarantine)
        let mutationProbe = ReturningValidatorMutationProbe(
            expectedURL: quarantine,
            expectedData: output,
            replacement: changed
        )
        let service = DraftArtifactReconciliationService(
            store: fixture.store,
            storage: fixture.storage
        )
        service.artifactFormatValidator = {
            try mutationProbe.validateThenMutate($0, format: $1)
        }

        let summary = try service.reconcilePendingIntents()

        XCTAssertEqual(
            summary,
            DraftArtifactReconciliationSummary(recoveryRequiredCount: 1)
        )
        XCTAssertEqual(mutationProbe.invocationCount, 1)
        XCTAssertEqual(mutationProbe.validatedFormats, [DocumentExportFormat.markdown.rawValue])
        XCTAssertEqual(mutationProbe.validatedHashes, [intent.outputSHA256])
        XCTAssertEqual(mutationProbe.identitiesBeforeMutation, [originalIdentity])
        XCTAssertEqual(mutationProbe.identitiesAfterMutation, [originalIdentity])
        let preserved = try Data(contentsOf: quarantine)
        XCTAssertEqual(preserved, changed)
        XCTAssertEqual(
            DocumentStorage.sha256Hex(of: preserved),
            DocumentStorage.sha256Hex(of: changed)
        )
        XCTAssertNotEqual(DocumentStorage.sha256Hex(of: preserved), intent.outputSHA256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicURL.path))
        XCTAssertEqual(
            try fixture.store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).isEmpty
        )
        XCTAssertNotNil(
            try fixture.store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )
    }

    private struct Fixture {
        let store: SupraStore
        let matter: MatterRecord
        let storage: DocumentStorage
    }

    private func makeFixture() throws -> Fixture {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Reconciliation durability matter")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Supra-Reconciliation-Durability-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(store: store, matter: matter, storage: DocumentStorage(root: root))
    }

    private func install(
        _ data: Data,
        intent: DraftArtifactIntentRecord,
        storage: DocumentStorage
    ) throws -> URL {
        let directory = storage.exportsDirectory(forMatterID: intent.matterID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(intent.fileName, isDirectory: false)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    private func installRollbackQuarantine(
        _ data: Data,
        intent: DraftArtifactIntentRecord,
        storage: DocumentStorage
    ) throws -> URL {
        let directory = storage.exportsDirectory(forMatterID: intent.matterID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(
            ".supra-draft-rollback-bbf231d5-d197-47d5-92ec-78ac7f33e593-\(intent.fileName)",
            isDirectory: false
        )
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}

private enum ReconciliationSynchronizationPhase: String, Equatable, Sendable {
    case exactFile
    case anchoredParent
}

private struct ReconciliationSynchronizationObservation: Equatable, Sendable {
    let phase: ReconciliationSynchronizationPhase
    let intentStatus: String?
    let auditEventCount: Int
    let artifactSHA256: String
    let parentURL: URL?
    let parentDescriptorIdentity: ReconciliationFilesystemIdentity?
}

private final class RelaunchSynchronizationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ReconciliationSynchronizationObservation] = []

    var observations: [ReconciliationSynchronizationObservation] {
        lock.withLock { recorded }
    }

    func record(
        phase: ReconciliationSynchronizationPhase,
        store: SupraStore,
        matterID: String,
        intentID: String,
        artifactURL: URL,
        parentURL: URL? = nil,
        parentDescriptor: Int32? = nil
    ) throws {
        let descriptorIdentity = try parentDescriptor.map(reconciliationIdentity(descriptor:))
        let observation = ReconciliationSynchronizationObservation(
            phase: phase,
            intentStatus: try store.draftArtifacts.intent(id: intentID)?.status,
            auditEventCount: try store.auditEvents.fetchEvents(matterID: matterID).count,
            artifactSHA256: DocumentStorage.sha256Hex(of: try Data(contentsOf: artifactURL)),
            parentURL: parentURL?.standardizedFileURL,
            parentDescriptorIdentity: descriptorIdentity
        )
        lock.withLock { recorded.append(observation) }
    }
}

private final class FinalUnlinkMutationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedURL: URL
    private let replacement: Data
    private var urls: [URL] = []
    private var beforeIdentities: [ReconciliationFilesystemIdentity] = []
    private var afterIdentities: [ReconciliationFilesystemIdentity] = []
    private var hashes: [String] = []

    init(expectedURL: URL, replacement: Data) {
        self.expectedURL = expectedURL.standardizedFileURL
        self.replacement = replacement
    }

    var observedURLs: [URL] { lock.withLock { urls } }
    var identitiesBeforeMutation: [ReconciliationFilesystemIdentity] {
        lock.withLock { beforeIdentities }
    }
    var identitiesAfterMutation: [ReconciliationFilesystemIdentity] {
        lock.withLock { afterIdentities }
    }
    var replacementHashes: [String] { lock.withLock { hashes } }

    func mutate(_ candidate: URL) throws {
        let standardizedCandidate = candidate.standardizedFileURL
        guard standardizedCandidate == expectedURL else {
            throw ReconciliationDurabilityInjectedFailure.unexpectedUnlinkCandidate
        }
        let before = try reconciliationIdentity(at: standardizedCandidate)
        try overwriteSameInode(at: standardizedCandidate, with: replacement)
        let after = try reconciliationIdentity(at: standardizedCandidate)
        let hash = DocumentStorage.sha256Hex(of: try Data(contentsOf: standardizedCandidate))
        lock.withLock {
            urls.append(standardizedCandidate)
            beforeIdentities.append(before)
            afterIdentities.append(after)
            hashes.append(hash)
        }
    }
}

private final class ReturningValidatorMutationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedURL: URL
    private let expectedData: Data
    private let replacement: Data
    private var count = 0
    private var formats: [String] = []
    private var hashes: [String] = []
    private var beforeIdentities: [ReconciliationFilesystemIdentity] = []
    private var afterIdentities: [ReconciliationFilesystemIdentity] = []

    init(expectedURL: URL, expectedData: Data, replacement: Data) {
        self.expectedURL = expectedURL.standardizedFileURL
        self.expectedData = expectedData
        self.replacement = replacement
    }

    var invocationCount: Int { lock.withLock { count } }
    var validatedFormats: [String] { lock.withLock { formats } }
    var validatedHashes: [String] { lock.withLock { hashes } }
    var identitiesBeforeMutation: [ReconciliationFilesystemIdentity] {
        lock.withLock { beforeIdentities }
    }
    var identitiesAfterMutation: [ReconciliationFilesystemIdentity] {
        lock.withLock { afterIdentities }
    }

    func validateThenMutate(_ candidateData: Data, format: DocumentExportFormat) throws {
        guard candidateData == expectedData else {
            throw ReconciliationDurabilityInjectedFailure.unexpectedValidatorData
        }
        try DocumentExportValidator.validate(candidateData, as: format)
        let before = try reconciliationIdentity(at: expectedURL)
        try overwriteSameInode(at: expectedURL, with: replacement)
        let after = try reconciliationIdentity(at: expectedURL)
        lock.withLock {
            count += 1
            formats.append(format.rawValue)
            hashes.append(DocumentStorage.sha256Hex(of: candidateData))
            beforeIdentities.append(before)
            afterIdentities.append(after)
        }
    }
}

private struct ReconciliationFilesystemIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

private func reconciliationIdentity(at url: URL) throws -> ReconciliationFilesystemIdentity {
    var information = stat()
    guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return ReconciliationFilesystemIdentity(
        device: UInt64(information.st_dev),
        inode: UInt64(information.st_ino)
    )
}

private func reconciliationIdentity(descriptor: Int32) throws -> ReconciliationFilesystemIdentity {
    var information = stat()
    guard Darwin.fstat(descriptor, &information) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return ReconciliationFilesystemIdentity(
        device: UInt64(information.st_dev),
        inode: UInt64(information.st_ino)
    )
}

private func overwriteSameInode(at url: URL, with data: Data) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: data)
    try handle.synchronize()
}

private enum ReconciliationDurabilityInjectedFailure: Error {
    case exactFileSynchronization
    case unexpectedParentSynchronization
    case unexpectedUnlinkCandidate
    case unexpectedValidatorData
}
