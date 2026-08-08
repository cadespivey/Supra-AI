import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class CaseFileReviewControllerTests: XCTestCase {
    private static let modelLineageJSON = #"{"artifact_fingerprint_sha256":"7777777777777777777777777777777777777777777777777777777777777777","content_binding_algorithm":"supra-release-model-sha256-v1","content_binding_schema_version":1,"model_repository":"synthetic/review-runtime","model_revision":"0123456789abcdef0123456789abcdef01234567"}"#

    func testTRPSESS01ExactOutputBecomesOneReviewRowWithDistinctEvidenceKinds() async throws {
        // T-RP-SESS-01 expected RED: the persisted exhaustive reconciliation
        // envelope is private and no CaseFileReviewController can project its
        // exact values and supporting/contrary sources into a Review Project.
        let fixture = try await makeExactReviewFixture()
        let reconciliationJSON = try XCTUnwrap(fixture.result.run.reconciliationJSON)
        let snapshot = try JSONDecoder().decode(
            ExhaustiveListReviewSnapshot.self,
            from: Data(reconciliationJSON.utf8)
        )

        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.items.map(\.itemKey), ["repair-obligation-4219"])
        XCTAssertEqual(snapshot.items.first?.values, ["$4,219.00"])
        XCTAssertEqual(snapshot.items.first?.evidence.count, 1)
        XCTAssertEqual(snapshot.items.first?.contraryEvidence.count, 1)

        let controller = CaseFileReviewController(
            matterID: fixture.matterID,
            store: fixture.store
        )
        controller.load()
        XCTAssertEqual(controller.eligibleOutputs.map(\.sourceRunID), [fixture.result.run.id])

        try controller.openReview(
            sourceRunID: fixture.result.run.id,
            title: "Repair duties review"
        )

        let row = try XCTUnwrap(controller.rows.first)
        XCTAssertEqual(controller.rows.count, 1)
        XCTAssertEqual(row.finding, "repair-obligation-4219")
        XCTAssertEqual(row.generatedValues, ["$4,219.00"])
        XCTAssertEqual(row.supportingSourceCount, 1)
        XCTAssertEqual(row.contrarySourceCount, 1)
        XCTAssertNotEqual(row.generatedValues, ["$2,011.00"])

        controller.selectCell(row.cellID)
        XCTAssertEqual(controller.selectedEvidence.count, 2)
        XCTAssertEqual(
            Set(controller.selectedEvidence.map(\.kind)),
            Set([.supporting, .contrary])
        )
        let supporting = try XCTUnwrap(
            controller.selectedEvidence.first { $0.kind == .supporting }
        )
        let contrary = try XCTUnwrap(
            controller.selectedEvidence.first { $0.kind == .contrary }
        )
        XCTAssertEqual(supporting.excerpt, "$4,219.00")
        XCTAssertEqual(contrary.excerpt, "$2,011.00")
        XCTAssertFalse(supporting.excerpt.contains("$2,011.00"))
        XCTAssertFalse(contrary.excerpt.contains("$4,219.00"))
    }

    func testTRPSESS02MarkReviewedSurvivesControllerRecreationWithoutChangingEvidence() async throws {
        // T-RP-SESS-02 expected RED: there is no matter-scoped controller, no
        // auditable Mark Reviewed mutation, and no relaunch reconstruction of
        // selected Review Project rows or exact Sources.
        let fixture = try await makeExactReviewFixture()
        let controller = CaseFileReviewController(
            matterID: fixture.matterID,
            store: fixture.store
        )
        controller.load()
        try controller.openReview(
            sourceRunID: fixture.result.run.id,
            title: "Persistent review"
        )
        let row = try XCTUnwrap(controller.rows.first)
        controller.selectCell(row.cellID)
        let evidenceBefore = controller.selectedEvidence
        let reviewedAt = Date(timeIntervalSince1970: 2_031_101_719)

        try controller.markReviewed(
            cellID: row.cellID,
            reviewedBy: "attorney-canary-731",
            reviewedAt: reviewedAt
        )

        let reopened = CaseFileReviewController(
            matterID: fixture.matterID,
            store: fixture.store
        )
        reopened.load()
        let reopenedRow = try XCTUnwrap(reopened.rows.first)
        reopened.selectCell(reopenedRow.cellID)

        XCTAssertEqual(reopenedRow.reviewState, .reviewed)
        XCTAssertEqual(reopenedRow.reviewedBy, "attorney-canary-731")
        XCTAssertEqual(reopenedRow.reviewedAt, reviewedAt)
        XCTAssertEqual(reopenedRow.generatedValues, ["$4,219.00"])
        XCTAssertEqual(reopened.selectedEvidence, evidenceBefore)
        XCTAssertEqual(reopened.selectedEvidence.map(\.excerpt), ["$4,219.00", "$2,011.00"])
    }

    func testTRPSESS03LegacyAndUnlinkedExhaustiveOutputsStayIneligible() async throws {
        // T-RP-SESS-03 expected RED: without a fail-closed eligibility boundary,
        // the UI could offer any exhaustive-looking output even when no unique
        // exact v2 run and attached source proof authorize a Review Project.
        let fixture = try await makeExactReviewFixture()
        let legacy = try fixture.store.structuredOutputs.createOutput(
            matterID: fixture.matterID,
            title: "Legacy exhaustive-looking output",
            outputType: .documentExhaustiveList
        )
        _ = try fixture.store.structuredOutputs.createVersion(
            structuredOutputID: legacy.id,
            contentMarkdown: "Legacy content without exact run proof",
            requiredSections: [],
            presentSections: [],
            missingSections: [],
            assuranceState: .preliminary
        )
        let controller = CaseFileReviewController(
            matterID: fixture.matterID,
            store: fixture.store
        )

        controller.load()

        XCTAssertEqual(controller.eligibleOutputs.count, 1)
        XCTAssertEqual(controller.eligibleOutputs.first?.sourceRunID, fixture.result.run.id)
        XCTAssertFalse(controller.eligibleOutputs.contains { $0.outputID == legacy.id })
        XCTAssertThrowsError(
            try controller.openReview(
                sourceRunID: "missing-exact-run-canary-991",
                title: "Must not open"
            )
        )
        XCTAssertTrue(controller.projects.isEmpty)
    }

    func testTRPSESS04MarkReviewedUsesTrimmedLocalProfileIdentity() async throws {
        // T-RP-SESS-04 expected RED: the native Review action supplies the
        // literal actor "user" instead of deriving the durable reviewer identity
        // from the local profile with Supra's established fallback policy.
        let fixture = try await makeExactReviewFixture()
        var profile = AssistantProfile()
        profile.fullName = "  Casey Finch  \n"
        try fixture.store.appSettings.setSetting(AssistantProfile.profileKey, value: profile)
        let controller = CaseFileReviewController(
            matterID: fixture.matterID,
            store: fixture.store
        )
        controller.load()
        try controller.openReview(
            sourceRunID: fixture.result.run.id,
            title: "Profile-bound review"
        )
        let row = try XCTUnwrap(controller.rows.first)

        try controller.markReviewed(cellID: row.cellID)

        let reviewed = try XCTUnwrap(controller.rows.first)
        XCTAssertEqual(reviewed.reviewState, .reviewed)
        XCTAssertEqual(reviewed.reviewedBy, "Casey Finch")
        XCTAssertNotEqual(reviewed.reviewedBy, "user")
    }

    private func makeExactReviewFixture() async throws -> ReviewControllerFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CaseFileReviewController-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
        let matter = try store.matters.createMatter(name: "Synthetic Review Controller Matter")
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            text: "Repair obligation: $4,219.00. Contrary schedule amount: $2,011.00."
        )
        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "review-controller-\(UUID().uuidString)",
                matterID: matter.id,
                title: "Repair obligations",
                query: "Extract the exact repair obligation and retain contrary amounts.",
                characterBudget: 4_219,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            let source = try XCTUnwrap(input.partition.sources.first)
            let supportingRange = try XCTUnwrap(
                Self.characterRange(of: "$4,219.00", in: source.text)
            )
            let contraryRange = try XCTUnwrap(
                Self.characterRange(of: "$2,011.00", in: source.text)
            )
            let supporting = CorpusAnalysisEvidenceReference(
                documentID: source.documentID,
                revisionID: source.revisionID,
                locatorJSON: source.locatorJSON,
                quote: "$4,219.00",
                charStart: supportingRange.lowerBound,
                charEnd: supportingRange.upperBound
            )
            let contrary = CorpusAnalysisEvidenceReference(
                documentID: source.documentID,
                revisionID: source.revisionID,
                locatorJSON: source.locatorJSON,
                quote: "$2,011.00",
                charStart: contraryRange.lowerBound,
                charEnd: contraryRange.upperBound
            )
            let payload = ReviewMapResponse(items: [ReviewMapItem(
                itemKey: "repair-obligation-4219",
                value: "$4,219.00",
                evidence: [supporting],
                contraryEvidence: [contrary]
            )])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(payload), as: UTF8.self)
        }
        return ReviewControllerFixture(
            store: store,
            matterID: matter.id,
            result: result
        )
    }

    private func insertDocument(
        store: SupraStore,
        matterID: String,
        text: String
    ) throws -> String {
        let key = "review-controller-\(UUID().uuidString)"
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: key,
            byteSize: text.utf8.count,
            originalExtension: "txt",
            managedRelativePath: "blobs/\(key).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID,
            blobID: blob.id,
            displayName: "Repair Schedule 4219.txt",
            status: MatterDocumentStatus.ready.rawValue,
            extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            indexStatus: DocumentIndexStatus.textIndexed.rawValue
        ))
        let part = DocumentPagePartRecord(
            id: "\(key)-part",
            documentID: document.id,
            partIndex: 0,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count
        )
        let revision = DocumentPartRevisionRecord(
            id: "\(key)-revision",
            documentID: document.id,
            partIndex: 0,
            derivationKey: "synthetic-review-controller",
            origin: "synthetic_test",
            method: "plain-text",
            text: text,
            charCount: text.count
        )
        let selection = DocumentPartSelectionRecord(
            id: "\(key)-selection",
            documentID: document.id,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "synthetic-review-controller",
            selectedBy: "test",
            decisionJSON: #"{"rule":"fixture"}"#
        )
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: [part],
            revisions: [revision],
            selections: [selection]
        )
        return document.id
    }

    nonisolated private static func characterRange(
        of quote: String,
        in value: String
    ) -> Range<Int>? {
        guard let range = value.range(of: quote) else { return nil }
        return value.distance(from: value.startIndex, to: range.lowerBound)
            ..< value.distance(from: value.startIndex, to: range.upperBound)
    }
}

private struct ReviewControllerFixture {
    let store: SupraStore
    let matterID: String
    let result: ExhaustiveListResult
}

private struct ReviewMapResponse: Encodable {
    var schemaVersion = 1
    var items: [ReviewMapItem]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case items
    }
}

private struct ReviewMapItem: Encodable {
    var itemKey: String
    var value: String
    var evidence: [CorpusAnalysisEvidenceReference]
    var contraryEvidence: [CorpusAnalysisEvidenceReference]

    private enum CodingKeys: String, CodingKey {
        case itemKey = "item_key"
        case value
        case evidence
        case contraryEvidence = "contrary_evidence"
    }
}
