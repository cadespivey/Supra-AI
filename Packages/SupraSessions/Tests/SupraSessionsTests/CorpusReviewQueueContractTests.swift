import Foundation
import GRDB
import SupraCore
import SupraDocuments
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

/// Compile-contract REDs are isolated here so queue execution can stay focused
/// on FIFO, cancellation, and relaunch behavior.
@MainActor
final class CorpusReviewQueueContractTests: XCTestCase {
    func testTQUEUE01V2PayloadRoundTripPreservesVersionedTaskAndContentBoundModel() throws {
        // T-QUEUE-01 expected RED: the durable payload contains only run_id;
        // the reconstructible request, explicit task/prompt versions, canonical
        // request digest, and exact content-bound model identity do not exist.
        let payload = makePayload(runID: "run-nondefault-queue-01")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(payload)
        let decoded = try JSONDecoder().decode(CorpusAnalysisJobPayload.self, from: encoded)
        let request = try queuedRequest(from: decoded)
        let json = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.runID, "run-nondefault-queue-01")
        XCTAssertEqual(decoded.requestDigest, Self.requestDigest)
        XCTAssertEqual(decoded.pinnedModel, Self.pinnedModel)
        XCTAssertEqual(decoded.pinnedModel.modelRepository, "synthetic/legal-review-model-nondefault")
        XCTAssertEqual(decoded.pinnedModel.modelRevision, Self.pinnedRevision)
        XCTAssertEqual(
            decoded.pinnedModel.contentBindingAlgorithm,
            RuntimeModelContentBinding.fingerprintAlgorithm
        )
        XCTAssertEqual(
            decoded.pinnedModel.contentBindingSchemaVersion,
            RuntimeModelContentBinding.supportedManifestSchemaVersion
        )
        XCTAssertEqual(decoded.pinnedModel.artifactFingerprintSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(request.taskSchemaVersion, ExhaustiveListTask.schemaVersion)
        XCTAssertEqual(request.promptBuilderVersion, ExhaustiveListTask.promptBuilderVersion)
        XCTAssertEqual(request.runKey, "run-key-nondefault-queue")
        XCTAssertEqual(request.matterID, "matter-nondefault-queue")
        XCTAssertEqual(request.title, "Synthetic privilege review matrix")
        XCTAssertEqual(request.query, "List every nondefault privilege indicator and its exact source.")
        XCTAssertEqual(request.scope.schemaVersion, 7)
        XCTAssertEqual(request.scope.documentIDs, ["document-zeta", "document-alpha"])
        XCTAssertEqual(request.characterBudget, 31_337)
        XCTAssertEqual(request.maximumRetryCount, 4)
        XCTAssertTrue(json.contains("\"schema_version\":2"))
        XCTAssertTrue(json.contains("\"task_schema_version\":1"))
        XCTAssertTrue(json.contains("\"prompt_builder_version\":\"exhaustive-list-v1\""))
        XCTAssertTrue(json.contains("\"artifact_fingerprint_sha256\":\"\(String(repeating: "a", count: 64))\""))
        XCTAssertTrue(json.contains("\"character_budget\":31337"))
        XCTAssertFalse(
            json.contains("\"character_budget\":24000"),
            "the exact task must contain the non-default budget, not the old default"
        )
        XCTAssertFalse(
            json.contains("evaluation_expected_item_keys"),
            "evaluation-only answer keys must not enter a production queue payload"
        )
    }

