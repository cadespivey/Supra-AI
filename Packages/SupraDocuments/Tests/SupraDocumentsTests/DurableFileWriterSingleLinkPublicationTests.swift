import Darwin
import Foundation
@testable import SupraDocuments
import XCTest

final class DurableFileWriterSingleLinkPublicationTests: XCTestCase {
    // ACR-FILE-035. Expected RED at b07f07a5: a returning pre-validation
    // callback can add an unknown exact hard link to the managed temporary and
    // the writer still installs that aliased inode successfully.
    func testACRFILE035BeforeValidationHardLinkPreventsPublication() throws {
        try assertReturningFaultCallbackHardLinkPreventsPublication(
            at: .beforeValidation,
            label: "before-validation"
        )
    }

    // ACR-FILE-036. The final caller-controlled fault checkpoint before the
    // isolated rename must also leave exactly one named link.
    func testACRFILE036BeforeInstallHardLinkPreventsPublication() throws {
        try assertReturningFaultCallbackHardLinkPreventsPublication(
            at: .beforeInstall,
            label: "before-install"
        )
    }

    // ACR-FILE-037. A format validator may return normally after adding an
    // unknown exact hard link. Successful publication must reject that alias.
    func testACRFILE037ReturningValidatorHardLinkPreventsPublication() throws {
        let fixture = try makeSingleLinkFixture(label: "validator")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.parent.appendingPathComponent("unknown-validator-link.md")
        var validatorCalls = 0

        XCTAssertThrowsError(
            try DurableFileWriter().writeNewOwned(
                fixture.payload,
                to: fixture.destination,
                containedIn: fixture.root,
                validator: { validated in
                    validatorCalls += 1
                    XCTAssertEqual(validated, fixture.payload)
                    let temporary = try XCTUnwrap(
                        try singleLinkTemporary(in: fixture.parent)
                    )
                    try FileManager.default.linkItem(at: temporary, to: alias)
                    try assertSingleLinkSameInode(
                        temporary,
                        alias,
                        expectedLinkCount: 2
                    )
                }
            )
        ) { error in
            guard case .managedTemporaryCleanupUncertain = error as? DurableFileWriter.WriterError else {
                return XCTFail("Expected managed temporary cleanup uncertainty, got \(error)")
            }
        }

        XCTAssertEqual(validatorCalls, 1)
        try assertRejectedPublicationPreservedOnlyAlias(
            fixture: fixture,
            alias: alias
        )
    }

    // ACR-FILE-038. The final parent-directory synchronizer is the last
    // returning callback before success. If it adds an alias to the installed
    // inode, the writer must leave the publication recoverable and fail closed.
    func testACRFILE038FinalParentSyncHardLinkPreventsSuccessfulPublication() throws {
        let fixture = try makeSingleLinkFixture(label: "final-parent-sync")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.parent.appendingPathComponent("unknown-final-sync-link.md")
        let probe = FinalSyncHardLinkProbe(
            destination: fixture.destination,
            alias: alias
        )
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            anchoredParentDirectorySynchronizer: {
                try probe.synchronize(parentURL: $0, parentDescriptor: $1)
            }
        )

        XCTAssertThrowsError(
            try writer.writeNewOwned(
                fixture.payload,
                to: fixture.destination,
                containedIn: fixture.root,
                validator: { XCTAssertEqual($0, fixture.payload) }
            )
        ) { error in
            guard case .postInstallStateUncertain = error as? DurableFileWriter.WriterError else {
                return XCTFail("Expected post-install uncertainty, got \(error)")
            }
        }

        XCTAssertEqual(probe.hardLinkCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.payload)
        XCTAssertEqual(try Data(contentsOf: alias), fixture.payload)
        try assertSingleLinkSameInode(
            fixture.destination,
            alias,
            expectedLinkCount: 2
        )
        XCTAssertTrue(try singleLinkTemporaryArtifacts(in: fixture.parent).isEmpty)
    }

    private func assertReturningFaultCallbackHardLinkPreventsPublication(
        at stage: DurableFileWriter.FaultStage,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = try makeSingleLinkFixture(label: label)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.parent.appendingPathComponent("unknown-\(label)-link.md")
        let probe = ReturningFaultHardLinkProbe(
            stage: stage,
            parent: fixture.parent,
            alias: alias
        )
        let writer = DurableFileWriter { try probe.handle($0) }

        XCTAssertThrowsError(
            try writer.writeNewOwned(
                fixture.payload,
                to: fixture.destination,
                containedIn: fixture.root,
                validator: { XCTAssertEqual($0, fixture.payload, file: file, line: line) }
            ),
            file: file,
            line: line
        ) { error in
            guard case .managedTemporaryCleanupUncertain = error as? DurableFileWriter.WriterError else {
                return XCTFail(
                    "Expected managed temporary cleanup uncertainty, got \(error)",
                    file: file,
                    line: line
                )
            }
        }

        XCTAssertEqual(probe.hardLinkCount, 1, file: file, line: line)
        try assertRejectedPublicationPreservedOnlyAlias(
            fixture: fixture,
            alias: alias,
            file: file,
            line: line
        )
    }
}

