import Darwin
import Foundation
import GRDB
@testable import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class PublicationSingleLinkTests: XCTestCase {
    // ACR-EXPORT-024. Expected RED at 6315ee0c: a returning beforeInstall
    // callback can leave an unknown exact hard link to the managed temporary;
    // the controller then finalizes and audits that aliased inode.
    func testACREXPORT024BeforeInstallHardLinkRequiresRecoveryWithoutAudit() async throws {
        let fixture = try makePublicationSingleLinkFixture(label: "before-install")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.parent.appendingPathComponent("unknown-before-install-link.md")
        let injector = PublicationTemporaryHardLinkInjector(
            parent: fixture.parent,
            destinationName: fixture.destination.lastPathComponent,
            alias: alias
        )
        let auditProbe = PublicationAuditProbe()
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            fileWriter: DurableFileWriter { stage in
                guard stage == .beforeInstall else { return }
                try injector.inject()
            },
            fileStampProvider: { "fixed" },
            auditRecorder: { _ in auditProbe.record() }
        )

        let result = await controller.draftCustomDescription(
            matterID: fixture.matter.id,
            input: fixture.input
        )

        if case .success = result {
            XCTFail("aliased managed temporary unexpectedly finalized")
        }
        XCTAssertEqual(injector.callCount, 1)
        XCTAssertEqual(auditProbe.callCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let intent = try await publicationIntent(
            store: fixture.store,
            matterID: fixture.matter.id
        )
        try assertPublicationSingleLinkFile(
            alias,
            intent: intent,
            expectedLinkCount: 1
        )
        XCTAssertEqual(intent.status, DraftArtifactIntentStatus.recoveryRequired.rawValue)
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).isEmpty
        )
        XCTAssertTrue(
            try publicationTemporaryArtifacts(
                in: fixture.parent,
                destinationName: fixture.destination.lastPathComponent
            ).isEmpty
        )
    }

    // ACR-EXPORT-025. A returning final parent-sync callback is the last
    // external boundary before writer success. Adding an alias there must stop
    // before audit and preserve both exact public names for recovery.
    func testACREXPORT025FinalParentSyncHardLinkRequiresRecoveryWithoutAudit() async throws {
        let fixture = try makePublicationSingleLinkFixture(label: "final-sync")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.parent.appendingPathComponent("unknown-final-sync-link.md")
        let injector = PublicationFinalSyncHardLinkInjector(
            destination: fixture.destination,
            alias: alias
        )
        let auditProbe = PublicationAuditProbe()
        let writer = DurableFileWriter(
            faultInjector: { _ in },
            anchoredParentDirectorySynchronizer: {
                try injector.synchronize(parentURL: $0, parentDescriptor: $1)
            }
        )
        let controller = MatterDraftingController(
            store: fixture.store,
            storage: fixture.storage,
            fileWriter: writer,
            fileStampProvider: { "fixed" },
            auditRecorder: { _ in auditProbe.record() }
        )

        let result = await controller.draftCustomDescription(
            matterID: fixture.matter.id,
            input: fixture.input
        )

        if case .success = result {
            XCTFail("final-sync alias unexpectedly crossed the audit boundary")
        }
        XCTAssertEqual(injector.hardLinkCount, 1)
        XCTAssertEqual(auditProbe.callCount, 0)
        let intent = try await publicationIntent(
            store: fixture.store,
            matterID: fixture.matter.id
        )
        try assertPublicationSingleLinkFile(
            fixture.destination,
            intent: intent,
            expectedLinkCount: 2
        )
        try assertPublicationSingleLinkFile(
            alias,
            intent: intent,
            expectedLinkCount: 2
        )
        try assertPublicationSameInode(fixture.destination, alias, expectedLinkCount: 2)
        XCTAssertEqual(intent.status, DraftArtifactIntentStatus.recoveryRequired.rawValue)
        XCTAssertTrue(
            try fixture.store.auditEvents.fetchEvents(matterID: fixture.matter.id).isEmpty
        )
        XCTAssertTrue(
            try publicationTemporaryArtifacts(
                in: fixture.parent,
                destinationName: fixture.destination.lastPathComponent
            ).isEmpty
        )
    }
}

private typealias PublicationSingleLinkFixture = (
    store: SupraStore,
    matter: MatterRecord,
    root: URL,
    storage: DocumentStorage,
    parent: URL,
    destination: URL,
    input: CustomDraftDescriptionInput
)