    func testTQUEUE01PreparedDigestBindsTaskJobMatterRunAndExactModelBeforeResolution() async throws {
        // T-QUEUE-01 expected RED: there is no prepare-then-enqueue v2 path and
        // no host recomputation that binds the queued request to the job matter,
        // frozen run ledger, or exact installed model bytes before generation.
        let store = try makeStore(testName: "TQUEUE01Bindings")
        let primary = try prepareFixture(store: store, caseName: "primary-bindings", partCount: 1)
        let alternatePayload = try preparePayload(
            store: store,
            matterID: primary.matterID,
            documentID: primary.documentID,
            caseName: "alternate-bindings"
        )
        XCTAssertNotEqual(primary.payload.runID, alternatePayload.runID)
        let foreignMatter = try store.matters.createMatter(name: "Synthetic foreign job matter")
        let probe = ModelResolutionProbe(resolvedModel: Self.pinnedModel)
        let runner = makeProductionRunner(store: store, probe: probe)
        let queue = makeQueue(store: store) { payload in
            try await runner.run(payload)
        }

        var changedQuery = try queuedRequest(from: primary.payload)
        changedQuery.query = "Tampered query that was never frozen or digested."
        var queryPayload = primary.payload
        queryPayload.task = .exhaustiveList(changedQuery)

        var changedTaskSchema = try queuedRequest(from: primary.payload)
        changedTaskSchema.taskSchemaVersion = 97
        var taskSchemaPayload = primary.payload
        taskSchemaPayload.task = .exhaustiveList(changedTaskSchema)

        var changedPromptVersion = try queuedRequest(from: primary.payload)
        changedPromptVersion.promptBuilderVersion = "exhaustive-list-tampered-97"
        var promptPayload = primary.payload
        promptPayload.task = .exhaustiveList(changedPromptVersion)

        var swappedRunPayload = primary.payload
        swappedRunPayload.runID = alternatePayload.runID

        var changedModelPayload = primary.payload
        changedModelPayload.pinnedModel = Self.alternatePinnedModel

        let invalidJobs = try [
            queue.enqueueCorpusAnalysis(matterID: primary.matterID, payload: queryPayload),
            queue.enqueueCorpusAnalysis(matterID: primary.matterID, payload: taskSchemaPayload),
            queue.enqueueCorpusAnalysis(matterID: primary.matterID, payload: promptPayload),
            queue.enqueueCorpusAnalysis(matterID: primary.matterID, payload: swappedRunPayload),
            queue.enqueueCorpusAnalysis(matterID: foreignMatter.id, payload: primary.payload),
            queue.enqueueCorpusAnalysis(matterID: primary.matterID, payload: changedModelPayload),
        ].map { try XCTUnwrap($0) }

        await queue.waitUntilIdle()

        let jobs = try invalidJobs.map { try XCTUnwrap(store.documentJobs.fetchJob(id: $0)) }
        let resolutionCalls = await probe.resolutionCalls
        let generationCalls = await probe.generationCalls
        XCTAssertEqual(
            jobs.map(\.status),
            Array(repeating: DocumentProcessingJobStatus.failed.rawValue, count: invalidJobs.count)
        )
        XCTAssertTrue(jobs.allSatisfy { !($0.errorSummary ?? "").isEmpty })
        XCTAssertEqual(resolutionCalls, 0, "digest/coherence failures precede model resolution")
        XCTAssertEqual(generationCalls, 0, "no invalid request reaches generation")

        let persisted = try XCTUnwrap(
            store.corpusAnalysis.fetchRun(matterID: primary.matterID, id: primary.payload.runID)
        )
        XCTAssertEqual(persisted.requestSchemaVersion, 2)
        XCTAssertEqual(persisted.requestDigest, primary.payload.requestDigest)
        XCTAssertNil(persisted.completedAt)
    }

