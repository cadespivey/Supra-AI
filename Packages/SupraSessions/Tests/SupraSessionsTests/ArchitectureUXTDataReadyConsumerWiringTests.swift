import Foundation
import SupraCore
import SupraDocuments
import SupraStore
@testable import SupraSessions
import XCTest

/// Real Documents + Ask wiring boundary for T-DATA-READY-01.
///
/// Expected RED: `MatterDocumentsController` has no `readiness(documentID:)`
/// API, and the `ScopeReadiness` returned by
/// `DocumentQAController.scopeReadiness(scope:)` has no `documentReadiness`
/// projections. Both consumers still derive their visible result independently
/// from raw document/index fields instead of exposing the Store-owned receipt.
@MainActor
final class ArchitectureUXTDataReadyConsumerWiringTests: XCTestCase {
    private enum Wire {
        static let matterName = "T_DATA_READY_CONSUMER_MATTER_811"
        static let modelAID = "T_DATA_READY_CONSUMER_MODEL_A_811"
        static let modelARevision = "T_DATA_READY_CONSUMER_MODEL_A_REVISION_17"
        static let modelBID = "T_DATA_READY_CONSUMER_MODEL_B_823"
        static let modelBRevision = "T_DATA_READY_CONSUMER_MODEL_B_REVISION_19"
        static let modelDimension = 7
        static let forbiddenDefault = "DEFAULT-000"
        static let timestamp = Date(timeIntervalSince1970: 1_946_248_811)
    }

    private enum FixtureKind: String, CaseIterable {
        case ready
        case textOnly
        case wrongModel
        case extractionFailed
        case needsReview
        case staleRevision

        var ordinal: Int {
            switch self {
            case .ready: 1
            case .textOnly: 2
            case .wrongModel: 3
            case .extractionFailed: 4
            case .needsReview: 5
            case .staleRevision: 6
            }
        }

        var documentID: String {
            "t-data-ready-consumer-\(rawValue)-document-\(810 + ordinal)"
        }

        var partID: String { "\(documentID)-part-17" }
        var revisionID: String { "\(documentID)-revision-17" }
        var selectionID: String { "\(documentID)-selection-17" }
        var chunkID: String { "\(documentID)-chunk-17" }
        var text: String { "T_DATA_READY_CONSUMER_\(rawValue.uppercased())_WIRE_\(810 + ordinal)" }
        var nextText: String { "T_DATA_READY_CONSUMER_\(rawValue.uppercased())_N_PLUS_ONE_\(910 + ordinal)" }

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
        let documents: MatterDocumentsController
        let qa: DocumentQAController
        let storageRoot: URL
    }

    /// Expected RED: neither real consumer exposes its canonical per-document
    /// projection, so the receipt identity and typed primary reason cannot be
    /// compared at the controller boundary used by the app.
    func testDocumentsAndAskExposeTheSameCanonicalReceiptForEveryFixtureState() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let askScope = try XCTUnwrap(
            fixture.qa.scopeReadiness(scope: .wholeMatter),
            "Ask must expose readiness for the selected matter scope"
        )
        XCTAssertEqual(askScope.documentReadiness.count, FixtureKind.allCases.count)
        let askByDocumentID: [String: DocumentReadinessConsumerProjection] = Dictionary(
            uniqueKeysWithValues: askScope.documentReadiness.map { ($0.documentID, $0) }
        )

