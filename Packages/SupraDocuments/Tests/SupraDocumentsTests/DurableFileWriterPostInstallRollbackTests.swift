import Foundation
@testable import SupraDocuments
import XCTest

final class DurableFileWriterPostInstallRollbackTests: XCTestCase {
    // ACR-FILE-029. Expected RED: a throwing final parent synchronizer can
    // mutate the just-installed inode in place. Identity-only rollback then
    // deletes bytes that no longer match the validated publication. The writer
    // must instead preserve those changed bytes at the public name or an exact
    // same-directory recovery residue and report publication uncertainty.
    func testACRFILE029ThrowingFinalSyncMutationPreservesChangedInstalledBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Supra-Throwing-Final-Sync-Mutation-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
        let destination = parent.appendingPathComponent("motion.md")
        let validated = Data("# Validated publication\n".utf8)
        let changed = Data("# Changed by the throwing final synchronizer\n".utf8)
        let injector = ThrowingFinalSyncMutationInjector(
            destination: destination,
            changed: changed
        )
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            parentDirectorySynchronizer: { try injector.synchronize($0) }
        )

        XCTAssertThrowsError(
            try writer.writeNewOwned(
                validated,
                to: destination,
                containedIn: root,
                validator: { XCTAssertEqual($0, validated) }
            )
        ) { error in
            guard case .postInstallStateUncertain = error as? DurableFileWriter.WriterError else {
                return XCTFail("expected post-install uncertainty, got \(error)")
            }
        }

        XCTAssertTrue(injector.didMutate)
        let survivors = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).filter { candidate in
            (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && (try? Data(contentsOf: candidate)) == changed
        }
        XCTAssertEqual(
            survivors.count,
            1,
            "changed installed bytes must remain recoverable under one exact same-directory name"
        )
    }
}

private final class ThrowingFinalSyncMutationInjector: @unchecked Sendable {
    private enum InjectedFailure: Error {
        case finalSynchronization
    }

    private let lock = NSLock()
    private let destination: URL
    private let changed: Data
    private var mutated = false

    init(destination: URL, changed: Data) {
        self.destination = destination
        self.changed = changed
    }

    var didMutate: Bool { lock.withLock { mutated } }

    func synchronize(_ directory: URL) throws {
        let shouldMutate = lock.withLock { () -> Bool in
            guard !mutated,
                  FileManager.default.fileExists(atPath: destination.path) else {
                return false
            }
            mutated = true
            return true
        }
        guard shouldMutate else { return }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: changed)
        try handle.synchronize()
        throw InjectedFailure.finalSynchronization
    }
}