    func testTQUEUE01PreparedDigestDetectsFrozenSliceLedgerMutation() async throws {
        // T-QUEUE-01 expected RED: queue validation does not reconstruct the
        // digest from normalized frozen slices, so post-prepare store mutation
        // can otherwise reach the model under a stale request digest.
        let store = try makeStore(testName: "TQUEUE01FrozenLedger")
        let fixture = try prepareFixture(store: store, caseName: "frozen-ledger", partCount: 2)
        let slice = try XCTUnwrap(
            store.corpusAnalysis.fetchSlices(
                matterID: fixture.matterID,
                runID: fixture.payload.runID
            ).first
        )
        let revision = try XCTUnwrap(store.documentRevisions.fetchRevision(id: slice.revisionID))
        let overlapStart = slice.charStart
        let overlapEnd = slice.charStart + max(1, (slice.charEnd - slice.charStart) / 2)
        let lower = revision.text.index(revision.text.startIndex, offsetBy: overlapStart)
        let upper = revision.text.index(revision.text.startIndex, offsetBy: overlapEnd)
        let overlapText = String(revision.text[lower..<upper])
        let overlapLocator = DocumentSourceLocator(
            sourceKind: .text,
            charStart: overlapStart,
            charEnd: overlapEnd
        )
        try await store.database.writer.write { db in
            // Simulate hostile on-disk corruption without requiring the shipping
            // repository to expose mutation or weaken any immutability trigger.
            let immutabilityTriggers = try String.fetchAll(
                db,
                sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'trigger' AND tbl_name = 'corpus_analysis_partition_slices'
                """
            )
            for trigger in immutabilityTriggers {
                let quoted = trigger.replacingOccurrences(of: "\"", with: "\"\"")
                try db.execute(sql: "DROP TRIGGER \"\(quoted)\"")
            }
            try db.execute(
                sql: """
                INSERT INTO corpus_analysis_partition_slices (
                    id, run_id, partition_id, ordinal, member_key, document_id,
                    part_index, revision_id, char_start, char_end,
                    revision_char_count, text_sha256, locator_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "t-queue-01-overlap-corruption", slice.runID, slice.partitionID,
                    slice.ordinal + 97, slice.memberKey, slice.documentID,
                    slice.partIndex, slice.revisionID, overlapStart, overlapEnd,
                    slice.revisionCharCount,
                    DocumentStorage.sha256Hex(of: Data(overlapText.utf8)),
                    overlapLocator.encodedJSON(),
                ]
            )
        }

        let probe = ModelResolutionProbe(resolvedModel: Self.pinnedModel)
        let runner = makeProductionRunner(store: store, probe: probe)
        let queue = makeQueue(store: store) { payload in
            try await runner.run(payload)
        }
        let jobID = try XCTUnwrap(queue.enqueueCorpusAnalysis(
            matterID: fixture.matterID,
            payload: fixture.payload
        ))
        await queue.waitUntilIdle()

        let job = try XCTUnwrap(store.documentJobs.fetchJob(id: jobID))
        let resolutionCalls = await probe.resolutionCalls
        let generationCalls = await probe.generationCalls
        XCTAssertEqual(job.status, DocumentProcessingJobStatus.failed.rawValue)
        XCTAssertEqual(resolutionCalls, 0, "frozen-state mismatch must fail before model load")
        XCTAssertEqual(generationCalls, 0)
    }

    func testTQUEUE01WhitespaceOnlyRawQueryMutationFailsBeforeModelResolution() async throws {
        // T-QUEUE-01 expected RED: the runner accepts a raw query whose whitespace
        // differs from the frozen payload because request-digest validation binds
        // only its normalized form, so the mutated prompt reaches model resolution.
        let store = try makeStore(testName: "TQUEUE01RawQueryWhitespace")
        let fixture = try prepareFixture(
            store: store,
            caseName: "raw-query-whitespace",
            partCount: 1
        )
        var mutatedRequest = try queuedRequest(from: fixture.payload)
        let frozenQuery = mutatedRequest.query
        mutatedRequest.query = "\n\tList   every nondefault privilege indicator\n\nand its exact source.   "
        XCTAssertNotEqual(mutatedRequest.query, frozenQuery)
        XCTAssertEqual(
            CorpusAnalysisRequestDigest.normalizeQuery(mutatedRequest.query),
            frozenQuery,
            "the hostile raw query must preserve the previously digested normalized query"
        )
        var mutatedPayload = fixture.payload
        mutatedPayload.task = .exhaustiveList(mutatedRequest)

        let probe = ModelResolutionProbe(resolvedModel: Self.pinnedModel)
        let runner = makeProductionRunner(store: store, probe: probe)
        let queue = makeQueue(store: store) { payload in
            try await runner.run(payload)
        }
        let jobID = try XCTUnwrap(queue.enqueueCorpusAnalysis(
            matterID: fixture.matterID,
            payload: mutatedPayload
        ))
        await queue.waitUntilIdle()

        let job = try XCTUnwrap(store.documentJobs.fetchJob(id: jobID))
        let resolutionCalls = await probe.resolutionCalls
        let generationCalls = await probe.generationCalls
        XCTAssertEqual(job.status, DocumentProcessingJobStatus.failed.rawValue)
        XCTAssertFalse((job.errorSummary ?? "").isEmpty)
        XCTAssertEqual(resolutionCalls, 0, "raw prompt bytes must be frozen before model resolution")
        XCTAssertEqual(generationCalls, 0, "a mutated raw query must never reach generation")
    }