        for kind in FixtureKind.allCases {
            let canonical = try fixture.store.documentReadiness.fetchReceipt(
                documentID: kind.documentID
            )
            let documentsProjection: DocumentReadinessConsumerProjection = try XCTUnwrap(
                fixture.documents.readiness(documentID: kind.documentID),
                "Documents omitted the \(kind.rawValue) receipt"
            )
            let askProjection: DocumentReadinessConsumerProjection = try XCTUnwrap(
                askByDocumentID[kind.documentID],
                "Ask omitted the \(kind.rawValue) receipt"
            )

            XCTAssertEqual(documentsProjection.consumer, .documents, kind.rawValue)
            XCTAssertEqual(askProjection.consumer, .ask, kind.rawValue)
            XCTAssertEqual(documentsProjection.baseReceipt, canonical, kind.rawValue)
            XCTAssertEqual(askProjection.baseReceipt, canonical, kind.rawValue)
            XCTAssertEqual(
                documentsProjection.baseReceiptID,
                askProjection.baseReceiptID,
                kind.rawValue
            )

            for projection in [documentsProjection, askProjection] {
                XCTAssertEqual(projection.documentID, kind.documentID, kind.rawValue)
                XCTAssertEqual(projection.baseReceiptID, canonical.receiptID, kind.rawValue)
                XCTAssertEqual(projection.isBaseReady, kind.expectedBaseReady, kind.rawValue)
                XCTAssertEqual(
                    projection.primaryBaseExclusion,
                    kind.expectedPrimaryExclusion,
                    kind.rawValue
                )
                XCTAssertEqual(
                    projection.baseReceipt.activeEmbeddingModelID,
                    Wire.modelBID,
                    "the non-default active model must survive the real consumer wire"
                )
                XCTAssertNotEqual(
                    projection.baseReceipt.activeEmbeddingModelID,
                    Wire.forbiddenDefault,
                    kind.rawValue
                )
                XCTAssertFalse(projection.baseReceiptID.contains(kind.text), kind.rawValue)
                XCTAssertFalse(
                    projection.baseReceiptID.contains(Wire.forbiddenDefault),
                    kind.rawValue
                )
                XCTAssertEqual(
                    projection.taskExclusions,
                    [],
                    "base exclusions must not be recast as Ask task exclusions"
                )
                XCTAssertEqual(
                    projection.isEligibleForTask,
                    kind.expectedBaseReady,
                    "empty task policy may include but cannot redefine base readiness"
                )
            }
        }

