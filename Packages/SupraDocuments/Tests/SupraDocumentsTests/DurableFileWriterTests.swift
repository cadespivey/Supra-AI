import Darwin
import Foundation
@testable import SupraDocuments
import XCTest

final class DurableFileWriterTests: XCTestCase {
    func testACRFILE001FaultsPreserveExistingDestinationAndRemoveTemporaryFiles() throws {
        for stage in DurableFileWriter.FaultStage.allCases {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("output.txt")
            try Data("old-canary".utf8).write(to: destination)
            let writer = DurableFileWriter { observed in
                if observed == stage { throw InjectedFailure(stage: stage) }
            }

            XCTAssertThrowsError(
                try writer.write(Data("new-value".utf8), to: destination) { temporary in
                    XCTAssertEqual(try Data(contentsOf: temporary), Data("new-value".utf8))
                },
                "Expected injected failure at \(stage)"
            )
            XCTAssertEqual(try Data(contentsOf: destination), Data("old-canary".utf8))
            XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
        }
    }

    func testACRFILE002WriterFailureLeavesNewDestinationAbsentAndCleansPartialFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("new.txt")
        let writer = DurableFileWriter()

        XCTAssertThrowsError(
            try writer.write(to: destination, writer: { sink in
                try sink.write(Data("partial-private-data".utf8))
                throw InjectedFailure(stage: .duringWrite)
            }, validator: { _ in })
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
    }

    func testACRFILE003ValidatorFailurePreservesExistingBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("validated.txt")
        try Data("known-good".utf8).write(to: destination)

        XCTAssertThrowsError(
            try DurableFileWriter().write(Data("malformed".utf8), to: destination) { _ in
                throw InjectedFailure(stage: .beforeValidation)
            }
        )

