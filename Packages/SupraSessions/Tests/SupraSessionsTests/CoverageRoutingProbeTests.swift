import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

/// Phase 2 (retrieve-before-route): the evidence probe that replays a store's REAL matter-chat
/// user questions through the keyword router + corpus-coverage signal and tallies where they
/// diverge — the go/no-go input for flipping coverage to primary. Pure aggregation is tested
/// directly; the `run(...)` path is exercised against a seeded store with real chat history.
///
/// Expected RED before `CoverageRoutingProbe` / `CoverageRoutingReport` exist: the suite does not
/// compile ("cannot find 'CoverageRoutingProbe' in scope").
final class CoverageRoutingProbeTests: XCTestCase {

    // MARK: - Pure aggregation

    func testReportFoldsCountsAndRates() {
        let report = CoverageRoutingProbe.report(
            comparisons: [.agreeGround, .agreeGround, .coverageWouldGround, .agreeSkip, .marginal],
            matterCount: 2,
            usedSemantic: true
        )
        XCTAssertEqual(report.questionsScanned, 5)
        XCTAssertEqual(report.matterCount, 2)
        XCTAssertEqual(report.agreeGround, 2)
        XCTAssertEqual(report.agreeSkip, 1)
        XCTAssertEqual(report.coverageWouldGround, 1)
        XCTAssertEqual(report.coverageWouldSkip, 0)
        XCTAssertEqual(report.marginal, 1)
        XCTAssertTrue(report.usedSemantic)
        XCTAssertEqual(report.agreementRate, 3.0 / 5.0, accuracy: 1e-9)
        XCTAssertEqual(report.divergenceRate, 1.0 / 5.0, accuracy: 1e-9)
        XCTAssertEqual(report.wouldGroundRate, 1.0 / 5.0, accuracy: 1e-9)
        XCTAssertEqual(report.wouldSkipRate, 0.0, accuracy: 1e-9)
    }

    func testEmptyReportHasZeroRatesNotDivideByZero() {
        let report = CoverageRoutingProbe.report(comparisons: [], matterCount: 0, usedSemantic: false)
        XCTAssertEqual(report.questionsScanned, 0)
        XCTAssertEqual(report.agreementRate, 0)
        XCTAssertEqual(report.divergenceRate, 0)
        XCTAssertEqual(report.wouldGroundRate, 0)
        XCTAssertFalse(report.usedSemantic)
    }

    func testReadErrorsSurfaceAndFlagIncompleteScan() {
        let clean = CoverageRoutingProbe.report(comparisons: [.agreeGround], matterCount: 1, usedSemantic: false)
        XCTAssertEqual(clean.readErrors, 0)
        XCTAssertTrue(clean.completedCleanly)
        // A store read failure must be visible: an under-counted tally is not clean go/no-go evidence.
        let partial = CoverageRoutingProbe.report(
            comparisons: [.agreeGround], matterCount: 1, usedSemantic: false, readErrors: 2
        )
        XCTAssertEqual(partial.readErrors, 2)
        XCTAssertFalse(partial.completedCleanly)
    }

    // MARK: - Store-backed run over real chat history

    /// Seeds one matter with an indemnification corpus AND a June-meeting corpus, plus a chat
    /// whose user turns are one keyword-grounded question and one keyword-MISS question the
    /// corpus covers. Replaying them yields exactly one `agreeGround` and one
    /// `coverageWouldGround`. `usedSemantic` is false (nil embedder → FTS-only). Expected RED.
    func testRunReplaysUserQuestionsAndTalliesDivergence() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Probe Matter")
        for index in 1...2 {
            try await indexDocument(
                store, matterID: matter.id, name: "indemnity-\(index).txt",
                text: "SOURCE_\(index). The indemnification clause covers synthetic claims."
            )
            try await indexDocument(
                store, matterID: matter.id, name: "meeting-\(index).txt",
                text: "MEETING_\(index). The June board meeting approved the budget and merger timeline."
            )
        }
        let chat = try store.chats.createMatterChat(matterID: matter.id, title: "History")
        _ = try store.chats.appendUserMessage(chatID: chat.id, content: "What do my documents say about indemnification?")
        _ = try store.chats.appendUserMessage(chatID: chat.id, content: "What happened at the June meeting?")

        let report = await CoverageRoutingProbe.run(store: store, embedder: nil)

        XCTAssertEqual(report.matterCount, 1)
        XCTAssertEqual(report.questionsScanned, 2)
        XCTAssertEqual(report.agreeGround, 1)
        XCTAssertEqual(report.coverageWouldGround, 1)
        XCTAssertFalse(report.usedSemantic)
        XCTAssertTrue(report.completedCleanly, "a healthy store scan reports no read errors")
    }

    /// A matter with no chat history contributes nothing (no questions to replay), and matters
    /// are only counted when they have ≥1 replayable question. Expected RED.
    func testMatterWithoutQuestionsIsSkipped() async throws {
        let store = try makeStore()
        _ = try store.matters.createMatter(name: "Silent Matter")
        let report = await CoverageRoutingProbe.run(store: store, embedder: nil)
        XCTAssertEqual(report.matterCount, 0)
        XCTAssertEqual(report.questionsScanned, 0)
    }

    /// Duplicate user questions are de-duplicated so a repeated ask doesn't skew the tally. Expected RED.
    func testDuplicateQuestionsAreDeduplicated() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Repeat Matter")
        try await indexDocument(
            store, matterID: matter.id, name: "note.txt",
            text: "A single note about indemnification and nothing else."
        )
        let chat = try store.chats.createMatterChat(matterID: matter.id, title: "History")
        for _ in 1...3 {
            _ = try store.chats.appendUserMessage(chatID: chat.id, content: "Tell me about indemnification")
        }
        let report = await CoverageRoutingProbe.run(store: store, embedder: nil)
        XCTAssertEqual(report.questionsScanned, 1, "three identical questions collapse to one")
    }

    // MARK: - Harness

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverageProbeStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }

    @discardableResult
    private func insertDocument(
        _ store: SupraStore, _ matterID: String, name: String
    ) throws -> MatterDocumentRecord {
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                sha256: name, byteSize: 1, originalExtension: "pdf",
                managedRelativePath: "blobs/\(UUID().uuidString).pdf"
            )
        ).blob
        return try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID, blobID: blob.id, folderID: nil, displayName: name,
            status: MatterDocumentStatus.indexing.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue
        ))
    }

    private func indexDocument(
        _ store: SupraStore, matterID: String, name: String, text: String
    ) async throws {
        let document = try insertDocument(store, matterID, name: name)
        let revision = DocumentPartRevisionRecord(
            documentID: document.id, partIndex: 0,
            derivationKey: "coverage-probe-\(document.id)", origin: "parser", method: "synthetic",
            text: text, charCount: text.count
        )
        let selection = DocumentPartSelectionRecord(
            documentID: document.id, partIndex: 0, selectedRevisionID: revision.id,
            selectionKey: "coverage-probe-selection-\(document.id)", selectedBy: "system",
            policyVersion: 1, decisionJSON: #"{"rule":"synthetic_fixture"}"#
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [
                DocumentPagePartRecord(
                    documentID: document.id, partIndex: 0,
                    sourceKind: DocumentSourceKind.text.rawValue,
                    normalizedText: text, charCount: text.count
                ),
            ],
            revisions: [revision],
            selections: [selection]
        )
        _ = try await DocumentIndexingService(store: store, embedder: nil).indexDocument(documentID: document.id)
    }
}
