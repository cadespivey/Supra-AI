import Foundation
import SupraCore
import SupraStore
@testable import SupraSessions
import XCTest

/// Cross-consumer boundary for T-DATA-READY-01.
///
/// Expected RED: `CanonicalDocumentReadinessLedger`,
/// `DocumentReadinessConsumer`, and `DocumentTaskEligibilityExclusion` do not
/// exist. This selected test must fail to compile on that missing adapter before
/// Documents, Ask, Chronology, or drafting can keep interpreting raw document
/// status/index fields independently.
final class ArchitectureUXTDataReady01Tests: XCTestCase {
    private enum Wire {
        static let documentID = "ready-ledger-document-713"
        static let partID = "ready-ledger-part-713-7"
        static let revisionID = "ready-ledger-revision-713-7"
        static let selectionID = "ready-ledger-selection-713-7"
        static let chunkID = "ready-ledger-chunk-713-7"
        static let text = "T_DATA_READY_01_CONSUMER_WIRE_731"
        static let nextText = "T_DATA_READY_01_CONSUMER_WIRE_N_PLUS_1_733"
        static let displayName = "T_DATA_READY_01_CONSUMER_SOURCE_719.txt"
        static let modelAID = "T_DATA_READY_01_CONSUMER_MODEL_A_731"
        static let modelARevision = "T_DATA_READY_01_CONSUMER_MODEL_A_REVISION_7"
        static let modelBID = "T_DATA_READY_01_CONSUMER_MODEL_B_733"
        static let modelBRevision = "T_DATA_READY_01_CONSUMER_MODEL_B_REVISION_8"
        static let modelDimension = 7
        static let forbiddenDefault = "DEFAULT-000"
        static let timestamp = Date(timeIntervalSince1970: 1_946_247_731)
    }

    private enum FixtureKind: String, CaseIterable {
        case ready
        case textOnly
        case wrongModel
        case extractionFailed
        case needsReview
        case staleRevision

        var expectedBaseReady: Bool { self == .ready }

        var expectedPrimaryExclusion: DocumentReadinessExclusionReason? {
            switch self {
            case .ready:
                nil
            case .textOnly, .wrongModel:
                .semanticIndexIncomplete
            case .extractionFailed:
                .extractionFailed
            case .needsReview:
                .reviewRequired
            case .staleRevision:
                .staleRevision
            }
        }
    }

    private struct Fixture {
        let store: SupraStore
        let matterID: String
    }

    /// Expected RED: the canonical Sessions ledger and its four typed consumer
    /// projections do not exist, so this fixture table cannot compile.
    func testAllConsumersExposeTheExactCanonicalStoreReceiptAcrossFixtureTable() throws {
        XCTAssertEqual(
            Set(DocumentReadinessConsumer.allCases),
            Set([.documents, .ask, .chronology, .drafting])
        )
        for kind in FixtureKind.allCases {
            let fixture = try makeFixture(kind)
            let canonical = try fixture.store.documentReadiness.fetchReceipt(
                documentID: Wire.documentID
            )
            let ledger = CanonicalDocumentReadinessLedger(store: fixture.store)
            let projections = try ledger.consumerProjections(
                matterID: fixture.matterID,
                documentIDs: [Wire.documentID]
            )

            XCTAssertEqual(
                projections.count,
                DocumentReadinessConsumer.allCases.count,
                kind.rawValue
            )
            XCTAssertEqual(
                Set(projections.map(\.consumer)),
                Set(DocumentReadinessConsumer.allCases),
                kind.rawValue
            )
            for projection in projections {
                XCTAssertEqual(projection.documentID, Wire.documentID, kind.rawValue)
                XCTAssertEqual(projection.baseReceiptID, canonical.receiptID, kind.rawValue)
                XCTAssertEqual(projection.isBaseReady, canonical.isBaseReady, kind.rawValue)
                XCTAssertEqual(
                    projection.primaryBaseExclusion,
                    canonical.primaryExclusion,
                    kind.rawValue
                )
                XCTAssertEqual(projection.isBaseReady, kind.expectedBaseReady, kind.rawValue)
                XCTAssertEqual(
                    projection.primaryBaseExclusion,
                    kind.expectedPrimaryExclusion,
                    kind.rawValue
                )
                XCTAssertEqual(projection.taskExclusions, [], kind.rawValue)
                XCTAssertEqual(
                    projection.isEligibleForTask,
                    kind.expectedBaseReady,
                    "task eligibility must include, but never redefine, base readiness"
                )
                XCTAssertFalse(projection.baseReceiptID.contains(Wire.text), kind.rawValue)
                XCTAssertFalse(projection.baseReceiptID.contains(Wire.displayName), kind.rawValue)
                XCTAssertFalse(
                    projection.baseReceiptID.contains(Wire.forbiddenDefault),
                    kind.rawValue
                )
            }

            if kind == .wrongModel {
                XCTAssertEqual(canonical.activeEmbeddingModelID, Wire.modelBID)
                XCTAssertEqual(canonical.activeEmbeddingModelRevision, Wire.modelBRevision)
                XCTAssertEqual(canonical.availableEmbeddingModelIDs, [Wire.modelAID])
                XCTAssertFalse(canonical.receiptID.contains(Wire.modelAID))
                XCTAssertFalse(canonical.receiptID.contains(Wire.modelBID))
            }
        }
    }

