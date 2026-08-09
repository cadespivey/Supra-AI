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

    func testTRPSESS05AttorneyValueEditAndRestoreProjectThroughTheExactCell() async throws {
        // T-RP-SESS-05 expected RED: Review rows do not expose a typed effective-value
        // projection, and the controller has no cell-scoped edit/reset actions that
        // preserve frozen proof while clearing a prior review attestation.
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
            title: "Editable Review value"
        )
        let original = try XCTUnwrap(
            controller.rows.first { $0.finding == "repair-obligation-4219" }
        )
        XCTAssertEqual(controller.rows.map(\.cellID), [original.cellID])
        XCTAssertEqual(original.valueState, .generated)
        XCTAssertNil(original.attorneyValue)
        XCTAssertEqual(original.displayValue, "$4,219.00")
        XCTAssertFalse(original.displayValue.contains("105 calendar days after written notice"))

        controller.selectCell(original.cellID)
        let evidenceBefore = controller.selectedEvidence
        let generatedBefore = original.generatedValues
        let supportingBefore = original.supportingSourceCount
        let contraryBefore = original.contrarySourceCount
        let reviewedAt = Date(timeIntervalSince1970: 2_031_102_005)
        try controller.markReviewed(
            cellID: original.cellID,
            reviewedBy: "attorney-review-canary-2005",
            reviewedAt: reviewedAt
        )
        XCTAssertEqual(
            try XCTUnwrap(controller.rows.first { $0.cellID == original.cellID }).reviewState,
            .reviewed
        )

        let editedAt = Date(timeIntervalSince1970: 2_031_102_011)
        try controller.editValue(
            cellID: original.cellID,
            value: "  105 calendar days after written notice  \n",
            at: editedAt
        )

        let edited = try XCTUnwrap(controller.rows.first { $0.cellID == original.cellID })
        XCTAssertEqual(edited.cellID, original.cellID)
        XCTAssertEqual(edited.finding, "repair-obligation-4219")
        XCTAssertEqual(edited.valueState, .edited)
        XCTAssertEqual(edited.attorneyValue, "105 calendar days after written notice")
        XCTAssertEqual(edited.displayValue, "105 calendar days after written notice")
        XCTAssertFalse(edited.displayValue.contains("$4,219.00"))
        XCTAssertEqual(edited.generatedValues, generatedBefore)
        XCTAssertEqual(edited.supportingSourceCount, supportingBefore)
        XCTAssertEqual(edited.contrarySourceCount, contraryBefore)
        XCTAssertEqual(edited.reviewState, .needsReview)
        XCTAssertNil(edited.reviewedBy)
        XCTAssertNil(edited.reviewedAt)
        XCTAssertEqual(controller.selectedCellID, original.cellID)
        XCTAssertEqual(controller.selectedEvidence, evidenceBefore)
        let editAudit = try XCTUnwrap(
            try fixture.store.auditEvents.fetchEvents(
                relatedTable: "case_file_review_cells",
                relatedID: original.cellID,
                eventType: "case_file_review_cell_value_edited"
            ).first
        )
        XCTAssertEqual(editAudit.actor, "Casey Finch")
        XCTAssertEqual(editAudit.timestamp, editedAt)
        XCTAssertNotEqual(editAudit.actor, "  Casey Finch  \n")

        let reopened = CaseFileReviewController(
            matterID: fixture.matterID,
            store: fixture.store
        )
        reopened.load()
        let persisted = try XCTUnwrap(reopened.rows.first { $0.cellID == original.cellID })
        XCTAssertEqual(persisted.valueState, .edited)
        XCTAssertEqual(persisted.attorneyValue, "105 calendar days after written notice")
        XCTAssertEqual(persisted.displayValue, "105 calendar days after written notice")
        XCTAssertEqual(persisted.generatedValues, generatedBefore)
        reopened.selectCell(original.cellID)
        XCTAssertEqual(reopened.selectedEvidence, evidenceBefore)
        try reopened.markReviewed(
            cellID: original.cellID,
            reviewedBy: "attorney-edited-review-canary-2023",
            reviewedAt: Date(timeIntervalSince1970: 2_031_102_023)
        )

        let restoredAt = Date(timeIntervalSince1970: 2_031_102_029)
        try reopened.useGeneratedValue(cellID: original.cellID, at: restoredAt)

        let restored = try XCTUnwrap(reopened.rows.first { $0.cellID == original.cellID })
        XCTAssertEqual(restored.cellID, original.cellID)
        XCTAssertEqual(restored.valueState, .generated)
        XCTAssertNil(restored.attorneyValue)
        XCTAssertEqual(restored.displayValue, "$4,219.00")
        XCTAssertFalse(restored.displayValue.contains("105 calendar days after written notice"))
        XCTAssertEqual(restored.generatedValues, generatedBefore)
        XCTAssertEqual(restored.supportingSourceCount, supportingBefore)
        XCTAssertEqual(restored.contrarySourceCount, contraryBefore)
        XCTAssertEqual(restored.reviewState, .needsReview)
        XCTAssertNil(restored.reviewedBy)
        XCTAssertNil(restored.reviewedAt)
        XCTAssertEqual(reopened.selectedCellID, original.cellID)
        XCTAssertEqual(reopened.selectedEvidence, evidenceBefore)
        let restoreAudit = try XCTUnwrap(
            try fixture.store.auditEvents.fetchEvents(
                relatedTable: "case_file_review_cells",
                relatedID: original.cellID,
                eventType: "case_file_review_cell_value_restored"
            ).first
        )
        XCTAssertEqual(restoreAudit.actor, "Casey Finch")
        XCTAssertEqual(restoreAudit.timestamp, restoredAt)
    }

    func testTRPSESS06DerivedProgressAndFiltersKeepReviewAxesIndependent() async throws {
        // T-RP-SESS-06 expected RED: CaseFileReviewController has no typed support
        // state, derived ReviewProgress, or typed row-filter projection. The UI
        // therefore cannot report non-default progress or distinguish an edited
        // row from the union of contrary and unsupported evidence attention.
        let reviewedCellID = "reviewed-clean-cell-canary-6106"
        let editedCellID = "edited-contrary-cell-canary-6206"
        let unsupportedCellID = "unsupported-cell-canary-6306"
        let rows = [
            CaseFileReviewController.Row(
                cellID: reviewedCellID,
                finding: "Reviewed clean finding 6106",
                generatedValues: ["generated-reviewed-canary-6106"],
                attorneyValue: nil,
                supportingSourceCount: 1,
                contrarySourceCount: 0,
                reviewState: .reviewed,
                valueState: .generated,
                supportState: .supported,
                reviewedBy: "Synthetic Reviewer 6106",
                reviewedAt: Date(timeIntervalSince1970: 2_031_106_106)
            ),
            CaseFileReviewController.Row(
                cellID: editedCellID,
                finding: "Edited contrary finding 6206",
                generatedValues: ["generated-edited-canary-6206"],
                attorneyValue: "attorney-override-canary-6206",
                supportingSourceCount: 1,
                contrarySourceCount: 2,
                reviewState: .needsReview,
                valueState: .edited,
                supportState: .supported,
                reviewedBy: nil,
                reviewedAt: nil
            ),
            CaseFileReviewController.Row(
                cellID: unsupportedCellID,
                finding: "Unsupported finding 6306",
                generatedValues: ["generated-unsupported-canary-6306"],
                attorneyValue: nil,
                supportingSourceCount: 0,
                contrarySourceCount: 0,
                reviewState: .needsReview,
                valueState: .generated,
                supportState: .unsupported,
                reviewedBy: nil,
                reviewedAt: nil
            ),
        ]

        let progress = CaseFileReviewController.ReviewProgress(rows: rows)

        XCTAssertEqual(progress.totalCount, 3)
        XCTAssertEqual(progress.reviewedCount, 1)
        XCTAssertEqual(progress.needsReviewCount, 2)
        XCTAssertEqual(progress.editedCount, 1)
        XCTAssertEqual(progress.evidenceAttentionCount, 2)
        XCTAssertNotEqual(progress.reviewedCount, 0)
        XCTAssertNotEqual(progress.evidenceAttentionCount, 0)

        XCTAssertEqual(
            CaseFileReviewController.RowFilter.all.apply(to: rows).map(\.cellID),
            [reviewedCellID, editedCellID, unsupportedCellID]
        )
        let needsReviewIDs = CaseFileReviewController.RowFilter.needsReview
            .apply(to: rows).map(\.cellID)
        XCTAssertEqual(needsReviewIDs, [editedCellID, unsupportedCellID])
        XCTAssertFalse(needsReviewIDs.contains(reviewedCellID))

        let editedIDs = CaseFileReviewController.RowFilter.edited
            .apply(to: rows).map(\.cellID)
        XCTAssertEqual(editedIDs, [editedCellID])
        XCTAssertFalse(editedIDs.contains(reviewedCellID))
        XCTAssertFalse(editedIDs.contains(unsupportedCellID))

        let evidenceAttentionIDs = CaseFileReviewController.RowFilter.evidenceAttention
            .apply(to: rows).map(\.cellID)
        XCTAssertEqual(evidenceAttentionIDs, [editedCellID, unsupportedCellID])
        XCTAssertFalse(evidenceAttentionIDs.contains(reviewedCellID))

        let fixture = try await makeExactReviewFixture()
        let controller = CaseFileReviewController(
            matterID: fixture.matterID,
            store: fixture.store
        )
        controller.load()
        try controller.openReview(
            sourceRunID: fixture.result.run.id,
            title: "Workflow delegate canary review"
        )
        let projectedRow = try XCTUnwrap(controller.rows.first)

        XCTAssertEqual(controller.reviewProgress.totalCount, 1)
        XCTAssertEqual(controller.reviewProgress.reviewedCount, 0)
        XCTAssertEqual(controller.reviewProgress.needsReviewCount, 1)
        XCTAssertEqual(controller.reviewProgress.editedCount, 0)
        XCTAssertEqual(controller.reviewProgress.evidenceAttentionCount, 1)
        XCTAssertEqual(controller.rows(matching: .all).map(\.cellID), [projectedRow.cellID])
        XCTAssertEqual(
            controller.rows(matching: .needsReview).map(\.cellID),
            [projectedRow.cellID]
        )
        XCTAssertEqual(
            controller.rows(matching: .evidenceAttention).map(\.cellID),
            [projectedRow.cellID]
        )
        XCTAssertTrue(controller.rows(matching: .edited).isEmpty)

        try controller.editValue(
            cellID: projectedRow.cellID,
            value: "delegate-attorney-override-canary-6406",
            editedBy: "Synthetic Delegate Reviewer 6406",
            at: Date(timeIntervalSince1970: 2_031_106_406)
        )

        XCTAssertEqual(controller.reviewProgress.totalCount, 1)
        XCTAssertEqual(controller.reviewProgress.reviewedCount, 0)
        XCTAssertEqual(controller.reviewProgress.needsReviewCount, 1)
        XCTAssertEqual(controller.reviewProgress.editedCount, 1)
        XCTAssertEqual(controller.reviewProgress.evidenceAttentionCount, 1)
        XCTAssertEqual(
            controller.rows(matching: .edited).map(\.cellID),
            [projectedRow.cellID]
        )
    }

    func testTRPSESS07FailedProjectSelectionPreservesTheLoadedProjection() async throws {
        // T-RP-SESS-07 expected RED: selectProject currently clears the loaded
        // rows, selected cell, and exact evidence when the requested project is
        // unavailable. A failed switch must leave that current working projection
        // intact and report the rejected non-default project ID instead.
        let fixture = try await makeExactReviewFixture()
        let controller = CaseFileReviewController(
            matterID: fixture.matterID,
            store: fixture.store
        )
        controller.load()
        try controller.openReview(
            sourceRunID: fixture.result.run.id,
            title: "Switch-preservation review"
        )
        let row = try XCTUnwrap(controller.rows.first)
        controller.selectCell(row.cellID)
        let selectedProjectIDBefore = try XCTUnwrap(controller.selectedProjectID)
        let rowsBefore = controller.rows
        let selectedCellIDBefore = try XCTUnwrap(controller.selectedCellID)
        let evidenceBefore = controller.selectedEvidence
        XCTAssertFalse(evidenceBefore.isEmpty, "the selected exact row needs evidence to preserve")
        let unavailableProjectID = "missing-review-project-canary-7307"

        controller.selectProject(unavailableProjectID)

        XCTAssertEqual(controller.selectedProjectID, selectedProjectIDBefore)
        XCTAssertEqual(controller.rows, rowsBefore)
        XCTAssertEqual(controller.selectedCellID, selectedCellIDBefore)
        XCTAssertEqual(controller.selectedEvidence, evidenceBefore)
        XCTAssertEqual(
            controller.message,
            CaseFileReviewControllerError.projectUnavailable(unavailableProjectID)
                .localizedDescription
        )
        XCTAssertNotEqual(controller.selectedProjectID, unavailableProjectID)
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
