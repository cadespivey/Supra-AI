import Foundation
import SupraCore
@testable import SupraSessions
import SupraStore
import XCTest

final class OutputAssuranceUXTests: XCTestCase {
    private enum TUX06Fixture {
        static let modelID = "tux06-readiness-model-811"
        static let modelRevision = "tux06-readiness-revision-17"
        static let modelDisplayName = "TUX06 Readiness Model 811"
        static let dimension = 8
        static let timestamp = Date(timeIntervalSince1970: 1_946_248_811)
    }

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
        try configureTUX06EmbeddingModel(store)
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "tux06-readiness",
            byteSize: 1,
            originalExtension: "txt",
            managedRelativePath: "blobs/tux06-readiness.txt"
        )).blob
        for index in 1...8 {
            let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
                id: "tux06-ready-document-\(index)-811",
                matterID: matter.id,
                blobID: blob.id,
                displayName: "ready-\(index).txt",
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.ready.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractionMethod: "synthetic@toolchain:tux06-readiness-17",
                extractedTextChecksum: "tux06-ready-checksum-\(index)-811",
                pagePartCount: 1,
                importedAt: TUX06Fixture.timestamp,
                createdAt: TUX06Fixture.timestamp,
                updatedAt: TUX06Fixture.timestamp
            ))
            try seedTUX06CanonicalReadiness(store, document: document, ordinal: index)
            let receipt = try store.documentReadiness.fetchReceipt(documentID: document.id)
            XCTAssertTrue(receipt.isBaseReady, "ready fixture \(index) must be receipt-complete")
            XCTAssertEqual(receipt.activeEmbeddingModelID, TUX06Fixture.modelID)
            XCTAssertEqual(receipt.activeEmbeddingModelRevision, TUX06Fixture.modelRevision)
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

    private func configureTUX06EmbeddingModel(_ store: SupraStore) throws {
        _ = try store.documentSettings.loadSettings()
        try store.documentSettings.upsertEmbeddingModel(
            DocumentEmbeddingModelRecord(
                id: TUX06Fixture.modelID,
                repoID: "synthetic/tux06-readiness-model-811",
                localPath: "/synthetic/tux06-readiness-model-811",
                displayName: TUX06Fixture.modelDisplayName,
                dimension: TUX06Fixture.dimension,
                runtimeFamily: "tux06-readiness-fixture-17",
                revision: TUX06Fixture.modelRevision,
                isDefault: false,
                isSelected: false,
                lastTestLoadAt: TUX06Fixture.timestamp,
                lastTestLoadResult: "passed",
                createdAt: TUX06Fixture.timestamp,
                updatedAt: TUX06Fixture.timestamp
            )
        )
        try store.documentSettings.selectEmbeddingModel(id: TUX06Fixture.modelID)
        try store.documentSettings.updateSettings {
            $0.embeddingModelLastTestedAt = TUX06Fixture.timestamp
            $0.chunkerVersion = 2
        }
    }

    private func seedTUX06CanonicalReadiness(
        _ store: SupraStore,
        document: MatterDocumentRecord,
        ordinal: Int
    ) throws {
        let text = "TUX06_CANONICAL_READY_WIRE_\(ordinal)_811"
        let part = DocumentPagePartRecord(
            id: "tux06-ready-part-\(ordinal)-811",
            documentID: document.id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count,
            createdAt: TUX06Fixture.timestamp,
            updatedAt: TUX06Fixture.timestamp
        )
        let revision = DocumentPartRevisionRecord(
            id: "tux06-ready-revision-\(ordinal)-811",
            documentID: document.id,
            partIndex: 0,
            derivationKey: "tux06-ready-derivation-\(ordinal)-17",
            origin: "parser",
            method: "synthetic_exact_text",
            text: text,
            charCount: text.count,
            toolchainVersion: "tux06-readiness-toolchain-17",
            createdAt: TUX06Fixture.timestamp
        )
        let selection = DocumentPartSelectionRecord(
            id: "tux06-ready-selection-\(ordinal)-811",
            documentID: document.id,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "tux06-ready-selection-key-\(ordinal)-17",
            selectedBy: "synthetic_policy",
            policyVersion: 17,
            decisionJSON: #"{"wire":"TUX06_CANONICAL_SELECTION_811"}"#,
            createdAt: TUX06Fixture.timestamp
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [part],
            revisions: [revision],
            selections: [selection]
        )
        let chunk = DocumentChunkRecord(
            id: "tux06-ready-chunk-\(ordinal)-811",
            documentID: document.id,
            pagePartID: part.id,
            revisionID: revision.id,
            chunkerVersion: 2,
            chunkIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            charStart: 0,
            charEnd: text.count,
            normalizedText: text,
            displayExcerpt: text,
            tokenCount: 8,
            createdAt: TUX06Fixture.timestamp,
            updatedAt: TUX06Fixture.timestamp
        )
        try store.documentIndex.replaceChunks(documentID: document.id, chunks: [chunk])
        try store.documentIndex.upsertEmbedding(
            DocumentChunkEmbeddingRecord(
                id: "tux06-ready-embedding-\(ordinal)-811",
                chunkID: chunk.id,
                documentID: document.id,
                embeddingModelID: TUX06Fixture.modelID,
                modelDisplayName: TUX06Fixture.modelDisplayName,
                modelRevision: TUX06Fixture.modelRevision,
                dimension: TUX06Fixture.dimension,
                normalized: true,
                vector: unitVectorData(dimension: TUX06Fixture.dimension),
                createdAt: TUX06Fixture.timestamp
            )
        )
    }

    private func unitVectorData(dimension: Int) -> Data {
        (0..<dimension).reduce(into: Data()) { data, index in
            var bits = (index == 0 ? Float(1) : Float(0)).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssuranceUXStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
