import Darwin
import Foundation
@testable import SupraDocuments
import XCTest

final class DurableFileWriterTemporaryCleanupContentTests: XCTestCase {
    // ACR-FILE-032. Expected RED: a throwing pre-validation callback can mutate
    // the writer-owned temporary in place. Cleanup currently treats unchanged
    // inode identity as deletion authority and silently removes the callback's
    // changed bytes. It must classify cleanup as uncertain and preserve an
    // authenticated same-directory residue instead.
    func testACRFILE032ThrowingCallbackMutationPreservesChangedTemporary() throws {
        let fixture = makeFixture(label: "throwing-mutation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let changed = Data("changed callback-owned temporary bytes".utf8)
        let injector = ThrowingTemporaryMutationInjector(
            parent: fixture.parent,
            changed: changed
        )
        let writer = DurableFileWriter { try injector.inject($0) }

        XCTAssertThrowsError(
            try writer.writeNewOwned(
                fixture.payload,
                to: fixture.destination,
                containedIn: fixture.root,
                validator: { _ in XCTFail("throwing callback must stop before validation") }
            )
        ) { error in
            guard case let .managedTemporaryCleanupUncertain(name, _) =
                error as? DurableFileWriter.WriterError else {
                return XCTFail("expected managed temporary cleanup uncertainty, got \(error)")
            }
            XCTAssertEqual(name, injector.temporaryName)
        }

        XCTAssertTrue(injector.didMutate)
        XCTAssertEqual(try matchingFiles(in: fixture.parent, data: changed).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    // ACR-FILE-033. Expected RED: a throwing callback can add an unknown exact
    // hard link to the managed temporary. Removing only the known temporary name
    // does not establish cleanup while the retained descriptor has st_nlink > 0.
    func testACRFILE033ThrowingCallbackHardLinkRequiresCleanupUncertainty() throws {
        let fixture = makeFixture(label: "throwing-hard-link")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unknownLink = fixture.parent.appendingPathComponent("unknown-exact-temporary-link")
        let injector = ThrowingTemporaryLinkInjector(
            parent: fixture.parent,
            unknownLink: unknownLink
        )
        let writer = DurableFileWriter { try injector.inject($0) }

        XCTAssertThrowsError(
            try writer.writeNewOwned(
                fixture.payload,
                to: fixture.destination,
                containedIn: fixture.root,
                validator: { _ in XCTFail("throwing callback must stop before validation") }
            )
        ) { error in
            guard case let .managedTemporaryCleanupUncertain(name, _) =
                error as? DurableFileWriter.WriterError else {
                return XCTFail("expected managed temporary cleanup uncertainty, got \(error)")
            }
            XCTAssertEqual(name, injector.temporaryName)
        }

        XCTAssertTrue(injector.didLink)
        XCTAssertEqual(try Data(contentsOf: unknownLink), fixture.payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    // ACR-FILE-034. Expected RED: even a returning validator is an untrusted
    // boundary. It can inspect the immutable Data argument, mutate the known
    // temporary inode in place, and return. Publication must fail at a stable
    // byte rebind, and cleanup must preserve rather than delete the changed bytes.
    func testACRFILE034ReturningValidatorMutationPreservesChangedTemporary() throws {
        let fixture = makeFixture(label: "returning-validator")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let changed = Data("changed by returning validator".utf8)
        let writer = DurableFileWriter()
        var validatorCallCount = 0

        XCTAssertThrowsError(
            try writer.writeNewOwned(
                fixture.payload,
                to: fixture.destination,
                containedIn: fixture.root,
                validator: { candidateData in
                    validatorCallCount += 1
                    XCTAssertEqual(candidateData, fixture.payload)
                    let temporary = try XCTUnwrap(
                        FileManager.default.contentsOfDirectory(
                            at: fixture.parent,
                            includingPropertiesForKeys: nil
                        ).first { $0.lastPathComponent.contains(".supra-tmp-") }
                    )
                    let handle = try FileHandle(forWritingTo: temporary)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: changed)
                    try handle.synchronize()
                }
            )
        ) { error in
            guard case let .managedTemporaryCleanupUncertain(name, _) =
                error as? DurableFileWriter.WriterError else {
                return XCTFail("expected managed temporary cleanup uncertainty, got \(error)")
            }
            XCTAssertTrue(name.hasPrefix(".\(fixture.destination.lastPathComponent).supra-tmp-"))
        }

        XCTAssertEqual(validatorCallCount, 1)
        XCTAssertEqual(try matchingFiles(in: fixture.parent, data: changed).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    private func makeFixture(
        label: String
    ) -> (root: URL, parent: URL, destination: URL, payload: Data) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Supra-Temporary-Cleanup-Content-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        let parent = root
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("matter-123", isDirectory: true)
        return (
            root,
            parent,
            parent.appendingPathComponent("motion.md"),
            Data("# Validated managed temporary\n".utf8)
        )
    }

    private func matchingFiles(in directory: URL, data: Data) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).filter { candidate in
            (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && (try? Data(contentsOf: candidate)) == data
        }
    }
}

private final class ThrowingTemporaryMutationInjector: @unchecked Sendable {
    private enum InjectedFailure: Error { case afterMutation }

    private let lock = NSLock()
    private let parent: URL
    private let changed: Data
    private var mutated = false
    private var capturedTemporaryName: String?

    init(parent: URL, changed: Data) {
        self.parent = parent
        self.changed = changed
    }

    var didMutate: Bool { lock.withLock { mutated } }
    var temporaryName: String? { lock.withLock { capturedTemporaryName } }

    func inject(_ stage: DurableFileWriter.FaultStage) throws {
        guard stage == .beforeValidation else { return }
        let temporary = try currentManagedTemporary(in: parent)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: changed)
        try handle.synchronize()
        lock.withLock {
            capturedTemporaryName = temporary.lastPathComponent
            mutated = true
        }
        throw InjectedFailure.afterMutation
    }
}

private final class ThrowingTemporaryLinkInjector: @unchecked Sendable {
    private enum InjectedFailure: Error { case afterLink }

    private let lock = NSLock()
    private let parent: URL
    private let unknownLink: URL
    private var linked = false
    private var capturedTemporaryName: String?

    init(parent: URL, unknownLink: URL) {
        self.parent = parent
        self.unknownLink = unknownLink
    }

    var didLink: Bool { lock.withLock { linked } }
    var temporaryName: String? { lock.withLock { capturedTemporaryName } }

    func inject(_ stage: DurableFileWriter.FaultStage) throws {
        guard stage == .beforeValidation else { return }
        let temporary = try currentManagedTemporary(in: parent)
        try FileManager.default.linkItem(at: temporary, to: unknownLink)
        var status = stat()
        XCTAssertEqual(temporary.path.withCString { Darwin.lstat($0, &status) }, 0)
        XCTAssertEqual(status.st_nlink, 2)
        lock.withLock {
            capturedTemporaryName = temporary.lastPathComponent
            linked = true
        }
        throw InjectedFailure.afterLink
    }
}

private func currentManagedTemporary(in parent: URL) throws -> URL {
    try XCTUnwrap(
        FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.contains(".supra-tmp-") }
    )
}