private typealias SingleLinkFixture = (
    root: URL,
    parent: URL,
    destination: URL,
    payload: Data
)

private func makeSingleLinkFixture(label: String) throws -> SingleLinkFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Supra-Single-Link-\(label)-\(UUID().uuidString)",
        isDirectory: true
    )
    let parent = root
        .appendingPathComponent("exports", isDirectory: true)
        .appendingPathComponent("matter-123", isDirectory: true)
    let destination = parent.appendingPathComponent("motion.md")
    return (
        root,
        parent,
        destination,
        Data("# Single-link publication \(label)\n".utf8)
    )
}

private func assertRejectedPublicationPreservedOnlyAlias(
    fixture: SingleLinkFixture,
    alias: URL,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    XCTAssertFalse(
        FileManager.default.fileExists(atPath: fixture.destination.path),
        file: file,
        line: line
    )
    XCTAssertEqual(
        try Data(contentsOf: alias),
        fixture.payload,
        file: file,
        line: line
    )
    XCTAssertEqual(
        try DocumentStorage.sha256Hex(ofFileAt: alias),
        DocumentStorage.sha256Hex(of: fixture.payload),
        file: file,
        line: line
    )
    var status = stat()
    XCTAssertEqual(
        alias.path.withCString { Darwin.lstat($0, &status) },
        0,
        file: file,
        line: line
    )
    XCTAssertEqual(UInt64(status.st_nlink), 1, file: file, line: line)
    XCTAssertTrue(
        try singleLinkTemporaryArtifacts(in: fixture.parent).isEmpty,
        file: file,
        line: line
    )
}

private func singleLinkTemporary(in parent: URL) throws -> URL? {
    let artifacts = try singleLinkTemporaryArtifacts(in: parent)
    return artifacts.count == 1 ? artifacts.first : nil
}

private func singleLinkTemporaryArtifacts(in parent: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: parent,
        includingPropertiesForKeys: nil
    ).filter { candidate in
        let name = candidate.lastPathComponent
        let prefix = ".motion.md.supra-tmp-"
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }
}

private func assertSingleLinkSameInode(
    _ lhs: URL,
    _ rhs: URL,
    expectedLinkCount: UInt64,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    var lhsStatus = stat()
    var rhsStatus = stat()
    XCTAssertEqual(
        lhs.path.withCString { Darwin.lstat($0, &lhsStatus) },
        0,
        file: file,
        line: line
    )
    XCTAssertEqual(
        rhs.path.withCString { Darwin.lstat($0, &rhsStatus) },
        0,
        file: file,
        line: line
    )
    XCTAssertEqual(lhsStatus.st_dev, rhsStatus.st_dev, file: file, line: line)
    XCTAssertEqual(lhsStatus.st_ino, rhsStatus.st_ino, file: file, line: line)
    XCTAssertEqual(UInt64(lhsStatus.st_nlink), expectedLinkCount, file: file, line: line)
    XCTAssertEqual(UInt64(rhsStatus.st_nlink), expectedLinkCount, file: file, line: line)
}

private final class ReturningFaultHardLinkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let stage: DurableFileWriter.FaultStage
    private let parent: URL
    private let alias: URL
    private var linksCreated = 0

    init(stage: DurableFileWriter.FaultStage, parent: URL, alias: URL) {
        self.stage = stage
        self.parent = parent
        self.alias = alias
    }

    var hardLinkCount: Int { lock.withLock { linksCreated } }

    func handle(_ observed: DurableFileWriter.FaultStage) throws {
        guard observed == stage else { return }
        let temporary = try XCTUnwrap(try singleLinkTemporary(in: parent))
        try FileManager.default.linkItem(at: temporary, to: alias)
        try assertSingleLinkSameInode(temporary, alias, expectedLinkCount: 2)
        lock.withLock { linksCreated += 1 }
    }
}

private final class FinalSyncHardLinkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let alias: URL
    private var linksCreated = 0

    init(destination: URL, alias: URL) {
        self.destination = destination
        self.alias = alias
    }

    var hardLinkCount: Int { lock.withLock { linksCreated } }

    func synchronize(parentURL: URL, parentDescriptor: Int32) throws {
        var status = stat()
        guard Darwin.fstat(parentDescriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard FileManager.default.fileExists(atPath: destination.path),
              !FileManager.default.fileExists(atPath: alias.path) else {
            return
        }
        XCTAssertEqual(
            parentURL.standardizedFileURL,
            destination.deletingLastPathComponent().standardizedFileURL
        )
        try FileManager.default.linkItem(at: destination, to: alias)
        try assertSingleLinkSameInode(destination, alias, expectedLinkCount: 2)
        lock.withLock { linksCreated += 1 }
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