        XCTAssertEqual(
            askScope.readyDocuments,
            askScope.documentReadiness.filter(\.isBaseReady).count,
            "Ask's visible ready count must be derived from the same receipts it exposes"
        )
        XCTAssertEqual(askScope.readyDocuments, 1)
        XCTAssertFalse(askScope.isFullyReady)
    }

    /// Expected RED: Documents caches raw records and Ask re-derives readiness,
    /// so there is no consumer receipt refresh contract that can prove an N+1
    /// selection replaced every previously green output.
    func testNPlusOneSelectionInvalidatesDocumentsAndAskWithoutAStaleGreenReceipt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }
        let documentID = FixtureKind.ready.documentID

        let canonicalBefore = try fixture.store.documentReadiness.fetchReceipt(
            documentID: documentID
        )
        let documentsBefore: DocumentReadinessConsumerProjection = try XCTUnwrap(
            fixture.documents.readiness(documentID: documentID)
        )
        let askBeforeScope = try XCTUnwrap(
            fixture.qa.scopeReadiness(scope: .wholeMatter)
        )
        let askBefore: DocumentReadinessConsumerProjection = try XCTUnwrap(
            askBeforeScope.documentReadiness.first { $0.documentID == documentID }
        )
        XCTAssertTrue(canonicalBefore.isBaseReady)
        XCTAssertEqual(documentsBefore.baseReceiptID, canonicalBefore.receiptID)
        XCTAssertEqual(askBefore.baseReceiptID, canonicalBefore.receiptID)
        XCTAssertFalse(canonicalBefore.receiptID.contains(Wire.forbiddenDefault))

        try appendNPlusOneSelection(store: fixture.store, kind: .ready)
        fixture.documents.reload()

        let canonicalAfter = try fixture.store.documentReadiness.fetchReceipt(
            documentID: documentID
        )
        let documentsAfter: DocumentReadinessConsumerProjection = try XCTUnwrap(
            fixture.documents.readiness(documentID: documentID)
        )
        let askAfterScope = try XCTUnwrap(
            fixture.qa.scopeReadiness(scope: .wholeMatter)
        )
        let askAfter: DocumentReadinessConsumerProjection = try XCTUnwrap(
            askAfterScope.documentReadiness.first { $0.documentID == documentID }
        )

        XCTAssertNotEqual(canonicalAfter.receiptID, canonicalBefore.receiptID)
        for projection in [documentsAfter, askAfter] {
            XCTAssertEqual(projection.baseReceiptID, canonicalAfter.receiptID)
            XCTAssertNotEqual(projection.baseReceiptID, canonicalBefore.receiptID)
            XCTAssertFalse(projection.isBaseReady)
            XCTAssertEqual(projection.primaryBaseExclusion, .staleRevision)
            XCTAssertEqual(projection.taskExclusions, [])
            XCTAssertFalse(projection.isEligibleForTask)
            XCTAssertFalse(projection.baseReceiptID.contains(FixtureKind.ready.nextText))
            XCTAssertFalse(projection.baseReceiptID.contains(Wire.forbiddenDefault))
        }
        XCTAssertEqual(
            askAfterScope.readyDocuments,
            askAfterScope.documentReadiness.filter(\.isBaseReady).count
        )
        XCTAssertEqual(askAfterScope.readyDocuments, 0)
    }

    private func makeFixture() throws -> Fixture {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: Wire.matterName)
        try configureEmbeddingModels(store)
        for kind in FixtureKind.allCases {
            try seedDocument(store: store, matterID: matter.id, kind: kind)
        }

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TDataReadyConsumerWiring-\(UUID().uuidString)",
                isDirectory: true
            )
        let storage = DocumentStorage(root: storageRoot.appendingPathComponent("Managed"))
        let importService = DocumentImportService(store: store, storage: storage, ocr: nil)
        let queue = DocumentProcessingQueue(
            store: store,
            importService: importService,
            makeIndexingService: { DocumentIndexingService(store: store, embedder: nil) },
            notifier: ConsumerWiringNoopDocumentNotifier()
        )
        let documents = MatterDocumentsController(
            matterID: matter.id,
            store: store,
            queue: queue,
            isImportReady: { true },
            storage: storage
        )
        let qa = DocumentQAController(
            matterID: matter.id,
            store: store,
            runtimeClient: StubRuntimeClient(),
            embedder: nil
        )
        return Fixture(
            store: store,
            matterID: matter.id,
            documents: documents,
            qa: qa,
            storageRoot: storageRoot
        )
    }

    private func configureEmbeddingModels(_ store: SupraStore) throws {
        _ = try store.documentSettings.loadSettings()
        try store.documentSettings.upsertEmbeddingModel(
            embeddingModel(id: Wire.modelAID, revision: Wire.modelARevision)
        )
        try store.documentSettings.upsertEmbeddingModel(
            embeddingModel(id: Wire.modelBID, revision: Wire.modelBRevision)
        )
        try store.documentSettings.selectEmbeddingModel(id: Wire.modelBID)
        try store.documentSettings.updateSettings {
            $0.embeddingModelLastTestedAt = Wire.timestamp
            $0.chunkerVersion = 2
        }
    }

    private func embeddingModel(
        id: String,
        revision: String
    ) -> DocumentEmbeddingModelRecord {
        DocumentEmbeddingModelRecord(
            id: id,
            repoID: "synthetic/\(id)",
            localPath: "/synthetic/\(id)",
            displayName: id,
            dimension: Wire.modelDimension,
            runtimeFamily: "t-data-ready-consumer-wire-17",
            revision: revision,
            isDefault: false,
            isSelected: false,
            lastTestLoadAt: Wire.timestamp,
            lastTestLoadResult: "passed",
            createdAt: Wire.timestamp,
            updatedAt: Wire.timestamp
        )
    }

    private func seedDocument(
        store: SupraStore,
        matterID: String,
        kind: FixtureKind
    ) throws {
        let blob = try store.documentLibrary.upsertBlob(
            DocumentBlobRecord(
                id: "\(kind.documentID)-blob-17",
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
        let status: MatterDocumentStatus = switch kind {
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
                id: kind.documentID,
                matterID: matterID,
                blobID: blob.id,
                displayName: "\(kind.rawValue)-consumer-wire-\(810 + kind.ordinal).txt",
                status: status.rawValue,
                extractionStatus: extractionStatus.rawValue,
                indexStatus: indexStatus.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractionMethod: "T_DATA_READY_CONSUMER_EXTRACTOR_17",
                extractedTextChecksum: String(repeating: String(kind.ordinal + 1), count: 64),
                pagePartCount: 1,
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
                derivationKey: "\(kind.documentID)-derivation-17",
                origin: "parser",
                method: "synthetic_exact_text",
                text: kind.text,
                charCount: kind.text.count,
                toolchainVersion: "T_DATA_READY_CONSUMER_TOOLCHAIN_17",
                createdAt: Wire.timestamp
            )
        )
        _ = try store.documentRevisions.appendSelection(
            DocumentPartSelectionRecord(
                id: kind.selectionID,
                documentID: kind.documentID,
                partIndex: 0,
                selectedRevisionID: kind.revisionID,
                selectionKey: "\(kind.documentID)-selection-key-17",
                selectedBy: "synthetic_policy",
                policyVersion: 17,
                decisionJSON: #"{"wire":"T_DATA_READY_CONSUMER_SELECTION_17"}"#,
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
                    tokenCount: 17,
                    createdAt: Wire.timestamp,
                    updatedAt: Wire.timestamp
                ),
            ]
        )

        if kind != .textOnly {
            let embeddingModelID = kind == .wrongModel ? Wire.modelAID : Wire.modelBID
            let embeddingRevision = kind == .wrongModel
                ? Wire.modelARevision
                : Wire.modelBRevision
            try store.documentIndex.upsertEmbedding(
                DocumentChunkEmbeddingRecord(
                    id: "\(kind.documentID)-embedding-17",
                    chunkID: kind.chunkID,
                    documentID: kind.documentID,
                    embeddingModelID: embeddingModelID,
                    modelDisplayName: embeddingModelID,
                    modelRevision: embeddingRevision,
                    dimension: Wire.modelDimension,
                    normalized: true,
                    vector: Self.floatBlob([1, 0, 0, 0, 0, 0, 0]),
                    createdAt: Wire.timestamp
                )
            )
        }
        if kind == .staleRevision {
            try appendNPlusOneSelection(store: store, kind: kind)
        }
    }

    private func appendNPlusOneSelection(
        store: SupraStore,
        kind: FixtureKind
    ) throws {
        let nextRevisionID = "\(kind.documentID)-revision-19"
        _ = try store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: nextRevisionID,
                documentID: kind.documentID,
                partIndex: 0,
                derivationKey: "\(kind.documentID)-derivation-19",
                origin: "user_edit",
                method: "synthetic_manual",
                text: kind.nextText,
                charCount: kind.nextText.count,
                toolchainVersion: "T_DATA_READY_CONSUMER_TOOLCHAIN_19",
                author: "synthetic-attorney-823",
                reason: "T-DATA-READY-01 real-consumer N+1 invalidation",
                supersedesRevisionID: kind.revisionID,
                createdAt: Wire.timestamp.addingTimeInterval(19)
            )
        )
        _ = try store.documentRevisions.appendSelection(
            DocumentPartSelectionRecord(
                id: "\(kind.documentID)-selection-19",
                documentID: kind.documentID,
                partIndex: 0,
                selectedRevisionID: nextRevisionID,
                selectionKey: "\(kind.documentID)-selection-key-19",
                selectedBy: "synthetic_attorney",
                decisionJSON: #"{"wire":"T_DATA_READY_CONSUMER_SELECTION_19"}"#,
                supersedesSelectionID: kind.selectionID,
                createdAt: Wire.timestamp.addingTimeInterval(20)
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

private final class ConsumerWiringNoopDocumentNotifier: DocumentNotifying, @unchecked Sendable {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .authorized }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .authorized }
    func notify(title: String, body: String) async {}
}