    /// Expected RED: no shared projection keeps additive task exclusions apart
    /// from the Store-owned base receipt today.
    func testTaskExclusionsStayTypedAndCannotRewriteTheSharedBaseReceipt() throws {
        let fixture = try makeFixture(.ready)
        let canonical = try fixture.store.documentReadiness.fetchReceipt(
            documentID: Wire.documentID
        )
        let ledger = CanonicalDocumentReadinessLedger(store: fixture.store)
        let exclusions: [DocumentReadinessConsumer: [String: [DocumentTaskEligibilityExclusion]]] = [
            .ask: [Wire.documentID: [.outsideSelectedAskScope]],
            .chronology: [Wire.documentID: [.missingChronologyDateEvidence]],
            .drafting: [Wire.documentID: [.missingDraftingSourceSelection]],
        ]

        let projections = try ledger.consumerProjections(
            matterID: fixture.matterID,
            documentIDs: [Wire.documentID],
            taskExclusions: exclusions
        )
        let byConsumer = Dictionary(
            uniqueKeysWithValues: projections.map { ($0.consumer, $0) }
        )

        for consumer in DocumentReadinessConsumer.allCases {
            let projection = try XCTUnwrap(byConsumer[consumer])
            XCTAssertTrue(projection.isBaseReady, consumer.rawValue)
            XCTAssertNil(projection.primaryBaseExclusion, consumer.rawValue)
            XCTAssertEqual(projection.baseReceiptID, canonical.receiptID, consumer.rawValue)
            XCTAssertFalse(projection.baseReceiptID.contains(Wire.forbiddenDefault))
        }

        XCTAssertEqual(byConsumer[.documents]?.taskExclusions, [])
        XCTAssertEqual(byConsumer[.ask]?.taskExclusions, [.outsideSelectedAskScope])
        XCTAssertEqual(
            byConsumer[.chronology]?.taskExclusions,
            [.missingChronologyDateEvidence]
        )
        XCTAssertEqual(
            byConsumer[.drafting]?.taskExclusions,
            [.missingDraftingSourceSelection]
        )
        XCTAssertTrue(try XCTUnwrap(byConsumer[.documents]).isEligibleForTask)
        XCTAssertFalse(try XCTUnwrap(byConsumer[.ask]).isEligibleForTask)
        XCTAssertFalse(try XCTUnwrap(byConsumer[.chronology]).isEligibleForTask)
        XCTAssertFalse(try XCTUnwrap(byConsumer[.drafting]).isEligibleForTask)
        XCTAssertFalse(
            projections.map(\.taskExclusions).description.contains(Wire.forbiddenDefault),
            "the non-default task wires must be visible without a fabricated default reason"
        )
    }

