import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class HostileDocumentImportTests: XCTestCase {
    private var base = URL(fileURLWithPath: "/tmp")
    private var sources = URL(fileURLWithPath: "/tmp")
    private var managed = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACRHostileTree-\(UUID().uuidString)", isDirectory: true)
        sources = base.appendingPathComponent("Sources", isDirectory: true)
        managed = base.appendingPathComponent("Managed", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testACRIMPORT009RejectsSymlinkOutsideRootWithoutBlob() async throws {
        let outside = base.appendingPathComponent("outside.txt")
        try "OUTSIDE-CANARY".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: sources.appendingPathComponent("linked.txt"),
            withDestinationURL: outside
        )

        let (store, matterID) = try makeStoreAndMatter()
        let outcome = try await DocumentImportService(
            store: store,
            storage: DocumentStorage(root: managed),
            ocr: nil
        ).importSources([sources], matterID: matterID)

        XCTAssertEqual(outcome.report.items.first?.rejectionCode, ImportPolicyViolation.Code.symbolicLink.rawValue)
        XCTAssertEqual(try store.documentLibrary.fetchDocuments(matterID: matterID).count, 0)
        XCTAssertFalse(containsRegularFile(under: managed.appendingPathComponent("blobs")))
    }

    func testACRIMPORT010RejectsHardLinksAsAmbiguousDuplicateIdentity() async throws {
        let first = sources.appendingPathComponent("first.txt")
        let second = sources.appendingPathComponent("second.txt")
        try "HARDLINK-CANARY".write(to: first, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: first, to: second)

        let (store, matterID) = try makeStoreAndMatter()
        let outcome = try await DocumentImportService(
            store: store,
            storage: DocumentStorage(root: managed),
            ocr: nil
        ).importSources([sources], matterID: matterID)

        XCTAssertEqual(outcome.report.failedCount, 2)
        XCTAssertTrue(outcome.report.items.allSatisfy {
            $0.rejectionCode == ImportPolicyViolation.Code.hardLink.rawValue
        })
        XCTAssertEqual(try store.documentLibrary.fetchDocuments(matterID: matterID).count, 0)
    }

    func testACRIMPORT011LimitRejectionLeavesNoManagedBlobOrRow() async throws {
        let oversized = sources.appendingPathComponent("oversized.txt")
        try Data(repeating: 0x41, count: 17).write(to: oversized)
        let (store, matterID) = try makeStoreAndMatter()
        let service = DocumentImportService(
            store: store,
            storage: DocumentStorage(root: managed),
            extraction: ExtractionService(policy: ImportPolicy(maxInputBytes: 16)),
            importPolicy: ImportPolicy(maxInputBytes: 16),
            ocr: nil
        )

        let outcome = try await service.importSources([oversized], matterID: matterID)

        XCTAssertEqual(outcome.report.failedCount, 1)
        XCTAssertEqual(outcome.report.items.first?.rejectionCode, ImportPolicyViolation.Code.sourceTooLarge.rawValue)
        XCTAssertEqual(try store.documentLibrary.fetchBlobs(limit: 10).count, 0)
        XCTAssertFalse(containsRegularFile(under: managed.appendingPathComponent("blobs")))
    }

    func testACRIMPORT012RejectsTreeDepthAndAggregateBytesPerItem() async throws {
        let deep = sources.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "deep".write(to: deep.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)
        try "123456".write(to: sources.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        try "abcdef".write(to: sources.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        let policy = ImportPolicy(maxTreeDepth: 2, maxAggregateSourceBytes: 10)
        let (store, matterID) = try makeStoreAndMatter()

        let outcome = try await DocumentImportService(
            store: store,
            storage: DocumentStorage(root: managed),
            extraction: ExtractionService(policy: policy),
            importPolicy: policy,
            ocr: nil
        ).importSources([sources], matterID: matterID)

        XCTAssertTrue(outcome.report.items.contains { $0.rejectionCode == ImportPolicyViolation.Code.treeDepth.rawValue })
        XCTAssertTrue(outcome.report.items.contains { $0.rejectionCode == ImportPolicyViolation.Code.aggregateSourceBytes.rawValue })
    }

    func testACRIMPORT013DetectsRootReplacementRace() async throws {
        let victim = sources.appendingPathComponent("victim.txt")
        try "SAFE".write(to: victim, atomically: true, encoding: .utf8)
        let replacement = base.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try "ESCAPE".write(to: replacement.appendingPathComponent("victim.txt"), atomically: true, encoding: .utf8)
        let race = RootReplacementFault(root: sources, replacement: replacement)
        let (store, matterID) = try makeStoreAndMatter()
        let service = DocumentImportService(
            store: store,
            storage: DocumentStorage(root: managed),
            ocr: nil,
            traversalFaultInjector: race.inject
        )

        let outcome = try await service.importSources([sources], matterID: matterID)

        XCTAssertTrue(outcome.report.items.contains { $0.rejectionCode == ImportPolicyViolation.Code.rootChanged.rawValue })
        XCTAssertEqual(try store.documentLibrary.fetchDocuments(matterID: matterID).count, 0)
        XCTAssertFalse(containsRegularFile(under: managed.appendingPathComponent("blobs")))
    }

    func testACRIMPORT014RejectsFinderAliasWithoutFollowingIt() async throws {
        let outside = base.appendingPathComponent("alias-target.txt")
        try "ALIAS-OUTSIDE-CANARY".write(to: outside, atomically: true, encoding: .utf8)
        let alias = sources.appendingPathComponent("target-alias.txt")
        let bookmark = try outside.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(bookmark, to: alias)
        XCTAssertEqual(try alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile, true)

        let (store, matterID) = try makeStoreAndMatter()
        let outcome = try await DocumentImportService(
            store: store,
            storage: DocumentStorage(root: managed),
            ocr: nil
        ).importSources([sources], matterID: matterID)

        XCTAssertEqual(outcome.report.items.first?.rejectionCode, ImportPolicyViolation.Code.alias.rawValue)
        XCTAssertEqual(try store.documentLibrary.fetchDocuments(matterID: matterID).count, 0)
        XCTAssertFalse(containsRegularFile(under: managed.appendingPathComponent("blobs")))
    }

    func testACRIMPORT015CancellationCleansStagingAndCreatesNoRows() async throws {
        let source = sources.appendingPathComponent("cancelled.txt")
        try Data(repeating: 0x43, count: 4_096).write(to: source)
        let (store, matterID) = try makeStoreAndMatter()
        let storage = DocumentStorage(root: managed) { stage in
            if stage == .beforeInstall { throw CancellationError() }
        }

        do {
            _ = try await DocumentImportService(store: store, storage: storage, ocr: nil)
                .importSources([source], matterID: matterID)
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected: cancellation is not converted to a normal failed import.
        }

        XCTAssertEqual(try store.documentLibrary.fetchDocuments(matterID: matterID).count, 0)
        XCTAssertEqual(try store.documentLibrary.fetchBlobs(limit: 10).count, 0)
        XCTAssertFalse(containsRegularFile(under: managed.appendingPathComponent("temp")))
        XCTAssertFalse(containsRegularFile(under: managed.appendingPathComponent("blobs")))
    }

    func testACRIMPORT016FileCountBudgetRejectsOnlyItemsBeyondLimit() async throws {
        try "one".write(to: sources.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "two".write(to: sources.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        let policy = ImportPolicy(maxFileCount: 1)
        let (store, matterID) = try makeStoreAndMatter()

        let outcome = try await DocumentImportService(
            store: store,
            storage: DocumentStorage(root: managed),
            importPolicy: policy,
            ocr: nil
        ).importSources([sources], matterID: matterID)

        XCTAssertEqual(outcome.report.importedCount, 1)
        XCTAssertEqual(outcome.report.failedCount, 1)
        XCTAssertTrue(outcome.report.items.contains {
            $0.rejectionCode == ImportPolicyViolation.Code.fileCount.rawValue
        })
    }

    func testACRIMPORT020RejectsCandidateReplacementAfterValidation() async throws {
        let victim = sources.appendingPathComponent("victim.txt")
        try "SAFE-CANDIDATE".write(to: victim, atomically: true, encoding: .utf8)
        let fault = CandidateReplacementFault(victim: victim)
        let (store, matterID) = try makeStoreAndMatter()

        let outcome = try await DocumentImportService(
            store: store,
            storage: DocumentStorage(root: managed),
            ocr: nil,
            traversalFaultInjector: fault.inject
        ).importSources([sources], matterID: matterID)

        XCTAssertEqual(
            outcome.report.items.first?.rejectionCode,
            ImportPolicyViolation.Code.candidateChanged.rawValue
        )
        XCTAssertEqual(try store.documentLibrary.fetchDocuments(matterID: matterID).count, 0)
        XCTAssertFalse(containsRegularFile(under: managed.appendingPathComponent("blobs")))
    }

    private func makeStoreAndMatter() throws -> (SupraStore, String) {
        let database = base.appendingPathComponent("store-\(UUID().uuidString).sqlite")
        let store = try SupraStore(url: database)
        let matter = try store.matters.createMatter(name: "Synthetic hostile import")
        return (store, matter.id)
    }

    private func containsRegularFile(under root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return false }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return true }
        }
        return false
    }
}

private final class RootReplacementFault: @unchecked Sendable {
    private let root: URL
    private let replacement: URL
    private var fired = false
    private let lock = NSLock()

    init(root: URL, replacement: URL) {
        self.root = root
        self.replacement = replacement
    }

    func inject(stage: ImportTraversalStage, url: URL) throws {
        guard stage == .afterRootPinned else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        let moved = root.deletingLastPathComponent().appendingPathComponent("original-sources")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: replacement)
    }
}

private final class CandidateReplacementFault: @unchecked Sendable {
    private let victim: URL
    private var fired = false
    private let lock = NSLock()

    init(victim: URL) {
        self.victim = victim
    }

    func inject(stage: ImportTraversalStage, url: URL) throws {
        guard stage == .afterCandidateValidated, url.standardizedFileURL == victim.standardizedFileURL else { return }
        try lock.withLock {
            guard !fired else { return }
            fired = true
            try FileManager.default.removeItem(at: victim)
            try "REPLACED-CANDIDATE".write(to: victim, atomically: true, encoding: .utf8)
        }
    }
}
