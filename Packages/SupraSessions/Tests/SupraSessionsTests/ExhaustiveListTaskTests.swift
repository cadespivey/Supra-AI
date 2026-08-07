import CryptoKit
import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class ExhaustiveListTaskTests: XCTestCase {
    private static let modelLineageJSON = #"{"model_repository":"synthetic/exhaustive-runtime","model_revision":"exhaustive-revision-nondefault"}"#

    func testTEVID01ExactQuoteSpanIsValidatedAndLocatorIsDerivedByHost() async throws {
        // T-EVID-01 expected RED: the mapper ignores emitted quote/span fields and
        // persists the model's whole-revision locator/excerpt instead of validating
        // the frozen text and deriving the exact evidence range on the host.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic exact quote evidence")
        let prefix = "PREFIX-219-NONDEFAULT | "
        let exactQuote = "Payment was due on October 17, 2031 in the amount of $731.42."
        let suffix = " | SUFFIX-887-NONDEFAULT"
        let sourceText = prefix + exactQuote + suffix
        let expectedStart = prefix.count
        let expectedEnd = expectedStart + exactQuote.count
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "exact-quote-schedule.txt",
            partTexts: [sourceText]
        )

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "exact-quote-host-derived-locator-run",
                matterID: matter.id,
                title: "Exact quoted payment",
                query: "Extract the exact payment sentence.",
                characterBudget: 1_733,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            try Self.quotedResponse(
                input,
                itemKey: "exact-payment-sentence-219",
                value: exactQuote,
                quote: exactQuote,
                charStart: expectedStart,
                charEnd: expectedEnd
            )
        }

        XCTAssertEqual(result.version.verificationStatus, OutputVerificationStatus.allSupported.rawValue)
        let outputSource = try XCTUnwrap(
            store.documentSources.fetchSources(structuredOutputVersionID: result.version.id).first
        )
        XCTAssertEqual(outputSource.revisionID, fixture.revisionIDs.first)
        let locator = try JSONDecoder().decode(
            DocumentSourceLocator.self,
            from: Data(outputSource.locatorJSON.utf8)
        )
        XCTAssertEqual(locator.charStart, expectedStart)
        XCTAssertNotEqual(locator.charStart, 0, "the old whole-revision locator start must be absent")
        XCTAssertEqual(locator.charEnd, expectedEnd)
        XCTAssertNotEqual(locator.charEnd, sourceText.count, "the old whole-revision locator end must be absent")
        XCTAssertEqual(outputSource.excerpt, exactQuote)

        let verificationJSON = try XCTUnwrap(result.version.verificationJSON)
        let support = try XCTUnwrap(DateCoding.decoder.decode(
            [PropositionSupportResult].self,
            from: Data(verificationJSON.utf8)
        ).first)
        XCTAssertEqual(support.status, .supported)
        XCTAssertEqual(support.evidence.first?.locator, outputSource.locatorJSON)
        XCTAssertEqual(support.evidence.first?.retainedExcerpt, exactQuote)
    }

    func testTEVID02FabricatedValueWithStructurallyValidRevisionEvidenceIsRejected() async throws {
        // T-EVID-02 expected RED: exhaustive-list support treats any structurally
        // valid primary evidence reference as supported without checking whether
        // the frozen source text supports the emitted value.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic fabricated-value rejection")
        let supportedValue = "$731.42"
        let fabricatedValue = "$9,913.77"
        let sourceText = "NONDEFAULT-SCHEDULE-417 states the exact payment amount is \(supportedValue)."
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "payment-schedule.txt",
            partTexts: [sourceText]
        )

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "fabricated-value-host-validation-run",
                matterID: matter.id,
                title: "Validated payment schedule",
                query: "Extract the exact scheduled payment amount.",
                characterBudget: 1_811,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            try Self.response(input, items: [
                .init(
                    itemKey: "scheduled-payment-417",
                    value: fabricatedValue,
                    evidence: [.primary]
                ),
            ])
        }

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.values, [fabricatedValue], "the rejected model value remains visible for review")
        XCTAssertEqual(result.version.verificationStatus, OutputVerificationStatus.needsReview.rawValue)
        XCTAssertNotEqual(result.version.verificationStatus, OutputVerificationStatus.allSupported.rawValue)
        let verificationJSON = try XCTUnwrap(result.version.verificationJSON)
        let supportResults = try DateCoding.decoder.decode(
            [PropositionSupportResult].self,
            from: Data(verificationJSON.utf8)
        )
        let support = try XCTUnwrap(supportResults.first)
        XCTAssertEqual(support.status, .unsupported)
        XCTAssertFalse(support.evidence.isEmpty)
        XCTAssertEqual(support.evidence.first?.sourceID, fixture.revisionIDs.first)
        let retainedExcerpt = try XCTUnwrap(support.evidence.first?.retainedExcerpt)
        XCTAssertTrue(retainedExcerpt.contains(supportedValue))
        XCTAssertFalse(retainedExcerpt.contains(fabricatedValue))
        XCTAssertEqual(
            result.version.verificationDimensions.result(for: .propositionSupport).status,
            .failed
        )
        XCTAssertEqual(
            result.version.verificationDimensions.result(for: .criticalValueFidelity).status,
            .failed
        )
        let output = try XCTUnwrap(store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
    }

    func testTCORP04WholeMatterMembershipAndEligibilityDriftUsesFrozenLineageAndMarksStale() async throws {
        // T-CORP-04 expected RED: staleness compares revision IDs only for frozen
        // eligible members; an added whole-matter source and eligibility change are
        // missed, while output lineage is rebuilt from the mutated live scope.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic frozen scope drift")
        let original = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "frozen-scope-original.txt",
            partTexts: ["FROZEN-SCOPE-VALUE-613-NONDEFAULT"]
        )
        let frozenLineageHash = try Self.wholeMatterLineageHash(store: store, matterID: matter.id)
        let mutation = ListScopeDriftProbe()

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "whole-matter-membership-drift-run",
                matterID: matter.id,
                title: "Frozen-scope lineage review",
                query: "Extract the frozen-scope value.",
                scope: .wholeMatter,
                characterBudget: 1_919,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            if await mutation.claimMutation() {
                let added = try insertListFixtureDocument(
                    store: store,
                    matterID: matter.id,
                    name: "added-after-freeze.txt",
                    partTexts: ["ADDED-IN-SCOPE-VALUE-827-NONDEFAULT"]
                )
                await mutation.recordAddedDocumentID(added.documentID)
                try store.documentLibrary.updateStatus(
                    documentID: original.documentID,
                    status: .needsReview
                )
            }
            return try Self.response(input, items: [
                .init(
                    itemKey: "frozen-scope-value-613",
                    value: "FROZEN-SCOPE-VALUE-613-NONDEFAULT",
                    evidence: [.primary]
                ),
            ])
        }

        let capturedAddedDocumentID = await mutation.addedDocumentID
        let addedDocumentID = try XCTUnwrap(capturedAddedDocumentID)
        let snapshot = try JSONDecoder().decode(
            CorpusAnalysisSnapshot.self,
            from: Data(result.run.corpusSnapshotJSON.utf8)
        )
        XCTAssertEqual(snapshot.members.compactMap(\.documentID), [original.documentID])
        XCTAssertFalse(snapshot.members.compactMap(\.documentID).contains(addedDocumentID))
        XCTAssertEqual(snapshot.members.first?.disposition, .eligible)

        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.stale.rawValue)
        let reasonsJSON = try XCTUnwrap(result.run.assuranceReasonsJSON)
        let reasons = try JSONDecoder().decode([String].self, from: Data(reasonsJSON.utf8))
        XCTAssertTrue(reasons.contains { $0.contains(original.documentID) }, "eligibility drift must name the frozen member")
        XCTAssertTrue(reasons.contains { $0.contains(addedDocumentID) }, "membership drift must name the added in-scope member")

        let sourceSet = try XCTUnwrap(store.documentSources.fetchSourceSet(
            structuredOutputVersionID: result.version.id
        ))
        let persistedLineageHash = try XCTUnwrap(sourceSet.corpusSnapshotHash)
        let mutatedLiveLineageHash = try Self.wholeMatterLineageHash(store: store, matterID: matter.id)
        XCTAssertNotEqual(frozenLineageHash, mutatedLiveLineageHash, "the mutation must change the live-scope hash")
        XCTAssertEqual(persistedLineageHash, frozenLineageHash)
        XCTAssertNotEqual(
            persistedLineageHash,
            mutatedLiveLineageHash,
            "frozen-run lineage must not be silently replaced by current whole-matter membership"
        )

        let outputSources = try store.documentSources.fetchSources(
            structuredOutputVersionID: result.version.id
        )
        XCTAssertEqual(Set(outputSources.compactMap(\.documentID)), [original.documentID])
        XCTAssertFalse(outputSources.compactMap(\.documentID).contains(addedDocumentID))
        XCTAssertEqual(
            try store.documentLibrary.fetchDocument(id: original.documentID)?.status,
            MatterDocumentStatus.needsReview.rawValue
        )
    }

    func testTCORP05ChangedSemanticRequestCannotReuseRunKeyOrAttachedOutput() async throws {
        // T-CORP-05 expected RED: run-key collision checks omit the exhaustive-list
        // query/task request digest, so a changed semantic request silently returns
        // the first run's already-attached output without invoking the generator.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic request digest collision")
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "request-digest-source.txt",
            partTexts: ["REQUEST-DIGEST-VALUE-541-NONDEFAULT"]
        )
        let runKey = "semantic-request-digest-run-key"
        let firstQuery = "Extract the request-digest value 541."
        let changedQuery = "Extract a materially different termination-date field 977."
        let first = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: runKey,
                matterID: matter.id,
                title: "First semantic request",
                query: firstQuery,
                characterBudget: 1_577,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            try Self.response(input, items: [
                .init(
                    itemKey: "request-digest-value-541",
                    value: "REQUEST-DIGEST-VALUE-541-NONDEFAULT",
                    evidence: [.primary]
                ),
            ])
        }
        let beforeRun = try XCTUnwrap(store.corpusAnalysis.fetchRun(matterID: matter.id, id: first.run.id))
        let changedGeneratorProbe = ListGeneratorProbe()
        var secondResult: ExhaustiveListResult?
        var collisionError: CorpusAnalysisEngineError?
        var unexpectedErrorDescription: String?

        do {
            secondResult = try await ExhaustiveListTask(store: store).run(
                request: ExhaustiveListRequest(
                    runKey: runKey,
                    matterID: matter.id,
                    title: "Changed semantic request",
                    query: changedQuery,
                    characterBudget: 1_577,
                    modelLineageJSON: Self.modelLineageJSON
                )
            ) { input in
                await changedGeneratorProbe.recordCall()
                return try Self.response(input, items: [
                    .init(
                        itemKey: "changed-termination-date-977",
                        value: "CHANGED-TERMINATION-DATE-977-NONDEFAULT",
                        evidence: [.primary]
                    ),
                ])
            }
        } catch let error as CorpusAnalysisEngineError {
            collisionError = error
        } catch {
            unexpectedErrorDescription = error.localizedDescription
        }

        XCTAssertNil(secondResult, "a changed request must not reuse the first attached output")
        XCTAssertEqual(collisionError, .runKeyCollision(runKey))
        XCTAssertNil(unexpectedErrorDescription)
        let changedGeneratorCallCount = await changedGeneratorProbe.callCount
        XCTAssertEqual(changedGeneratorCallCount, 0, "collision must fail before generation")
        let afterRun = try XCTUnwrap(store.corpusAnalysis.fetchRun(matterID: matter.id, id: first.run.id))
        XCTAssertEqual(afterRun.structuredOutputVersionID, first.version.id)
        XCTAssertEqual(afterRun.corpusSnapshotJSON, beforeRun.corpusSnapshotJSON)
        XCTAssertEqual(afterRun.reconciliationJSON, beforeRun.reconciliationJSON)
        let outputs = try store.structuredOutputs.fetchOutputs(matterID: matter.id)
        let versions = try store.structuredOutputs.fetchVersions(structuredOutputID: first.outputID)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(versions.map(\.id), [first.version.id])
        let outputSources = try store.documentSources.fetchSources(structuredOutputVersionID: first.version.id)
        XCTAssertEqual(outputSources.compactMap(\.revisionID), fixture.revisionIDs)
        let generationID = try XCTUnwrap(first.version.generationSessionID)
        let generation = try XCTUnwrap(store.generation.fetchGenerationSession(generationID: generationID))
        XCTAssertTrue(generation.prompt.contains(firstQuery))
        XCTAssertFalse(generation.prompt.contains(changedQuery))
    }

    func testTENG09ListReconcilesDuplicatesConflictsContraryEvidenceAndNamedOmissions() async throws {
        // T-ENG-09 expected RED: exhaustive-list schema, reconciliation, metrics, and atomic output linkage are missing.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic exhaustive list")
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "invoice-ledger.txt",
            partTexts: ["MAP-A", "MAP-A-DUPLICATE", "MAP-B-ONE", "MAP-B-CONFLICT-X"]
        )

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "list-quality-run",
                matterID: matter.id,
                title: "Every invoice reference",
                query: "Extract every invoice reference.",
                characterBudget: 1,
                evaluationExpectedItemKeys: ["invoice-a", "invoice-b", "invoice-c"],
                modelLineageJSON: #"{"model_repository":"synthetic/exhaustive-runtime","model_revision":"exhaustive-revision-nondefault"}"#
            )
        ) { input in
            let source = try XCTUnwrap(input.partition.sources.first)
            switch source.text {
            case "MAP-A":
                return try Self.response(input, items: [
                    .init(itemKey: "invoice-a", value: "$100", evidence: [.primary]),
                ])
            case "MAP-A-DUPLICATE":
                return try Self.response(input, items: [
                    .init(itemKey: "invoice-a", value: "$100", evidence: [.primary]),
                ])
            case "MAP-B-ONE":
                return try Self.response(input, items: [
                    .init(itemKey: "invoice-b", value: "$200", evidence: [.primary]),
                ])
            default:
                return try Self.response(input, items: [
                    .init(
                        itemKey: "invoice-b",
                        value: "$250",
                        evidence: [.primary],
                        contraryEvidence: [.primary]
                    ),
                    .init(itemKey: "invoice-x", value: "$999", evidence: [.primary]),
                ])
            }
        }

        XCTAssertEqual(Set(result.items.map(\.itemKey)), ["invoice-a", "invoice-b", "invoice-x"])
        let invoiceB = try XCTUnwrap(result.items.first { $0.itemKey == "invoice-b" })
        XCTAssertEqual(Set(invoiceB.values), ["$200", "$250"])
        XCTAssertEqual(invoiceB.contraryEvidence.count, 1)
        XCTAssertEqual(result.omissions.map(\.itemKey), ["invoice-c"])
        XCTAssertEqual(result.metrics.recall, 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(result.metrics.precision, 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(result.metrics.duplicateCount, 1)
        XCTAssertEqual(result.metrics.conflictCount, 1)
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)

        let persistedRun = try XCTUnwrap(store.corpusAnalysis.fetchRun(matterID: matter.id, id: result.run.id))
        XCTAssertEqual(persistedRun.structuredOutputVersionID, result.version.id)
        let output = try XCTUnwrap(store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        XCTAssertEqual(output.id, result.outputID)
        XCTAssertEqual(output.outputType, StructuredOutputType.documentExhaustiveList.rawValue)
        XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
        XCTAssertEqual(output.activeVersionID, result.version.id)
        let sourceSet = try XCTUnwrap(store.documentSources.fetchSourceSet(
            structuredOutputVersionID: result.version.id
        ))
        XCTAssertEqual(sourceSet.status, DocumentSourceSetStatus.attached.rawValue)
        XCTAssertNotNil(sourceSet.embeddingModelID, "T-LIN-01: engine source sets stamp embedding lineage")
        XCTAssertNotNil(sourceSet.embeddingModelRevision)
        XCTAssertNotNil(sourceSet.chunkerVersion)
        XCTAssertNotNil(sourceSet.retrievalConfigJSON)
        XCTAssertNotNil(sourceSet.corpusSnapshotHash)
        XCTAssertNotNil(sourceSet.packingReportJSON)
        let outputSources = try store.documentSources.fetchSources(sourceSetID: sourceSet.id)
        XCTAssertEqual(Set(outputSources.compactMap(\.revisionID)), Set(fixture.revisionIDs))
        XCTAssertTrue(result.version.contentMarkdown.contains("invoice-c"))
        XCTAssertTrue(try XCTUnwrap(persistedRun.reconciliationJSON).contains("invoice-c"))
        let generationID = try XCTUnwrap(result.version.generationSessionID, "T-LIN-03: engine versions carry generation lineage")
        let generation = try XCTUnwrap(store.generation.fetchGenerationSession(generationID: generationID))
        XCTAssertEqual(generation.modelRepository, "synthetic/exhaustive-runtime")
        XCTAssertEqual(generation.modelRevision, "exhaustive-revision-nondefault")
        XCTAssertEqual(generation.promptBuilderVersion, "exhaustive-list-v1")
        XCTAssertEqual(result.version.promptBuilderVersion, "exhaustive-list-v1")
        XCTAssertEqual(result.version.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        XCTAssertTrue(generation.prompt.contains("Extract every invoice reference."))
        XCTAssertTrue(generation.optionsJSON.contains("character_budget"))
    }

    func testTENG10FailedPartitionPersistsIncompleteOutputWithNamedDocumentAndReason() async throws {
        // T-ENG-10 expected RED: failed partitions cannot yet produce an attached, explicitly incomplete list output.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic incomplete list")
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "partial-invoices.txt",
            partTexts: ["MAP-GOOD", "MAP-FAIL"]
        )

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "list-incomplete-run",
                matterID: matter.id,
                title: "Incomplete invoice list",
                query: "Extract every invoice.",
                characterBudget: 1,
                evaluationExpectedItemKeys: ["invoice-good", "invoice-missing"],
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            if input.partition.sources.first?.text == "MAP-FAIL" {
                throw CorpusAnalysisMapFailure.permanent("synthetic forced map failure")
            }
            return try Self.response(input, items: [
                .init(itemKey: "invoice-good", value: "$100", evidence: [.primary]),
            ])
        }

        XCTAssertEqual(result.run.status, CorpusAnalysisRunStatus.persisted.rawValue)
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        XCTAssertEqual(result.coverage.failedPartitionCount, 1)
        XCTAssertEqual(result.coverage.pendingPartitionCount, 0)
        XCTAssertEqual(result.omissions.map(\.itemKey), ["invoice-missing"])
        XCTAssertEqual(result.version.verificationStatus, OutputVerificationStatus.needsReview.rawValue)
        XCTAssertTrue(result.version.contentMarkdown.contains("Assurance: corpus_incomplete"))
        XCTAssertFalse(result.version.contentMarkdown.contains("Assurance: corpus_complete"))
        XCTAssertTrue(result.version.contentMarkdown.contains("partial-invoices.txt"))
        XCTAssertTrue(result.version.contentMarkdown.contains("synthetic forced map failure"))
        let output = try XCTUnwrap(store.structuredOutputs.fetchOutputs(matterID: matter.id).first)
        XCTAssertEqual(output.status, StructuredOutputStatus.needsReview.rawValue)
        XCTAssertEqual(
            try store.corpusAnalysis.fetchRun(matterID: matter.id, id: result.run.id)?.structuredOutputVersionID,
            result.version.id
        )
    }

    func testTENG11SchemaInvalidMapFailsPartitionAndPersistsOnlyResponseDigest() async throws {
        // T-ENG-11 expected RED: the typed engine mapper cannot receive or fail closed on malformed raw model output.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic malformed list")
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "malformed-list.txt",
            partTexts: ["MAP-MALFORMED"]
        )
        let malformed = #"{"schema_version":1,"items":[{"item_key":7,"value":"bad"}]}"#
        let expectedDigest = SHA256.hash(data: Data(malformed.utf8)).map { String(format: "%02x", $0) }.joined()

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "list-schema-run",
                matterID: matter.id,
                title: "Malformed list",
                query: "Extract every reference.",
                characterBudget: 1,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { _ in malformed }

        let partition = try XCTUnwrap(result.partitions.first)
        XCTAssertEqual(partition.disposition, CorpusAnalysisPartitionDisposition.failed.rawValue)
        XCTAssertEqual(partition.dispositionReason, "schema_invalid")
        XCTAssertTrue(try XCTUnwrap(partition.errorSummary).contains(expectedDigest))
        XCTAssertTrue(partition.attemptHistoryJSON.contains(expectedDigest))
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertFalse(result.version.contentMarkdown.contains(malformed))
        XCTAssertFalse(try XCTUnwrap(result.run.reconciliationJSON).contains(malformed))
        XCTAssertTrue(result.version.contentMarkdown.contains(expectedDigest))
    }

    func testTENG12NegativeConclusionIsBlockedUnlessCoverageIsCompleteAndNoPositiveExists() async throws {
        // T-ENG-12 expected RED: no negative-conclusion gate maps inadequate coverage to negative_blocked.
        let incompleteStore = try makeStore()
        let incompleteMatter = try incompleteStore.matters.createMatter(name: "Synthetic blocked negative")
        _ = try insertDocument(
            store: incompleteStore,
            matterID: incompleteMatter.id,
            name: "blocked-negative.txt",
            partTexts: ["MAP-FAIL"]
        )
        let incomplete = try await ExhaustiveListTask(store: incompleteStore).run(
            request: ExhaustiveListRequest(
                runKey: "negative-blocked-run",
                matterID: incompleteMatter.id,
                title: "Blocked negative",
                query: "Find any termination reference.",
                characterBudget: 1,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { _ in throw CorpusAnalysisMapFailure.permanent("synthetic negative probe failure") }
        let blocked = CorpusNegativeGate.evaluate(
            run: incomplete.run,
            coverage: incomplete.coverage,
            positiveFindingCount: incomplete.items.count
        )
        XCTAssertFalse(blocked.allowed)
        XCTAssertEqual(blocked.assuranceState, .negativeBlocked)
        XCTAssertTrue(blocked.reasons.contains { $0.contains("failed") || $0.contains("incomplete") })

        let completeStore = try makeStore()
        let completeMatter = try completeStore.matters.createMatter(name: "Synthetic allowed negative")
        _ = try insertDocument(
            store: completeStore,
            matterID: completeMatter.id,
            name: "allowed-negative.txt",
            partTexts: ["MAP-NONE"]
        )
        let complete = try await ExhaustiveListTask(store: completeStore).run(
            request: ExhaustiveListRequest(
                runKey: "negative-allowed-run",
                matterID: completeMatter.id,
                title: "Allowed negative",
                query: "Find any termination reference.",
                characterBudget: 1,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in try Self.response(input, items: []) }
        let allowed = CorpusNegativeGate.evaluate(
            run: complete.run,
            coverage: complete.coverage,
            positiveFindingCount: complete.items.count
        )
        XCTAssertTrue(allowed.allowed)
        XCTAssertEqual(allowed.assuranceState, .corpusComplete)
        XCTAssertTrue(allowed.reasons.isEmpty)
    }

    func testTDIM04ContraryEvidenceAcrossPartitionsFailsNamedDimensionWithBothPositionsRetained() async throws {
        // T-DIM-04 expected RED: exhaustive output dimensions do not consume
        // the engine's cross-partition contrary-evidence references.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic contrary sweep")
        let supporting = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "supporting-agreement.txt",
            partTexts: ["PRIMARY-POSITION-NONDEFAULT"]
        )
        let contrary = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "contrary-amendment.txt",
            partTexts: ["CONTRARY-POSITION-NONDEFAULT"]
        )
        let supportingRevisionID = try XCTUnwrap(supporting.revisionIDs.first)

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "contrary-dimension-run",
                matterID: matter.id,
                title: "Renewal positions",
                query: "Extract every renewal position and sweep for contrary evidence.",
                characterBudget: 1,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            let source = try XCTUnwrap(input.partition.sources.first)
            if source.revisionID == supportingRevisionID {
                return try Self.response(input, items: [
                    .init(itemKey: "renewal", value: "Agreement renews", evidence: [.primary]),
                ])
            }
            return try Self.response(input, items: [
                .init(
                    itemKey: "renewal",
                    value: "Agreement renews",
                    evidence: [],
                    contraryEvidence: [.primary]
                ),
            ])
        }

        let dimension = result.version.verificationDimensions.result(for: .contraryEvidence)
        XCTAssertEqual(dimension.status, .failed)
        XCTAssertTrue(dimension.reason?.contains("contrary-amendment.txt") == true)
        XCTAssertEqual(Set(dimension.evidence.map(\.sourceID)), Set(contrary.revisionIDs))
        XCTAssertTrue(dimension.evidence.allSatisfy { !$0.locator.isEmpty && !$0.excerpt.isEmpty })
        XCTAssertEqual(
            result.version.verificationDimensions.result(for: .propositionSupport).status,
            .satisfied,
            "contrary review must remain independent from proposition support"
        )
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        let renewal = try XCTUnwrap(result.items.first { $0.itemKey == "renewal" })
        XCTAssertEqual(Set(renewal.evidence.map(\.revisionID)), Set(supporting.revisionIDs))
        XCTAssertEqual(Set(renewal.contraryEvidence.map(\.revisionID)), Set(contrary.revisionIDs))
        let sources = try store.documentSources.fetchSources(structuredOutputVersionID: result.version.id)
        XCTAssertEqual(
            Set(sources.compactMap(\.revisionID)),
            Set(supporting.revisionIDs + contrary.revisionIDs),
            "both the supporting and contrary positions must remain attached"
        )
    }

    func testTDIM05FailedPartitionFailsListAndCorpusDimensionsWithoutErasingSupport() async throws {
        // T-DIM-05 expected RED: the coverage ledger affects aggregate assurance
        // but is not bound into independently persisted dimensions.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic dimension completeness")
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "successful-ledger.txt",
            partTexts: ["MAP-SUCCESS-NONDEFAULT"]
        )
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "failed-ledger.txt",
            partTexts: ["MAP-FAILURE-NONDEFAULT"]
        )

        let result = try await ExhaustiveListTask(store: store).run(
            request: ExhaustiveListRequest(
                runKey: "dimension-incomplete-run",
                matterID: matter.id,
                title: "Incomplete payment list",
                query: "Extract every payment.",
                characterBudget: 1,
                modelLineageJSON: Self.modelLineageJSON
            )
        ) { input in
            if input.partition.sources.first?.text == "MAP-FAILURE-NONDEFAULT" {
                throw CorpusAnalysisMapFailure.permanent("NONDEFAULT DIMENSION PARTITION FAILURE")
            }
            return try Self.response(input, items: [
                .init(itemKey: "payment-one", value: "$731", evidence: [.primary]),
            ])
        }

        let dimensions = result.version.verificationDimensions
        XCTAssertEqual(dimensions.result(for: .listCompleteness).status, .failed)
        XCTAssertTrue(dimensions.result(for: .listCompleteness).reason?.contains("failed-ledger.txt") == true)
        XCTAssertEqual(dimensions.result(for: .corpusCoverage).status, .failed)
        XCTAssertTrue(dimensions.result(for: .corpusCoverage).reason?.contains("NONDEFAULT DIMENSION PARTITION FAILURE") == true)
        XCTAssertEqual(dimensions.result(for: .propositionSupport).status, .satisfied)
        XCTAssertEqual(result.version.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
    }

    func testTDIM06RankedRetrievalCannotAuthorizeOrPersistCleanNegativeConclusion() {
        // T-DIM-06 expected RED: the negative gate has no method contract and
        // therefore cannot reject a top-k absence probe before persistence.
        let decision = CorpusNegativeGate.evaluate(
            method: CorpusNegativeMethod.rankedRetrieval,
            proposedConclusion: "NO TERMINATION CLAUSE EXISTS — NONDEFAULT",
            positiveFindingCount: 0
        )

        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.assuranceState, .negativeBlocked)
        XCTAssertNil(decision.permittedConclusion)
        XCTAssertEqual(decision.verificationDimensions.result(for: .negativeValidity).status, .failed)
        XCTAssertTrue(decision.verificationDimensions.result(for: .negativeValidity).reason?.contains(
            "adequate exhaustive method was not run"
        ) == true)
    }

    func testTDIM07LowConfidenceMemberBlocksNegativeDespiteCompleteTerminalPartitions() {
        // T-DIM-07 expected RED: a complete partition ledger does not inspect
        // review-required/low-confidence snapshot members for negative validity.
        let run = CorpusAnalysisRunRecord(
            runKey: "low-confidence-negative-run",
            matterID: "synthetic-negative-matter",
            taskKind: CorpusAnalysisTaskKind.negativeCheck.rawValue,
            scopeJSON: #"{"schema_version":1}"#,
            corpusSnapshotJSON: #"{"schema_version":1,"members":[]}"#,
            partitionStrategy: "part_range:characters=173",
            partitionStrategyVersion: 1,
            status: CorpusAnalysisRunStatus.persisted.rawValue,
            assuranceState: OutputAssuranceState.corpusComplete.rawValue
        )
        let snapshot = CorpusAnalysisSnapshot(members: [
            .init(
                memberKey: "document:low-ocr",
                documentID: "low-ocr-document",
                displayName: "Low OCR Exhibit",
                revisionIDs: ["low-ocr-revision"],
                indexState: DocumentIndexStatus.textIndexed.rawValue,
                disposition: .excluded,
                reason: "low_ocr_confidence:page=3:confidence=0.31"
            ),
        ])
        let decision = CorpusNegativeGate.evaluate(
            method: CorpusNegativeMethod.exhaustiveCorpus,
            proposedConclusion: "NO RESPONSIVE PAYMENT EXISTS — NONDEFAULT",
            run: run,
            coverage: Self.completeCoverage,
            snapshot: snapshot,
            positiveFindingCount: 0
        )

        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.assuranceState, .negativeBlocked)
        XCTAssertNil(decision.permittedConclusion)
        XCTAssertEqual(decision.verificationDimensions.result(for: .negativeValidity).status, .failed)
        XCTAssertEqual(decision.verificationDimensions.result(for: .lowConfidenceHandling).status, .failed)
        let reason = decision.verificationDimensions.result(for: .negativeValidity).reason ?? ""
        XCTAssertTrue(reason.contains("Low OCR Exhibit"))
        XCTAssertTrue(reason.contains("page=3"))
        XCTAssertTrue(reason.contains("confidence=0.31"))
    }

    private static var completeCoverage: CorpusAnalysisCoverage {
        CorpusAnalysisCoverage(
            snapshotMemberCount: 1,
            eligibleMemberCount: 1,
            excludedMemberCount: 0,
            excludedMembersDisclosed: true,
            partitionCount: 1,
            pendingPartitionCount: 0,
            succeededPartitionCount: 1,
            failedPartitionCount: 0,
            cancelledPartitionCount: 0,
            excludedPartitionCount: 0,
            terminalPartitionCount: 1,
            balanceErrorCount: 0
        )
    }

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExhaustiveListTask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    private func insertDocument(
        store: SupraStore,
        matterID: String,
        name: String,
        partTexts: [String]
    ) throws -> ListFixtureDocument {
        try insertListFixtureDocument(
            store: store,
            matterID: matterID,
            name: name,
            partTexts: partTexts
        )
    }

    private static func wholeMatterLineageHash(
        store: SupraStore,
        matterID: String
    ) throws -> String {
        let report = DocumentSourceLineageBuilder.report(summary: nil, candidates: [])
        return try DocumentSourceLineageBuilder.make(
            store: store,
            matterID: matterID,
            scope: .wholeMatter,
            configuration: DocumentRetrievalConfiguration(
                schemaVersion: 1,
                mode: DocumentSourceSetMode.exhaustive.rawValue,
                depth: nil,
                candidateLimit: 37,
                packedLimit: 19,
                maxPerDocument: nil,
                semanticFloor: nil,
                rrfK: nil,
                characterBudget: 1_919
            ),
            packingReport: report
        ).corpusSnapshotHash
    }

    private static func response(
        _ input: ExhaustiveListGenerationInput,
        items: [SyntheticListItem]
    ) throws -> String {
        let source = try XCTUnwrap(input.partition.sources.first)
        let evidence = CorpusAnalysisEvidenceReference(
            documentID: source.documentID,
            revisionID: source.revisionID,
            locatorJSON: source.locatorJSON
        )
        let payload = SyntheticListResponse(items: items.map { item in
            SyntheticListMapItem(
                itemKey: item.itemKey,
                value: item.value,
                evidence: item.evidence.map { _ in evidence },
                contraryEvidence: item.contraryEvidence.map { _ in evidence }
            )
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private static func quotedResponse(
        _ input: ExhaustiveListGenerationInput,
        itemKey: String,
        value: String,
        quote: String,
        charStart: Int,
        charEnd: Int
    ) throws -> String {
        let source = try XCTUnwrap(input.partition.sources.first)
        let payload = SyntheticQuotedListResponse(items: [
            SyntheticQuotedListMapItem(
                itemKey: itemKey,
                value: value,
                evidence: [SyntheticQuotedEvidenceReference(
                    documentID: source.documentID,
                    revisionID: source.revisionID,
                    locatorJSON: source.locatorJSON,
                    quote: quote,
                    charStart: charStart,
                    charEnd: charEnd
                )]
            ),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}

private func insertListFixtureDocument(
    store: SupraStore,
    matterID: String,
    name: String,
    partTexts: [String]
) throws -> ListFixtureDocument {
    let key = "\(name.replacingOccurrences(of: ".", with: "-"))-\(UUID().uuidString)"
    let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
        sha256: "list-\(key)",
        byteSize: partTexts.reduce(0) { $0 + $1.utf8.count },
        originalExtension: "txt",
        managedRelativePath: "blobs/\(key).txt"
    )).blob
    let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
        matterID: matterID,
        blobID: blob.id,
        displayName: name,
        status: MatterDocumentStatus.ready.rawValue,
        extractionStatus: DocumentExtractionStatus.extracted.rawValue,
        indexStatus: DocumentIndexStatus.textIndexed.rawValue
    ))
    let parts = partTexts.enumerated().map { index, text in
        DocumentPagePartRecord(
            id: "\(key)-part-\(index)",
            documentID: document.id,
            partIndex: index,
            sourceKind: DocumentSourceKind.text.rawValue,
            normalizedText: text,
            charCount: text.count
        )
    }
    let revisions = partTexts.enumerated().map { index, text in
        DocumentPartRevisionRecord(
            id: "\(key)-revision-\(index)",
            documentID: document.id,
            partIndex: index,
            derivationKey: "fixture-\(index)",
            origin: "synthetic_test",
            method: "plain-text",
            text: text,
            charCount: text.count
        )
    }
    let selections = revisions.map { revision in
        DocumentPartSelectionRecord(
            id: "\(key)-selection-\(revision.partIndex)",
            documentID: document.id,
            partIndex: revision.partIndex,
            selectedRevisionID: revision.id,
            selectionKey: "fixture-\(revision.partIndex)",
            selectedBy: "test",
            decisionJSON: #"{"rule":"fixture"}"#
        )
    }
    _ = try store.documentRevisions.replacePartsAndPersistLineage(
        documentID: document.id,
        parts: parts,
        revisions: revisions,
        selections: selections
    )
    return ListFixtureDocument(documentID: document.id, revisionIDs: revisions.map(\.id))
}

private actor ListScopeDriftProbe {
    private var mutationClaimed = false
    private(set) var addedDocumentID: String?

    func claimMutation() -> Bool {
        if mutationClaimed { return false }
        mutationClaimed = true
        return true
    }

    func recordAddedDocumentID(_ documentID: String) {
        addedDocumentID = documentID
    }
}

private actor ListGeneratorProbe {
    private(set) var callCount = 0

    func recordCall() {
        callCount += 1
    }
}

private struct ListFixtureDocument {
    var documentID: String
    var revisionIDs: [String]
}

private enum SyntheticEvidenceToken {
    case primary
}

private struct SyntheticListItem {
    var itemKey: String
    var value: String
    var evidence: [SyntheticEvidenceToken]
    var contraryEvidence: [SyntheticEvidenceToken] = []
}

private struct SyntheticListResponse: Encodable {
    var schemaVersion = 1
    var items: [SyntheticListMapItem]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case items
    }
}

private struct SyntheticListMapItem: Encodable {
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

private struct SyntheticQuotedListResponse: Encodable {
    var schemaVersion = 1
    var items: [SyntheticQuotedListMapItem]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case items
    }
}

private struct SyntheticQuotedListMapItem: Encodable {
    var itemKey: String
    var value: String
    var evidence: [SyntheticQuotedEvidenceReference]
    var contraryEvidence: [SyntheticQuotedEvidenceReference] = []

    private enum CodingKeys: String, CodingKey {
        case itemKey = "item_key"
        case value
        case evidence
        case contraryEvidence = "contrary_evidence"
    }
}

private struct SyntheticQuotedEvidenceReference: Encodable {
    var documentID: String
    var revisionID: String
    var locatorJSON: String
    var quote: String
    var charStart: Int
    var charEnd: Int

    private enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case revisionID = "revision_id"
        case locatorJSON = "locator_json"
        case quote
        case charStart = "char_start"
        case charEnd = "char_end"
    }
}