private func makePublicationSingleLinkFixture(
    label: String
) throws -> PublicationSingleLinkFixture {
    let store = try SupraStore.inMemory()
    let matter = try store.matters.createMatter(name: "Single-link \(label)")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Supra-Publication-Single-Link-\(label)-\(UUID().uuidString)",
        isDirectory: true
    )
    let storage = DocumentStorage(root: root)
    let parent = storage.exportsDirectory(forMatterID: matter.id)
    let title = "Single link \(label)"
    let destination = parent.appendingPathComponent(
        "Single-link-\(label)-fixed.md"
    )
    return (
        store,
        matter,
        root,
        storage,
        parent,
        destination,
        CustomDraftDescriptionInput(
            title: title,
            description: "The publication must own one exact filesystem link."
        )
    )
}

private func publicationIntent(
    store: SupraStore,
    matterID: String
) async throws -> DraftArtifactIntentRecord {
    let intents = try await store.database.writer.read { db in
        try DraftArtifactIntentRecord.fetchAll(
            db,
            sql: "SELECT * FROM draft_artifact_intents WHERE matter_id = ?",
            arguments: [matterID]
        )
    }
    XCTAssertEqual(intents.count, 1)
    return try XCTUnwrap(intents.first)
}

private func assertPublicationSingleLinkFile(
    _ url: URL,
    intent: DraftArtifactIntentRecord,
    expectedLinkCount: UInt64,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let data = try Data(contentsOf: url)
    XCTAssertEqual(data.count, intent.outputByteSize, file: file, line: line)
    XCTAssertEqual(
        DocumentStorage.sha256Hex(of: data),
        intent.outputSHA256,
        file: file,
        line: line
    )
    var status = stat()
    XCTAssertEqual(
        url.path.withCString { Darwin.lstat($0, &status) },
        0,
        file: file,
        line: line
    )
    XCTAssertEqual(UInt64(status.st_nlink), expectedLinkCount, file: file, line: line)
}

private func assertPublicationSameInode(
    _ lhs: URL,
    _ rhs: URL,
    expectedLinkCount: UInt64,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    var lhsStatus = stat()
    var rhsStatus = stat()
    XCTAssertEqual(lhs.path.withCString { Darwin.lstat($0, &lhsStatus) }, 0, file: file, line: line)
    XCTAssertEqual(rhs.path.withCString { Darwin.lstat($0, &rhsStatus) }, 0, file: file, line: line)
    XCTAssertEqual(lhsStatus.st_dev, rhsStatus.st_dev, file: file, line: line)
    XCTAssertEqual(lhsStatus.st_ino, rhsStatus.st_ino, file: file, line: line)
    XCTAssertEqual(UInt64(lhsStatus.st_nlink), expectedLinkCount, file: file, line: line)
    XCTAssertEqual(UInt64(rhsStatus.st_nlink), expectedLinkCount, file: file, line: line)
}

private func publicationTemporaryArtifacts(
    in parent: URL,
    destinationName: String
) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: parent,
        includingPropertiesForKeys: nil
    ).filter { candidate in
        let prefix = ".\(destinationName).supra-tmp-"
        let name = candidate.lastPathComponent
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }
}

private final class PublicationTemporaryHardLinkInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let parent: URL
    private let destinationName: String
    private let alias: URL
    private var calls = 0

    init(parent: URL, destinationName: String, alias: URL) {
        self.parent = parent
        self.destinationName = destinationName
        self.alias = alias
    }

    var callCount: Int { lock.withLock { calls } }

    func inject() throws {
        let temporary = try XCTUnwrap(
            try publicationTemporaryArtifacts(
                in: parent,
                destinationName: destinationName
            ).only
        )
        try FileManager.default.linkItem(at: temporary, to: alias)
        try assertPublicationSameInode(temporary, alias, expectedLinkCount: 2)
        lock.withLock { calls += 1 }
    }
}

private final class PublicationFinalSyncHardLinkInjector: @unchecked Sendable {
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
        guard FileManager.default.fileExists(atPath: destination.path),
              !FileManager.default.fileExists(atPath: alias.path) else {
            guard Darwin.fsync(parentDescriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        XCTAssertEqual(
            parentURL.standardizedFileURL,
            destination.deletingLastPathComponent().standardizedFileURL
        )
        try FileManager.default.linkItem(at: destination, to: alias)
        try assertPublicationSameInode(destination, alias, expectedLinkCount: 2)
        lock.withLock { linksCreated += 1 }
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private final class PublicationAuditProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func record() {
        lock.withLock { calls += 1 }
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
