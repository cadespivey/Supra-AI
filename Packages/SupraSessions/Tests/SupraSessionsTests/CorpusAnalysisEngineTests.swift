import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import SupraStore
import XCTest

final class CorpusAnalysisEngineTests: XCTestCase {
    func testTENG01FrozenSnapshotIgnoresMidRunEditAndMarksResultStale() async throws {
        // T-ENG-01 expected RED: no frozen corpus snapshot or stale result contract exists.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic frozen corpus")
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "frozen.txt",
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed,
            partTexts: ["ORIGINAL-FIRST", "ORIGINAL-SECOND"]
        )
        let probe = EngineProbe()
        let result = try await CorpusAnalysisEngine(store: store).run(
            request: CorpusAnalysisRequest(
                runKey: "freeze-run",
                matterID: matter.id,
                taskKind: .customExtraction,
                scope: CorpusAnalysisScope(documentIDs: [fixture.documentID]),
                characterBudget: 1
            )
        ) { input in
            await probe.record(input)
            if await probe.claimEdit() {
                _ = try store.documentRevisions.appendUserEdit(
                    documentID: fixture.documentID,
                    partID: fixture.partIDs[1],
                    text: "EDITED-SECOND",
                    author: "Synthetic tester",
                    reason: "T-ENG-01 mid-run edit"
                )
            }
            return CorpusAnalysisMapOutput(findings: input.sources.map { source in
                CorpusAnalysisFinding(
                    id: "finding-\(source.revisionID)",
                    value: source.text,
                    evidence: [CorpusAnalysisEvidenceReference(
                        documentID: source.documentID,
                        revisionID: source.revisionID,
                        locatorJSON: source.locatorJSON
                    )]
                )
            })
        }

