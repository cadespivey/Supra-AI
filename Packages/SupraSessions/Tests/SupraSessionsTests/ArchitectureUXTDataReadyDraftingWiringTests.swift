import Foundation
import SupraCore
import SupraStore
@testable import SupraSessions
import XCTest

/// Real drafting-source wiring boundary for T-DATA-READY-01.
///
/// Expected RED: `MotionDraftFactSource` does not expose the canonical Store
/// receipt used to decide `isReady`, and `MotionDraftReadiness` does not expose
/// input-scoped drafting projections. The shipping controller still recomputes
/// fact readiness from raw status/index fields, which incorrectly admits a
/// source whose vectors belong to the wrong active model and cannot distinguish
/// base readiness from the user's source selection.
@MainActor
final class ArchitectureUXTDataReadyDraftingWiringTests: XCTestCase {
    private enum Wire {
        static let matterName = "T_DATA_READY_DRAFTING_MATTER_981"
        static let modelAID = "T_DATA_READY_DRAFTING_MODEL_A_983"
        static let modelARevision = "T_DATA_READY_DRAFTING_MODEL_A_REVISION_29"
        static let modelBID = "T_DATA_READY_DRAFTING_MODEL_B_991"
        static let modelBRevision = "T_DATA_READY_DRAFTING_MODEL_B_REVISION_31"
        static let modelDimension = 7
        static let forbiddenDefault = "DEFAULT-000"
        static let timestamp = Date(timeIntervalSince1970: 1_946_251_981)
    }

    private enum FixtureKind: String, CaseIterable {
        case readySelected
        case readyUnselected
        case wrongActiveModel
        case staleRevision

        var ordinal: Int {
            switch self {
            case .readySelected: 1
            case .readyUnselected: 2
            case .wrongActiveModel: 3
            case .staleRevision: 4
            }
        }

        var documentID: String { "drafting-readiness-\(rawValue)-981" }
        var partID: String { "\(documentID)-part-29" }
        var revisionID: String { "\(documentID)-revision-29" }
        var selectionID: String { "\(documentID)-selection-29" }
        var chunkID: String { "\(documentID)-chunk-29" }
        var text: String {
            "T_DATA_READY_DRAFTING_\(rawValue.uppercased())_WIRE_\(980 + ordinal) states a synthetic allegation."
        }

        var expectedBaseReady: Bool {
            self == .readySelected || self == .readyUnselected
        }

        var expectedPrimaryBaseExclusion: DocumentReadinessExclusionReason? {
            switch self {
            case .readySelected, .readyUnselected:
                nil
            case .wrongActiveModel:
                .semanticIndexIncomplete
            case .staleRevision:
                .staleRevision
            }
        }
    }

    /// Expected RED: raw document/index status makes the wrong-model source look
    /// ready and exposes no receipt identity that can be reconciled with Store.
    func testMotionFactSourcesCarryExactCanonicalDraftingReadiness() throws {
        let fixture = try makeFixture()
        let controller = MatterDraftingController(store: fixture.store)
        let sources = controller.motionFactSources(matterID: fixture.matterID)
        XCTAssertEqual(sources.count, FixtureKind.allCases.count)
        let sourcesByDocumentID = Dictionary(
            uniqueKeysWithValues: sources.map { ($0.documentID, $0) }
        )

        for kind in FixtureKind.allCases {
            let canonical = try fixture.store.documentReadiness.fetchReceipt(
                documentID: kind.documentID
            )
            let source = try XCTUnwrap(
                sourcesByDocumentID[kind.documentID],
                "Drafting omitted the \(kind.rawValue) fact source"
            )
            let projection: DocumentReadinessConsumerProjection = source.readiness

            XCTAssertEqual(projection.consumer, .drafting, kind.rawValue)
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
                [],
                "candidate rows must expose base readiness before input selection policy"
            )
            XCTAssertEqual(source.isReady, kind.expectedBaseReady, kind.rawValue)
            XCTAssertEqual(
                projection.baseReceipt.activeEmbeddingModelID,
                Wire.modelBID,
                "the selected non-default model must survive the real drafting wire"
            )
            XCTAssertEqual(
                projection.baseReceipt.activeEmbeddingModelRevision,
                Wire.modelBRevision,
                kind.rawValue
            )
            XCTAssertFalse(projection.baseReceiptID.contains(kind.text), kind.rawValue)
            XCTAssertFalse(
                projection.baseReceiptID.contains(Wire.forbiddenDefault),
                kind.rawValue
            )
            XCTAssertFalse(source.text.contains(Wire.forbiddenDefault), kind.rawValue)
        }

