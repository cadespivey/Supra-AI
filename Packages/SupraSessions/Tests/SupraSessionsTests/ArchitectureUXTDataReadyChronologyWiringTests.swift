import Foundation
import SupraCore
import SupraStore
@testable import SupraSessions
import XCTest

/// Real Chronology wiring boundary for T-DATA-READY-01.
///
/// Expected RED: `DocumentChronologyController.scopeReadiness(scope:)` still
/// forwards Ask's projections unchanged. Its public output therefore identifies
/// every receipt as `.ask` and never adds the chronology-only
/// `.missingChronologyDateEvidence` exclusion for a base-ready undated source.
@MainActor
final class ArchitectureUXTDataReadyChronologyWiringTests: XCTestCase {
    private enum Wire {
        static let matterName = "T_DATA_READY_CHRONOLOGY_MATTER_941"
        static let modelID = "T_DATA_READY_CHRONOLOGY_MODEL_941"
        static let modelRevision = "T_DATA_READY_CHRONOLOGY_MODEL_REVISION_23"
        static let modelDimension = 7
        static let forbiddenDefault = "DEFAULT-000"
        static let timestamp = Date(timeIntervalSince1970: 1_946_250_941)
    }

    private enum FixtureKind: String, CaseIterable {
        case readyDated
        case readyUndated
        case staleDated

        var ordinal: Int {
            switch self {
            case .readyDated: 1
            case .readyUndated: 2
            case .staleDated: 3
            }
        }

        var documentID: String { "chronology-readiness-\(rawValue)-941" }
        var partID: String { "\(documentID)-part-23" }
        var revisionID: String { "\(documentID)-revision-23" }
        var selectionID: String { "\(documentID)-selection-23" }
        var chunkID: String { "\(documentID)-chunk-23" }
        var text: String {
            switch self {
            case .readyDated:
                "On August 13, 2026, T_DATA_READY_CHRONOLOGY_DATED_WIRE_947 occurred."
            case .readyUndated:
                "T_DATA_READY_CHRONOLOGY_UNDATED_WIRE_953 has no temporal marker."
            case .staleDated:
                "On August 14, 2026, T_DATA_READY_CHRONOLOGY_STALE_WIRE_967 occurred."
            }
        }
        var metadataCreatedAt: Date? {
            self == .readyUndated ? nil : Wire.timestamp.addingTimeInterval(Double(ordinal))
        }
        var expectedBaseReady: Bool { self != .staleDated }
        var expectedPrimaryBaseExclusion: DocumentReadinessExclusionReason? {
            self == .staleDated ? .staleRevision : nil
        }
        var expectedTaskExclusions: [DocumentTaskEligibilityExclusion] {
            self == .readyUndated ? [.missingChronologyDateEvidence] : []
        }
    }

