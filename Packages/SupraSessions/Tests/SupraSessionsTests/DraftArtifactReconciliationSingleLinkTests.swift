import Darwin
import Foundation
@testable import SupraDocuments
import SupraStore
@testable import SupraSessions
import XCTest

final class DraftArtifactReconciliationSingleLinkTests: XCTestCase {
    // T-DAR-22. Expected RED at 6315ee0c: relaunch reconciliation accepts a
    // prepared public artifact with an unknown exact hard-link alias, finalizes
    // the intent, and emits its audit. A publication is complete only when its
    // exact inode has one named link.
    func testTDAR22AliasedPublicArtifactRequiresRecoveryWithoutAudit() throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Relaunch single-link matter")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Supra-Reconciliation-Single-Link-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DocumentStorage(root: root)
        let output = Data("# Relaunch single-link publication\n".utf8)
        let intent = try store.draftArtifacts.prepareGenericIntent(
            matterID: matter.id,
            artifactKind: .customDescription,
            format: .markdown,
            fileName: "Relaunch-single-link.md",
            output: output,
            id: "relaunch-single-link"
        )
        let parent = storage.exportsDirectory(forMatterID: matter.id)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let publicURL = parent.appendingPathComponent(intent.fileName)
        let alias = parent.appendingPathComponent("unknown-relaunch-public-link.md")
        try output.write(to: publicURL)
        try FileManager.default.linkItem(at: publicURL, to: alias)
        try assertReconciliationSameInode(
            publicURL,
            alias,
            expectedLinkCount: 2
        )

        let summary = try DraftArtifactReconciliationService(
            store: store,
            storage: storage
        ).reconcilePendingIntents()

        XCTAssertEqual(summary.finalizedCount, 0)
        XCTAssertEqual(summary.abortedCount, 0)
        XCTAssertEqual(summary.recoveryRequiredCount, 1)
        XCTAssertEqual(
            try store.draftArtifacts.intent(id: intent.id)?.status,
            DraftArtifactIntentStatus.recoveryRequired.rawValue
        )
        XCTAssertTrue(try store.auditEvents.fetchEvents(matterID: matter.id).isEmpty)
        XCTAssertNotNil(
            try store.remediationRecovery.pendingItem(
                kind: .interruptedDraftArtifact,
                relatedID: intent.id
            )
        )
        try assertReconciliationSingleLinkFile(
            publicURL,
            expected: output,
            expectedLinkCount: 2
        )
        try assertReconciliationSingleLinkFile(
            alias,
            expected: output,
            expectedLinkCount: 2
        )
        try assertReconciliationSameInode(
            publicURL,
            alias,
            expectedLinkCount: 2
        )
    }
}

private func assertReconciliationSingleLinkFile(
    _ url: URL,
    expected: Data,
    expectedLinkCount: UInt64,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let data = try Data(contentsOf: url)
    XCTAssertEqual(data, expected, file: file, line: line)
    XCTAssertEqual(
        DocumentStorage.sha256Hex(of: data),
        DocumentStorage.sha256Hex(of: expected),
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

private func assertReconciliationSameInode(
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