    /// Expected RED: the four consumers have no shared refresh boundary that
    /// replaces every stale green projection after an N+1 selection.
    func testNPlusOneSelectionInvalidatesEveryConsumerWithoutAStaleGreenProjection() throws {
        let fixture = try makeFixture(.ready)
        let ledger = CanonicalDocumentReadinessLedger(store: fixture.store)
        let before = try ledger.consumerProjections(
            matterID: fixture.matterID,
            documentIDs: [Wire.documentID]
        )
        XCTAssertTrue(before.allSatisfy(\.isBaseReady))
        let priorReceiptIDs = Set(before.map(\.baseReceiptID))
        XCTAssertEqual(priorReceiptIDs.count, 1)

        try appendNPlusOneSelection(fixture.store)

        let after = try ledger.consumerProjections(
            matterID: fixture.matterID,
            documentIDs: [Wire.documentID]
        )
        XCTAssertEqual(Set(after.map(\.baseReceiptID)).count, 1)
        XCTAssertNotEqual(Set(after.map(\.baseReceiptID)), priorReceiptIDs)
        for projection in after {
            XCTAssertFalse(projection.isBaseReady, projection.consumer.rawValue)
            XCTAssertEqual(
                projection.primaryBaseExclusion,
                .staleRevision,
                projection.consumer.rawValue
            )
            XCTAssertFalse(projection.isEligibleForTask, projection.consumer.rawValue)
            XCTAssertFalse(projection.baseReceiptID.contains(Wire.nextText))
            XCTAssertFalse(projection.baseReceiptID.contains(Wire.forbiddenDefault))
        }
    }