        XCTAssertEqual(try Data(contentsOf: destination), Data("known-good".utf8))
        XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
    }

    func testACRFILE004SuccessfulReplacementIsCompleteValidatedAndSameDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("complete.txt")
        try Data("old".utf8).write(to: destination)
        var validatedURL: URL?

        try DurableFileWriter().write(Data("complete-new-value".utf8), to: destination) { temporary in
            validatedURL = temporary
            XCTAssertEqual(temporary.deletingLastPathComponent(), destination.deletingLastPathComponent())
            XCTAssertEqual(try String(contentsOf: temporary, encoding: .utf8), "complete-new-value")
        }

        XCTAssertNotEqual(validatedURL, destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "complete-new-value")
        XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
    }

    func testACRFILE005CancellationUsesFailureGuarantees() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("cancelled.txt")
        try Data("old-canary".utf8).write(to: destination)
        let writer = DurableFileWriter { stage in
            if stage == .beforeInstall { throw CancellationError() }
        }

        XCTAssertThrowsError(
            try writer.write(Data("new".utf8), to: destination, validator: { _ in })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("old-canary".utf8))
        XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
    }

    // Expected RED: DurableFileWriter has no create-only install API, so callers can
    // accidentally replace an earlier export that has the same display filename.
    func testACRFILE006CreateOnlyWriteNeverReplacesExistingDestination() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("motion.docx")
        let canary = Data("first-motion-canary".utf8)
        try canary.write(to: destination)

        XCTAssertThrowsError(
            try DurableFileWriter().writeNew(
                Data("second-motion".utf8),
                to: destination,
                validator: { _ in }
            )
        ) { error in
            XCTAssertEqual(error as? DurableFileWriter.WriterError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), canary)
        XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
    }

    // Expected RED: the replacement rename permits both concurrent writers to report
    // success; create-only installation must choose exactly one winner atomically.
    func testACRFILE007ConcurrentCreateOnlyWritesHaveOneWinner() async throws {
        enum Outcome: Sendable, Equatable {
            case installed(String)
            case destinationExists
            case unexpected(String)
        }

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("raced-motion.docx")
        let writer = DurableFileWriter()
        let payloads = ["motion-alpha", "motion-beta"]

        let outcomes = await withTaskGroup(of: Outcome.self, returning: [Outcome].self) { group in
            for payload in payloads {
                group.addTask {
                    do {
                        try writer.writeNew(
                            Data(payload.utf8),
                            to: destination,
                            validator: { _ in }
                        )
                        return .installed(payload)
                    } catch DurableFileWriter.WriterError.destinationExists {
                        return .destinationExists
                    } catch {
                        return .unexpected(String(describing: error))
                    }
                }
            }
            var values: [Outcome] = []
            for await outcome in group { values.append(outcome) }
            return values
        }

        let winners = outcomes.compactMap { outcome -> String? in
            if case let .installed(payload) = outcome { return payload }
            return nil
        }
        XCTAssertEqual(winners.count, 1, "Expected one atomic create winner, got \(outcomes)")
        XCTAssertEqual(outcomes.filter { $0 == .destinationExists }.count, 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), winners.first)
        XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
    }

    // Expected RED: a successful rename does not make the destination directory
    // entry durable until the parent directory is synchronized.
    func testACRFILE008ReplacementSynchronizesParentAfterInstallAndPropagatesFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("replacement.txt")
        let replacement = Data("durable-replacement".utf8)
        try Data("old-canary".utf8).write(to: destination)

        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { observedParent in
                guard observedParent == directory.standardizedFileURL else {
                    throw InjectedDirectorySyncFailure.unexpectedParent(observedParent)
                }
                guard try Data(contentsOf: destination) == replacement else {
                    throw InjectedDirectorySyncFailure.destinationNotInstalled
                }
                throw InjectedDirectorySyncFailure.injected
            }
        )

        XCTAssertThrowsError(
            try writer.write(replacement, to: destination, validator: { _ in })
        ) { error in
            XCTAssertEqual(error as? InjectedDirectorySyncFailure, .injected)
        }
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
    }

    // Expected RED: create-only installation needs the same parent-directory
    // durability boundary as replacement installation.
    func testACRFILE009CreateOnlySynchronizesParentAfterInstallAndPropagatesFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("new-motion.docx")
        let payload = Data("durable-new-motion".utf8)
        let synchronizer = FailFirstDirectorySynchronizer { observedParent in
            guard observedParent == directory.standardizedFileURL else {
                throw InjectedDirectorySyncFailure.unexpectedParent(observedParent)
            }
            guard try Data(contentsOf: destination) == payload else {
                throw InjectedDirectorySyncFailure.destinationNotInstalled
            }
            throw InjectedDirectorySyncFailure.injected
        }

        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { observedParent in
                try synchronizer.synchronize(observedParent)
            }
        )

        XCTAssertThrowsError(
            try writer.writeNew(payload, to: destination, validator: { _ in })
        ) { error in
            XCTAssertEqual(error as? InjectedDirectorySyncFailure, .injected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(synchronizer.callCount, 2, "Rollback deletion must also be synchronized")
        XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
    }

    // Expected RED: rollback must not remove a different file that replaced the
    // installed create-only destination before synchronization reported failure.
    func testACRFILE010CreateOnlySyncRollbackPreservesConcurrentReplacement() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("new-motion.docx")
        let payload = Data("motion-created-by-writer".utf8)
        let concurrentPayload = Data("concurrent-owner-data".utf8)
        let synchronizer = FailFirstDirectorySynchronizer { _ in
            try concurrentPayload.write(to: destination, options: .atomic)
            throw InjectedDirectorySyncFailure.injected
        }
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { try synchronizer.synchronize($0) }
        )

        XCTAssertThrowsError(
            try writer.writeNew(payload, to: destination, validator: { _ in })
        ) { error in
            XCTAssertEqual(error as? InjectedDirectorySyncFailure, .injected)
        }
        XCTAssertEqual(try Data(contentsOf: destination), concurrentPayload)
        XCTAssertEqual(synchronizer.callCount, 1, "A foreign destination needs no writer rollback")
        XCTAssertTrue(try temporaryArtifacts(in: directory).isEmpty)
    }

    // Expected RED: replacement after the helper's identity check must never be
    // unlinked merely because it occupies the same pathname as the owned file.
    func testACRFILE011FinalUnlinkWindowPreservesRegularFileReplacement() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidate = directory.appendingPathComponent("owned.docx")
        let preservedOwned = directory.appendingPathComponent("preserved-owned.docx")
        let ownedBytes = Data("writer-owned".utf8)
        let foreignBytes = Data("foreign-regular-canary".utf8)
        try ownedBytes.write(to: candidate)

        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { _ in },
            fileUnlinkCheckpoint: { observedCandidate in
                try FileManager.default.moveItem(at: observedCandidate, to: preservedOwned)
                try foreignBytes.write(to: observedCandidate)
            }
        )
        let identity = try XCTUnwrap(writer.installedFileIdentity(at: candidate))

        XCTAssertFalse(try writer.unlinkFile(matching: identity, at: candidate))
        XCTAssertEqual(try Data(contentsOf: preservedOwned), ownedBytes)
        XCTAssertEqual(try Data(contentsOf: candidate), foreignBytes)
    }

    // Expected RED: a symlink substituted in the final check/unlink window is
    // foreign namespace state and must remain present without being followed.
    func testACRFILE012FinalUnlinkWindowPreservesSymlinkReplacement() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidate = directory.appendingPathComponent("owned.docx")
        let preservedOwned = directory.appendingPathComponent("preserved-owned.docx")
        let symlinkTarget = directory.appendingPathComponent("foreign-target.docx")
        let ownedBytes = Data("writer-owned".utf8)
        let foreignBytes = Data("foreign-symlink-target-canary".utf8)
        try ownedBytes.write(to: candidate)
        try foreignBytes.write(to: symlinkTarget)

        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { _ in },
            fileUnlinkCheckpoint: { observedCandidate in
                try FileManager.default.moveItem(at: observedCandidate, to: preservedOwned)
                try FileManager.default.createSymbolicLink(
                    at: observedCandidate,
                    withDestinationURL: symlinkTarget
                )
            }
        )
        let identity = try XCTUnwrap(writer.installedFileIdentity(at: candidate))

        XCTAssertFalse(try writer.unlinkFile(matching: identity, at: candidate))
        XCTAssertEqual(try Data(contentsOf: preservedOwned), ownedBytes)
        XCTAssertEqual(try Data(contentsOf: symlinkTarget), foreignBytes)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: candidate.path),
            symlinkTarget.path
        )
    }

    // Expected RED: unwind cleanup owns the temporary inode it created, not a
    // reusable UUID pathname. A replacement at that name must remain untouched.
    func testACRFILE013ContainedWriteUnwindPreservesTemporaryNameReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
        let destination = parent.appendingPathComponent("motion.docx")
        let preservedOwned = root.appendingPathComponent("preserved-owned-temp.docx")
        let ownedBytes = Data("writer-owned-temp".utf8)
        let foreignBytes = Data("foreign-temp-name-canary".utf8)
        let writer = DurableFileWriter { stage in
            guard stage == .beforeValidation else { return }
            let artifacts = try FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.contains(".supra-tmp-") }
            guard let temporary = artifacts.first else {
                throw InjectedTemporaryMutationFailure.missingTemporary
            }
            try FileManager.default.moveItem(at: temporary, to: preservedOwned)
            try foreignBytes.write(to: temporary)
            throw InjectedFailure(stage: stage)
        }

        XCTAssertThrowsError(
            try writer.writeNewOwned(
                ownedBytes,
                to: destination,
                containedIn: root,
                validator: { _ in }
            )
        ) { error in
            guard case .managedTemporaryCleanupUncertain = error as? DurableFileWriter.WriterError else {
                return XCTFail("Expected managed temporary cleanup uncertainty, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: preservedOwned), ownedBytes)
        let replacements = try temporaryArtifacts(in: parent)
        XCTAssertEqual(replacements.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(replacements.first)), foreignBytes)
    }

    // A throwing compensation checkpoint may also replace the quarantine it was
    // handed. Catch-path restore must authenticate the descriptor-relative entry
    // before restoring anything to the public destination.
    func testACRFILE014ThrowingCheckpointNeverRestoresForeignQuarantine() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
            .appendingPathComponent("owned.txt")
        let ownedBytes = Data("writer-owned-publication".utf8)
        let foreignBytes = Data("foreign-quarantine-canary".utf8)
        let writer = DurableFileWriter()
        let identity = try writer.writeNewOwned(
            ownedBytes,
            to: destination,
            containedIn: root,
            validator: { _ in }
        )
        var observedQuarantine: URL?
        let preservedOwned = root.appendingPathComponent("preserved-owned-publication.txt")

        XCTAssertThrowsError(
            try writer.removeInstalledFile(
                matching: identity,
                at: destination,
                containedIn: root,
                quarantineCheckpoint: { _, quarantine in
                    observedQuarantine = quarantine
                    try FileManager.default.moveItem(at: quarantine, to: preservedOwned)
                    try foreignBytes.write(to: quarantine)
                    throw InjectedFailure(stage: .beforeInstall)
                },
                contentValidator: { _ in }
            )
        )

        let quarantine = try XCTUnwrap(observedQuarantine)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: preservedOwned), ownedBytes)
        XCTAssertEqual(try Data(contentsOf: quarantine), foreignBytes)
    }

    // The descriptor-origin inode, not a replacement first observed after the
    // validation checkpoint, is the only entry this write may install.
    func testACRFILE015BeforeValidationReplacementIsNeverAcceptedForInstall() throws {
        try assertContainedWriteRejectsTemporaryReplacement(at: .beforeValidation)
    }

    // The final install checkpoint is also an untrusted namespace window. The
    // writer must bind the source again immediately before the atomic rename.
    func testACRFILE016BeforeInstallReplacementIsNeverAcceptedForInstall() throws {
        try assertContainedWriteRejectsTemporaryReplacement(at: .beforeInstall)
    }

    // The validator result must be bound to the writer-created bytes. The
    // managed writer supplies an immutable Data value rather than a pathname
    // that can be swapped only for validation.
    func testACRFILE017ValidatorSwapAndRestoreCannotAuthorizeOriginBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
            .appendingPathComponent("motion.docx")
        let invalidOrigin = Data("not-an-office-archive".utf8)
        let writer = DurableFileWriter()

        XCTAssertThrowsError(
            try writer.writeNewOwned(
                invalidOrigin,
                to: destination,
                containedIn: root,
                validator: { temporaryData in
                    XCTAssertEqual(temporaryData, invalidOrigin)
                    try DocumentExportValidator.validate(temporaryData, as: .docx)
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? DocumentExportValidator.ValidationError,
                .unreadableOfficeArchive
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // ACR-FILE-018. Each newly published directory entry is part of the same
    // durability boundary as the final file. Creating the managed root,
    // `exports`, and the matter directory must synchronize each containing
    // parent before the installed artifact can be reported durable.
    func testACRFILE018ContainedWriteSynchronizesEveryCreatedDirectoryComponent() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("managed-root", isDirectory: true)
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        let matter = exports.appendingPathComponent("matter-123", isDirectory: true)
        let destination = matter.appendingPathComponent("motion.md")
        let payload = Data("# Durable directory chain\n".utf8)
        let synchronizer = DirectorySynchronizationRecorder()
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            anchoredParentDirectorySynchronizer: {
                try synchronizer.synchronize($0, descriptor: $1)
            }
        )

        _ = try writer.writeNewOwned(
            payload,
            to: destination,
            containedIn: root,
            validator: { _ in }
        )

        XCTAssertEqual(
            synchronizer.directories,
            [container, root, exports, matter].map(\.standardizedFileURL)
        )
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    // ACR-FILE-019. A mkdir that survived a failed parent fsync can appear on a
    // retry without being durable. Authenticate and synchronize every existing
    // managed directory edge on every contained publication, not only the call
    // that happened to create it.
    func testACRFILE019ContainedWriteSynchronizesEveryExistingDirectoryComponent() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("managed-root", isDirectory: true)
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        let matter = exports.appendingPathComponent("matter-123", isDirectory: true)
        try FileManager.default.createDirectory(at: matter, withIntermediateDirectories: true)
        let destination = matter.appendingPathComponent("motion.md")
        let payload = Data("# Durable existing directory chain\n".utf8)
        let synchronizer = DirectorySynchronizationRecorder()
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            anchoredParentDirectorySynchronizer: {
                try synchronizer.synchronize($0, descriptor: $1)
            }
        )

        _ = try writer.writeNewOwned(
            payload,
            to: destination,
            containedIn: root,
            validator: { _ in }
        )

        XCTAssertEqual(
            synchronizer.directories,
            [container, root, exports, matter].map(\.standardizedFileURL)
        )
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    // ACR-FILE-022. Authentication of each managed-directory edge is a
    // durability boundary, not an advisory observation. A failed sync of the
    // container, root, or exports edge must stop publication before any final
    // artifact or writer temporary can remain visible.
    func testACRFILE022ContainedWritePropagatesEveryManagedEdgeSyncFailure() throws {
        for failingEdge in 0..<3 {
            let container = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: container) }
            let root = container.appendingPathComponent("managed-root", isDirectory: true)
            let exports = root.appendingPathComponent("exports", isDirectory: true)
            let matter = exports.appendingPathComponent("matter-123", isDirectory: true)
            let destination = matter.appendingPathComponent("motion.md")
            let edges = [container, root, exports].map(\.standardizedFileURL)
            let failingURL = edges[failingEdge]
            let writer = DurableFileWriter(
                faultInjector: { _ in },
                parentDirectorySynchronizer: { observedURL in
                    if observedURL.standardizedFileURL == failingURL {
                        throw InjectedDirectorySyncFailure.injected
                    }
                }
            )

            XCTAssertThrowsError(
                try writer.writeNewOwned(
                    Data("# Must not publish\n".utf8),
                    to: destination,
                    containedIn: root,
                    validator: { _ in }
                ),
                "edge \(failingEdge) unexpectedly ignored its sync failure"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            let residues = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.lastPathComponent.contains(".supra-tmp-") } ?? []
            XCTAssertTrue(residues.isEmpty, "edge \(failingEdge) left \(residues)")
        }
    }

    private func assertContainedWriteRejectsTemporaryReplacement(
        at replacementStage: DurableFileWriter.FaultStage
    ) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
        let destination = parent.appendingPathComponent("motion.docx")
        let preservedOwned = root.appendingPathComponent(
            "preserved-owned-\(replacementStage.rawValue).docx"
        )
        let ownedBytes = Data("writer-owned-origin-\(replacementStage.rawValue)".utf8)
        let foreignBytes = Data("foreign-replacement-\(replacementStage.rawValue)".utf8)
        let writer = DurableFileWriter { observedStage in
            guard observedStage == replacementStage else { return }
            let artifacts = try FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.contains(".supra-tmp-") }
            guard let temporary = artifacts.first else {
                throw InjectedTemporaryMutationFailure.missingTemporary
            }
            try FileManager.default.moveItem(at: temporary, to: preservedOwned)
            try foreignBytes.write(to: temporary)
        }

        XCTAssertThrowsError(
            try writer.writeNewOwned(
                ownedBytes,
                to: destination,
                containedIn: root,
                validator: { _ in }
            )
        ) { error in
            guard case .managedTemporaryCleanupUncertain = error as? DurableFileWriter.WriterError else {
                return XCTFail("Expected managed temporary cleanup uncertainty, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: preservedOwned), ownedBytes)
        let replacements = try temporaryArtifacts(in: parent)
        XCTAssertEqual(replacements.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(replacements.first)), foreignBytes)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Supra-DurableFileWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func temporaryArtifacts(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".supra-tmp-") }
    }
}

