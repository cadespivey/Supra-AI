import Foundation
import SupraCore
@testable import SupraStore
import XCTest

final class DocumentImportSourceLedgerTests: XCTestCase {
    func testTACC03TerminalBucketsBalanceAndContentDenominatorExcludesOnlyContainers() throws {
        // T-ACC-03 expected RED: v059 ledger records, states, and summary APIs do not exist.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic source accounting")
        let batch = try store.documentJobs.createBatch(matterID: matter.id)
        let terminalStates: [DocumentImportSourceState] = [
            .admitted,
            .containerCompleted,
            .rejected,
            .unsupportedByPolicy,
            .failed,
            .cancelled,
            .interrupted,
            .excludedHidden,
            .excludedByUser,
        ]

        for (index, state) in terminalStates.enumerated() {
            let source = try store.documentJobs.recordDiscovered(
                batchID: batch.id,
                matterID: matter.id,
                sourceKey: "0/terminal-\(index)",
                sourceDisplayPath: "Fixture/terminal-\(index).txt"
            )
            let transitioned = try store.documentJobs.markState(
                sourceID: source.id,
                state: state,
                rejectionCode: state == .rejected ? "synthetic_rejection" : nil,
                reason: state == .failed ? "Synthetic parser failure" : nil
            )
            XCTAssertEqual(transitioned.state, state.rawValue)
        }

        let summary = try store.documentJobs.sourcesSummary(batchID: batch.id)
        XCTAssertEqual(summary.totalCount, 9)
        XCTAssertEqual(summary.terminalCount, 9)
        XCTAssertEqual(summary.unfinishedCount, 0)
        XCTAssertEqual(summary.contentDenominator, 8)
        XCTAssertEqual(summary.admittedCount, 1)
        XCTAssertEqual(summary.containerCompletedCount, 1)
        XCTAssertEqual(summary.rejectedCount, 1)
        XCTAssertEqual(summary.unsupportedByPolicyCount, 1)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.cancelledCount, 1)
        XCTAssertEqual(summary.interruptedCount, 1)
        XCTAssertEqual(summary.excludedHiddenCount, 1)
        XCTAssertEqual(summary.excludedByUserCount, 1)
        XCTAssertEqual(summary.balanceErrorCount, 0)
        XCTAssertTrue(try store.documentJobs.unfinishedSources(batchID: batch.id).isEmpty)

        let emptyBatch = try store.documentJobs.createBatch(matterID: matter.id)
        let emptySummary = try store.documentJobs.sourcesSummary(batchID: emptyBatch.id)
        XCTAssertEqual(emptySummary.totalCount, 0)
        XCTAssertEqual(emptySummary.contentDenominator, 0)
        XCTAssertEqual(emptySummary.balanceErrorCount, 0)
    }

    func testTACC04TopLevelBookmarkClearsAtomicallyAndChildrenNeverStoreOne() throws {
        // T-ACC-04 expected RED: bookmark persistence and terminal clearing are absent.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic bookmark lifecycle")
        let batch = try store.documentJobs.createBatch(matterID: matter.id)
        let bookmark = Data("synthetic-security-scope".utf8)
        let parent = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "0",
            sourceDisplayPath: "Selected Folder",
            sourceBookmark: bookmark,
            state: .selected
        )
        let child = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "0/nested.txt",
            sourceDisplayPath: "Selected Folder/nested.txt",
            sourceBookmark: Data("must-not-persist".utf8),
            parentSourceID: parent.id
        )

        XCTAssertEqual(parent.sourceBookmark, bookmark)
        XCTAssertNil(child.sourceBookmark)
        let active = try store.documentJobs.markState(sourceID: parent.id, state: .copying)
        XCTAssertEqual(active.sourceBookmark, bookmark)
        let terminal = try store.documentJobs.markState(sourceID: parent.id, state: .containerCompleted)
        XCTAssertNil(terminal.sourceBookmark)
        XCTAssertEqual(terminal.state, DocumentImportSourceState.containerCompleted.rawValue)
        XCTAssertTrue(try store.documentJobs.unfinishedSources(batchID: batch.id).map(\.id).contains(child.id))
    }

    func testRecordDiscoveredIsIdempotentAndMatterScoped() throws {
        // T-ACC-01 / INV-19 expected RED: ledger identity and scoped fetch APIs are absent.
        let store = try makeStore()
        let firstMatter = try store.matters.createMatter(name: "Synthetic first matter")
        let secondMatter = try store.matters.createMatter(name: "Synthetic second matter")
        let firstBatch = try store.documentJobs.createBatch(matterID: firstMatter.id)
        let secondBatch = try store.documentJobs.createBatch(matterID: secondMatter.id)

        let first = try store.documentJobs.recordDiscovered(
            batchID: firstBatch.id,
            matterID: firstMatter.id,
            sourceKey: "0/shared.txt",
            sourceDisplayPath: "Root/shared.txt"
        )
        let repeated = try store.documentJobs.recordDiscovered(
            batchID: firstBatch.id,
            matterID: firstMatter.id,
            sourceKey: "0/shared.txt",
            sourceDisplayPath: "Root/shared.txt"
        )
        let other = try store.documentJobs.recordDiscovered(
            batchID: secondBatch.id,
            matterID: secondMatter.id,
            sourceKey: "0/shared.txt",
            sourceDisplayPath: "Root/shared.txt"
        )

        XCTAssertEqual(repeated.id, first.id)
        XCTAssertNotEqual(other.id, first.id)
        XCTAssertEqual(try store.documentJobs.fetchSources(batchID: firstBatch.id).map(\.id), [first.id])
        XCTAssertEqual(try store.documentJobs.fetchSources(matterID: firstMatter.id).map(\.id), [first.id])
        XCTAssertFalse(try store.documentJobs.fetchSources(matterID: firstMatter.id).map(\.id).contains(other.id))
        XCTAssertThrowsError(try store.documentJobs.recordDiscovered(
            batchID: firstBatch.id,
            matterID: secondMatter.id,
            sourceKey: "cross-matter",
            sourceDisplayPath: "cross-matter.txt"
        ))
    }

    func testBatchPersistsValidatedTargetFolderIntent() throws {
        // M2-W1 expected RED: the batch has no durable target-folder intent.
        let store = try makeStore()
        let firstMatter = try store.matters.createMatter(name: "Synthetic target matter")
        let secondMatter = try store.matters.createMatter(name: "Synthetic foreign matter")
        let target = try store.documentLibrary.createFolder(matterID: firstMatter.id, name: "Production")
        let foreign = try store.documentLibrary.createFolder(matterID: secondMatter.id, name: "Foreign")

        let batch = try store.documentJobs.createBatch(
            matterID: firstMatter.id,
            targetFolderID: target.id,
            targetFolderRequested: true
        )
        XCTAssertEqual(batch.targetFolderID, target.id)
        XCTAssertTrue(batch.targetFolderRequested)

        let rootBatch = try store.documentJobs.createBatch(matterID: firstMatter.id)
        XCTAssertNil(rootBatch.targetFolderID)
        XCTAssertFalse(rootBatch.targetFolderRequested)
        XCTAssertThrowsError(try store.documentJobs.createBatch(
            matterID: firstMatter.id,
            targetFolderID: foreign.id,
            targetFolderRequested: true
        ))
    }

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSourceLedgerStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }
}