    private func makeFixture(_ kind: FixtureKind) throws -> Fixture {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(
            name: "T-DATA-READY-01 consumer matter 709"
        )
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                id: "ready-ledger-blob-713",
                sha256: String(repeating: "7", count: 64),
                byteSize: Wire.text.utf8.count,
                originalExtension: "txt",
                managedRelativePath: "blobs/T_DATA_READY_01_CONSUMER_WIRE_731.txt",
                mimeType: "text/plain",
                integrityStatus: DocumentBlobIntegrityStatus.verified.rawValue,
                verifiedAt: Wire.timestamp,
                createdAt: Wire.timestamp
            )
        ).blob

        let documentStatus: MatterDocumentStatus = switch kind {
        case .extractionFailed: .failed
        case .needsReview: .needsReview
        default: .ready
        }
        let extractionStatus: DocumentExtractionStatus = kind == .extractionFailed
            ? .failed
            : .extracted
        let indexStatus: DocumentIndexStatus = kind == .textOnly
            ? .textIndexed
            : .ready

        _ = try store.documentLibrary.insertDocument(
            MatterDocumentRecord(
                id: Wire.documentID,
                matterID: matter.id,
                blobID: blob.id,
                displayName: Wire.displayName,
                status: documentStatus.rawValue,
                extractionStatus: extractionStatus.rawValue,
                indexStatus: indexStatus.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractionMethod: "T_DATA_READY_01_CONSUMER_EXTRACTOR_7",
                extractedTextChecksum: String(repeating: "3", count: 64),
                pagePartCount: 1,
                importedAt: Wire.timestamp,
                createdAt: Wire.timestamp,
                updatedAt: Wire.timestamp
            )
        )
        try store.documentIndex.replaceParts(
            documentID: Wire.documentID,
            parts: [
                DocumentPagePartRecord(
                    id: Wire.partID,
                    documentID: Wire.documentID,
                    partIndex: 0,
                    sourceKind: DocumentSourceKind.text.rawValue,
                    normalizedText: Wire.text,
                    charCount: Wire.text.count,
                    createdAt: Wire.timestamp,
                    updatedAt: Wire.timestamp
                ),
            ]
        )
        _ = try store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: Wire.revisionID,
                documentID: Wire.documentID,
                partIndex: 0,
                derivationKey: "T_DATA_READY_01_CONSUMER_DERIVATION_7",
                origin: "parser",
                method: "synthetic_exact_text",
                text: Wire.text,
                charCount: Wire.text.count,
                toolchainVersion: "T_DATA_READY_01_CONSUMER_TOOLCHAIN_7",
                createdAt: Wire.timestamp
            )
        )
        _ = try store.documentRevisions.appendSelection(
            DocumentPartSelectionRecord(
                id: Wire.selectionID,
                documentID: Wire.documentID,
                partIndex: 0,
                selectedRevisionID: Wire.revisionID,
                selectionKey: "T_DATA_READY_01_CONSUMER_SELECTION_7",
                selectedBy: "synthetic_policy",
                policyVersion: 7,
                decisionJSON: #"{"wire":"T_DATA_READY_01_CONSUMER_SELECTION_DECISION_7"}"#,
                createdAt: Wire.timestamp
            )
        )
        try store.documentIndex.replaceChunks(
            documentID: Wire.documentID,
            chunks: [
                DocumentChunkRecord(
                    id: Wire.chunkID,
                    documentID: Wire.documentID,
                    pagePartID: Wire.partID,
                    revisionID: Wire.revisionID,
                    chunkerVersion: 2,
                    chunkIndex: 0,
                    sourceKind: DocumentSourceKind.text.rawValue,
                    charStart: 0,
                    charEnd: Wire.text.count,
                    normalizedText: Wire.text,
                    displayExcerpt: Wire.text,
                    tokenCount: 7,
                    createdAt: Wire.timestamp,
                    updatedAt: Wire.timestamp
                ),
            ]
        )

        _ = try store.documentSettings.loadSettings()
        try store.documentSettings.upsertEmbeddingModel(
            embeddingModel(
                id: Wire.modelAID,
                revision: Wire.modelARevision,
                selected: false
            )
        )
        try store.documentSettings.selectEmbeddingModel(id: Wire.modelAID)
        try store.documentSettings.updateSettings {
            $0.embeddingModelLastTestedAt = Wire.timestamp
            $0.chunkerVersion = 2
        }

        if kind != .textOnly {
            try store.documentIndex.upsertEmbedding(
                DocumentChunkEmbeddingRecord(
                    id: "ready-ledger-embedding-713-7",
                    chunkID: Wire.chunkID,
                    documentID: Wire.documentID,
                    embeddingModelID: Wire.modelAID,
                    modelDisplayName: Wire.modelAID,
                    modelRevision: Wire.modelARevision,
                    dimension: Wire.modelDimension,
                    normalized: true,
                    vector: Self.floatBlob([1, 0, 0, 0, 0, 0, 0]),
                    createdAt: Wire.timestamp
                )
            )
        }

        if kind == .wrongModel {
            try store.documentSettings.upsertEmbeddingModel(
                embeddingModel(
                    id: Wire.modelBID,
                    revision: Wire.modelBRevision,
                    selected: false
                )
            )
            try store.documentSettings.selectEmbeddingModel(id: Wire.modelBID)
            try store.documentSettings.updateSettings {
                $0.embeddingModelLastTestedAt = Wire.timestamp.addingTimeInterval(8)
            }
        }
        if kind == .staleRevision {
            try appendNPlusOneSelection(store)
        }

        return Fixture(store: store, matterID: matter.id)
    }

    private func embeddingModel(
        id: String,
        revision: String,
        selected: Bool
    ) -> DocumentEmbeddingModelRecord {
        DocumentEmbeddingModelRecord(
            id: id,
            repoID: "synthetic/\(id)",
            localPath: "/synthetic/\(id)",
            displayName: id,
            dimension: Wire.modelDimension,
            runtimeFamily: "synthetic-wire-7",
            revision: revision,
            isDefault: false,
            isSelected: selected,
            lastTestLoadAt: Wire.timestamp,
            lastTestLoadResult: "passed",
            createdAt: Wire.timestamp,
            updatedAt: Wire.timestamp
        )
    }

    private func appendNPlusOneSelection(_ store: SupraStore) throws {
        _ = try store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: "ready-ledger-revision-713-8",
                documentID: Wire.documentID,
                partIndex: 0,
                derivationKey: "T_DATA_READY_01_CONSUMER_DERIVATION_8",
                origin: "user_edit",
                method: "synthetic_manual",
                text: Wire.nextText,
                charCount: Wire.nextText.count,
                toolchainVersion: "T_DATA_READY_01_CONSUMER_TOOLCHAIN_8",
                author: "synthetic-attorney-733",
                reason: "T-DATA-READY-01 consumer N+1 invalidation",
                supersedesRevisionID: Wire.revisionID,
                createdAt: Wire.timestamp.addingTimeInterval(8)
            )
        )
        _ = try store.documentRevisions.appendSelection(
            DocumentPartSelectionRecord(
                id: "ready-ledger-selection-713-8",
                documentID: Wire.documentID,
                partIndex: 0,
                selectedRevisionID: "ready-ledger-revision-713-8",
                selectionKey: "T_DATA_READY_01_CONSUMER_SELECTION_8",
                selectedBy: "synthetic_attorney",
                decisionJSON: #"{"wire":"T_DATA_READY_01_CONSUMER_SELECTION_DECISION_8"}"#,
                supersedesSelectionID: Wire.selectionID,
                createdAt: Wire.timestamp.addingTimeInterval(9)
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