        let observedInputs = await probe.inputs
        let observedTexts = observedInputs.flatMap(\.sources).map(\.text)
        XCTAssertEqual(observedTexts, ["ORIGINAL-FIRST", "ORIGINAL-SECOND"])
        XCTAssertFalse(observedTexts.contains("EDITED-SECOND"))
        XCTAssertEqual(result.snapshot.members.first?.revisionIDs, fixture.revisionIDs)
        XCTAssertEqual(result.run.status, CorpusAnalysisRunStatus.persisted.rawValue)
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.stale.rawValue)
        XCTAssertTrue(result.assuranceReasons.contains { $0.contains(fixture.documentID) })
        let currentParts = try store.documentIndex.fetchParts(documentID: fixture.documentID)
        XCTAssertNotEqual(currentParts[1].currentRevisionID, fixture.revisionIDs[1])
    }

    func testTENG02SnapshotDisclosesFailedReviewAndExcludedHiddenMembers() async throws {
        // T-ENG-02 expected RED: failed/excluded members vanish from readiness denominators.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic disclosed corpus")
        let eligible = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "eligible.txt",
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed,
            partTexts: ["ELIGIBLE-EVIDENCE"]
        )
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "failed-parser.txt",
            status: .failed,
            extractionStatus: .failed,
            indexStatus: .failed,
            partTexts: []
        )
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "review-required.txt",
            status: .needsReview,
            extractionStatus: .extracted,
            indexStatus: .textIndexed,
            partTexts: ["REVIEW-EVIDENCE"]
        )
        let batch = try store.documentJobs.createBatch(matterID: matter.id)
        _ = try store.documentJobs.recordDiscovered(
            batchID: batch.id,
            matterID: matter.id,
            sourceKey: "selection:hidden",
            sourceDisplayPath: ".synthetic-hidden",
            state: .excludedHidden
        )

        let result = try await CorpusAnalysisEngine(store: store).run(
            request: CorpusAnalysisRequest(
                runKey: "disclosure-run",
                matterID: matter.id,
                taskKind: .customExtraction,
                scope: .wholeMatter,
                characterBudget: 1
            )
        ) { input in
            CorpusAnalysisMapOutput(findings: input.sources.map { source in
                CorpusAnalysisFinding(
                    id: "finding-\(source.revisionID)",
                    value: source.text,
                    evidence: [.init(
                        documentID: source.documentID,
                        revisionID: source.revisionID,
                        locatorJSON: source.locatorJSON
                    )]
                )
            })
        }

        XCTAssertEqual(result.snapshot.members.count, 4)
        XCTAssertEqual(result.coverage.snapshotMemberCount, 4)
        XCTAssertEqual(result.coverage.eligibleMemberCount, 1)
        XCTAssertEqual(result.coverage.excludedMemberCount, 3)
        XCTAssertEqual(result.coverage.partitionCount, 1)
        XCTAssertEqual(result.findings.first?.evidence.first?.revisionID, eligible.revisionIDs[0])
        let reasonByName: [String: String?] = Dictionary(uniqueKeysWithValues: result.snapshot.members.map {
            ($0.displayName, $0.reason)
        })
        XCTAssertEqual(try XCTUnwrap(reasonByName["failed-parser.txt"] ?? nil), "extraction_failed")
        XCTAssertEqual(try XCTUnwrap(reasonByName["review-required.txt"] ?? nil), "review_required")
        XCTAssertEqual(try XCTUnwrap(reasonByName[".synthetic-hidden"] ?? nil), "excluded_hidden")
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
        XCTAssertTrue(result.coverage.excludedMembersDisclosed)
    }

    func testTENG05EngineMapsAllSixPartitionsWhileRetrievalRemainsCappedAtFour() async throws {
        // T-ENG-05 expected RED: no uncapped engine path exists; ordinary retrieval already caps per document.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic uncapped corpus")
        let texts = (1...6).map { "RESPONSIVE-\($0) planted corpus fact" }
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "six-partitions.txt",
            status: .indexing,
            extractionStatus: .extracted,
            indexStatus: .notIndexed,
            partTexts: texts
        )
        let indexedDocumentCount = try await DocumentIndexingService(store: store)
            .indexMatter(matterID: matter.id)
        XCTAssertEqual(indexedDocumentCount, 1)

        let retrieval = try await DocumentRetrievalService(store: store).retrieve(
            matterID: matter.id,
            query: "responsive planted corpus fact",
            scope: .wholeMatter,
            limit: 40,
            depth: .deep
        )
        XCTAssertLessThanOrEqual(retrieval.sources.count, 4)
        XCTAssertEqual(Set(retrieval.sources.map(\.documentID)), [fixture.documentID])

        let probe = EngineProbe()
        let result = try await CorpusAnalysisEngine(store: store).run(
            request: CorpusAnalysisRequest(
                runKey: "uncapped-run",
                matterID: matter.id,
                taskKind: .customExtraction,
                scope: CorpusAnalysisScope(documentIDs: [fixture.documentID]),
                characterBudget: 1
            )
        ) { input in
            await probe.record(input)
            return CorpusAnalysisMapOutput(findings: input.sources.map { source in
                CorpusAnalysisFinding(
                    id: "finding-\(source.revisionID)",
                    value: source.text,
                    evidence: [.init(
                        documentID: source.documentID,
                        revisionID: source.revisionID,
                        locatorJSON: source.locatorJSON
                    )]
                )
            })
        }

        XCTAssertEqual(result.partitions.count, 6)
        XCTAssertEqual(result.findings.count, 6)
        XCTAssertEqual(
            Set(result.findings.flatMap { $0.evidence }.map { $0.revisionID }),
            Set(fixture.revisionIDs)
        )
        XCTAssertTrue(result.partitions.allSatisfy {
            $0.disposition == CorpusAnalysisPartitionDisposition.succeeded.rawValue
        })
        let recordedInputs = await probe.inputs
        let prompts = recordedInputs.map { $0.promptEnvelope }
        XCTAssertEqual(prompts.count, 6)
        XCTAssertTrue(prompts.allSatisfy { $0.contains("BEGIN_UNTRUSTED_SOURCE_DATA") })
        XCTAssertTrue(prompts.allSatisfy { $0.contains("END_UNTRUSTED_SOURCE_DATA") })
    }

    func testTENG06CancellationRetainsSuccessesAndTerminalizesEveryUnfinishedPartition() async throws {
        // T-ENG-06 expected RED: cancellation marks only the run; unfinished partitions remain pending.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic cancelled corpus")
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "cancelled.txt",
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed,
            partTexts: (1...6).map { "CANCEL-PART-\($0)" }
        )
        let probe = EngineProbe()

        do {
            _ = try await CorpusAnalysisEngine(store: store).run(
                request: CorpusAnalysisRequest(
                    runKey: "cancelled-run",
                    matterID: matter.id,
                    taskKind: .customExtraction,
                    characterBudget: 1
                )
            ) { input in
                let ordinal = await probe.recordAndReturnOrdinal(input)
                if ordinal == 3 { throw CancellationError() }
                return CorpusAnalysisMapOutput(findings: input.sources.map { source in
                    CorpusAnalysisFinding(
                        id: "finding-\(source.revisionID)",
                        value: source.text,
                        evidence: [.init(
                            documentID: source.documentID,
                            revisionID: source.revisionID,
                            locatorJSON: source.locatorJSON
                        )]
                    )
                })
            }
            XCTFail("Cancellation must escape to the caller")
        } catch is CancellationError {
            // Expected: the persisted ledger is the recovery artifact.
        }

        let run = try XCTUnwrap(store.corpusAnalysis.fetchRun(
            matterID: matter.id,
            runKey: "cancelled-run"
        ))
        let partitions = try store.corpusAnalysis.fetchPartitions(
            matterID: matter.id,
            runID: run.id
        )
        XCTAssertEqual(run.status, CorpusAnalysisRunStatus.cancelled.rawValue)
        XCTAssertNil(run.structuredOutputVersionID)
        XCTAssertEqual(partitions.count, 6)
        XCTAssertEqual(partitions.count { $0.disposition == CorpusAnalysisPartitionDisposition.succeeded.rawValue }, 2)
        XCTAssertEqual(partitions.count { $0.disposition == CorpusAnalysisPartitionDisposition.cancelled.rawValue }, 4)
        XCTAssertEqual(partitions.count { $0.disposition == CorpusAnalysisPartitionDisposition.pending.rawValue }, 0)
        XCTAssertEqual(partitions.compactMap(\.findingsJSON).count, 2, "successful checkpoints must survive cancellation")
        let cancelledCoverage = try JSONDecoder().decode(
            CorpusAnalysisCoverage.self,
            from: Data(try XCTUnwrap(run.coverageJSON).utf8)
        )
        XCTAssertEqual(cancelledCoverage.partitionCount, 6)
        XCTAssertEqual(cancelledCoverage.terminalPartitionCount, 6)
        XCTAssertEqual(cancelledCoverage.succeededPartitionCount, 2)
        XCTAssertEqual(cancelledCoverage.cancelledPartitionCount, 4)
        XCTAssertEqual(cancelledCoverage.balanceErrorCount, 0)
    }

    func testTENG07RelaunchResumesOnlyNonSucceededPartitionsAgainstFrozenSnapshot() async throws {
        // T-ENG-07 expected RED: a cancelled run cannot reopen its non-succeeded partitions.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic resumed corpus")
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "resumed.txt",
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed,
            partTexts: (1...5).map { "RESUME-PART-\($0)" }
        )
        let firstProbe = EngineProbe()
        let request = CorpusAnalysisRequest(
            runKey: "resumed-run",
            matterID: matter.id,
            taskKind: .customExtraction,
            characterBudget: 1
        )

        do {
            _ = try await CorpusAnalysisEngine(store: store).run(request: request) { input in
                let ordinal = await firstProbe.recordAndReturnOrdinal(input)
                if ordinal == 3 { throw CancellationError() }
                return Self.mapFindings(input)
            }
            XCTFail("The first process life must stop after two checkpoints")
        } catch is CancellationError {
            // Simulates force-quit/cancel after durable successes.
        }

        let interrupted = try XCTUnwrap(store.corpusAnalysis.fetchRun(
            matterID: matter.id,
            runKey: request.runKey
        ))
        let frozenSnapshot = try JSONDecoder().decode(
            CorpusAnalysisSnapshot.self,
            from: Data(interrupted.corpusSnapshotJSON.utf8)
        )
        XCTAssertEqual(frozenSnapshot.members.first?.revisionIDs, fixture.revisionIDs)

        let resumeProbe = EngineProbe()
        let resumed = try await CorpusAnalysisEngine(store: store).run(request: request) { input in
            await resumeProbe.record(input)
            return Self.mapFindings(input)
        }

        let resumedTexts = await resumeProbe.inputs.flatMap(\.sources).map(\.text)
        XCTAssertEqual(resumedTexts, ["RESUME-PART-3", "RESUME-PART-4", "RESUME-PART-5"])
        XCTAssertFalse(resumedTexts.contains("RESUME-PART-1"), "a succeeded partition must be a cache hit")
        XCTAssertFalse(resumedTexts.contains("RESUME-PART-2"), "a succeeded partition must be a cache hit")
        XCTAssertEqual(resumed.snapshot, frozenSnapshot)
        XCTAssertEqual(resumed.snapshot.members.first?.revisionIDs, fixture.revisionIDs)
        XCTAssertEqual(resumed.run.status, CorpusAnalysisRunStatus.persisted.rawValue)
        XCTAssertEqual(resumed.run.assuranceState, OutputAssuranceState.corpusComplete.rawValue)
        XCTAssertEqual(resumed.coverage.succeededPartitionCount, 5)
        XCTAssertEqual(resumed.coverage.pendingPartitionCount, 0)
        XCTAssertEqual(resumed.coverage.terminalPartitionCount, 5)
        XCTAssertEqual(resumed.coverage.balanceErrorCount, 0)
        XCTAssertEqual(resumed.findings.count, 5)
        XCTAssertEqual(
            resumed.partitions.map(\.attemptCount),
            [1, 1, 2, 1, 1],
            "the cancelled in-flight attempt is retained before its successful retry"
        )
    }

    func testTENG07RelaunchRetriesTransientFailureAndMapsPendingWithoutReplayingSuccesses() async throws {
        // T-ENG-07 expected RED: no bootstrap path distinguishes checkpoints, retryable failures, and pending work.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic interrupted corpus")
        let texts = (1...4).map { "INTERRUPTED-PART-\($0)" }
        let fixture = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "interrupted.txt",
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed,
            partTexts: texts
        )
        let snapshot = CorpusAnalysisSnapshot(members: [.init(
            memberKey: "document:\(fixture.documentID)",
            documentID: fixture.documentID,
            displayName: "interrupted.txt",
            revisionIDs: fixture.revisionIDs,
            indexState: DocumentIndexStatus.textIndexed.rawValue,
            disposition: .eligible
        )])
        let run = try store.corpusAnalysis.createOrFetchRun(CorpusAnalysisRunRecord(
            id: "interrupted-ledger-run",
            runKey: "interrupted-ledger-key",
            matterID: matter.id,
            taskKind: CorpusAnalysisTaskKind.customExtraction.rawValue,
            scopeJSON: try Self.canonicalJSON(CorpusAnalysisScope.wholeMatter),
            corpusSnapshotJSON: try Self.canonicalJSON(snapshot),
            partitionStrategy: "part_range:characters=1",
            partitionStrategyVersion: 1,
            status: CorpusAnalysisRunStatus.planning.rawValue
        ))
        let partitions = try fixture.revisionIDs.enumerated().map { index, revisionID in
            CorpusAnalysisPartitionRecord(
                id: "interrupted-partition-\(index)",
                runID: run.id,
                partitionKey: String(format: "%06d|part:\(index)", index),
                inputRevisionIDsJSON: try Self.canonicalJSON([revisionID])
            )
        }
        try store.corpusAnalysis.createPartitions(
            matterID: matter.id,
            runID: run.id,
            partitions: partitions
        )
        _ = try store.corpusAnalysis.updateStatus(matterID: matter.id, runID: run.id, to: .running)

        for index in 0...1 {
            _ = try store.corpusAnalysis.beginAttempt(
                matterID: matter.id,
                runID: run.id,
                partitionID: partitions[index].id
            )
            try store.corpusAnalysis.completeAttemptSucceeded(
                matterID: matter.id,
                runID: run.id,
                partitionID: partitions[index].id,
                findingsJSON: try Self.findingsJSON(
                    documentID: fixture.documentID,
                    revisionID: fixture.revisionIDs[index],
                    text: texts[index]
                )
            )
        }
        _ = try store.corpusAnalysis.beginAttempt(
            matterID: matter.id,
            runID: run.id,
            partitionID: partitions[2].id
        )
        let retryScheduled = try store.corpusAnalysis.completeAttemptFailed(
            matterID: matter.id,
            runID: run.id,
            partitionID: partitions[2].id,
            retryable: true,
            errorSummary: "synthetic interrupted transient failure",
            maximumRetryCount: 0
        )
        XCTAssertFalse(retryScheduled)
        // partition[3] remains pending, representing work never started before process death.

        let resumeProbe = EngineProbe()
        let resumed = try await CorpusAnalysisEngine(store: store).run(
            request: CorpusAnalysisRequest(
                runKey: run.runKey,
                matterID: matter.id,
                taskKind: .customExtraction,
                characterBudget: 1,
                maximumRetryCount: 2
            )
        ) { input in
            await resumeProbe.record(input)
            return Self.mapFindings(input)
        }

        let resumedTexts = await resumeProbe.inputs.flatMap(\.sources).map(\.text)
        XCTAssertEqual(resumedTexts, ["INTERRUPTED-PART-3", "INTERRUPTED-PART-4"])
        XCTAssertEqual(resumed.snapshot, snapshot)
        XCTAssertEqual(resumed.snapshot.members.first?.revisionIDs, fixture.revisionIDs)
        XCTAssertEqual(resumed.findings.count, 4)
        XCTAssertEqual(resumed.partitions.map(\.attemptCount), [1, 1, 2, 1])
        XCTAssertTrue(resumed.partitions.allSatisfy {
            $0.disposition == CorpusAnalysisPartitionDisposition.succeeded.rawValue
        })
        XCTAssertEqual(resumed.coverage.succeededPartitionCount, 4)
        XCTAssertEqual(resumed.coverage.terminalPartitionCount, 4)
        XCTAssertEqual(resumed.coverage.pendingPartitionCount, 0)
        XCTAssertEqual(resumed.coverage.balanceErrorCount, 0)
    }

    func testTENG08TransientRetryCapPersistsThreeAttemptsAndBalancesAsIncomplete() async throws {
        // T-ENG-08 expected RED: mapper failures have no transient classification or durable bounded attempts.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic retry-exhausted corpus")
        _ = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "retry.txt",
            status: .ready,
            extractionStatus: .extracted,
            indexStatus: .textIndexed,
            partTexts: ["RETRY-PART-1"]
        )
        let probe = EngineProbe()

        let result = try await CorpusAnalysisEngine(store: store).run(
            request: CorpusAnalysisRequest(
                runKey: "retry-run",
                matterID: matter.id,
                taskKind: .customExtraction,
                characterBudget: 1,
                maximumRetryCount: 2
            )
        ) { input in
            _ = await probe.recordAndReturnOrdinal(input)
            throw CorpusAnalysisMapFailure.transient("synthetic transient mapper failure")
        }

        let attemptsMade = await probe.inputs.count
        XCTAssertEqual(attemptsMade, 3, "two retries means three total attempts")
        let partition = try XCTUnwrap(result.partitions.first)
        XCTAssertEqual(partition.attemptCount, 3)
        XCTAssertEqual(partition.disposition, CorpusAnalysisPartitionDisposition.failed.rawValue)
        XCTAssertEqual(partition.dispositionReason, "retry_exhausted")
        XCTAssertEqual(partition.errorSummary, "synthetic transient mapper failure")
        let history = try JSONDecoder().decode(
            [SyntheticAttemptHistoryEntry].self,
            from: Data(partition.attemptHistoryJSON.utf8)
        )
        XCTAssertEqual(history.map(\.attemptNumber), [1, 2, 3])
        XCTAssertEqual(history.map(\.outcome), ["failed", "failed", "failed"])
        XCTAssertTrue(history.allSatisfy(\.retryable))
        XCTAssertTrue(history.allSatisfy { $0.errorSummary == "synthetic transient mapper failure" })

        XCTAssertEqual(result.run.status, CorpusAnalysisRunStatus.persisted.rawValue)
        XCTAssertEqual(result.run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)
        XCTAssertNil(result.run.structuredOutputVersionID)
        XCTAssertEqual(result.coverage.partitionCount, 1)
        XCTAssertEqual(result.coverage.failedPartitionCount, 1)
        XCTAssertEqual(result.coverage.pendingPartitionCount, 0)
        XCTAssertEqual(result.coverage.terminalPartitionCount, 1)
        XCTAssertEqual(result.coverage.balanceErrorCount, 0)
        XCTAssertTrue(result.findings.isEmpty)
    }

    private func makeStore() throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CorpusAnalysisEngine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    private func insertDocument(
        store: SupraStore,
        matterID: String,
        name: String,
        status: MatterDocumentStatus,
        extractionStatus: DocumentExtractionStatus,
        indexStatus: DocumentIndexStatus,
        partTexts: [String]
    ) throws -> CorpusFixtureDocument {
        let key = name.replacingOccurrences(of: ".", with: "-")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "corpus-\(key)-\(UUID().uuidString)",
            byteSize: partTexts.reduce(0) { $0 + $1.utf8.count },
            originalExtension: "txt",
            managedRelativePath: "blobs/\(key).txt"
        )).blob
        let document = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID,
            blobID: blob.id,
            displayName: name,
            status: status.rawValue,
            extractionStatus: extractionStatus.rawValue,
            indexStatus: indexStatus.rawValue
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
        if !parts.isEmpty {
            _ = try store.documentRevisions.replacePartsAndPersistLineage(
                documentID: document.id,
                parts: parts,
                revisions: revisions,
                selections: selections
            )
        }
        return CorpusFixtureDocument(
            documentID: document.id,
            partIDs: parts.map(\.id),
            revisionIDs: revisions.map(\.id)
        )
    }

    private static func mapFindings(_ input: CorpusAnalysisPartitionInput) -> CorpusAnalysisMapOutput {
        CorpusAnalysisMapOutput(findings: input.sources.map { source in
            CorpusAnalysisFinding(
                id: "finding-\(source.revisionID)",
                value: source.text,
                evidence: [.init(
                    documentID: source.documentID,
                    revisionID: source.revisionID,
                    locatorJSON: source.locatorJSON
                )]
            )
        })
    }

    private static func findingsJSON(
        documentID: String,
        revisionID: String,
        text: String
    ) throws -> String {
        let locator = DocumentSourceLocator(
            sourceKind: .text,
            charStart: 0,
            charEnd: text.count
        )
        return try canonicalJSON([CorpusAnalysisFinding(
            id: "finding-\(revisionID)",
            value: text,
            evidence: [.init(
                documentID: documentID,
                revisionID: revisionID,
                locatorJSON: locator.encodedJSON()
            )]
        )])
    }

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private struct CorpusFixtureDocument: Sendable {
    var documentID: String
    var partIDs: [String]
    var revisionIDs: [String]
}

private struct SyntheticAttemptHistoryEntry: Decodable {
    var attemptNumber: Int
    var outcome: String
    var retryable: Bool
    var errorSummary: String?

    private enum CodingKeys: String, CodingKey {
        case attemptNumber = "attempt_number"
        case outcome
        case retryable
        case errorSummary = "error_summary"
    }
}

private actor EngineProbe {
    private(set) var inputs: [CorpusAnalysisPartitionInput] = []
    private var editClaimed = false

    func record(_ input: CorpusAnalysisPartitionInput) {
        inputs.append(input)
    }

    func recordAndReturnOrdinal(_ input: CorpusAnalysisPartitionInput) -> Int {
        inputs.append(input)
        return inputs.count
    }

    func claimEdit() -> Bool {
        if editClaimed { return false }
        editClaimed = true
        return true
    }
}
