import Foundation
import SupraCore
@testable import SupraSessions
import SupraStore
import XCTest

final class OutputAssuranceUXTests: XCTestCase {
    func testTUX03PDFHighlightIsScopedToTheRecordedLocatorPage() {
        // T-UX-03 expected RED: PDFKitView accepts the first document-wide text
        // match, even when its page differs from the persisted locator page.
        XCTAssertEqual(
            PDFLocatorHighlightPolicy.selectionIndex(
                targetPageIndex: 2,
                candidatePageIndexes: [0, 2]
            ),
            1
        )
        XCTAssertEqual(
            PDFLocatorHighlightPolicy.selectionIndex(
                targetPageIndex: 0,
                candidatePageIndexes: [0, 2]
            ),
            0
        )
        XCTAssertNil(
            PDFLocatorHighlightPolicy.selectionIndex(
                targetPageIndex: 1,
                candidatePageIndexes: [0, 2]
            )
        )
    }

    func testTUX06ReadinessNamesFailedAndReviewMembersWithoutFalseCleanDenominator() throws {
        // T-UX-06 expected RED: readiness removes failed documents from its
        // denominator and has no explicit review-member accounting or copy.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic readiness disclosure")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "tux06-readiness",
            byteSize: 1,
            originalExtension: "txt",
            managedRelativePath: "blobs/tux06-readiness.txt"
        )).blob
        for index in 1...8 {
            _ = try store.documentLibrary.insertDocument(MatterDocumentRecord(
                matterID: matter.id,
                blobID: blob.id,
                displayName: "ready-\(index).txt",
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.ready.rawValue
            ))
        }
        for index in 1...2 {
            _ = try store.documentLibrary.insertDocument(MatterDocumentRecord(
                matterID: matter.id,
                blobID: blob.id,
                displayName: "failed-\(index).txt",
                status: MatterDocumentStatus.failed.rawValue,
                extractionStatus: DocumentExtractionStatus.failed.rawValue,
                indexStatus: DocumentIndexStatus.failed.rawValue,
                extractionErrorsJSON: #"["NONDEFAULT parser failure"]"#
            ))
        }
        _ = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matter.id,
            blobID: blob.id,
            displayName: "review-scan.pdf",
            status: MatterDocumentStatus.needsReview.rawValue,
            extractionStatus: DocumentExtractionStatus.ocrComplete.rawValue,
            indexStatus: DocumentIndexStatus.ready.rawValue,
            ocrConfidenceSummary: "low OCR confidence 0.31 on page 3"
        ))

        let readiness = try DocumentRetrievalService(store: store)
            .scopeReadiness(matterID: matter.id, scope: .wholeMatter)

        XCTAssertEqual(readiness.totalDocuments, 11)
        XCTAssertEqual(readiness.readyDocuments, 8)
        XCTAssertEqual(readiness.failedDocuments, 2)
        XCTAssertEqual(readiness.needsReviewDocuments, 1)
        XCTAssertEqual(readiness.summaryText, "8 ready, 2 failed, 1 needs review")
        XCTAssertFalse(readiness.summaryText.contains("8 of 8 ready"))
        XCTAssertFalse(readiness.isFullyReady)
        XCTAssertTrue(readiness.blockingReasons.contains { $0.contains("failed-1.txt") })
        XCTAssertTrue(readiness.blockingReasons.contains { $0.contains("review-scan.pdf") && $0.contains("0.31") })
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssuranceUXStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