        let wrongModel = try XCTUnwrap(sourcesByDocumentID[FixtureKind.wrongActiveModel.documentID])
        let wrongModelProjection: DocumentReadinessConsumerProjection = wrongModel.readiness
        XCTAssertFalse(wrongModel.isReady)
        XCTAssertNotNil(wrongModel.blockingReason)
        XCTAssertEqual(wrongModelProjection.primaryBaseExclusion, .semanticIndexIncomplete)

        let stale = try XCTUnwrap(sourcesByDocumentID[FixtureKind.staleRevision.documentID])
        let staleProjection: DocumentReadinessConsumerProjection = stale.readiness
        XCTAssertFalse(stale.isReady)
        XCTAssertEqual(staleProjection.primaryBaseExclusion, .staleRevision)
    }

    /// Expected RED: motion input readiness exposes only prose blockers, so a
    /// base-ready candidate omitted from the input cannot carry the additive,
    /// typed `.missingDraftingSourceSelection` policy without rewriting its
    /// canonical receipt.
    func testMotionInputAddsSelectionPolicyWithoutRelabelingBaseReadiness() throws {
        let fixture = try makeFixture()
        let controller = MatterDraftingController(store: fixture.store)
        let sources = controller.motionFactSources(matterID: fixture.matterID)
        let sourcesByDocumentID = Dictionary(
            uniqueKeysWithValues: sources.map { ($0.documentID, $0) }
        )
        let selectedKinds: [FixtureKind] = [
            .readySelected,
            .wrongActiveModel,
            .staleRevision,
        ]
        let selections = try selectedKinds.map { kind -> MotionDraftFactSourceSelection in
            let source = try XCTUnwrap(sourcesByDocumentID[kind.documentID])
            return MotionDraftFactSourceSelection(
                chunkID: source.chunkID,
                expectedRevisionID: source.documentRevisionID,
                expectedExcerptSHA256: source.excerptSHA256
            )
        }
        let input = MotionToDismissDraftInput(
            parties: [],
            partyRepresented: "Synthetic Defendant 983",
            representedPartyName: "Synthetic Respondent LLC 991",
            recipients: [],
            respondingTo: "Synthetic Complaint 997",
            grounds: ["failure to state a claim"],
            reliefSought: "Dismissal without a fabricated default",
            selectedFacts: selections,
            selectedAuthorities: []
        )

        let readiness = controller.motionReadiness(input: input, matterID: fixture.matterID)
        XCTAssertEqual(readiness.selectedFactCount, selectedKinds.count)
        let inputProjections: [DocumentReadinessConsumerProjection] =
            readiness.factDocumentReadiness
        XCTAssertEqual(inputProjections.count, FixtureKind.allCases.count)
        let projectionsByDocumentID: [String: DocumentReadinessConsumerProjection] = Dictionary(
            uniqueKeysWithValues: inputProjections.map {
                ($0.documentID, $0)
            }
        )

        for kind in FixtureKind.allCases {
            let canonical = try fixture.store.documentReadiness.fetchReceipt(
                documentID: kind.documentID
            )
            let projection = try XCTUnwrap(projectionsByDocumentID[kind.documentID])
            XCTAssertEqual(projection.consumer, .drafting, kind.rawValue)
            XCTAssertEqual(projection.baseReceipt, canonical, kind.rawValue)
            XCTAssertEqual(projection.baseReceiptID, canonical.receiptID, kind.rawValue)
            XCTAssertEqual(projection.isBaseReady, kind.expectedBaseReady, kind.rawValue)
            XCTAssertEqual(
                projection.primaryBaseExclusion,
                kind.expectedPrimaryBaseExclusion,
                kind.rawValue
            )
            XCTAssertFalse(projection.baseReceiptID.contains(Wire.forbiddenDefault))
        }

        let selected = try XCTUnwrap(
            projectionsByDocumentID[FixtureKind.readySelected.documentID]
        )
        XCTAssertTrue(selected.isBaseReady)
        XCTAssertNil(selected.primaryBaseExclusion)
        XCTAssertEqual(selected.taskExclusions, [])
        XCTAssertTrue(selected.isEligibleForTask)

        let unselected = try XCTUnwrap(
            projectionsByDocumentID[FixtureKind.readyUnselected.documentID]
        )
        XCTAssertTrue(unselected.isBaseReady)
        XCTAssertNil(unselected.primaryBaseExclusion)
        XCTAssertEqual(
            unselected.taskExclusions,
            [.missingDraftingSourceSelection]
        )
        XCTAssertFalse(unselected.isEligibleForTask)
        XCTAssertEqual(
            unselected.baseReceiptID,
            try fixture.store.documentReadiness.fetchReceipt(
                documentID: FixtureKind.readyUnselected.documentID
            ).receiptID,
            "selection policy must never mint or rewrite the Store receipt"
        )

        for kind in [FixtureKind.wrongActiveModel, .staleRevision] {
            let projection = try XCTUnwrap(projectionsByDocumentID[kind.documentID])
            XCTAssertEqual(
                projection.taskExclusions,
                [],
                "selected but base-blocked sources must retain their exact base reason"
            )
            XCTAssertFalse(projection.isEligibleForTask)
        }
        XCTAssertFalse(
            inputProjections.description.contains(Wire.forbiddenDefault)
        )
    }

    private func makeFixture() throws -> (store: SupraStore, matterID: String) {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: Wire.matterName)
        try configureEmbeddingModels(store)
        for kind in FixtureKind.allCases {
            try seedDocument(store: store, matterID: matter.id, kind: kind)
        }
        return (store, matter.id)
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
            runtimeFamily: "t-data-ready-drafting-wire-29",
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
                id: "\(kind.documentID)-blob-29",
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
                displayName: "\(kind.rawValue)-drafting-wire-\(980 + kind.ordinal).txt",
                status: MatterDocumentStatus.ready.rawValue,
                extractionStatus: DocumentExtractionStatus.extracted.rawValue,
                indexStatus: DocumentIndexStatus.ready.rawValue,
                sourceKind: DocumentSourceKind.text.rawValue,
                extractionMethod: "T_DATA_READY_DRAFTING_EXTRACTOR_29",
                extractedTextChecksum: String(repeating: String(kind.ordinal + 4), count: 64),
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
                derivationKey: "\(kind.documentID)-derivation-29",
                origin: "parser",
                method: "synthetic_exact_text",
                text: kind.text,
                charCount: kind.text.count,
                toolchainVersion: "T_DATA_READY_DRAFTING_TOOLCHAIN_29",
                createdAt: Wire.timestamp
            )
        )
        _ = try store.documentRevisions.appendSelection(
            DocumentPartSelectionRecord(
                id: kind.selectionID,
                documentID: kind.documentID,
                partIndex: 0,
                selectedRevisionID: kind.revisionID,
                selectionKey: "\(kind.documentID)-selection-key-29",
                selectedBy: "synthetic_policy",
                policyVersion: 29,
                decisionJSON: #"{"wire":"T_DATA_READY_DRAFTING_SELECTION_29"}"#,
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
                    tokenCount: 29,
                    createdAt: Wire.timestamp,
                    updatedAt: Wire.timestamp
                ),
            ]
        )
        let embeddingModelID = kind == .wrongActiveModel
            ? Wire.modelAID
            : Wire.modelBID
        let embeddingModelRevision = kind == .wrongActiveModel
            ? Wire.modelARevision
            : Wire.modelBRevision
        try store.documentIndex.upsertEmbedding(
            DocumentChunkEmbeddingRecord(
                id: "\(kind.documentID)-embedding-29",
                chunkID: kind.chunkID,
                documentID: kind.documentID,
                embeddingModelID: embeddingModelID,
                modelDisplayName: embeddingModelID,
                modelRevision: embeddingModelRevision,
                dimension: Wire.modelDimension,
                normalized: true,
                vector: Self.floatBlob([1, 0, 0, 0, 0, 0, 0]),
                createdAt: Wire.timestamp
            )
        )

        if kind == .staleRevision {
            try appendNPlusOneSelection(store: store, kind: kind)
        }
    }

    private func appendNPlusOneSelection(
        store: SupraStore,
        kind: FixtureKind
    ) throws {
        let nextText = "T_DATA_READY_DRAFTING_N_PLUS_ONE_997 replaces the selected revision."
        let nextRevisionID = "\(kind.documentID)-revision-31"
        _ = try store.documentRevisions.appendRevision(
            DocumentPartRevisionRecord(
                id: nextRevisionID,
                documentID: kind.documentID,
                partIndex: 0,
                derivationKey: "\(kind.documentID)-derivation-31",
                origin: "user_edit",
                method: "synthetic_manual",
                text: nextText,
                charCount: nextText.count,
                toolchainVersion: "T_DATA_READY_DRAFTING_TOOLCHAIN_31",
                author: "synthetic-attorney-997",
                reason: "T-DATA-READY-01 drafting N+1 invalidation",
                supersedesRevisionID: kind.revisionID,
                createdAt: Wire.timestamp.addingTimeInterval(31)
            )
        )
        _ = try store.documentRevisions.appendSelection(
            DocumentPartSelectionRecord(
                id: "\(kind.documentID)-selection-31",
                documentID: kind.documentID,
                partIndex: 0,
                selectedRevisionID: nextRevisionID,
                selectionKey: "\(kind.documentID)-selection-key-31",
                selectedBy: "synthetic_attorney",
                decisionJSON: #"{"wire":"T_DATA_READY_DRAFTING_SELECTION_31"}"#,
                supersedesSelectionID: kind.selectionID,
                createdAt: Wire.timestamp.addingTimeInterval(32)
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
