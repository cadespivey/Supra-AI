import Foundation
import GRDB
import SupraCore
import SupraDocuments
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class CaseFileReviewCreationControllerTests: XCTestCase {
    func testTRPCREATESESS01ExactScopePreviewDisclosesWholeMatterAndSelectedDenominators() throws {
        // T-RP-CREATE-SESS-01 expected RED: no public Review creation controller
        // or exact scope-preview projection exists over CorpusAnalysisExactPlanner.
        let fixture = try makeScopeFixture(testName: "SESS01")
        let controller = makeController(matterID: fixture.matterID, store: fixture.store)

        let wholeMatter = try controller.inspectScope(scope: .wholeMatter)

        XCTAssertEqual(wholeMatter.scope, .wholeMatter)
        XCTAssertEqual(wholeMatter.eligibleCount, 2)
        XCTAssertEqual(wholeMatter.excludedCount, 3)
        XCTAssertEqual(
            wholeMatter.members.map(\.memberKey),
            [
                "document:\(fixture.defaultEligibleID)",
                "document:\(fixture.selectedEligibleID)",
                "document:\(fixture.extractionFailedID)",
                "document:\(fixture.reviewRequiredID)",
                "import-source:\(fixture.unfinishedSourceID)",
            ]
        )
        XCTAssertEqual(
            wholeMatter.members.map(\.displayName),
            [
                "Default Eligible Lease 1101.txt",
                "Selected Atlas Amendment 1201.txt",
                "Failed Scan 1401.pdf",
                "Review Required Exhibit 1301.pdf",
                "Unfinished Import 1501.msg",
            ]
        )
        XCTAssertEqual(
            wholeMatter.members.map(\.disposition),
            [.eligible, .eligible, .excluded, .excluded, .excluded]
        )
        XCTAssertEqual(
            wholeMatter.members.map(\.reason),
            [nil, nil, "extraction_failed", "review_required", "copying"]
        )

        let selectedScope = CorpusAnalysisScope(
            schemaVersion: 1,
            documentIDs: [fixture.reviewRequiredID, fixture.selectedEligibleID]
        )
        let selected = try controller.inspectScope(scope: selectedScope)

        XCTAssertEqual(selected.scope, selectedScope)
        XCTAssertEqual(selected.scope.documentIDs, [fixture.reviewRequiredID, fixture.selectedEligibleID])
        XCTAssertEqual(selected.eligibleCount, 1)
        XCTAssertEqual(selected.excludedCount, 1)
        XCTAssertEqual(
            selected.members.map(\.memberKey),
            [
                "document:\(fixture.selectedEligibleID)",
                "document:\(fixture.reviewRequiredID)",
            ]
        )
        XCTAssertEqual(
            selected.members.map(\.reason),
            [nil, "review_required"]
        )
        XCTAssertFalse(
            selected.members.contains { $0.documentID == fixture.defaultEligibleID },
            "the explicit preview must not leak the default whole-matter eligible document"
        )
        XCTAssertFalse(
            selected.members.contains { $0.documentID == fixture.extractionFailedID },
            "the explicit preview must not leak an unselected excluded document"
        )
        XCTAssertFalse(
            selected.members.contains { $0.memberKey == "import-source:\(fixture.unfinishedSourceID)" },
            "documentless whole-matter exclusions do not belong to an explicit document scope"
        )

        // Receipt-polish RED: an all-excluded scope is still a valid source
        // receipt. Hiding its member and reason behind `noEligibleSources`
        // prevents the setup UI from explaining why Start is unavailable.
        let allExcludedScope = CorpusAnalysisScope(
            schemaVersion: 1,
            documentIDs: [fixture.reviewRequiredID]
        )
        let allExcluded = try controller.inspectScope(scope: allExcludedScope)
        XCTAssertEqual(allExcluded.scope, allExcludedScope)
        XCTAssertEqual(allExcluded.eligibleCount, 0)
        XCTAssertEqual(allExcluded.excludedCount, 1)
        XCTAssertEqual(allExcluded.members.map(\.documentID), [fixture.reviewRequiredID])
        XCTAssertEqual(allExcluded.members.map(\.displayName), ["Review Required Exhibit 1301.pdf"])
        XCTAssertEqual(allExcluded.members.map(\.reason), ["review_required"])
    }

    func testTRPCREATESESS02SubmissionFreezesExactNondefaultPayloadAndRejectsInvalidInputBeforeWriting() throws {
        // T-RP-CREATE-SESS-02 expected RED: no app-facing creation method
        // validates setup, prepares the v2 ledger, and enqueues its exact payload.
        let fixture = try makeScopeFixture(testName: "SESS02-success")
        let controller = makeController(matterID: fixture.matterID, store: fixture.store)
        let selectedScope = CorpusAnalysisScope(
            schemaVersion: 1,
            documentIDs: [fixture.selectedEligibleID]
        )

        let submission = try controller.startReview(
            projectName: "  Atlas privilege signals — 2027  \n",
            instruction: "\nExtract every attorney-client communication   and cite its operative indicator.  ",
            scope: selectedScope,
            pinnedModel: Self.pinnedModel
        )

        let counts = try persistedCounts(store: fixture.store)
        XCTAssertEqual(counts.runCount, 1)
        XCTAssertEqual(counts.partitionCount, 1)
        XCTAssertEqual(counts.sliceCount, 1)
        XCTAssertEqual(counts.corpusJobCount, 1)
        let job = try XCTUnwrap(fixture.store.documentJobs.fetchJob(id: submission.jobID))
        let run = try XCTUnwrap(
            fixture.store.corpusAnalysis.fetchRun(
                matterID: fixture.matterID,
                id: submission.runID
            )
        )
        let payloadJSON = try XCTUnwrap(job.payloadJSON)
        let payload = try JSONDecoder().decode(
            CorpusAnalysisJobPayload.self,
            from: Data(payloadJSON.utf8)
        )
        let request = try exhaustiveRequest(from: payload)

        XCTAssertEqual(job.kind, DocumentProcessingJobKind.corpusAnalysis.rawValue)
        XCTAssertEqual(job.status, DocumentProcessingJobStatus.queued.rawValue)
        XCTAssertEqual(job.queuePosition, 0)
        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.runID, submission.runID)
        XCTAssertEqual(payload.runID, run.id)
        XCTAssertEqual(payload.requestDigest, run.requestDigest)
        XCTAssertEqual(payload.requestDigest.count, 64)
        XCTAssertNotEqual(payload.requestDigest, String(repeating: "0", count: 64))
        XCTAssertEqual(payload.pinnedModel, Self.pinnedModel)
        XCTAssertEqual(
            payload.pinnedModel.modelRepository,
            "synthetic/atlas-review-model-nondefault"
        )
        XCTAssertEqual(payload.pinnedModel.modelRevision, Self.pinnedRevision)
        XCTAssertEqual(
            payload.pinnedModel.artifactFingerprintSHA256,
            String(repeating: "a", count: 64)
        )
        XCTAssertNotEqual(payload.pinnedModel, Self.defaultModelCanary)
        XCTAssertEqual(request.taskSchemaVersion, ExhaustiveListTask.schemaVersion)
        XCTAssertEqual(request.promptBuilderVersion, ExhaustiveListTask.promptBuilderVersion)
        XCTAssertEqual(request.runKey, run.runKey)
        XCTAssertEqual(request.matterID, fixture.matterID)
        XCTAssertEqual(request.title, "Atlas privilege signals — 2027")
        XCTAssertEqual(
            request.query,
            "Extract every attorney-client communication and cite its operative indicator."
        )
        XCTAssertEqual(request.scope, selectedScope)
        XCTAssertEqual(request.scope.documentIDs, [fixture.selectedEligibleID])
        XCTAssertEqual(request.characterBudget, 24_000)
        XCTAssertEqual(request.maximumRetryCount, 2)
        XCTAssertFalse(
            request.title.contains("New Review"),
            "the exact title field must contain the non-default project name, not the UI default"
        )
        XCTAssertFalse(
            request.query.contains("Review this matter"),
            "the exact query field must contain the entered instruction, not a default prompt"
        )
        XCTAssertFalse(
            request.scope.documentIDs?.contains(fixture.defaultEligibleID) == true,
            "the exact scope field must not silently widen to the whole matter"
        )
        XCTAssertEqual(run.status, CorpusAnalysisRunStatus.planning.rawValue)
        XCTAssertEqual(run.requestSchemaVersion, 2)
        XCTAssertEqual(run.modelLineageJSON, try canonicalJSON(Self.pinnedModel))
        XCTAssertNil(run.assuranceState)
        XCTAssertNil(run.structuredOutputVersionID)

        try assertRejectedWithoutWrites(
            testName: "SESS02-blank-name",
            expected: .projectNameRequired
        ) { controller, fixture in
            try controller.startReview(
                projectName: " \n\t ",
                instruction: "Extract every nondefault waiver marker.",
                scope: CorpusAnalysisScope(documentIDs: [fixture.selectedEligibleID]),
                pinnedModel: Self.pinnedModel
            )
        }
        try assertRejectedWithoutWrites(
            testName: "SESS02-blank-instruction",
            expected: .instructionRequired
        ) { controller, fixture in
            try controller.startReview(
                projectName: "Waiver review 2202",
                instruction: " \n\t ",
                scope: CorpusAnalysisScope(documentIDs: [fixture.selectedEligibleID]),
                pinnedModel: Self.pinnedModel
            )
        }
        let foreignDocumentID = "foreign-document-canary-2302"
        try assertRejectedWithoutWrites(
            testName: "SESS02-foreign-source",
            expected: .selectedDocumentsUnavailable([foreignDocumentID])
        ) { controller, fixture in
            try controller.startReview(
                projectName: "Foreign scope rejection 2302",
                instruction: "Extract every cross-matter canary.",
                scope: CorpusAnalysisScope(
                    schemaVersion: 1,
                    documentIDs: [fixture.selectedEligibleID, foreignDocumentID]
                ),
                pinnedModel: Self.pinnedModel
            )
        }
        try assertRejectedWithoutWrites(
            testName: "SESS02-missing-model",
            expected: .modelUnavailable
        ) { controller, fixture in
            try controller.startReview(
                projectName: "Missing model rejection 2402",
                instruction: "Extract every unavailable-model canary.",
                scope: CorpusAnalysisScope(documentIDs: [fixture.selectedEligibleID]),
                pinnedModel: nil
            )
        }

        let conflict = try makeScopeFixture(testName: "SESS02-existing-job")
        let conflictController = makeController(matterID: conflict.matterID, store: conflict.store)
        let first = try conflictController.startReview(
            projectName: "Existing nonterminal Review 2502",
            instruction: "Extract every first-job canary.",
            scope: CorpusAnalysisScope(documentIDs: [conflict.selectedEligibleID]),
            pinnedModel: Self.pinnedModel
        )
        XCTAssertNotNil(try conflict.store.documentJobs.fetchJob(id: first.jobID))
        let beforeConflict = try persistedCounts(store: conflict.store)
        XCTAssertThrowsError(
            try conflictController.startReview(
                projectName: "Forbidden second Review 2602",
                instruction: "Extract every second-job canary.",
                scope: CorpusAnalysisScope(documentIDs: [conflict.defaultEligibleID]),
                pinnedModel: Self.pinnedModel
            )
        ) { error in
            XCTAssertEqual(error as? CaseFileReviewCreationError, .reviewAlreadyInProgress)
        }
        XCTAssertEqual(try persistedCounts(store: conflict.store), beforeConflict)
    }

    func testTRPCREATESESS03SubmissionFailureAtomicallyLeavesNoRunLedgerOrQueueJob() throws {
        // T-RP-CREATE-SESS-03 expected RED: no creation controller delegates
        // one fully normalized request to an atomic Store submitter and reports
        // that submitter's rejection without independently pre-persisting work.
        let fixture = try makeScopeFixture(testName: "SESS03")
        let submissionProbe = ReviewSubmissionProbe()
        let controller = makeController(
            matterID: fixture.matterID,
            store: fixture.store,
            submitCorpusAnalysis: { request, pinnedModel, _ in
                submissionProbe.record(request: request, pinnedModel: pinnedModel)
                return nil
            }
        )

        XCTAssertThrowsError(
            try controller.startReview(
                projectName: "Inert enqueue failure 3103",
                instruction: "Extract every inert-run canary and cite it.",
                scope: CorpusAnalysisScope(
                    schemaVersion: 1,
                    documentIDs: [fixture.selectedEligibleID]
                ),
                pinnedModel: Self.pinnedModel
            )
        ) { error in
            XCTAssertEqual(error as? CaseFileReviewCreationError, .submissionFailed)
        }

        XCTAssertEqual(submissionProbe.callCount, 1)
        XCTAssertEqual(submissionProbe.request?.matterID, fixture.matterID)
        XCTAssertEqual(submissionProbe.request?.title, "Inert enqueue failure 3103")
        XCTAssertEqual(
            submissionProbe.request?.query,
            "Extract every inert-run canary and cite it."
        )
        XCTAssertEqual(
            submissionProbe.request?.scope.documentIDs,
            [fixture.selectedEligibleID]
        )
        XCTAssertEqual(submissionProbe.pinnedModel, Self.pinnedModel)
        XCTAssertEqual(try persistedCounts(store: fixture.store), .zero)
        let runs: [CorpusAnalysisRunRecord] = try fixture.store.database.writer.read { db in
            try CorpusAnalysisRunRecord.fetchAll(
                db,
                sql: "SELECT * FROM corpus_analysis_runs WHERE matter_id = ?",
                arguments: [fixture.matterID]
            )
        }
        XCTAssertTrue(runs.isEmpty, "an atomically rejected submission must leave no inert run")
    }

    func testTRPCREATESESS07SelectedScopeRejectsExcludedDocumentBeforeSubmission() throws {
        // T-RP-CREATE-SESS-07 expected RED: startReview rejects only selected
        // IDs missing from the matter. A mixed explicit scope containing one
        // eligible source and one known-but-excluded source is silently narrowed
        // and submitted instead of failing with the excluded document identity.
        let fixture = try makeScopeFixture(testName: "SESS07-excluded-selected-source")
        let submissionProbe = ReviewSubmissionProbe()
        let controller = makeController(
            matterID: fixture.matterID,
            store: fixture.store,
            submitCorpusAnalysis: { request, pinnedModel, _ in
                submissionProbe.record(request: request, pinnedModel: pinnedModel)
                return (
                    runID: "forbidden-excluded-source-run-7107",
                    jobID: "forbidden-excluded-source-job-7207"
                )
            }
        )
        let scope = CorpusAnalysisScope(
            schemaVersion: 1,
            documentIDs: [fixture.selectedEligibleID, fixture.reviewRequiredID]
        )
        let preview = try controller.inspectScope(scope: scope)
        XCTAssertEqual(preview.eligibleCount, 1)
        XCTAssertEqual(preview.excludedCount, 1)
        XCTAssertEqual(
            preview.members.filter { $0.disposition == .excluded }.map(\.documentID),
            [fixture.reviewRequiredID]
        )

        XCTAssertThrowsError(
            try controller.startReview(
                projectName: "Excluded source rejection 7107",
                instruction: "Extract every synthetic excluded-source canary.",
                scope: scope,
                pinnedModel: Self.pinnedModel
            )
        ) { error in
            XCTAssertEqual(
                error as? CaseFileReviewCreationError,
                .selectedDocumentsUnavailable([fixture.reviewRequiredID])
            )
        }
        XCTAssertEqual(
            submissionProbe.callCount,
            0,
            "an explicit scope containing an excluded document must fail before queue submission"
        )
        XCTAssertEqual(try persistedCounts(store: fixture.store), .zero)
    }

    func testTRPCREATESESS08WholeMatterStartRejectsStaleScopeReceiptAndRefreshedRetrySucceeds() throws {
        // T-RP-CREATE-SESS-08 expected RED: startReview has no explicit expected
        // ScopePreview receipt. Whole-matter membership can change after the UI
        // discloses its denominator and before submission without failing closed.
        let fixture = try makeScopeFixture(testName: "SESS08-whole-matter-drift")
        let submissionProbe = ReviewSubmissionProbe()
        let controller = makeController(
            matterID: fixture.matterID,
            store: fixture.store,
            submitCorpusAnalysis: { request, pinnedModel, _ in
                submissionProbe.record(request: request, pinnedModel: pinnedModel)
                return (
                    runID: "scope-receipt-retry-run-8108",
                    jobID: "scope-receipt-retry-job-8208"
                )
            }
        )
        let staleReceipt = try controller.inspectScope(scope: .wholeMatter)
        XCTAssertEqual(staleReceipt.members.count, 5)
        let addedDocument = try insertDocument(
            store: fixture.store,
            matterID: fixture.matterID,
            id: "whole-matter-membership-drift-document-8308",
            name: "Later Added Scope Member 8308.txt",
            text: "LATER-ADDED-WHOLE-MATTER-CANARY-8308",
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed
        )
        let refreshedReceipt = try controller.inspectScope(scope: .wholeMatter)
        XCTAssertNotEqual(refreshedReceipt, staleReceipt)
        XCTAssertEqual(refreshedReceipt.members.count, 6)
        XCTAssertTrue(refreshedReceipt.members.contains {
            $0.documentID == addedDocument.id && $0.revisionIDs == ["revision-\(addedDocument.id)"]
        })

        XCTAssertThrowsError(
            try controller.startReview(
                projectName: "Whole-matter receipt rejection 8108",
                instruction: "Extract every source disclosed in the exact scope receipt.",
                scope: .wholeMatter,
                expectedScopePreview: staleReceipt,
                pinnedModel: Self.pinnedModel
            )
        ) { error in
            XCTAssertEqual(error as? CaseFileReviewCreationError, .scopeChanged)
        }
        XCTAssertEqual(
            submissionProbe.callCount,
            0,
            "membership drift must fail before the atomic submission boundary"
        )
        XCTAssertEqual(try persistedCounts(store: fixture.store), .zero)

        let retry = try controller.startReview(
            projectName: "Whole-matter receipt retry 8408",
            instruction: "Extract every source disclosed in the refreshed exact scope receipt.",
            scope: .wholeMatter,
            expectedScopePreview: refreshedReceipt,
            pinnedModel: Self.pinnedModel
        )
        XCTAssertEqual(retry.runID, "scope-receipt-retry-run-8108")
        XCTAssertEqual(retry.jobID, "scope-receipt-retry-job-8208")
        XCTAssertEqual(submissionProbe.callCount, 1)
        XCTAssertEqual(submissionProbe.request?.scope, .wholeMatter)
        XCTAssertEqual(submissionProbe.pinnedModel, Self.pinnedModel)
    }

    func testTRPCREATESESS09RevisionDriftDuringModelPinFailsBeforeSubmissionAndUnchangedRetrySucceeds() async throws {
        // T-RP-CREATE-SESS-09 expected RED: the model-ID start contract neither
        // accepts a scope receipt nor rechecks exact eligible revision identities
        // after asynchronous pinning. A source edit during pinning can therefore
        // submit a denominator the user never reviewed.
        let fixture = try makeScopeFixture(testName: "SESS09-revision-drift")
        let scope = CorpusAnalysisScope(
            schemaVersion: 1,
            documentIDs: [fixture.selectedEligibleID]
        )
        let submissionProbe = ReviewSubmissionProbe()
        var pinCallCount = 0
        let selectedModelID = ModelID(
            UUID(uuidString: "99999999-0909-4909-8909-999999999999")!
        )
        let controller = makeController(
            matterID: fixture.matterID,
            store: fixture.store,
            makeCorpusAnalysisPinnedModel: { receivedModelID in
                XCTAssertEqual(receivedModelID, selectedModelID)
                pinCallCount += 1
                if pinCallCount == 1 {
                    try self.replaceSelectedRevision(
                        store: fixture.store,
                        documentID: fixture.selectedEligibleID,
                        revisionID: "scope-receipt-replacement-revision-9109",
                        selectionID: "scope-receipt-replacement-selection-9209",
                        text: "REPLACEMENT-ELIGIBLE-REVISION-CANARY-9309"
                    )
                }
                return Self.pinnedModel
            },
            submitCorpusAnalysis: { request, pinnedModel, _ in
                submissionProbe.record(request: request, pinnedModel: pinnedModel)
                return (
                    runID: "revision-receipt-retry-run-9409",
                    jobID: "revision-receipt-retry-job-9509"
                )
            }
        )
        let staleReceipt = try controller.inspectScope(scope: scope)
        XCTAssertEqual(staleReceipt.members.single?.revisionIDs, [
            "revision-\(fixture.selectedEligibleID)"
        ])

        do {
            _ = try await controller.startReview(
                projectName: "Revision receipt rejection 9109",
                instruction: "Extract only the revision identity the user reviewed.",
                scope: scope,
                expectedScopePreview: staleReceipt,
                modelID: selectedModelID
            )
            XCTFail("revision drift after model pinning must reject the stale scope receipt")
        } catch {
            XCTAssertEqual(error as? CaseFileReviewCreationError, .scopeChanged)
        }
        XCTAssertEqual(pinCallCount, 1, "the drift gate must run after the selected model is pinned")
        XCTAssertEqual(
            submissionProbe.callCount,
            0,
            "revision drift must fail before the atomic submission boundary"
        )
        XCTAssertEqual(try persistedCounts(store: fixture.store), .zero)
        let refreshedReceipt = try controller.inspectScope(scope: scope)
        XCTAssertEqual(
            refreshedReceipt.members.single?.revisionIDs,
            ["scope-receipt-replacement-revision-9109"]
        )
        XCTAssertNotEqual(refreshedReceipt, staleReceipt)

        let retry = try await controller.startReview(
            projectName: "Revision receipt retry 9609",
            instruction: "Extract only the refreshed revision identity.",
            scope: scope,
            expectedScopePreview: refreshedReceipt,
            modelID: selectedModelID
        )
        XCTAssertEqual(retry.runID, "revision-receipt-retry-run-9409")
        XCTAssertEqual(retry.jobID, "revision-receipt-retry-job-9509")
        XCTAssertEqual(pinCallCount, 2)
        XCTAssertEqual(submissionProbe.callCount, 1)
        XCTAssertEqual(submissionProbe.request?.scope, scope)
        XCTAssertEqual(submissionProbe.pinnedModel, Self.pinnedModel)
    }

    func testTRPCREATESESS10LateWholeMatterSourceInsideSubmitRejectsApprovedReceiptAtomically() throws {
        // T-RP-CREATE-SESS-10 expected RED: the controller's submit seam does
        // not carry the user-approved canonical receipt to Store, and every
        // submission error is flattened to submissionFailed. An eligible
        // whole-matter document inserted after the controller comparison but
        // before atomic submit can therefore enter an unapproved denominator.
        let fixture = try makeScopeFixture(testName: "SESS10-atomic-receipt-drift")
        let approvedPreview = try makeController(
            matterID: fixture.matterID,
            store: fixture.store
        ).inspectScope(scope: .wholeMatter)
        let approvedReceipt = CorpusAnalysisSnapshot(
            schemaVersion: 2,
            members: approvedPreview.members
        )
        let lateDocumentID = "whole-matter-submit-gap-document-1010"
        var submitCallCount = 0
        var receivedApprovedReceipt: CorpusAnalysisSnapshot?
        let controller = makeController(
            matterID: fixture.matterID,
            store: fixture.store,
            submitCorpusAnalysis: { request, pinnedModel, approvedScopeReceipt in
                submitCallCount += 1
                receivedApprovedReceipt = approvedScopeReceipt
                let insertedLateDocument = try self.insertDocument(
                    store: fixture.store,
                    matterID: fixture.matterID,
                    id: lateDocumentID,
                    name: "Late Eligible Atomic Receipt 1010.txt",
                    text: "LATE-ELIGIBLE-ATOMIC-RECEIPT-CANARY-1010",
                    status: .ready,
                    extractionStatus: .extracted,
                    indexStatus: .textIndexed
                )
                XCTAssertEqual(insertedLateDocument.id, lateDocumentID)
                let prepared = try CorpusAnalysisQueuePreparer(store: fixture.store)
                    .prepareExhaustiveListSubmission(
                        request: request,
                        pinnedModel: pinnedModel
                    )
                let payloadJSON = String(
                    decoding: try JSONEncoder().encode(prepared.payload),
                    as: UTF8.self
                )
                let proposedJob = DocumentProcessingJobRecord(
                    id: prepared.jobID,
                    matterID: request.matterID,
                    kind: DocumentProcessingJobKind.corpusAnalysis.rawValue,
                    payloadJSON: payloadJSON
                )
                let job = try fixture.store.corpusAnalysis.submitPreparedCorpusAnalysis(
                    run: prepared.run,
                    partitions: prepared.partitions,
                    slices: prepared.slices,
                    job: proposedJob,
                    approvedScopeReceipt: approvedScopeReceipt
                )
                return (runID: prepared.run.id, jobID: job.id)
            }
        )

        XCTAssertThrowsError(
            try controller.startReview(
                projectName: "Atomic receipt boundary 1010",
                instruction: "Extract every source from the approved receipt, never a late addition.",
                scope: .wholeMatter,
                expectedScopePreview: approvedPreview,
                pinnedModel: Self.pinnedModel
            )
        ) { error in
            XCTAssertEqual(error as? CaseFileReviewCreationError, .scopeChanged)
        }
        XCTAssertEqual(
            submitCallCount,
            1,
            "the counterexample must enter the submit closure after the controller comparison"
        )
        XCTAssertEqual(receivedApprovedReceipt, approvedReceipt)
        XCTAssertEqual(try persistedCounts(store: fixture.store), .zero)
        XCTAssertEqual(
            try fixture.store.documentLibrary.fetchDocument(id: lateDocumentID)?.displayName,
            "Late Eligible Atomic Receipt 1010.txt",
            "the rejected submission must not roll back the independently committed late source"
        )
        let refreshedPreview = try controller.inspectScope(scope: .wholeMatter)
        XCTAssertEqual(refreshedPreview.eligibleCount, approvedPreview.eligibleCount + 1)
        let refreshedLateMember: CorpusAnalysisSnapshotMember = try XCTUnwrap(
            refreshedPreview.members.first { $0.documentID == lateDocumentID }
        )
        XCTAssertEqual(refreshedLateMember.revisionIDs, ["revision-\(lateDocumentID)"])
        XCTAssertEqual(
            refreshedLateMember.disposition,
            CorpusAnalysisSnapshotDisposition.eligible
        )
    }

    func testTRPCREATESESS06TerminalReviewPermitsASecondDistinctSubmission() throws {
        // T-RP-CREATE-SESS-06 expected RED: no creation controller generates a
        // fresh immutable run identity after prior Review work is terminal. A
        // title-derived or fixed run key would strand the matter after one run.
        let fixture = try makeScopeFixture(testName: "SESS06-terminal-restart")
        let controller = makeController(matterID: fixture.matterID, store: fixture.store)
        let scope = CorpusAnalysisScope(
            schemaVersion: 1,
            documentIDs: [fixture.selectedEligibleID]
        )
        let first = try controller.startReview(
            projectName: "Repeatable Atlas review 6106",
            instruction: "Extract the same renewal deadline after each terminal run.",
            scope: scope,
            pinnedModel: Self.pinnedModel
        )
        let firstRun = try XCTUnwrap(
            fixture.store.corpusAnalysis.fetchRun(
                matterID: fixture.matterID,
                id: first.runID
            )
        )
        let cancelledRun = try fixture.store.corpusAnalysis.cancelRun(
            matterID: fixture.matterID,
            runID: first.runID
        )
        XCTAssertEqual(cancelledRun.status, CorpusAnalysisRunStatus.cancelled.rawValue)
        try fixture.store.documentJobs.cancelJob(id: first.jobID)
        XCTAssertEqual(
            try fixture.store.documentJobs.fetchJob(id: first.jobID)?.status,
            DocumentProcessingJobStatus.cancelled.rawValue
        )

        let second = try controller.startReview(
            projectName: "Repeatable Atlas review 6106",
            instruction: "Extract the same renewal deadline after each terminal run.",
            scope: scope,
            pinnedModel: Self.pinnedModel
        )
        let secondRun = try XCTUnwrap(
            fixture.store.corpusAnalysis.fetchRun(
                matterID: fixture.matterID,
                id: second.runID
            )
        )

        XCTAssertNotEqual(second.runID, first.runID)
        XCTAssertNotEqual(second.jobID, first.jobID)
        XCTAssertNotEqual(secondRun.runKey, firstRun.runKey)
        XCTAssertEqual(secondRun.status, CorpusAnalysisRunStatus.planning.rawValue)
        XCTAssertEqual(try persistedCounts(store: fixture.store).runCount, 2)
        XCTAssertEqual(try persistedCounts(store: fixture.store).corpusJobCount, 2)
    }

    func testTRPCREATESESS04DurableLifecycleProjectionAndActionsRemainMatterAndJobScoped() async throws {
        // T-RP-CREATE-SESS-04 expected RED: Review has no creation controller
        // that reconstructs queue/run state or routes job-scoped lifecycle actions.
        let queued = try makePreparedLifecycleFixture(.queued)
        try assertLifecycle(
            queued,
            expectedState: .queued,
            label: "Queued",
            terminal: 0,
            total: 4,
            queuePosition: 37,
            detail: nil,
            actions: [.cancel]
        )
        let queuedRecorder = ReviewActionRecorder()
        let queuedController = makeController(
            matterID: queued.matterID,
            store: queued.store,
            recorder: queuedRecorder
        )
        queuedController.load()
        let foreignMatter = try queued.store.matters.createMatter(name: "Synthetic foreign action matter")
        let foreignJob = try enqueuePersistedJob(
            store: queued.store,
            matterID: foreignMatter.id,
            payload: queued.payload
        )
        XCTAssertThrowsError(try queuedController.cancel(jobID: foreignJob.id)) { error in
            XCTAssertEqual(
                error as? CaseFileReviewCreationError,
                .jobUnavailable(foreignJob.id)
            )
        }
        XCTAssertTrue(queuedRecorder.actions.isEmpty)
        try queuedController.cancel(jobID: queued.jobID)
        XCTAssertEqual(queuedRecorder.actions, [.init(kind: .cancel, jobID: queued.jobID)])

        let active = try makePreparedLifecycleFixture(.active)
        try assertLifecycle(
            active,
            expectedState: .reviewing,
            label: "Reviewing",
            terminal: 1,
            total: 4,
            queuePosition: 0,
            detail: nil,
            actions: [.pause, .cancel]
        )
        let activeRecorder = ReviewActionRecorder()
        let activeController = makeController(
            matterID: active.matterID,
            store: active.store,
            recorder: activeRecorder
        )
        activeController.load()
        try activeController.pause(jobID: active.jobID)
        try activeController.cancel(jobID: active.jobID)
        XCTAssertEqual(
            activeRecorder.actions,
            [
                .init(kind: .pause, jobID: active.jobID),
                .init(kind: .cancel, jobID: active.jobID),
            ]
        )

        let pausing = try makePreparedLifecycleFixture(.pausing)
        try assertLifecycle(
            pausing,
            pausingJobID: pausing.jobID,
            expectedState: .pausing,
            label: "Pausing",
            terminal: 2,
            total: 4,
            queuePosition: 0,
            detail: nil,
            actions: [.cancel]
        )

        let paused = try makePreparedLifecycleFixture(.paused)
        try assertLifecycle(
            paused,
            expectedState: .paused,
            label: "Paused",
            terminal: 3,
            total: 4,
            queuePosition: 0,
            detail: nil,
            actions: [.resume, .cancel]
        )
        let pausedRecorder = ReviewActionRecorder()
        let pausedController = makeController(
            matterID: paused.matterID,
            store: paused.store,
            recorder: pausedRecorder
        )
        pausedController.load()
        try pausedController.resume(jobID: paused.jobID)
        try pausedController.cancel(jobID: paused.jobID)
        XCTAssertEqual(
            pausedRecorder.actions,
            [
                .init(kind: .resume, jobID: paused.jobID),
                .init(kind: .cancel, jobID: paused.jobID),
            ]
        )

        let failed = try makePreparedLifecycleFixture(.failed)
        try assertLifecycle(
            failed,
            expectedState: .failed,
            label: "Failed",
            terminal: 2,
            total: 4,
            queuePosition: nil,
            detail: "Local model verification failed: synthetic checksum 7314.",
            actions: []
        )

        let cancelled = try makePreparedLifecycleFixture(.cancelled)
        try assertLifecycle(
            cancelled,
            expectedState: .cancelled,
            label: "Cancelled",
            terminal: 4,
            total: 4,
            queuePosition: nil,
            detail: nil,
            actions: []
        )

        let ineligible = try await makeCompletedLifecycleFixture(reviewable: false)
        try assertLifecycle(
            ineligible,
            expectedState: .finished,
            label: "Finished",
            terminal: ineligible.totalPartitions,
            total: ineligible.totalPartitions,
            queuePosition: nil,
            detail: "Finished, but this result is not eligible to open in Review.",
            actions: []
        )
        let ineligibleController = makeController(
            matterID: ineligible.matterID,
            store: ineligible.store
        )
        ineligibleController.load()
        XCTAssertNil(try XCTUnwrap(ineligibleController.runs.single).structuredOutputVersionID)

        let reviewable = try await makeCompletedLifecycleFixture(reviewable: true)
        try assertLifecycle(
            reviewable,
            expectedState: .finished,
            label: "Finished",
            terminal: reviewable.totalPartitions,
            total: reviewable.totalPartitions,
            queuePosition: nil,
            detail: nil,
            actions: [.openResults]
        )
        let reviewableController = makeController(
            matterID: reviewable.matterID,
            store: reviewable.store
        )
        reviewableController.load()
        XCTAssertEqual(
            try XCTUnwrap(reviewableController.runs.single).structuredOutputVersionID,
            reviewable.structuredOutputVersionID
        )
    }

    private static let pinnedRevision = "0123456789abcdef0123456789abcdef01234567"
    private static let pinnedModel = CorpusAnalysisPinnedModel(
        modelRepository: "synthetic/atlas-review-model-nondefault",
        modelRevision: pinnedRevision,
        contentBindingAlgorithm: RuntimeModelContentBinding.fingerprintAlgorithm,
        contentBindingSchemaVersion: RuntimeModelContentBinding.supportedManifestSchemaVersion,
        artifactFingerprintSHA256: String(repeating: "a", count: 64)
    )
    private static let defaultModelCanary = CorpusAnalysisPinnedModel(
        modelRepository: "synthetic/default-chat-model-must-not-run",
        modelRevision: String(repeating: "d", count: 40),
        contentBindingAlgorithm: RuntimeModelContentBinding.fingerprintAlgorithm,
        contentBindingSchemaVersion: RuntimeModelContentBinding.supportedManifestSchemaVersion,
        artifactFingerprintSHA256: String(repeating: "f", count: 64)
    )

    private func makeScopeFixture(testName: String) throws -> ScopeFixture {
        let location = try makeStoreLocation(testName: testName)
        let store = try SupraStore(url: location.databaseURL)
        let matter = try store.matters.createMatter(name: "Synthetic guided Review \(testName)")
        let defaultEligible = try insertDocument(
            store: store,
            matterID: matter.id,
            id: "doc-eligible-default-\(testName.lowercased())",
            name: "Default Eligible Lease 1101.txt",
            text: "DEFAULT-ELIGIBLE-CANARY-1101",
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed
        )
        let selectedEligible = try insertDocument(
            store: store,
            matterID: matter.id,
            id: "doc-eligible-selected-\(testName.lowercased())",
            name: "Selected Atlas Amendment 1201.txt",
            text: "SELECTED-ATLAS-CANARY-1201",
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed
        )
        let extractionFailed = try insertDocument(
            store: store,
            matterID: matter.id,
            id: "doc-extraction-failed-\(testName.lowercased())",
            name: "Failed Scan 1401.pdf",
            text: nil,
            status: .failed,
            extractionStatus: .failed,
            indexStatus: .failed
        )
        let reviewRequired = try insertDocument(
            store: store,
            matterID: matter.id,
            id: "doc-review-required-\(testName.lowercased())",
            name: "Review Required Exhibit 1301.pdf",
            text: nil,
            status: .needsReview,
            extractionStatus: .extracted,
            indexStatus: .textIndexed
        )
        let batch = try store.documentJobs.createBatch(matterID: matter.id)
        let unfinished = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "selection:unfinished-1501",
            sourceDisplayPath: "Unfinished Import 1501.msg",
            sourceBookmark: Data("SYNTHETIC-BOOKMARK-1501".utf8),
            state: .selected
        )
        let copying = try store.documentJobs.markState(sourceID: unfinished.id, state: .copying)
        XCTAssertEqual(copying.state, DocumentImportSourceState.copying.rawValue)

        return ScopeFixture(
            location: location,
            store: store,
            matterID: matter.id,
            defaultEligibleID: defaultEligible.id,
            selectedEligibleID: selectedEligible.id,
            extractionFailedID: extractionFailed.id,
            reviewRequiredID: reviewRequired.id,
            unfinishedSourceID: unfinished.id
        )
    }

    private func assertRejectedWithoutWrites(
        testName: String,
        expected: CaseFileReviewCreationError,
        operation: (
            CaseFileReviewCreationController,
            ScopeFixture
        ) throws -> CaseFileReviewCreationController.Submission
    ) throws {
        let fixture = try makeScopeFixture(testName: testName)
        let controller = makeController(matterID: fixture.matterID, store: fixture.store)
        XCTAssertThrowsError(try operation(controller, fixture)) { error in
            XCTAssertEqual(error as? CaseFileReviewCreationError, expected)
        }
        XCTAssertEqual(try persistedCounts(store: fixture.store), .zero)
    }

    private func makePreparedLifecycleFixture(
        _ scenario: PreparedLifecycleScenario
    ) throws -> LifecycleFixture {
        let location = try makeStoreLocation(testName: "SESS04-\(scenario.rawValue)")
        let store = try SupraStore(url: location.databaseURL)
        let matter = try store.matters.createMatter(
            name: "Synthetic lifecycle \(scenario.rawValue) matter"
        )
        let document = try insertDocument(
            store: store,
            matterID: matter.id,
            id: "lifecycle-document-\(scenario.rawValue)",
            name: "Lifecycle Source \(scenario.rawValue).txt",
            text: String(repeating: "L", count: 337),
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed
        )
        let request = ExhaustiveListQueuedRequest(
            taskSchemaVersion: ExhaustiveListTask.schemaVersion,
            promptBuilderVersion: ExhaustiveListTask.promptBuilderVersion,
            runKey: "guided-review-lifecycle-\(scenario.rawValue)-4404",
            matterID: matter.id,
            title: "Lifecycle \(scenario.rawValue) Review 4404",
            query: "Extract every lifecycle \(scenario.rawValue) canary.",
            scope: CorpusAnalysisScope(schemaVersion: 1, documentIDs: [document.id]),
            characterBudget: 100,
            maximumRetryCount: 3
        )
        let payload = try CorpusAnalysisQueuePreparer(store: store).prepareExhaustiveList(
            request: request,
            pinnedModel: Self.pinnedModel
        )
        let job = try enqueuePersistedJob(store: store, matterID: matter.id, payload: payload)
        let partitions = try store.corpusAnalysis.fetchPartitions(
            matterID: matter.id,
            runID: payload.runID
        )
        XCTAssertEqual(partitions.count, 4, "the lifecycle fixture must pin a 4-partition denominator")

        switch scenario {
        case .queued:
            try store.database.writer.write { db in
                try db.execute(
                    sql: "UPDATE document_processing_jobs SET queue_position = 37 WHERE id = ?",
                    arguments: [job.id]
                )
            }
        case .active:
            try markSucceeded(
                count: 1,
                partitions: partitions,
                matterID: matter.id,
                runID: payload.runID,
                store: store
            )
            let activated = try XCTUnwrap(store.documentJobs.activateNextJobIfIdle())
            XCTAssertEqual(activated.id, job.id)
            try store.documentJobs.updateJobProgress(id: job.id, phase: .analyzingCorpus)
        case .pausing:
            try markSucceeded(
                count: 2,
                partitions: partitions,
                matterID: matter.id,
                runID: payload.runID,
                store: store
            )
            let activated = try XCTUnwrap(store.documentJobs.activateNextJobIfIdle())
            XCTAssertEqual(activated.id, job.id)
            try store.documentJobs.updateJobProgress(id: job.id, phase: .analyzingCorpus)
        case .paused:
            try markSucceeded(
                count: 3,
                partitions: partitions,
                matterID: matter.id,
                runID: payload.runID,
                store: store
            )
            try store.documentJobs.pauseJob(id: job.id)
        case .failed:
            try markSucceeded(
                count: 1,
                partitions: partitions,
                matterID: matter.id,
                runID: payload.runID,
                store: store
            )
            let failedPartition = partitions[1]
            let begun = try store.corpusAnalysis.beginAttempt(
                matterID: matter.id,
                runID: payload.runID,
                partitionID: failedPartition.id
            )
            XCTAssertEqual(begun.id, failedPartition.id)
            let retryScheduled = try store.corpusAnalysis.completeAttemptFailed(
                matterID: matter.id,
                runID: payload.runID,
                partitionID: failedPartition.id,
                retryable: false,
                errorSummary: "Synthetic mapper rejection 7314.",
                maximumRetryCount: 3
            )
            XCTAssertFalse(retryScheduled)
            let failedRun = try store.corpusAnalysis.updateStatus(
                matterID: matter.id,
                runID: payload.runID,
                to: .failed
            )
            XCTAssertEqual(failedRun.status, CorpusAnalysisRunStatus.failed.rawValue)
            try store.documentJobs.failJob(
                id: job.id,
                errorSummary: "Local model verification failed: synthetic checksum 7314."
            )
        case .cancelled:
            let cancelledRun = try store.corpusAnalysis.cancelRun(
                matterID: matter.id,
                runID: payload.runID
            )
            XCTAssertEqual(cancelledRun.status, CorpusAnalysisRunStatus.cancelled.rawValue)
            try store.documentJobs.cancelJob(id: job.id)
        }
        let coverage = try store.corpusAnalysis.coverage(
            matterID: matter.id,
            runID: payload.runID
        )
        XCTAssertEqual(coverage.partitionCount, 4)
        return LifecycleFixture(
            location: location,
            store: store,
            matterID: matter.id,
            payload: payload,
            jobID: job.id,
            totalPartitions: coverage.partitionCount,
            structuredOutputVersionID: nil
        )
    }

    private func makeCompletedLifecycleFixture(
        reviewable: Bool
    ) async throws -> LifecycleFixture {
        let suffix = reviewable ? "reviewable" : "ineligible"
        let location = try makeStoreLocation(testName: "SESS04-\(suffix)")
        let store = try SupraStore(url: location.databaseURL)
        let matter = try store.matters.createMatter(name: "Synthetic completed \(suffix) matter")
        let eligible = try insertDocument(
            store: store,
            matterID: matter.id,
            id: "completed-\(suffix)-eligible-document",
            name: "Completed \(suffix) source.txt",
            text: "COMPLETED-\(suffix.uppercased())-SOURCE-CANARY-8404",
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed
        )
        if !reviewable {
            let excluded = try insertDocument(
                store: store,
                matterID: matter.id,
                id: "completed-ineligible-excluded-document",
                name: "Excluded Completion Scan 8504.pdf",
                text: nil,
                status: .needsReview,
                extractionStatus: .extracted,
                indexStatus: .textIndexed
            )
            XCTAssertEqual(excluded.status, MatterDocumentStatus.needsReview.rawValue)
        }
        let title = reviewable
            ? "Reviewable completion 8604"
            : "Ineligible completion 8704"
        let query = reviewable
            ? "Extract every reviewable completion canary."
            : "Extract every ineligible completion canary."
        let scope = CorpusAnalysisScope.wholeMatter
        let modelLineageJSON = try canonicalJSON(Self.pinnedModel)
        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "guided-review-completed-\(suffix)-8804",
                matterID: matter.id,
                title: title,
                query: query,
                scope: scope,
                characterBudget: 4_219,
                maximumRetryCount: 3,
                modelLineageJSON: modelLineageJSON
            )
        ) { _ in
            #"{"schema_version":1,"items":[]}"#
        }
        XCTAssertEqual(result.coverage.eligibleMemberCount, 1)
        XCTAssertEqual(result.coverage.excludedMemberCount, reviewable ? 0 : 1)
        let admitted = try store.corpusAnalysis.fetchExactReviewRun(
            matterID: matter.id,
            structuredOutputVersionID: result.version.id
        )
        if reviewable {
            XCTAssertEqual(admitted?.id, result.run.id)
        } else {
            XCTAssertNil(admitted)
        }
        let digest = try XCTUnwrap(result.run.requestDigest)
        let payload = CorpusAnalysisJobPayload(
            schemaVersion: 2,
            runID: result.run.id,
            requestDigest: digest,
            task: .exhaustiveList(ExhaustiveListQueuedRequest(
                taskSchemaVersion: ExhaustiveListTask.schemaVersion,
                promptBuilderVersion: ExhaustiveListTask.promptBuilderVersion,
                runKey: result.run.runKey,
                matterID: matter.id,
                title: title,
                query: query,
                scope: scope,
                characterBudget: 4_219,
                maximumRetryCount: 3
            )),
            pinnedModel: Self.pinnedModel
        )
        let job = try enqueuePersistedJob(store: store, matterID: matter.id, payload: payload)
        try store.documentJobs.completeJob(id: job.id)
        XCTAssertEqual(
            try store.documentJobs.fetchJob(id: job.id)?.status,
            DocumentProcessingJobStatus.complete.rawValue
        )
        return LifecycleFixture(
            location: location,
            store: store,
            matterID: matter.id,
            payload: payload,
            jobID: job.id,
            totalPartitions: result.coverage.partitionCount,
            structuredOutputVersionID: reviewable ? result.version.id : nil
        )
    }

    private func assertLifecycle(
        _ fixture: LifecycleFixture,
        pausingJobID: String? = nil,
        expectedState: CaseFileReviewCreationController.LifecycleState,
        label: String,
        terminal: Int,
        total: Int,
        queuePosition: Int?,
        detail: String?,
        actions: Set<CaseFileReviewCreationController.Action>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let initial = makeController(
            matterID: fixture.matterID,
            store: fixture.store,
            pausingJobID: { pausingJobID }
        )
        initial.load()
        let projected = try XCTUnwrap(initial.runs.single, file: file, line: line)

        XCTAssertEqual(projected.jobID, fixture.jobID, file: file, line: line)
        XCTAssertEqual(projected.runID, fixture.payload.runID, file: file, line: line)
        XCTAssertEqual(projected.state, expectedState, file: file, line: line)
        XCTAssertEqual(projected.statusLabel, label, file: file, line: line)
        XCTAssertEqual(projected.terminalPartitionCount, terminal, file: file, line: line)
        XCTAssertEqual(projected.partitionCount, total, file: file, line: line)
        XCTAssertEqual(projected.queuePosition, queuePosition, file: file, line: line)
        XCTAssertEqual(projected.detail, detail, file: file, line: line)
        XCTAssertEqual(projected.availableActions, actions, file: file, line: line)
        XCTAssertFalse(
            projected.progressLabel.contains("documents"),
            "Review progress must describe terminal partitions, not relabel them as documents",
            file: file,
            line: line
        )
        XCTAssertEqual(
            projected.progressLabel,
            "\(terminal) of \(total) partitions",
            file: file,
            line: line
        )

        let reopenedStore = try SupraStore(url: fixture.location.databaseURL)
        let reopened = makeController(
            matterID: fixture.matterID,
            store: reopenedStore,
            pausingJobID: { pausingJobID }
        )
        reopened.load()
        XCTAssertEqual(reopened.runs, initial.runs, file: file, line: line)
    }

    private func markSucceeded(
        count: Int,
        partitions: [CorpusAnalysisPartitionRecord],
        matterID: String,
        runID: String,
        store: SupraStore
    ) throws {
        let running = try store.corpusAnalysis.updateStatus(
            matterID: matterID,
            runID: runID,
            to: .running
        )
        XCTAssertEqual(running.status, CorpusAnalysisRunStatus.running.rawValue)
        for partition in partitions.prefix(count) {
            let begun = try store.corpusAnalysis.beginAttempt(
                matterID: matterID,
                runID: runID,
                partitionID: partition.id
            )
            XCTAssertEqual(begun.id, partition.id)
            try store.corpusAnalysis.completeAttemptSucceeded(
                matterID: matterID,
                runID: runID,
                partitionID: partition.id,
                findingsJSON: "[]"
            )
        }
    }

    private func makeController(
        matterID: String,
        store: SupraStore,
        recorder: ReviewActionRecorder? = nil,
        pausingJobID: @escaping () -> String? = { nil },
        makeCorpusAnalysisPinnedModel: CaseFileReviewCreationController.ManagedModelPinProvider? = nil,
        submitCorpusAnalysis: ((
            ExhaustiveListQueuedRequest,
            CorpusAnalysisPinnedModel,
            CorpusAnalysisSnapshot
        ) throws -> (runID: String, jobID: String)?)? = nil
    ) -> CaseFileReviewCreationController {
        let submit = submitCorpusAnalysis ?? { request, pinnedModel, _ in
            let payload = try CorpusAnalysisQueuePreparer(store: store).prepareExhaustiveList(
                request: request,
                pinnedModel: pinnedModel
            )
            let job = try self.enqueuePersistedJob(
                store: store,
                matterID: request.matterID,
                payload: payload
            )
            return (runID: payload.runID, jobID: job.id)
        }
        return CaseFileReviewCreationController(
            matterID: matterID,
            store: store,
            makeCorpusAnalysisPinnedModel: makeCorpusAnalysisPinnedModel,
            submitCorpusAnalysis: submit,
            pauseCorpusAnalysis: { recorder?.record(.pause, jobID: $0) },
            resumeCorpusAnalysis: { recorder?.record(.resume, jobID: $0) },
            cancelCorpusAnalysis: { recorder?.record(.cancel, jobID: $0) },
            pausingCorpusJobID: pausingJobID
        )
    }

    private func replaceSelectedRevision(
        store: SupraStore,
        documentID: String,
        revisionID: String,
        selectionID: String,
        text: String
    ) throws {
        let previousSelection = try XCTUnwrap(
            store.documentRevisions.fetchSelections(
                documentID: documentID,
                partIndex: 0
            ).last
        )
        let revision = try store.documentRevisions.appendRevision(DocumentPartRevisionRecord(
            id: revisionID,
            documentID: documentID,
            partIndex: 0,
            derivationKey: "guided-review-scope-receipt-replacement-\(revisionID)",
            origin: "synthetic_test",
            method: "user-corrected-text",
            text: text,
            charCount: text.count
        ))
        let selection = try store.documentRevisions.appendSelection(DocumentPartSelectionRecord(
            id: selectionID,
            documentID: documentID,
            partIndex: 0,
            selectedRevisionID: revision.id,
            selectionKey: "guided-review-scope-receipt-selection-\(selectionID)",
            selectedBy: "test",
            decisionJSON: #"{"rule":"scope-receipt-revision-drift"}"#,
            supersedesSelectionID: previousSelection.id
        ))
        XCTAssertEqual(selection.selectedRevisionID, revisionID)
        XCTAssertEqual(
            try store.documentIndex.fetchParts(documentID: documentID).single?.currentRevisionID,
            revisionID
        )
    }

    private func enqueuePersistedJob(
        store: SupraStore,
        matterID: String,
        payload: CorpusAnalysisJobPayload
    ) throws -> DocumentProcessingJobRecord {
        let payloadJSON = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        return try store.documentJobs.enqueueJob(
            matterID: matterID,
            kind: DocumentProcessingJobKind.corpusAnalysis.rawValue,
            payloadJSON: payloadJSON
        )
    }

    private func insertDocument(
        store: SupraStore,
        matterID: String,
        id: String,
        name: String,
        text: String?,
        status: MatterDocumentStatus,
        extractionStatus: DocumentExtractionStatus,
        indexStatus: DocumentIndexStatus
    ) throws -> MatterDocumentRecord {
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            id: "blob-\(id)",
            sha256: "sha-\(id)",
            byteSize: text?.utf8.count ?? 0,
            originalExtension: name.split(separator: ".").last.map(String.init) ?? "txt",
            managedRelativePath: "blobs/\(id)"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            id: id,
            matterID: matterID,
            blobID: blob.id,
            displayName: name,
            status: status.rawValue,
            extractionStatus: extractionStatus.rawValue,
            indexStatus: indexStatus.rawValue
        ))
        if let text {
            let part = DocumentPagePartRecord(
                id: "part-\(id)",
                documentID: document.id,
                partIndex: 0,
                sourceKind: DocumentSourceKind.text.rawValue,
                normalizedText: text,
                charCount: text.count
            )
            let revision = DocumentPartRevisionRecord(
                id: "revision-\(id)",
                documentID: document.id,
                partIndex: 0,
                derivationKey: "guided-review-creation-\(id)",
                origin: "synthetic_test",
                method: "plain-text",
                text: text,
                charCount: text.count
            )
            let selection = DocumentPartSelectionRecord(
                id: "selection-\(id)",
                documentID: document.id,
                partIndex: 0,
                selectedRevisionID: revision.id,
                selectionKey: "guided-review-creation-\(id)",
                selectedBy: "test",
                decisionJSON: #"{"rule":"guided-review-creation-fixture"}"#
            )
            let persisted = try store.documentRevisions.replacePartsAndPersistLineage(
                documentID: document.id,
                parts: [part],
                revisions: [revision],
                selections: [selection]
            )
            XCTAssertTrue(
                persisted.isEmpty,
                "a newly inserted synthetic part has no pre-existing user edit to preserve"
            )
        }
        return document
    }

    private func persistedCounts(store: SupraStore) throws -> PersistedCounts {
        try store.database.writer.read { db in
            PersistedCounts(
                runCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM corpus_analysis_runs") ?? -1,
                partitionCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM corpus_analysis_partitions"
                ) ?? -1,
                sliceCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM corpus_analysis_partition_slices"
                ) ?? -1,
                corpusJobCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM document_processing_jobs WHERE kind = ?",
                    arguments: [DocumentProcessingJobKind.corpusAnalysis.rawValue]
                ) ?? -1
            )
        }
    }

    private func exhaustiveRequest(
        from payload: CorpusAnalysisJobPayload
    ) throws -> ExhaustiveListQueuedRequest {
        if case .exhaustiveList(let request) = payload.task {
            return request
        }
        throw CreationControllerTestError.unexpectedQueuedTask
    }

    private func makeStoreLocation(testName: String) throws -> StoreLocation {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CaseFileReviewCreation-\(testName)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StoreLocation(
            directory: directory,
            databaseURL: directory.appendingPathComponent("test.sqlite")
        )
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private struct StoreLocation {
    var directory: URL
    var databaseURL: URL
}

private struct ScopeFixture {
    var location: StoreLocation
    var store: SupraStore
    var matterID: String
    var defaultEligibleID: String
    var selectedEligibleID: String
    var extractionFailedID: String
    var reviewRequiredID: String
    var unfinishedSourceID: String
}

private struct LifecycleFixture {
    var location: StoreLocation
    var store: SupraStore
    var matterID: String
    var payload: CorpusAnalysisJobPayload
    var jobID: String
    var totalPartitions: Int
    var structuredOutputVersionID: String?
}

private struct PersistedCounts: Equatable {
    var runCount: Int
    var partitionCount: Int
    var sliceCount: Int
    var corpusJobCount: Int

    static let zero = PersistedCounts(
        runCount: 0,
        partitionCount: 0,
        sliceCount: 0,
        corpusJobCount: 0
    )
}

private enum PreparedLifecycleScenario: String {
    case queued
    case active
    case pausing
    case paused
    case failed
    case cancelled
}

private enum RecordedReviewActionKind: Equatable {
    case pause
    case resume
    case cancel
}

private struct RecordedReviewAction: Equatable {
    var kind: RecordedReviewActionKind
    var jobID: String
}

@MainActor
private final class ReviewActionRecorder {
    private(set) var actions: [RecordedReviewAction] = []

    func record(_ kind: RecordedReviewActionKind, jobID: String) {
        actions.append(RecordedReviewAction(kind: kind, jobID: jobID))
    }
}

@MainActor
private final class ReviewSubmissionProbe {
    private(set) var callCount = 0
    private(set) var request: ExhaustiveListQueuedRequest?
    private(set) var pinnedModel: CorpusAnalysisPinnedModel?

    func record(
        request: ExhaustiveListQueuedRequest,
        pinnedModel: CorpusAnalysisPinnedModel
    ) {
        callCount += 1
        self.request = request
        self.pinnedModel = pinnedModel
    }
}

private enum CreationControllerTestError: Error {
    case unexpectedQueuedTask
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