    /// Expected RED: the actual Chronology controller must relabel the shared
    /// Store receipt for its own consumer and layer date eligibility beside,
    /// never inside, the canonical base state.
    func testChronologyPublishesCanonicalReceiptsWithAdditiveDateEligibility() throws {
        let fixture = try makeFixture()
        let controller = DocumentChronologyController(
            matterID: fixture.matterID,
            store: fixture.store,
            runtimeClient: StubRuntimeClient()
        )
        let readiness = try XCTUnwrap(
            controller.scopeReadiness(scope: .wholeMatter),
            "Chronology must publish readiness for the selected matter scope"
        )
        XCTAssertEqual(readiness.documentReadiness.count, FixtureKind.allCases.count)

        let projectionsByDocumentID = Dictionary(
            uniqueKeysWithValues: readiness.documentReadiness.map {
                ($0.documentID, $0)
            }
        )
        for kind in FixtureKind.allCases {
            let canonical = try fixture.store.documentReadiness.fetchReceipt(
                documentID: kind.documentID
            )
            let projection = try XCTUnwrap(
                projectionsByDocumentID[kind.documentID],
                "Chronology omitted the \(kind.rawValue) receipt"
            )

            XCTAssertEqual(projection.consumer, .chronology, kind.rawValue)
            XCTAssertEqual(projection.baseReceipt, canonical, kind.rawValue)
            XCTAssertEqual(projection.baseReceiptID, canonical.receiptID, kind.rawValue)
            XCTAssertEqual(projection.isBaseReady, kind.expectedBaseReady, kind.rawValue)
            XCTAssertEqual(
                projection.primaryBaseExclusion,
                kind.expectedPrimaryBaseExclusion,
                kind.rawValue
            )
            XCTAssertEqual(
                projection.taskExclusions,
                kind.expectedTaskExclusions,
                "chronology date policy must remain separate from base exclusions"
            )
            XCTAssertEqual(
                projection.isEligibleForTask,
                kind.expectedBaseReady && kind.expectedTaskExclusions.isEmpty,
                kind.rawValue
            )
            XCTAssertEqual(
                projection.baseReceipt.activeEmbeddingModelID,
                Wire.modelID,
                "the non-default active model must survive the Chronology wire"
            )
            XCTAssertEqual(
                projection.baseReceipt.activeEmbeddingModelRevision,
                Wire.modelRevision,
                kind.rawValue
            )
            XCTAssertFalse(projection.baseReceiptID.contains(kind.text), kind.rawValue)
            XCTAssertFalse(
                projection.baseReceiptID.contains(Wire.forbiddenDefault),
                kind.rawValue
            )
            XCTAssertFalse(
                projection.taskExclusions.description.contains(Wire.forbiddenDefault),
                kind.rawValue
            )
        }

        let undated = try XCTUnwrap(projectionsByDocumentID[FixtureKind.readyUndated.documentID])
        XCTAssertTrue(undated.isBaseReady)
        XCTAssertNil(undated.primaryBaseExclusion)
        XCTAssertFalse(undated.isEligibleForTask)

        let stale = try XCTUnwrap(projectionsByDocumentID[FixtureKind.staleDated.documentID])
        XCTAssertFalse(stale.isBaseReady)
        XCTAssertEqual(stale.primaryBaseExclusion, .staleRevision)
        XCTAssertEqual(stale.taskExclusions, [])
        XCTAssertFalse(stale.isEligibleForTask)

        XCTAssertEqual(
            readiness.readyDocuments,
            readiness.documentReadiness.filter(\.isBaseReady).count,
            "Chronology's visible base-ready count must not be rewritten by date eligibility"
        )
        XCTAssertEqual(readiness.readyDocuments, 2)
        XCTAssertEqual(readiness.documentReadiness.filter(\.isEligibleForTask).count, 1)
        XCTAssertFalse(
            readiness.documentReadiness.description.contains(Wire.forbiddenDefault)
        )
    }

