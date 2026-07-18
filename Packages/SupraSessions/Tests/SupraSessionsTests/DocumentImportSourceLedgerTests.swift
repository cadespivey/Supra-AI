import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class DocumentImportSourceLedgerIntegrationTests: XCTestCase {
    private var base = URL(fileURLWithPath: "/tmp")
    private var sources = URL(fileURLWithPath: "/tmp")
    private var managed = URL(fileURLWithPath: "/tmp")
    private var databaseURL = URL(fileURLWithPath: "/tmp/test.sqlite")

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSourceLedger-\(UUID().uuidString)", isDirectory: true)
        sources = base.appendingPathComponent("Selected Sources", isDirectory: true)
        managed = base.appendingPathComponent("Managed", isDirectory: true)
        databaseURL = base.appendingPathComponent("SupraAI.sqlite")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testTACC01ImportPersistsEveryDiscoveredItemAndPreservesFinishedReportShape() async throws {
        // T-ACC-01 expected RED: imports only build an in-memory report and silently skip hidden entries.
        let accepted = sources.appendingPathComponent("accepted.txt")
        let duplicate = sources.appendingPathComponent("duplicate.txt")
        let hidden = sources.appendingPathComponent(".hidden.txt")
        let unsupported = sources.appendingPathComponent("unsupported.xyz")
        let nestedDirectory = sources.appendingPathComponent("Nested", isDirectory: true)
        let outside = base.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try "SYNTHETIC-CONTENT".write(to: accepted, atomically: true, encoding: .utf8)
        try "SYNTHETIC-CONTENT".write(to: duplicate, atomically: true, encoding: .utf8)
        try "HIDDEN-CANARY".write(to: hidden, atomically: true, encoding: .utf8)
        try "UNSUPPORTED-CANARY".write(to: unsupported, atomically: true, encoding: .utf8)
        try "NESTED-CONTENT".write(
            to: nestedDirectory.appendingPathComponent("nested.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "OUTSIDE-CANARY".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: sources.appendingPathComponent("escape.txt"),
            withDestinationURL: outside
        )

        let store = try SupraStore(url: databaseURL)
        let matter = try store.matters.createMatter(name: "Synthetic mixed import")
        let outcome = try await DocumentImportService(
            store: store,
            storage: DocumentStorage(root: managed),
            ocr: nil
        ).importSources([sources], matterID: matter.id)
        let rows = try store.documentJobs.fetchSources(batchID: outcome.batchID)

        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(Set(rows.map(\.sourceKey)).count, rows.count)
        XCTAssertTrue(rows.allSatisfy(\.isTerminal))
        XCTAssertEqual(rows.filter { $0.state == DocumentImportSourceState.containerCompleted.rawValue }.count, 2)
        XCTAssertTrue(rows.filter { $0.state == DocumentImportSourceState.containerCompleted.rawValue }.allSatisfy {
            $0.documentID == nil
        })
        XCTAssertEqual(rows.first { $0.sourceDisplayPath.hasSuffix(".hidden.txt") }?.state, DocumentImportSourceState.excludedHidden.rawValue)
        XCTAssertEqual(rows.first { $0.sourceDisplayPath.hasSuffix("unsupported.xyz") }?.state, DocumentImportSourceState.unsupportedByPolicy.rawValue)
        XCTAssertEqual(rows.first { $0.sourceDisplayPath.hasSuffix("escape.txt") }?.state, DocumentImportSourceState.rejected.rawValue)
        XCTAssertEqual(
            rows.first { $0.sourceDisplayPath.hasSuffix("escape.txt") }?.rejectionCode,
            ImportPolicyViolation.Code.symbolicLink.rawValue
        )
        XCTAssertEqual(rows.filter { $0.state == DocumentImportSourceState.admitted.rawValue }.count, 3)
        XCTAssertTrue(rows.filter { $0.parentSourceID != nil }.allSatisfy { $0.sourceBookmark == nil })

        let reportPaths = Set(outcome.report.items.map(\.sourceDisplayPath))
        XCTAssertEqual(reportPaths.count, 5)
        XCTAssertFalse(reportPaths.contains(where: { $0.hasSuffix(".hidden.txt") }))
        XCTAssertFalse(reportPaths.contains(where: { $0 == sources.lastPathComponent || $0.hasSuffix("/Nested") }))
        XCTAssertEqual(outcome.report.items.filter { $0.disposition == DocumentImportDisposition.imported.rawValue }.count, 2)
        XCTAssertEqual(outcome.report.items.filter { $0.disposition == DocumentImportDisposition.duplicateBlobReused.rawValue }.count, 1)
        XCTAssertEqual(outcome.report.items.filter { $0.disposition == DocumentImportDisposition.unsupported.rawValue }.count, 1)
        XCTAssertEqual(outcome.report.items.filter { $0.rejectionCode == ImportPolicyViolation.Code.symbolicLink.rawValue }.count, 1)

        let summary = try store.documentJobs.sourcesSummary(batchID: outcome.batchID)
        XCTAssertEqual(summary.totalCount, rows.count)
        XCTAssertEqual(summary.unfinishedCount, 0)
        XCTAssertEqual(summary.contentDenominator, 6)
        XCTAssertEqual(summary.balanceErrorCount, 0)
    }

    func testTACC02PolicyRejectionSurvivesAbortBeforeBatchFinalization() async throws {
        // T-ACC-02 expected RED: the rejection exists only in memory until finalization.
        let outside = base.appendingPathComponent("outside.txt")
        try "OUTSIDE-CANARY".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: sources.appendingPathComponent("escape.txt"),
            withDestinationURL: outside
        )
        let store = try SupraStore(url: databaseURL)
        let matter = try store.matters.createMatter(name: "Synthetic interrupted rejection")
        let service = DocumentImportService(
            store: store,
            storage: DocumentStorage(root: managed),
            ocr: nil,
            sourceStateObserver: { row in
                if row.state == DocumentImportSourceState.rejected.rawValue {
                    throw CancellationError()
                }
            }
        )

        do {
            let unexpected = try await service.importSources([sources], matterID: matter.id)
            XCTFail("Expected injected abort, imported batch \(unexpected.batchID)")
        } catch is CancellationError {
            // Expected process-stop simulation after the durable rejection write.
        }

        let reopened = try SupraStore(url: databaseURL)
        let batches = try reopened.documentJobs.fetchBatches(matterID: matter.id)
        let batch = try XCTUnwrap(batches.single)
        let rejected = try XCTUnwrap(
            try reopened.documentJobs.fetchSources(batchID: batch.id).first {
                $0.state == DocumentImportSourceState.rejected.rawValue
            }
        )
        XCTAssertEqual(rejected.sourceDisplayPath, "Selected Sources/escape.txt")
        XCTAssertEqual(rejected.rejectionCode, ImportPolicyViolation.Code.symbolicLink.rawValue)
        XCTAssertGreaterThan(rejected.createdAt.timeIntervalSince1970, 0)
        XCTAssertGreaterThanOrEqual(rejected.updatedAt, rejected.createdAt)
        XCTAssertNil(batch.reportJSON)
        XCTAssertNil(batch.completedAt)
        XCTAssertEqual(try reopened.documentLibrary.fetchDocuments(matterID: matter.id).count, 0)
        XCTAssertEqual(try reopened.documentLibrary.fetchBlobs(limit: 10).count, 0)
    }

    func testTACC04OnlyTopLevelSourceCarriesBookmarkAndTerminalImportClearsIt() async throws {
        // T-ACC-04 expected RED: import never mints, exposes, or clears source bookmarks.
        let nested = sources.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "BOOKMARK-CANARY".write(
            to: nested.appendingPathComponent("nested.txt"),
            atomically: true,
            encoding: .utf8
        )
        let recorder = SourceStateRecorder()
        let store = try SupraStore(url: databaseURL)
        let matter = try store.matters.createMatter(name: "Synthetic bookmark import")
        let outcome = try await DocumentImportService(
            store: store,
            storage: DocumentStorage(root: managed),
            ocr: nil,
            sourceStateObserver: recorder.record
        ).importSources([sources], matterID: matter.id)

        let snapshots = recorder.snapshots
        let activeTopLevel = snapshots.first {
            $0.parentSourceID == nil && $0.state == DocumentImportSourceState.copying.rawValue
        }
        XCTAssertNotNil(activeTopLevel?.sourceBookmark)
        XCTAssertTrue(snapshots.filter { $0.parentSourceID != nil }.allSatisfy { $0.sourceBookmark == nil })

        let terminalRows = try store.documentJobs.fetchSources(batchID: outcome.batchID)
        XCTAssertFalse(terminalRows.isEmpty)
        XCTAssertTrue(terminalRows.allSatisfy(\.isTerminal))
        XCTAssertTrue(terminalRows.allSatisfy { $0.sourceBookmark == nil })
    }
}

private final class SourceStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [DocumentImportSourceRecord] = []

    var snapshots: [DocumentImportSourceRecord] {
        lock.withLock { recorded }
    }

    func record(_ row: DocumentImportSourceRecord) {
        lock.withLock { recorded.append(row) }
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