    func testTQUEUE01InjectedEmptyPartitionFailsBeforeModelResolution() async throws {
        // T-QUEUE-01 expected RED: the old digest binds only partition-backed
        // slices, so a hostile extra partition with no slices survives digest
        // recomputation and reaches model resolution before the engine rejects it.
        let store = try makeStore(testName: "TQUEUE01InjectedEmptyPartition")
        let fixture = try prepareFixture(
            store: store,
            caseName: "injected-empty-partition",
            partCount: 1
        )
        let originalPartitions = try store.corpusAnalysis.fetchPartitions(
            matterID: fixture.matterID,
            runID: fixture.payload.runID
        )
        let hostilePartitionID = "t-queue-01-hostile-empty-partition"
        try await store.database.writer.write { db in
            // Simulate hostile on-disk insertion without adding a mutation API
            // to the shipping repository or weakening normal preparation.
            try db.execute(
                sql: """
                INSERT INTO corpus_analysis_partitions (
                    id, run_id, partition_key, input_revision_ids_json
                ) VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    hostilePartitionID,
                    fixture.payload.runID,
                    "zz-hostile-empty-partition-nondefault",
                    "[]",
                ]
            )
        }
        let corruptedPartitions = try store.corpusAnalysis.fetchPartitions(
            matterID: fixture.matterID,
            runID: fixture.payload.runID
        )
        let corruptedSlices = try store.corpusAnalysis.fetchSlices(
            matterID: fixture.matterID,
            runID: fixture.payload.runID
        )
        let hostilePartition = try XCTUnwrap(
            corruptedPartitions.first { $0.id == hostilePartitionID }
        )
        XCTAssertEqual(corruptedPartitions.count, originalPartitions.count + 1)
        XCTAssertEqual(hostilePartition.inputRevisionIDsJSON, "[]")
        XCTAssertTrue(corruptedSlices.allSatisfy { $0.partitionID != hostilePartitionID })

        let probe = ModelResolutionProbe(resolvedModel: Self.pinnedModel)
        let runner = makeProductionRunner(store: store, probe: probe)
        let queue = makeQueue(store: store) { payload in
            try await runner.run(payload)
        }
        let jobID = try XCTUnwrap(queue.enqueueCorpusAnalysis(
            matterID: fixture.matterID,
            payload: fixture.payload
        ))
        await queue.waitUntilIdle()

        let job = try XCTUnwrap(store.documentJobs.fetchJob(id: jobID))
        let resolutionCalls = await probe.resolutionCalls
        let generationCalls = await probe.generationCalls
        XCTAssertEqual(job.status, DocumentProcessingJobStatus.failed.rawValue)
        XCTAssertFalse((job.errorSummary ?? "").isEmpty)
        XCTAssertEqual(resolutionCalls, 0, "partition/slice imbalance must fail before model load")
        XCTAssertEqual(generationCalls, 0, "an empty hostile partition must never generate")
    }

    func testTQUEUE03MissingAndWrongContentBoundModelsFailClosedWithoutFallback() async throws {
        // T-QUEUE-03 expected RED: no production corpus runner resolves the
        // exact content-bound artifact. A test closure can currently choose its
        // own comparison, while the shipping queue has no resolver at all.
        let store = try makeStore(testName: "TQUEUE03")
        let missing = try prepareFixture(store: store, caseName: "model-missing", partCount: 1)
        let wrong = try prepareFixture(store: store, caseName: "model-wrong", partCount: 1)
        let probe = ModelResolutionProbe(resolvedByRunKey: [
            "run-key-model-wrong": Self.alternatePinnedModel,
        ])
        let runner = makeProductionRunner(store: store, probe: probe)
        let queue = makeQueue(store: store) { payload in
            try await runner.run(payload)
        }

        let missingJobID = try XCTUnwrap(queue.enqueueCorpusAnalysis(
            matterID: missing.matterID,
            payload: missing.payload
        ))
        let wrongJobID = try XCTUnwrap(queue.enqueueCorpusAnalysis(
            matterID: wrong.matterID,
            payload: wrong.payload
        ))
        await queue.waitUntilIdle()

        let attempted = await probe.attemptedModels
        let generationCalls = await probe.generationCalls
        let missingJob = try XCTUnwrap(store.documentJobs.fetchJob(id: missingJobID))
        let wrongJob = try XCTUnwrap(store.documentJobs.fetchJob(id: wrongJobID))

        XCTAssertEqual(attempted.count, 2, "each valid job receives one production resolver check")
        XCTAssertEqual(generationCalls, 0, "missing and wrong artifacts must not generate")
        XCTAssertEqual(missingJob.status, DocumentProcessingJobStatus.failed.rawValue)
        XCTAssertEqual(wrongJob.status, DocumentProcessingJobStatus.failed.rawValue)
        XCTAssertTrue(missingJob.errorSummary?.contains(Self.pinnedModel.modelRepository) == true)
        XCTAssertTrue(wrongJob.errorSummary?.contains(Self.pinnedModel.modelRevision) == true)
        XCTAssertFalse((wrongJob.errorSummary ?? "").isEmpty)
    }

    func testTQUEUE01LegacyRunIDPayloadFailsClosedBeforeAnyRunnerOrModelCall() async throws {
        // T-QUEUE-01 expected RED: the current run-id-only payload is accepted as
        // the production format. Once v2 ships, legacy jobs must be failed with
        // an explicit non-empty explanation and never reconstructed from live state.
        let store = try makeStore(testName: "TQUEUE01Legacy")
        let matter = try store.matters.createMatter(name: "Synthetic legacy queue payload")
        let job = try store.documentJobs.enqueueJob(
            matterID: matter.id,
            kind: DocumentProcessingJobKind.corpusAnalysis.rawValue,
            payloadJSON: #"{"run_id":"legacy-run-id-only-must-not-run"}"#
        )
        let recorder = LegacyRunnerRecorder()
        let queue = makeQueue(store: store) { payload in
            await recorder.record(payload)
        }

        queue.bootstrap()
        await queue.waitUntilIdle()

        let persisted = try XCTUnwrap(store.documentJobs.fetchJob(id: job.id))
        let dispatchedPayloads = await recorder.payloads
        XCTAssertEqual(persisted.status, DocumentProcessingJobStatus.failed.rawValue)
        XCTAssertEqual(persisted.phase, DocumentProcessingPhase.failed.rawValue)
        XCTAssertFalse((persisted.errorSummary ?? "").isEmpty)
        XCTAssertTrue(dispatchedPayloads.isEmpty, "legacy payloads must fail before runner dispatch")
    }

    private static let requestDigest = String(repeating: "9", count: 64)
    private static let pinnedRevision = String(repeating: "d", count: 40)
    private static let pinnedModel = CorpusAnalysisPinnedModel(
        modelRepository: "synthetic/legal-review-model-nondefault",
        modelRevision: pinnedRevision,
        contentBindingAlgorithm: RuntimeModelContentBinding.fingerprintAlgorithm,
        contentBindingSchemaVersion: RuntimeModelContentBinding.supportedManifestSchemaVersion,
        artifactFingerprintSHA256: String(repeating: "a", count: 64)
    )
    private static let alternatePinnedModel = CorpusAnalysisPinnedModel(
        modelRepository: "synthetic/legal-review-model-nondefault",
        modelRevision: pinnedRevision,
        contentBindingAlgorithm: RuntimeModelContentBinding.fingerprintAlgorithm,
        contentBindingSchemaVersion: RuntimeModelContentBinding.supportedManifestSchemaVersion,
        artifactFingerprintSHA256: String(repeating: "b", count: 64)
    )

    private func makePayload(
        runID: String,
        matterID: String = "matter-nondefault-queue"
    ) -> CorpusAnalysisJobPayload {
        CorpusAnalysisJobPayload(
            schemaVersion: 2,
            runID: runID,
            requestDigest: Self.requestDigest,
            task: .exhaustiveList(makeQueuedRequest(
                runKey: "run-key-nondefault-queue",
                matterID: matterID,
                documentIDs: ["document-zeta", "document-alpha"]
            )),
            pinnedModel: Self.pinnedModel
        )
    }

    private func makeQueuedRequest(
        runKey: String,
        matterID: String,
        documentIDs: [String]
    ) -> ExhaustiveListQueuedRequest {
        ExhaustiveListQueuedRequest(
            taskSchemaVersion: ExhaustiveListTask.schemaVersion,
            promptBuilderVersion: ExhaustiveListTask.promptBuilderVersion,
            runKey: runKey,
            matterID: matterID,
            title: "Synthetic privilege review matrix",
            query: "List every nondefault privilege indicator and its exact source.",
            scope: CorpusAnalysisScope(schemaVersion: 7, documentIDs: documentIDs),
            characterBudget: 31_337,
            maximumRetryCount: 4
        )
    }

    private func queuedRequest(
        from payload: CorpusAnalysisJobPayload
    ) throws -> ExhaustiveListQueuedRequest {
        if case .exhaustiveList(let request) = payload.task { return request }
        throw QueueContractTestError.unexpectedTask
    }

    private func prepareFixture(
        store: SupraStore,
        caseName: String,
        partCount: Int
    ) throws -> PreparedQueueFixture {
        let matter = try store.matters.createMatter(name: "Synthetic prepared \(caseName)")
        let documentID = try insertDocument(
            store: store,
            matterID: matter.id,
            name: "\(caseName).txt",
            partTexts: (1...partCount).map { index in
                "NONDEFAULT-\(caseName)-PART-\(index)-" + String(repeating: "x", count: 97)
            }
        )
        let payload = try preparePayload(
            store: store,
            matterID: matter.id,
            documentID: documentID,
            caseName: caseName
        )
        let run = try XCTUnwrap(store.corpusAnalysis.fetchRun(matterID: matter.id, id: payload.runID))
        XCTAssertEqual(run.requestSchemaVersion, 2)
        XCTAssertEqual(run.requestDigest, payload.requestDigest)
        XCTAssertFalse(
            try store.corpusAnalysis.fetchPartitions(matterID: matter.id, runID: payload.runID).isEmpty
        )
        XCTAssertFalse(
            try store.corpusAnalysis.fetchSlices(matterID: matter.id, runID: payload.runID).isEmpty
        )
        return PreparedQueueFixture(matterID: matter.id, documentID: documentID, payload: payload)
    }

    private func preparePayload(
        store: SupraStore,
        matterID: String,
        documentID: String,
        caseName: String
    ) throws -> CorpusAnalysisJobPayload {
        try CorpusAnalysisQueuePreparer(store: store).prepareExhaustiveList(
            request: makeQueuedRequest(
                runKey: "run-key-\(caseName)",
                matterID: matterID,
                documentIDs: [documentID]
            ),
            pinnedModel: Self.pinnedModel
        )
    }

    private func insertDocument(
        store: SupraStore,
        matterID: String,
        name: String,
        partTexts: [String]
    ) throws -> String {
        let key = name.replacingOccurrences(of: ".", with: "-")
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(
            sha256: "queue-contract-\(key)-\(UUID().uuidString)",
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
                derivationKey: "queue-contract-\(index)",
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
                selectionKey: "queue-contract-\(revision.partIndex)",
                selectedBy: "test",
                decisionJSON: #"{"rule":"queue-contract"}"#
            )
        }
        _ = try store.documentRevisions.replacePartsAndPersistLineage(
            documentID: document.id,
            parts: parts,
            revisions: revisions,
            selections: selections
        )
        return document.id
    }

    private func makeProductionRunner(
        store: SupraStore,
        probe: ModelResolutionProbe
    ) -> CorpusAnalysisQueueRunner {
        CorpusAnalysisQueueRunner(
            store: store,
            resolvePinnedModel: { pinnedModel, request in
                await probe.resolve(pinnedModel, runKey: request.runKey)
            },
            exhaustiveListGenerator: { input in
                await probe.recordGeneration(input)
                return #"{"schema_version":1,"items":[]}"#
            }
        )
    }

    private func makeStore(testName: String) throws -> SupraStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CorpusReviewQueueContract-\(testName)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SupraStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    private func makeQueue(
        store: SupraStore,
        runner: @escaping @Sendable (CorpusAnalysisJobPayload) async throws -> Void
    ) -> DocumentProcessingQueue {
        let storage = DocumentStorage(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(
                "CorpusReviewQueueContractStorage-\(UUID().uuidString)",
                isDirectory: true
            )
        )
        return DocumentProcessingQueue(
            store: store,
            importService: DocumentImportService(store: store, storage: storage, ocr: nil),
            makeIndexingService: { DocumentIndexingService(store: store) },
            notifier: SilentContractNotifier(),
            corpusAnalysisRunner: runner
        )
    }
}

private struct PreparedQueueFixture {
    var matterID: String
    var documentID: String
    var payload: CorpusAnalysisJobPayload
}

private enum QueueContractTestError: Error {
    case unexpectedTask
}

private actor ModelResolutionProbe {
    private let resolvedModel: CorpusAnalysisPinnedModel?
    private let resolvedByRunKey: [String: CorpusAnalysisPinnedModel]
    private(set) var attemptedModels: [CorpusAnalysisPinnedModel] = []
    private(set) var resolutionCalls = 0
    private(set) var generationCalls = 0

    init(resolvedModel: CorpusAnalysisPinnedModel?) {
        self.resolvedModel = resolvedModel
        self.resolvedByRunKey = [:]
    }

    init(resolvedByRunKey: [String: CorpusAnalysisPinnedModel]) {
        self.resolvedModel = nil
        self.resolvedByRunKey = resolvedByRunKey
    }

    func resolve(
        _ requested: CorpusAnalysisPinnedModel,
        runKey: String
    ) -> CorpusAnalysisPinnedModel? {
        attemptedModels.append(requested)
        resolutionCalls += 1
        return resolvedByRunKey[runKey] ?? resolvedModel
    }

    func recordGeneration(_ input: ExhaustiveListGenerationInput) {
        _ = input.partition.partitionID
        generationCalls += 1
    }
}

private actor LegacyRunnerRecorder {
    private(set) var payloads: [CorpusAnalysisJobPayload] = []
    func record(_ payload: CorpusAnalysisJobPayload) { payloads.append(payload) }
}

private struct SilentContractNotifier: DocumentNotifying {
    func authorizationStatus() async -> DocumentNotificationAuthorizationStatus { .denied }
    func requestAuthorization() async -> DocumentNotificationAuthorizationStatus { .denied }
    func notify(title: String, body: String) async {}
}