private struct InjectedFailure: Error {
    let stage: DurableFileWriter.FaultStage
}

private enum InjectedTemporaryMutationFailure: Error {
    case missingTemporary
}

private enum InjectedDirectorySyncFailure: Error, Equatable {
    case injected
    case unexpectedParent(URL)
    case destinationNotInstalled
}

private final class FailFirstDirectorySynchronizer: @unchecked Sendable {
    private let lock = NSLock()
    private let firstCall: @Sendable (URL) throws -> Void
    private var calls = 0

    init(firstCall: @escaping @Sendable (URL) throws -> Void) {
        self.firstCall = firstCall
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func synchronize(_ directory: URL) throws {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call == 1 { try firstCall(directory) }
    }
}

private final class DirectorySynchronizationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDirectories: [URL] = []

    var directories: [URL] {
        lock.withLock { recordedDirectories }
    }

    func synchronize(_ directory: URL, descriptor: Int32) throws {
        var descriptorStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
            throw DirectorySynchronizationRecorderError.descriptorInspectionFailed(errno)
        }
        var pathStatus = stat()
        let pathResult = directory.path.withCString { Darwin.lstat($0, &pathStatus) }
        guard pathResult == 0 else {
            throw DirectorySynchronizationRecorderError.pathInspectionFailed(errno)
        }
        guard descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino,
              descriptorStatus.st_gen == pathStatus.st_gen else {
            throw DirectorySynchronizationRecorderError.descriptorPathMismatch
        }
        lock.withLock {
            recordedDirectories.append(directory.standardizedFileURL)
        }
    }
}

private enum DirectorySynchronizationRecorderError: Error {
    case descriptorInspectionFailed(Int32)
    case pathInspectionFailed(Int32)
    case descriptorPathMismatch
}