    private func makeFixture() throws -> (store: SupraStore, matterID: String) {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: Wire.matterName)
        try configureEmbeddingModel(store)
        for kind in FixtureKind.allCases {
            try seedDocument(store: store, matterID: matter.id, kind: kind)
        }
        return (store, matter.id)
    }

    private func configureEmbeddingModel(_ store: SupraStore) throws {
        _ = try store.documentSettings.loadSettings()
        try store.documentSettings.upsertEmbeddingModel(
            DocumentEmbeddingModelRecord(
                id: Wire.modelID,
                repoID: "synthetic/\(Wire.modelID)",
                localPath: "/synthetic/\(Wire.modelID)",
                displayName: Wire.modelID,
                dimension: Wire.modelDimension,
                runtimeFamily: "t-data-ready-chronology-wire-23",
                revision: Wire.modelRevision,
                isDefault: false,
                isSelected: false,
                lastTestLoadAt: Wire.timestamp,
                lastTestLoadResult: "passed",
                createdAt: Wire.timestamp,
                updatedAt: Wire.timestamp
            )
        )
        try store.documentSettings.selectEmbeddingModel(id: Wire.modelID)
        try store.documentSettings.updateSettings {
            $0.embeddingModelLastTestedAt = Wire.timestamp
            $0.chunkerVersion = 2
        }
    }

    private func seedDocument(
        store: SupraStore,
        matterID: String,
        kind: FixtureKind
    ) throws {
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                id: "\(kind.documentID)-blob-23",
                sha256: String(repeating: String(kind.ordinal), count: 64),
                byteSize: kind.text.utf8.count,
                originalExtension: "txt",
                managedRelativePath: "blobs/\(kind.documentID).txt",
                mimeType: "text/plain",
                integrityStatus: DocumentBlobIntegrityStatus.verified.rawValue,
                verifiedAt: Wire.timestamp,
                createdAt: Wire.timestamp
            )
        ).blob
        _ = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                id: kind.documentID,
                matterID: matterID,
                blobID: blob.id,
                displayName: "\(kind.rawValue)-chronology-wire-\(940 + kind.ordinal).txt",
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.ready.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractionMethod: "T_DATA_READY_CHRONOLOGY_EXTRACTOR_23",
                extractedTextChecksum: String(repeating: String(kind.ordinal + 3), count: 64),
                pagePartCount: 1,
                metadataCreatedAt: kind.metadataCreatedAt,
                importedAt: Wire.timestamp,
                createdAt: Wire.timestamp,
                updatedAt: Wire.timestamp
            )
        )
        try store.documentIndex.replaceParts(
            documentID: kind.documentID,
            parts: [
                DocumentPagePartRecord(
                    id: kind.partID,
                    documentID: kind.documentID,
                    partIndex: 0,
                    sourceKind: DocumentSourceKind.text.rawValue,
                    normalizedText: kind.text,
                    charCount: kind.text.count,
                    createdAt: Wire.timestamp,
                    updatedAt: Wire.timestamp
                ),
            ]
        )
        _ = try store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: kind.revisionID,
                documentID: kind.documentID,
                partIndex: 0,
                derivationKey: "\(kind.documentID)-derivation-23",
                origin: "parser",
                method: "synthetic_exact_text",
                text: kind.text,
                charCount: kind.text.count,
                toolchainVersion: "T_DATA_READY_CHRONOLOGY_TOOLCHAIN_23",
                createdAt: Wire.timestamp
            )
        )
        _ = try store.documentRevisions.appendSelection(
            DocumentPartSelectionRecord(
                id: kind.selectionID,
                documentID: kind.documentID,
                partIndex: 0,
                selectedRevisionID: kind.revisionID,
                selectionKey: "\(kind.documentID)-selection-key-23",
                selectedBy: "synthetic_policy",
                policyVersion: 23,
                decisionJSON: #"{"wire":"T_DATA_READY_CHRONOLOGY_SELECTION_23"}"#,
                createdAt: Wire.timestamp
            )
        )
        try store.documentIndex.replaceChunks(
            documentID: kind.documentID,
            chunks: [
                DocumentChunkRecord(
                    id: kind.chunkID,
                    documentID: kind.documentID,
                    pagePartID: kind.partID,
                    revisionID: kind.revisionID,
                    chunkerVersion: 2,
                    chunkIndex: 0,
                    sourceKind: DocumentSourceKind.text.rawValue,
                    charStart: 0,
                    charEnd: kind.text.count,
                    normalizedText: kind.text,
                    displayExcerpt: kind.text,
                    tokenCount: 23,
                    createdAt: Wire.timestamp,
                    updatedAt: Wire.timestamp
                ),
            ]
        )
        try store.documentIndex.upsertEmbedding(
            DocumentChunkEmbeddingRecord(
                id: "\(kind.documentID)-embedding-23",
                chunkID: kind.chunkID,
                documentID: kind.documentID,
                embeddingModelID: Wire.modelID,
                modelDisplayName: Wire.modelID,
                modelRevision: Wire.modelRevision,
                dimension: Wire.modelDimension,
                normalized: true,
                vector: Self.floatBlob([1, 0, 0, 0, 0, 0, 0]),
                createdAt: Wire.timestamp
            )
        )

        if kind == .staleDated {
            try appendNPlusOneSelection(store: store, kind: kind)
        }
    }

    private func appendNPlusOneSelection(
        store: SupraStore,
        kind: FixtureKind
    ) throws {
        let nextText = "On August 15, 2026, T_DATA_READY_CHRONOLOGY_N_PLUS_ONE_971 occurred."
        let nextRevisionID = "\(kind.documentID)-revision-29"
        _ = try store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: nextRevisionID,
                documentID: kind.documentID,
                partIndex: 0,
                derivationKey: "\(kind.documentID)-derivation-29",
                origin: "user_edit",
                method: "synthetic_manual",
                text: nextText,
                charCount: nextText.count,
                toolchainVersion: "T_DATA_READY_CHRONOLOGY_TOOLCHAIN_29",
                author: "synthetic-attorney-971",
                reason: "T-DATA-READY-01 chronology N+1 invalidation",
                supersedesRevisionID: kind.revisionID,
                createdAt: Wire.timestamp.addingTimeInterval(29)
            )
        )
        _ = try store.documentRevisions.appendSelection(
            DocumentPartSelectionRecord(
                id: "\(kind.documentID)-selection-29",
                documentID: kind.documentID,
                partIndex: 0,
                selectedRevisionID: nextRevisionID,
                selectionKey: "\(kind.documentID)-selection-key-29",
                selectedBy: "synthetic_attorney",
                decisionJSON: #"{"wire":"T_DATA_READY_CHRONOLOGY_SELECTION_29"}"#,
                supersedesSelectionID: kind.selectionID,
                createdAt: Wire.timestamp.addingTimeInterval(30)
            )
        )
    }

    private static func floatBlob(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * MemoryLayout<Float>.size)
        for value in values {
            var littleEndianBits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndianBits) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }
}
