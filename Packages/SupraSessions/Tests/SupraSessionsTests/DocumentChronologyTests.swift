import Foundation
import SupraCore
import SupraDocuments
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

@MainActor
final class DocumentChronologyTests: XCTestCase {

    func testTENG13ChronologyPersistsCoverageAndPassAuditWithoutChangingVisibleOutput() async throws {
        // Expected RED: DocumentChronologyController has no lastCorpusRunID and
        // the existing private orchestration never persists a chronology corpus
        // run, coverage denominator, dropped-source ledger, or per-pass audit.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic chronology parity")
        try await indexDoc(store, matter.id, nil, "amended-complaint.txt", "McKernon Motors amended complaint filed 2023-11-02.")
        try await indexDoc(store, matter.id, nil, "brake-failure-analysis.txt", "Brake failure analysis dated 2023-11-05.")
        try await indexDoc(store, matter.id, nil, "correspondence-liberty-rail.txt", "Correspondence with Liberty Rail on 2023-11-09.")
        try await indexDoc(store, matter.id, nil, "deposition-calloway.txt", "Deposition of Calloway taken 2023-11-14.")
        try await indexDoc(store, matter.id, nil, "expert-report-metallurgy.txt", "Metallurgy expert report dated 2023-11-20.")
        try await indexDoc(store, matter.id, nil, "warranty-terms-mckernon.txt", "Warranty terms executed 2023-11-27.")
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "| Date | Event | Source |\n| 2023-11-02 | Complaint filed [S1] | [S1] |"),
                .event(request, 1, .generationCompleted),
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime, maxSources: 3)
        let result = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID()))

        let expectedMarkdown = """
        > ⚠️ **DOCUMENT SUPPORT NEEDS REVIEW — DO NOT RELY.** Proposition document-proposition-1 came from an incompletely indexed scope. Generated from an incompletely indexed scope.

        > ⚠️ **CHRONOLOGY NEEDS REVIEW — DO NOT RELY.** One or more extraction passes omitted source labels; their dated facts may be uncovered.

        | Date | Event | Source |
        |---|---|---|
        | 2023-11-02 | Complaint filed [S1] | [S1] |

        ## Sources
        - **[S1]** amended-complaint.txt — chars 0–51
          > McKernon Motors amended complaint filed 2023-11-02.
        - **[S2]** brake-failure-analysis.txt — chars 0–40
          > Brake failure analysis dated 2023-11-05.
        - **[S3]** correspondence-liberty-rail.txt — chars 0–47
          > Correspondence with Liberty Rail on 2023-11-09.
        """
        let expectedMessage = "Chronology covers 3 of 6 dated sources; omitted to fit the model's budget: deposition-calloway.txt, expert-report-metallurgy.txt, warranty-terms-mckernon.txt. Narrow the scope or date range for full coverage."
        XCTAssertEqual(result.markdown, expectedMarkdown, "ledger adoption must preserve chronology markdown byte-for-byte")
        XCTAssertEqual(chronology.message, expectedMessage, "ledger adoption must preserve the existing UI coverage string")

        let runID = try XCTUnwrap(chronology.lastCorpusRunID)
        let run = try XCTUnwrap(store.corpusAnalysis.fetchRun(matterID: matter.id, id: runID))
        XCTAssertEqual(run.taskKind, CorpusAnalysisTaskKind.chronology.rawValue)
        XCTAssertEqual(run.status, CorpusAnalysisRunStatus.persisted.rawValue)
        XCTAssertEqual(run.structuredOutputVersionID, result.versionID)
        XCTAssertEqual(run.assuranceState, OutputAssuranceState.corpusIncomplete.rawValue)

        let coverage = try JSONDecoder().decode(
            CorpusAnalysisCoverage.self,
            from: Data(try XCTUnwrap(run.coverageJSON).utf8)
        )
        XCTAssertEqual(coverage.snapshotMemberCount, 6)
        XCTAssertEqual(coverage.eligibleMemberCount, 3)
        XCTAssertEqual(coverage.excludedMemberCount, 3)
        XCTAssertEqual(coverage.partitionCount, 3)
        XCTAssertEqual(coverage.succeededPartitionCount, 3)
        XCTAssertEqual(coverage.pendingPartitionCount, 0)
        XCTAssertEqual(coverage.balanceErrorCount, 0)

        let ledger = try JSONDecoder().decode(
            ChronologyLedgerReconciliationTestRecord.self,
            from: Data(try XCTUnwrap(run.reconciliationJSON).utf8)
        )
        XCTAssertEqual(ledger.droppedCount, 3)
        XCTAssertEqual(
            ledger.omittedDocumentNames,
            ["deposition-calloway.txt", "expert-report-metallurgy.txt", "warranty-terms-mckernon.txt"]
        )
        XCTAssertEqual(ledger.passes.count, 1)
        XCTAssertEqual(ledger.passes[0].sourceLabels, ["S1", "S2", "S3"])
        XCTAssertTrue(ledger.passes[0].coverageGap)
    }

    func testTENG14ChronologyCancelDiscardsOutputAndBalancesCancelledRunLedger() async throws {
        // Expected RED: cancellation currently discards output rows but creates
        // no durable run or partition ledger, so lastCorpusRunID is unavailable
        // and no cancelled/succeeded terminal accounting can be asserted.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic chronology cancellation")
        try await seedBrakeFilings(store, matter.id, count: 20)
        let secondPassStarted = expectation(description: "second chronology pass began streaming")
        let chronology = DocumentChronologyController(
            matterID: matter.id,
            store: store,
            runtimeClient: HangingSecondCallRuntimeClient(secondCallStarted: secondPassStarted)
        )

        let generation = Task {
            await chronology.generate(
                scope: .wholeMatter,
                format: .table,
                modelID: ModelID(),
                route: Self.tinyBatchRoute()
            )
        }
        await fulfillment(of: [secondPassStarted], timeout: 5)
        let runID = try XCTUnwrap(chronology.lastCorpusRunID)
        chronology.cancel()
        let result = await generation.value

        XCTAssertNil(result)
        XCTAssertEqual(chronology.message, "Chronology generation was cancelled.")
        XCTAssertTrue(try store.structuredOutputs.fetchOutputs(matterID: matter.id).isEmpty)
        XCTAssertTrue(try store.documentSources.fetchSourceSets(matterID: matter.id).isEmpty)

        let run = try XCTUnwrap(store.corpusAnalysis.fetchRun(matterID: matter.id, id: runID))
        XCTAssertEqual(run.status, CorpusAnalysisRunStatus.cancelled.rawValue)
        XCTAssertNil(run.structuredOutputVersionID)
        let coverage = try JSONDecoder().decode(
            CorpusAnalysisCoverage.self,
            from: Data(try XCTUnwrap(run.coverageJSON).utf8)
        )
        XCTAssertEqual(coverage.pendingPartitionCount, 0)
        XCTAssertEqual(coverage.terminalPartitionCount, coverage.partitionCount)
        XCTAssertGreaterThan(coverage.succeededPartitionCount, 0)
        XCTAssertGreaterThan(coverage.cancelledPartitionCount, 0)
        XCTAssertEqual(coverage.balanceErrorCount, 0)

        let partitions = try store.corpusAnalysis.fetchPartitions(matterID: matter.id, runID: runID)
        XCTAssertFalse(partitions.isEmpty)
        XCTAssertTrue(partitions.allSatisfy {
            $0.disposition != CorpusAnalysisPartitionDisposition.pending.rawValue
        })
    }

    func testTableChronologyUsesScopeOnlyDatedFactsWithCitations() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        let contracts = try store.documentLibrary.createFolder(matterID: matter.id, name: "Contracts")
        let notes = try store.documentLibrary.createFolder(matterID: matter.id, name: "Notes")

        try await indexDoc(store, matter.id, contracts.id, "agreement.txt", "The agreement was executed on March 3, 2024 and amended in July 2024.")
        try await indexDoc(store, matter.id, notes.id, "intake.txt", "Counsel met the client on January 5, 2024 about the dispute.")

        // The model echoes a chronology citing the provided sources.
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "| Date | Event | Source |\n| 2024-01-05 | Counsel met client [S1] | [S1] |"),
                .event(request, 1, .generationCompleted)
            ])
        })

        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        // Narrative from the Notes folder only: must not include the contract date.
        let notesResult = try XCTUnwrapAsync(await chronology.generate(scope: RetrievalScope(folderIDs: [notes.id]), format: .narrative, modelID: ModelID()))
        XCTAssertEqual(notesResult.status, StructuredOutputStatus.complete.rawValue)
        // The source set for the notes-only chronology references only the notes doc.
        let notesSources = try store.documentSources.fetchSources(structuredOutputVersionID: notesResult.versionID)
        XCTAssertFalse(notesSources.isEmpty)
        let notesDoc = try XCTUnwrap(store.documentLibrary.fetchDocuments(matterID: matter.id).first { $0.displayName == "intake.txt" })
        XCTAssertTrue(notesSources.allSatisfy { $0.documentID == notesDoc.id })

        // Whole-matter table chronology references both documents.
        let allResult = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID()))
        let allOutput = try XCTUnwrap(store.structuredOutputs.fetchOutputs(matterID: matter.id).first { $0.id == allResult.outputID })
        XCTAssertEqual(allOutput.outputType, StructuredOutputType.factChronologyTable.rawValue)
        let allSources = try store.documentSources.fetchSources(structuredOutputVersionID: allResult.versionID)
        XCTAssertEqual(Set(allSources.map(\.documentID)).count, 2)
    }

    func testRegenerateCreatesNewVersionWithFreshSourceSet() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        try await indexDoc(store, matter.id, nil, "a.txt", "Agreement executed March 3, 2024.")
        let runtime = StubRuntimeClient(outcome: { request in
            .events([.event(request, 0, .token, token: "| Date | Event | Source |\n| 2024-03-03 | Executed [S1] | [S1] |"), .event(request, 1, .generationCompleted)])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let first = await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID())
        let firstResult = try XCTUnwrap(first)
        let regen = await chronology.regenerate(outputID: firstResult.outputID, modelID: ModelID())
        let regenResult = try XCTUnwrap(regen)

        // Same output, new version, with its own attached source set.
        XCTAssertEqual(regenResult.outputID, firstResult.outputID)
        XCTAssertNotEqual(regenResult.versionID, firstResult.versionID)
        XCTAssertEqual(try store.structuredOutputs.fetchVersions(structuredOutputID: firstResult.outputID).count, 2)
        XCTAssertFalse(try store.documentSources.fetchSources(structuredOutputVersionID: regenResult.versionID).isEmpty)
    }

    func testChronologyUsesStructuredOutputRouteOptionsAndPrompt() async throws {
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Acme")
        try await indexDoc(store, matter.id, nil, "timeline.txt", "The amendment was signed on July 9, 2024.")
        let runtime = StubRuntimeClient(outcome: { request in
            XCTAssertEqual(request.options.preset, .legalResearch)
            XCTAssertTrue(request.systemPrompt?.contains("legal document analysis assistant") ?? false)
            return .events([
                .event(request, 0, .token, token: "| Date | Event | Source |\n| 2024-07-09 | Amendment signed [S1] | [S1] |"),
                .event(request, 1, .generationCompleted)
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let generated = await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID())

        XCTAssertNotNil(generated)
    }

    func testUnsupportedChronologyCannotBecomeComplete() async throws {
        // ACR-DOCSUP-INT-04 expected RED: a resolved S1 currently marks the chronology
        // complete even when its proposition is absent from the cited source.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "Synthetic Matter A")
        try await indexDoc(store, matter.id, nil, "timeline.txt", "A status conference occurred January 5, 2025.")
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "| Date | Event | Source |\n| 2025-09-09 | Judgment entered [S1] | [S1] |"),
                .event(request, 1, .generationCompleted),
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let generated = await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID())
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.status, StructuredOutputStatus.needsReview.rawValue)
        let version = try XCTUnwrap(try store.structuredOutputs.fetchVersions(structuredOutputID: result.outputID).first)
        XCTAssertEqual(version.verificationStatus, OutputVerificationStatus.needsReview.rawValue)
        XCTAssertNotNil(version.verificationJSON)
    }

    func testDateExtractionDetectsCommonForms() {
        XCTAssertTrue(DateExtraction.containsDate("Signed on March 3, 2024."))
        XCTAssertTrue(DateExtraction.containsDate("Signed on 5 January 2024."))
        XCTAssertTrue(DateExtraction.containsDate("Signed on the 5th day of January, 2024."))
        XCTAssertTrue(DateExtraction.containsDate("2024-03-03 filing"))
        XCTAssertTrue(DateExtraction.containsDate("Due 3/3/2024"))
        XCTAssertTrue(DateExtraction.containsDate("Closed in 2023"))
        XCTAssertFalse(DateExtraction.containsDate("No dates here at all."))
    }

    // MARK: - W3.0 harvest fix (batched-chronology work order, Phase 1)

    func testMetadataDatesDoNotStarveTextChunks() async throws {
        // Every document carries BOTH a metadata date AND one dated text chunk.
        // Today `harvestSources` appends each document's metadata-date source
        // UNCONDITIONALLY — ahead of the `maxSources` cap that only text chunks are
        // checked against — so with enough metadata-dated documents the uncapped
        // metadata sources consume the budget and dated text chunks are dropped.
        //
        // Expected RED: with the default 30-source cap and 35 documents, the metadata
        // and text sources interleave per document, so only 15 documents' dated text
        // chunks survive before the cap fills (the other 20 are dropped) — the
        // text-chunk source count (15) is NOT equal to the document count (35).
        //
        // NOTE ON THE ASSERTION (deviation, see report): the work order phrased this
        // as "assert at least one text-chunk source survives", expecting zero
        // survivors. Because metadata and chunks interleave per document, the first
        // ~15 chunks always slip in before the cap fills, so a bare "≥ 1" assertion is
        // already GREEN and cannot observe the bug. The genuine behavioral RED for
        // this exact fixture is "no dated chunk is starved" → text-chunk count equals
        // document count. The W3.0 fix routes metadata sources through the same cap
        // and raises the default cap to 1,000, letting every dated chunk survive
        // (35 == 35, GREEN).
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")

        for i in 1...35 {
            let name = String(format: "mckernon-record-%02d.txt", i)
            try await indexDoc(
                store, matter.id, nil, name,
                "McKernon Motors record \(i): brake inspection dated 2024-03-03.",
                metadataCreatedAt: Date(timeIntervalSince1970: 1_500_000_000 + Double(i) * 86_400)
            )
        }

        // Any valid table answer; the assertion is on the persisted source packet.
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "| Date | Event | Source |\n| 2024-03-03 | Brake inspection [S1] | [S1] |"),
                .event(request, 1, .generationCompleted)
            ])
        })
        // Default maxSources (1,000) — the corrected safety cap under test.
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let result = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID()))

        let docCount = try store.documentLibrary.fetchDocuments(matterID: matter.id).count
        let sources = try store.documentSources.fetchSources(structuredOutputVersionID: result.versionID)
        // Metadata-date rows carry no chunkID; text-chunk rows do.
        let metadataSources = sources.filter { $0.chunkID == nil }
        let textChunkSources = sources.filter { $0.chunkID != nil }

        // Precondition: metadata-date seeding wired one metadata source per document.
        // A failure here means the harness could not seed `metadataCreatedAt`, not
        // that the feature is (in)correct.
        XCTAssertEqual(metadataSources.count, docCount, "each seeded document should contribute one metadata-date source")
        // Invariant under test: metadata dates must not starve dated text chunks.
        XCTAssertEqual(textChunkSources.count, docCount, "every document's dated text chunk should survive the harvest; got \(textChunkSources.count) of \(docCount)")
    }

    func testOmittedDocumentNamesAppearInMessage() async throws {
        // Six distinctively named documents, each with one dated text chunk, over a
        // small explicit cap of 3. The first three (alphabetically) survive; the last
        // three are omitted.
        //
        // Expected RED: the omission message is the aggregate "Chronology covers 3 of
        // 6 dated sources; the rest were omitted…" string, which names no documents,
        // so it does not contain any omitted document's display name. The W3.0 fix
        // makes produce() name up to five omitted documents in the message.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")

        // Alphabetical order determines survival: a/b/c survive (cap 3); d/e/w omitted.
        try await indexDoc(store, matter.id, nil, "amended-complaint.txt", "McKernon Motors amended complaint filed 2023-11-02.")
        try await indexDoc(store, matter.id, nil, "brake-failure-analysis.txt", "Brake failure analysis dated 2023-11-05.")
        try await indexDoc(store, matter.id, nil, "correspondence-liberty-rail.txt", "Correspondence with Liberty Rail on 2023-11-09.")
        try await indexDoc(store, matter.id, nil, "deposition-calloway.txt", "Deposition of Calloway taken 2023-11-14.")
        try await indexDoc(store, matter.id, nil, "expert-report-metallurgy.txt", "Metallurgy expert report dated 2023-11-20.")
        try await indexDoc(store, matter.id, nil, "warranty-terms-mckernon.txt", "Warranty terms executed 2023-11-27.")

        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "| Date | Event | Source |\n| 2023-11-02 | Complaint filed [S1] | [S1] |"),
                .event(request, 1, .generationCompleted)
            ])
        })
        // Explicit small cap so only three of six dated chunks survive.
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime, maxSources: 3)

        // Unwrapping the result proves generation actually ran (and set `message` via
        // the real omission path) instead of bailing early into an unrelated message.
        _ = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID()))

        let message = try XCTUnwrap(chronology.message)
        // "deposition-calloway.txt" is the first omitted document (4th alphabetically).
        XCTAssertTrue(
            message.contains("deposition-calloway.txt"),
            "omission message should name an omitted document; got: \(message)"
        )
    }

    // MARK: - W3.1 batched chronology (WO 42 follow-up)
    //
    // Shared fixture: twenty synthetic McKernon Motors "brake filing" documents,
    // each with one date-bearing chunk (~690 packed characters), generated with a
    // route whose 4,096-token context yields an 11,264-byte serialized-request
    // estimate before system-prompt overhead. The packet plus JSON envelope
    // therefore requires more than one batch. The
    // scripted model (see `scriptedAnswer`) echoes one supported table row per
    // label it is shown — and, when shown the ENTIRE packet at once (both S1 and
    // S20 in one prompt), emulates the real context-window failure this feature
    // fixes by reproducing only the earliest three sources.

    func testLargeScopeRunsMultipleBatchesAndMergesChronologically() async throws {
        // Expected RED before batching: produce() made exactly one generate call over the
        // whole packet — the call-count assertion fails (1 is not > 1), and the
        // truncated single-pass answer leaves the later batches' rows (e.g. the
        // 2024-01-10 and 2024-01-20 filings) missing from the final markdown.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 20)
        let log = PromptLog()
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: Self.batchScriptedRuntime(log: log))

        let result = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID(), route: Self.tinyBatchRoute()))

        XCTAssertGreaterThan(log.prompts.count, 1, "a packet past the serialized-size budget must run multiple map passes")
        let markdown = result.markdown
        let early = try XCTUnwrap(markdown.range(of: "| 2024-01-01 | Brake filing 1 recorded"), "first batch's earliest row is missing")
        let middle = try XCTUnwrap(markdown.range(of: "| 2024-01-10 | Brake filing 10 recorded"), "mid-packet row is missing")
        let late = try XCTUnwrap(markdown.range(of: "| 2024-01-20 | Brake filing 20 recorded"), "last batch's row is missing — later batches were dropped")
        XCTAssertTrue(
            early.lowerBound < middle.lowerBound && middle.lowerBound < late.lowerBound,
            "merged rows must appear in ascending date order"
        )
    }

    func testGlobalSourceLabelsStableAcrossBatches() async throws {
        // Expected RED before batching: there was a single pass, so the map-prompt count
        // assertion fails (1 is not > 1) — per-batch global-label stability is
        // unobservable until batching exists.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 20)
        let log = PromptLog()
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: Self.batchScriptedRuntime(log: log))

        _ = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID(), route: Self.tinyBatchRoute()))

        let mapPrompts = log.prompts.filter { $0.contains("BEGIN_UNTRUSTED_SOURCE_DATA") }
        XCTAssertGreaterThan(mapPrompts.count, 1, "the packet must be split across multiple map passes")
        for n in 1...20 {
            // The trailing quote pins the exact envelope label ("S2" cannot match "S20").
            let needle = "\"label\":\"S\(n)\""
            let occurrences = mapPrompts.filter { $0.contains(needle) }.count
            XCTAssertEqual(occurrences, 1, "label S\(n) must appear in exactly one map pass — labels are global and never restart per batch")
        }
        XCTAssertTrue(
            mapPrompts.allSatisfy { !$0.contains("\"label\":\"S21\"") },
            "no pass may relabel beyond the twenty harvested sources"
        )
    }

    func testNarrativeSynthesisUsesMergedEntriesOnly() async throws {
        // Expected RED before batching: narrative was one grounded pass — the only request's
        // prompt contains the untrusted source envelope, so the final-request
        // assertions (no envelope; merged entries present) fail, as does the
        // call-count assertion.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 20)
        let log = PromptLog()
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: Self.batchScriptedRuntime(log: log))

        _ = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .narrative, modelID: ModelID(), route: Self.tinyBatchRoute()))

        XCTAssertGreaterThan(log.prompts.count, 1, "narrative over a multi-batch packet needs map passes plus one synthesis pass")
        let synthesis = try XCTUnwrap(log.prompts.last, "no generate call recorded")
        XCTAssertFalse(
            synthesis.contains("BEGIN_UNTRUSTED_SOURCE_DATA"),
            "the second-stage synthesis prompt consumes merged entries, never raw source envelopes"
        )
        XCTAssertTrue(synthesis.contains("Brake filing 1 recorded"), "synthesis prompt must carry merged entries from the first batch")
        XCTAssertTrue(synthesis.contains("Brake filing 20 recorded"), "synthesis prompt must carry merged entries from the last batch")
    }

    func testCancelMidGenerationPersistsNothing() async throws {
        // Expected RED: compile error — value of type 'DocumentChronologyController'
        // has no member 'cancel'.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 20)
        let secondPassStarted = expectation(description: "second map pass began streaming")
        let runtime = HangingSecondCallRuntimeClient(secondCallStarted: secondPassStarted)
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let generation = Task { await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID(), route: Self.tinyBatchRoute()) }
        // The runtime double hangs its second stream, so the controller is
        // provably suspended inside batch 2 when the cancel lands.
        await fulfillment(of: [secondPassStarted], timeout: 5)
        chronology.cancel()
        let result = await generation.value

        XCTAssertNil(result, "a cancelled chronology must not produce a result")
        XCTAssertEqual(chronology.message, "Chronology generation was cancelled.")
        XCTAssertTrue(
            try store.structuredOutputs.fetchOutputs(matterID: matter.id).isEmpty,
            "no structured output row may persist after cancellation"
        )
    }

    func testCallerTaskCancellationPropagatesAndPersistsNothing() async throws {
        // Review finding 12. Expected RED: run() awaits an unstructured stored
        // Task, so cancelling only the caller leaves that inner task streaming
        // batch 2 indefinitely. The completion expectation times out until
        // caller cancellation is forwarded to the owned generation task.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 20)
        let secondPassStarted = expectation(description: "second map pass began streaming")
        let callerCancellationFinished = expectation(description: "caller cancellation ended chronology generation")
        let runtime = HangingSecondCallRuntimeClient(secondCallStarted: secondPassStarted)
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let generation = Task { () -> DocumentQAController.QAResult? in
            defer { callerCancellationFinished.fulfill() }
            return await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID(), route: Self.tinyBatchRoute())
        }
        await fulfillment(of: [secondPassStarted], timeout: 5)

        generation.cancel()
        await fulfillment(of: [callerCancellationFinished], timeout: 1)
        // Cleanup for the known-RED implementation after the timeout. A fixed
        // implementation has already ended, so this is a harmless no-op there.
        chronology.cancel()
        let result = await generation.value

        XCTAssertNil(result)
        XCTAssertEqual(chronology.message, "Chronology generation was cancelled.")
        XCTAssertTrue(
            try store.structuredOutputs.fetchOutputs(matterID: matter.id).isEmpty,
            "cancelling the caller task must never allow a detached inner run to persist an output"
        )
    }

    func testVerifierChecksAllBatchSources() async throws {
        // Expected RED: the truncated single pass never emits the last batch's
        // table row, and the persisted verification JSON records no result
        // touching S20. (The assertion is row-scoped — a bare "[S20]" search
        // would have silently passed via the source appendix, which always lists
        // every harvested label.)
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 20)
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: Self.batchScriptedRuntime(log: PromptLog()))

        let result = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID(), route: Self.tinyBatchRoute()))

        XCTAssertTrue(
            result.markdown.contains("| 2024-01-20 | Brake filing 20 recorded"),
            "the merged chronology must carry the last batch's cited row (appendix mentions don't count)"
        )
        // Complete status proves S20 resolved AND verified against source 20's
        // text: a verifier fed only batch 1's sources would flag S20 unresolved
        // and force needsReview.
        XCTAssertEqual(result.status, StructuredOutputStatus.complete.rawValue)
        let version = try XCTUnwrap(
            try store.structuredOutputs.fetchVersions(structuredOutputID: result.outputID).first { $0.id == result.versionID }
        )
        let verificationJSON = try XCTUnwrap(version.verificationJSON)
        XCTAssertTrue(verificationJSON.contains("S20"), "verification results must cover sources from every batch, not just the first")
    }

    func testUnparsedMapRowsForceNeedsReviewWithNote() async throws {
        // Expected RED before strict parsing: no map-pass parser existed, so the scripted malformed
        // rows are never produced, the clean truncated single-pass answer verifies
        // complete, and the unparsed-row note is absent; both assertions fail.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 20)
        let chronology = DocumentChronologyController(
            matterID: matter.id, store: store,
            runtimeClient: Self.batchScriptedRuntime(log: PromptLog(), appendMalformedRowsToFinalBatch: true)
        )

        let result = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID(), route: Self.tinyBatchRoute()))

        XCTAssertEqual(result.status, StructuredOutputStatus.needsReview.rawValue, "dropped model output must force review")
        XCTAssertTrue(
            result.markdown.contains("2 intermediate chronology lines could not be parsed and were omitted."),
            "the saved chronology must visibly disclose how many map-pass lines were dropped"
        )
        XCTAssertTrue(
            result.warnings.contains("2 intermediate chronology lines could not be parsed and were omitted."),
            "supplemental chronology review reasons must reach QAResult.warnings, not only artifact markdown"
        )
        let version = try XCTUnwrap(
            try store.structuredOutputs.fetchVersions(structuredOutputID: result.outputID).first { $0.id == result.versionID }
        )
        XCTAssertEqual(
            version.verificationStatus, OutputVerificationStatus.needsReview.rawValue,
            "an artifact forced to review by chronology gates must persist needs_review so export/UI gates cannot treat it as all-supported"
        )
    }

    func testSingleBatchIsSinglePass() async throws {
        // STANDING GUARD (green from day one — methodology §2): a scope whose
        // table packet fits one serialized-size budget must take the direct
        // single-pass path. This test passes before the batching implementation
        // lands; its job is to fail if the Phase-2 rewrite (or any later change)
        // turns small scopes into multi-pass map/merge runs — added latency and
        // an intermediate parse stage where none is needed.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 2)
        let log = PromptLog()
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: Self.batchScriptedRuntime(log: log))

        let result = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID()))

        XCTAssertEqual(log.prompts.count, 1, "a packet within one batch budget must remain a single pass")
        XCTAssertEqual(result.status, StructuredOutputStatus.complete.rawValue)
    }

    func testSerializedPromptBudgetSplitsMetadataHeavyScope() async throws {
        // Review finding 17. Expected RED before envelope budgeting: the planner counted only each
        // source's short `packedText`, so metadata-heavy envelopes (IDs, names,
        // locators, JSON keys/escaping) remain one oversized prompt even when the
        // actual serialized request exceeds the safe prompt-token budget.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        for n in 1...60 {
            try await indexDoc(
                store, matter.id, nil, String(format: "metadata-record-%02d-with-a-long-descriptive-filename.txt", n),
                "Routine switching-yard maintenance note without a textual calendar value.",
                metadataCreatedAt: Date(timeIntervalSince1970: 1_704_067_200 + Double(n) * 86_400)
            )
        }
        let log = PromptLog()
        let route = Self.tinyBatchRoute()
        let chronology = DocumentChronologyController(
            matterID: matter.id,
            store: store,
            runtimeClient: Self.batchScriptedRuntime(log: log)
        )

        _ = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID(), route: route))

        let promptTokenBudget = PromptBudget.promptTokenBudget(
            maxContextTokens: route.options.maxContextTokens,
            maxOutputTokens: route.options.maxOutputTokens
        )
        let serializedByteBudget = promptTokenBudget * 4
        XCTAssertGreaterThan(log.prompts.count, 1, "the metadata envelope must be split using actual serialized size")
        XCTAssertTrue(
            log.prompts.allSatisfy { prompt in
                prompt.utf8.count + route.systemPrompt.utf8.count <= serializedByteBudget
            },
            "every request must fit the prompt budget after JSON and routed-system overhead"
        )
    }

    func testBatchOrderingFallsBackToDocumentCreatedAt() async throws {
        // Review finding 18. Expected RED: prepared sources currently carry only
        // metadataCreatedAt. With metadata absent, the repository's alphabetical
        // display-name order wins instead of the plan's document.createdAt
        // fallback, so the later a-file maps before the earlier z-file.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        let early = Date(timeIntervalSince1970: 1_672_531_200)
        let late = Date(timeIntervalSince1970: 1_704_067_200)
        try await indexDoc(
            store, matter.id, nil, "a-late-record.txt", Self.brakeFilingText(2), createdAt: late
        )
        try await indexDoc(
            store, matter.id, nil, "z-early-record.txt", Self.brakeFilingText(1), createdAt: early
        )
        let route = ModelRoute(
            mode: .legalResearch,
            role: .legalReasoning,
            modelIdentifier: "synthetic-ordering-model",
            // The exact budget now reserves the full output plus the 256-token
            // chat-template margin. 1,024 keeps one serialized source safe while
            // still forcing the two documents into separate map passes.
            options: GenerationOptions(preset: .extractive, maxContextTokens: 1_024, maxOutputTokens: 128),
            requiresCourtListener: false,
            requiresCitations: true,
            requiresJurisdiction: false,
            allowUngroundedLaw: false,
            systemPrompt: ""
        )
        let log = PromptLog()
        let chronology = DocumentChronologyController(
            matterID: matter.id,
            store: store,
            runtimeClient: Self.batchScriptedRuntime(log: log)
        )

        _ = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID(), route: route))

        let prompts = log.prompts
        XCTAssertEqual(prompts.count, 2, "the tiny serialized budget should place one document in each map pass")
        if prompts.count == 2 {
            XCTAssertTrue(prompts[0].contains(#""label":"S2""#), "the earlier-created z-file must map first despite its name")
            XCTAssertTrue(prompts[1].contains(#""label":"S1""#), "the later-created a-file must map second")
        }
    }

    // MARK: - §3.5 review-finding REDs (adversarial review of the batching diff)

    func testReentrantGenerateDoesNotDisconnectCancelFromLiveRun() async throws {
        // Review finding 3 (generationTask clobber). Expected RED: the re-entrant
        // generate() overwrites the live run's task handle and its defer nils it,
        // so cancel()'s task-cancellation half no-ops; the runtime cancel still
        // finishes the hung stream, but the un-cancelled task classifies the
        // resulting .interrupted as a failure — message is "Chronology generation
        // failed: Generation ended unexpectedly." instead of "Chronology
        // generation was cancelled."
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 20)
        let secondPassStarted = expectation(description: "second map pass began streaming")
        let runtime = HangingSecondCallRuntimeClient(secondCallStarted: secondPassStarted)
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let liveRun = Task { await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID(), route: Self.tinyBatchRoute()) }
        await fulfillment(of: [secondPassStarted], timeout: 5)
        // Re-entrant call while the live run is suspended mid-batch-2 (the
        // realistic double-click window). Launched concurrently — a compliant
        // fix may either bounce immediately or await the live run, and a
        // sequential await here would deadlock against the later cancel().
        let reentrant = Task { await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID(), route: Self.tinyBatchRoute()) }
        // Let the re-entrant call reach the controller before cancelling.
        await Task.yield()
        chronology.cancel()
        let liveResult = await liveRun.value
        let reentrantResult = await reentrant.value

        XCTAssertNil(liveResult, "the cancelled live run must not produce a result")
        XCTAssertNil(reentrantResult, "the re-entrant call must not produce a result")
        XCTAssertEqual(chronology.message, "Chronology generation was cancelled.")
        XCTAssertTrue(
            try store.structuredOutputs.fetchOutputs(matterID: matter.id).isEmpty,
            "no structured output row may persist after cancellation, re-entrant call or not"
        )
    }

    func testZeroEntryMapPassForcesNeedsReviewWithCoverageNote() async throws {
        // Review finding 4 (zero-entry map pass fail-open). Expected RED: the
        // final batch's prose-only answer parses to zero entries AND zero
        // unparsed rows, so its facts silently vanish — status stays "complete"
        // and the coverage note is absent from the saved markdown.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 20)
        let runtime = StubRuntimeClient(outcome: { request in
            let labels = Self.labelNumbers(in: request.prompt)
            let answer: String
            if labels.contains(20), !labels.contains(1) {
                // The final map pass answers as prose — not one pipe-bearing line.
                answer = "The remaining filings describe routine switching-yard maintenance and add no dated events."
            } else {
                answer = Self.scriptedAnswer(for: request.prompt, appendMalformedRowsToFinalBatch: false)
            }
            return .events([
                .event(request, 0, .token, token: answer),
                .event(request, 1, .generationCompleted)
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let result = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID(), route: Self.tinyBatchRoute()))

        XCTAssertEqual(result.status, StructuredOutputStatus.needsReview.rawValue, "a map pass that yielded no usable rows must force review")
        XCTAssertTrue(
            result.markdown.contains("1 of 2 extraction passes produced no usable rows; their sources may be uncovered."),
            "the saved chronology must disclose the uncovered pass"
        )
        XCTAssertTrue(
            result.warnings.contains("1 of 2 extraction passes produced no usable rows; their sources may be uncovered."),
            "the uncovered-pass gate must be exposed through QAResult.warnings"
        )
        let version = try XCTUnwrap(
            try store.structuredOutputs.fetchVersions(structuredOutputID: result.outputID).first { $0.id == result.versionID }
        )
        XCTAssertEqual(version.verificationStatus, OutputVerificationStatus.needsReview.rawValue)
    }

    func testPartiallyRepresentedMapPassForcesNeedsReviewWithSourceCoverageNote() async throws {
        // Review finding 13 (partial map-pass fail-open). Expected RED: unlike a
        // zero-entry pass, this final pass returns one valid supported row, so
        // parsing and verification both look clean while the other dated source
        // labels from that pass disappear without a trace.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 20)
        let runtime = StubRuntimeClient(outcome: { request in
            let labels = Self.labelNumbers(in: request.prompt)
            let answer: String
            if labels.contains(20), !labels.contains(1), let represented = labels.first {
                answer = """
                | Date | Event | Source |
                | 2024-01-\(String(format: "%02d", represented)) | Brake filing \(represented) recorded [S\(represented)] | [S\(represented)] |
                """
            } else {
                answer = Self.scriptedAnswer(for: request.prompt, appendMalformedRowsToFinalBatch: false)
            }
            return .events([
                .event(request, 0, .token, token: answer),
                .event(request, 1, .generationCompleted)
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let result = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID(), route: Self.tinyBatchRoute()))

        XCTAssertEqual(result.status, StructuredOutputStatus.needsReview.rawValue)
        XCTAssertTrue(
            result.markdown.contains("One or more extraction passes omitted source labels; their dated facts may be uncovered."),
            "a partially represented pass needs a visible per-batch source-label coverage warning"
        )
        XCTAssertTrue(
            result.warnings.contains("One or more extraction passes omitted source labels; their dated facts may be uncovered."),
            "the same coverage reason must be exposed to the result/UI"
        )
    }

    func testOutOfBatchCitationForcesNeedsReviewAndStaysVisible() async throws {
        // Review finding 14 (cross-batch citation laundering). Expected RED: S20
        // exists globally, and the verifier accepts this row because S1 supports
        // it. Nothing currently records that the first map pass was never shown
        // S20, so the injected second label looks legitimate after merge.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 20)
        let runtime = StubRuntimeClient(outcome: { request in
            let labels = Self.labelNumbers(in: request.prompt)
            var answer = Self.scriptedAnswer(for: request.prompt, appendMalformedRowsToFinalBatch: false)
            if labels.contains(1), !labels.contains(20) {
                answer = answer.replacingOccurrences(
                    of: "Brake filing 1 recorded [S1] | [S1] |",
                    with: "Brake filing 1 recorded [S1] [S20] | [S1] [S20] |"
                )
            }
            return .events([
                .event(request, 0, .token, token: answer),
                .event(request, 1, .generationCompleted)
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let result = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID(), route: Self.tinyBatchRoute()))

        XCTAssertTrue(
            result.markdown.contains("| 2024-01-01 | Brake filing 1 recorded [S1] [S20]"),
            "fail-closed review must not hide or silently strip the model's out-of-batch citation"
        )
        XCTAssertEqual(result.status, StructuredOutputStatus.needsReview.rawValue)
        XCTAssertTrue(
            result.markdown.contains("1 intermediate citation(s) referred to a source outside its assigned source packet; review the affected rows."),
            "the saved chronology must disclose the map-boundary violation"
        )
    }

    func testMergeAddedMiscitationForcesNeedsReviewAndStaysVisible() async throws {
        // Review finding 5 (label-union laundering) — RED authored ahead of its
        // fix in the same session per coordinator ruling. Expected RED: batch 2
        // re-emits batch 1's 2024-01-01 row as a duplicate citing its own [S20],
        // whose source (brake filing 20, dated 2024-01-20) does not support that
        // row. Merge unions [S1, S20]; the verifier's any-of semantics passes on
        // S1 — the pre-fix artifact saved as "complete" with no note, laundering
        // the unsupported S20 citation into a verified-looking row.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 20)
        let runtime = StubRuntimeClient(outcome: { request in
            let labels = Self.labelNumbers(in: request.prompt)
            var answer = Self.scriptedAnswer(for: request.prompt, appendMalformedRowsToFinalBatch: false)
            if labels.contains(20), !labels.contains(1) {
                // Duplicate of batch 1's first row, mis-cited to this batch's S20.
                answer += "\n| 2024-01-01 | Brake filing 1 recorded [S20] | [S20] |"
            }
            return .events([
                .event(request, 0, .token, token: answer),
                .event(request, 1, .generationCompleted)
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let result = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID(), route: Self.tinyBatchRoute()))

        // No silent label removal: the union stays visible in the merged row
        // (a standing guard that remains green after the fix).
        XCTAssertTrue(
            result.markdown.contains("| 2024-01-01 | Brake filing 1 recorded [S1] [S20]"),
            "the merged row must keep the union-added label visible"
        )
        XCTAssertEqual(result.status, StructuredOutputStatus.needsReview.rawValue, "a union-added citation without extractive support must force review")
        XCTAssertTrue(
            result.markdown.contains("1 chronology citation(s) could not be verified against their sources; review the affected rows."),
            "the saved chronology must disclose the unverifiable merged citation"
        )
    }

    func testNarrativeOmittingMergedEntriesForcesNeedsReviewWithNote() async throws {
        // Review finding 7 (narrative completeness fail-open). Expected RED: the
        // scripted synthesis narrative reproduces only 2 of the 20 merged entries
        // (S1 and S20); both surviving sentences verify extractively, so the pre-fix
        // artifact persists as "complete" with no omission note — 18 facts
        // silently absent from a chronology whose appendix lists all 20 sources.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 20)
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: Self.batchScriptedRuntime(log: PromptLog()))

        let result = try XCTUnwrapAsync(await chronology.generate(scope: .wholeMatter, format: .narrative, modelID: ModelID(), route: Self.tinyBatchRoute()))

        XCTAssertEqual(result.status, StructuredOutputStatus.needsReview.rawValue, "silent narrative omission must force review")
        XCTAssertTrue(
            result.markdown.contains("The narrative omits 18 of 20 chronology entries; regenerate or use the table format."),
            "the saved narrative must disclose how many merged entries it dropped"
        )
        XCTAssertTrue(
            result.warnings.contains("The narrative omits 18 of 20 chronology entries; regenerate or use the table format."),
            "the omission gate must be exposed through QAResult.warnings"
        )
        let version = try XCTUnwrap(
            try store.structuredOutputs.fetchVersions(structuredOutputID: result.outputID).first { $0.id == result.versionID }
        )
        XCTAssertEqual(version.verificationStatus, OutputVerificationStatus.needsReview.rawValue)
    }

    func testNarrativeExtraExistingCitationCannotBorrowSupport() async throws {
        // Review finding 29. Expected RED: the aggregate verifier accepted S1's
        // support and never exposed that the same sentence's extra S2 citation
        // did not support filing 1; subset-based coverage also accepted it.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 2)
        let runtime = StubRuntimeClient(outcome: { request in
            let answer = if request.prompt.contains("MERGED ENTRIES:") {
                "Brake filing 1 recorded on 2024-01-01 [S1] [S2]. Brake filing 2 recorded on 2024-01-02 [S2]."
            } else {
                Self.scriptedAnswer(for: request.prompt, appendMalformedRowsToFinalBatch: false)
            }
            return .events([
                .event(request, 0, .token, token: answer),
                .event(request, 1, .generationCompleted),
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let result = try XCTUnwrapAsync(
            await chronology.generate(scope: .wholeMatter, format: .narrative, modelID: ModelID())
        )

        XCTAssertEqual(result.status, StructuredOutputStatus.needsReview.rawValue)
        XCTAssertTrue(result.warnings.contains(
            "1 final narrative citation(s) could not be verified independently against their sources; review the affected sentences."
        ))
        let version = try XCTUnwrap(
            try store.structuredOutputs.fetchVersions(structuredOutputID: result.outputID).first
        )
        XCTAssertEqual(version.verificationStatus, OutputVerificationStatus.needsReview.rawValue)
        XCTAssertTrue(version.verificationJSON?.contains("document-proposition-1-S2") == true)
    }

    func testFittingTableStillAuditsMismatchedCitationColumns() async throws {
        // Review finding 22. Pre-fix RED: fitting scopes bypass the strict map
        // parser. The final verifier accepts this row because supported S1 can
        // launder the mismatched-but-resolvable S2 Source column.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 2)
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(
                    request, 0, .token,
                    token: "| Date | Event | Source |\n| 2024-01-01 | Brake filing 1 recorded [S1] | [S2] |"
                ),
                .event(request, 1, .generationCompleted),
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let result = try XCTUnwrapAsync(
            await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID())
        )

        XCTAssertEqual(result.status, StructuredOutputStatus.needsReview.rawValue)
        XCTAssertTrue(
            result.warnings.contains("1 intermediate chronology lines could not be parsed and were omitted."),
            "the strict row contract must apply even when the scope takes the one-request path"
        )
    }

    func testFittingNarrativeUsesAuditableMapThenSynthesis() async throws {
        // Review finding 23. Pre-fix RED: a fitting narrative takes one raw
        // generation pass, leaving no merged entry set for completeness auditing.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 1)
        let log = PromptLog()
        let chronology = DocumentChronologyController(
            matterID: matter.id,
            store: store,
            runtimeClient: Self.batchScriptedRuntime(log: log)
        )

        _ = try XCTUnwrapAsync(
            await chronology.generate(scope: .wholeMatter, format: .narrative, modelID: ModelID())
        )

        XCTAssertEqual(log.prompts.count, 2, "narrative completeness requires a parseable map pass and a bounded synthesis pass")
        if log.prompts.count == 2 {
            XCTAssertTrue(log.prompts[0].contains("extracting dated facts"))
            XCTAssertTrue(log.prompts[1].contains("MERGED ENTRIES:"))
            XCTAssertFalse(log.prompts[1].contains("BEGIN_UNTRUSTED_SOURCE_DATA"))
        }
    }

    func testActualContextOverflowFallsBackToMapPass() async throws {
        // Review finding 24. The serialized-size estimate is deliberately only a
        // preflight. If the model tokenizer reports actual overflow, the result
        // must be discarded and retried through smaller map input instead of
        // failing the whole chronology or persisting rotated-context output.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 2)
        let log = PromptLog()
        let runtime = StubRuntimeClient(outcome: { request in
            log.record(request.prompt)
            if request.prompt.contains("building a fact chronology") {
                return .events([
                    .event(request, 0, .token, token: "discard me"),
                    .event(
                        request, 1, .generationCompleted,
                        metrics: RuntimeMetrics(contextOverflowed: true)
                    ),
                ])
            }
            let answer = Self.scriptedAnswer(for: request.prompt, appendMalformedRowsToFinalBatch: false)
            return .events([
                .event(request, 0, .token, token: answer),
                .event(request, 1, .generationCompleted),
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let result = try XCTUnwrapAsync(
            await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID())
        )

        XCTAssertEqual(log.prompts.count, 2)
        XCTAssertTrue(log.prompts[0].contains("building a fact chronology"))
        XCTAssertTrue(log.prompts[1].contains("extracting dated facts"))
        XCTAssertFalse(result.markdown.contains("discard me"), "output produced after real tokenizer overflow must never persist")
        XCTAssertEqual(result.status, StructuredOutputStatus.complete.rawValue)
    }

    func testActualMapOverflowSplitsAtSourceBoundaries() async throws {
        // Review finding 27. Expected RED before adaptive runtime recovery: a
        // map prompt that passed byte preflight but overflowed the real tokenizer
        // aborted the chronology instead of retrying smaller source ranges.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 2)
        let log = PromptLog()
        let runtime = StubRuntimeClient(outcome: { request in
            log.record(request.prompt)
            let labels = Self.labelNumbers(in: request.prompt)
            if request.prompt.contains("extracting dated facts"), labels.count > 1 {
                return .events([
                    .event(request, 0, .token, token: "discard overflowing map output"),
                    .event(
                        request, 1, .generationCompleted,
                        metrics: RuntimeMetrics(contextOverflowed: true)
                    ),
                ])
            }
            let answer = labels.isEmpty
                ? "Brake filing 1 recorded on 2024-01-01 [S1]. Brake filing 2 recorded on 2024-01-02 [S2]."
                : Self.scriptedAnswer(for: request.prompt, appendMalformedRowsToFinalBatch: false)
            return .events([
                .event(request, 0, .token, token: answer),
                .event(request, 1, .generationCompleted),
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let result = try XCTUnwrapAsync(
            await chronology.generate(scope: .wholeMatter, format: .narrative, modelID: ModelID())
        )

        let mapPrompts = log.prompts.filter { $0.contains("extracting dated facts") }
        XCTAssertEqual(mapPrompts.count, 3, "one overflowing map pass must retry as two source-boundary passes")
        XCTAssertEqual(log.prompts.count, 4, "the two successful map retries must feed one synthesis pass")
        XCTAssertFalse(result.markdown.contains("discard overflowing map output"))
        XCTAssertEqual(result.status, StructuredOutputStatus.complete.rawValue)
    }

    func testActualSynthesisOverflowSplitsAtEntryBoundaries() async throws {
        // Review finding 28. Expected RED before adaptive runtime recovery: a
        // synthesis prompt that overflowed the real tokenizer failed even though
        // its merged entries could be safely divided without touching raw data.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 2)
        let log = PromptLog()
        let runtime = StubRuntimeClient(outcome: { request in
            log.record(request.prompt)
            guard request.prompt.contains("MERGED ENTRIES:") else {
                let answer = Self.scriptedAnswer(for: request.prompt, appendMalformedRowsToFinalBatch: false)
                return .events([
                    .event(request, 0, .token, token: answer),
                    .event(request, 1, .generationCompleted),
                ])
            }

            let containsFirst = request.prompt.contains("Brake filing 1 recorded")
            let containsSecond = request.prompt.contains("Brake filing 2 recorded")
            if containsFirst, containsSecond {
                return .events([
                    .event(request, 0, .token, token: "discard overflowing synthesis output"),
                    .event(
                        request, 1, .generationCompleted,
                        metrics: RuntimeMetrics(contextOverflowed: true)
                    ),
                ])
            }
            let answer = containsFirst
                ? "Brake filing 1 recorded on 2024-01-01 [S1]."
                : "Brake filing 2 recorded on 2024-01-02 [S2]."
            return .events([
                .event(request, 0, .token, token: answer),
                .event(request, 1, .generationCompleted),
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let result = try XCTUnwrapAsync(
            await chronology.generate(scope: .wholeMatter, format: .narrative, modelID: ModelID())
        )

        let synthesisPrompts = log.prompts.filter { $0.contains("MERGED ENTRIES:") }
        XCTAssertEqual(synthesisPrompts.count, 3, "one overflowing synthesis must retry as two entry-boundary passes")
        XCTAssertEqual(log.prompts.count, 4, "one map pass plus three synthesis attempts are expected")
        XCTAssertFalse(result.markdown.contains("discard overflowing synthesis output"))
        XCTAssertEqual(result.status, StructuredOutputStatus.complete.rawValue)
    }

    func testRejectedReentryDoesNotPoisonSuccessfulRunMessage() async throws {
        // Review finding 25. Pre-fix RED: the rejected call writes "already
        // generating" into the active run's shared message, which survives a
        // later successful one-pass completion.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 1)
        let firstCallStarted = expectation(description: "first generation is held")
        let runtime = ControllableFirstCallRuntimeClient(firstCallStarted: firstCallStarted)
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let liveRun = Task {
            await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID())
        }
        await fulfillment(of: [firstCallStarted], timeout: 5)
        let rejected = await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID())
        XCTAssertNil(rejected)
        runtime.finishSuccessfully()
        let result = await liveRun.value

        XCTAssertNotNil(result)
        XCTAssertNil(chronology.message, "a rejected re-entry must not overwrite the owning run's user-facing state")
    }

    func testSaveFailureAtomicallyRollsBackOutputAndSourceSet() async throws {
        // Review finding 26. Pre-fix RED: output, source-set, and version writes
        // use separate transactions, so a forced version failure leaves a draft
        // output plus a pending source set even though generate() returns nil.
        let store = try makeStore()
        let matter = try store.matters.createMatter(name: "McKernon Motors v. Liberty Rail")
        try await seedBrakeFilings(store, matter.id, count: 1)
        try await store.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER chronology_version_failure
                BEFORE INSERT ON structured_output_versions
                BEGIN SELECT RAISE(FAIL, 'chronology save canary'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER chronology_source_cleanup_failure
                BEFORE DELETE ON document_source_sets
                BEGIN SELECT RAISE(FAIL, 'source cleanup must not be needed'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER chronology_output_cleanup_failure
                BEFORE DELETE ON structured_outputs
                BEGIN SELECT RAISE(FAIL, 'output cleanup must not be needed'); END
                """)
        }
        let runtime = StubRuntimeClient(outcome: { request in
            .events([
                .event(request, 0, .token, token: "| Date | Event | Source |\n| 2024-01-01 | Brake filing 1 recorded [S1] | [S1] |"),
                .event(request, 1, .generationCompleted),
            ])
        })
        let chronology = DocumentChronologyController(matterID: matter.id, store: store, runtimeClient: runtime)

        let result = await chronology.generate(scope: .wholeMatter, format: .table, modelID: ModelID())

        XCTAssertNil(result)
        XCTAssertTrue(try store.structuredOutputs.fetchOutputs(matterID: matter.id).isEmpty)
        XCTAssertTrue(
            try store.documentSources.fetchSourceSets(matterID: matter.id).isEmpty,
            "a failed save must roll back every provenance write in its transaction"
        )
    }

    // MARK: - Batching fixture + scripting helpers

    private func seedBrakeFilings(_ store: SupraStore, _ matterID: String, count: Int) async throws {
        for n in 1...count {
            try await indexDoc(store, matterID, nil, String(format: "brake-filing-%02d.txt", n), Self.brakeFilingText(n))
        }
    }

    /// One date-bearing chunk (~690 characters) per synthetic filing — under the
    /// chunker's 1,200-character maximum so each document yields exactly one
    /// chunk, and large enough that twenty of them (~13,800 source-text
    /// characters plus JSON envelope overhead) overflow the route's serialized
    /// request budget. The filler contains no dates.
    private static func brakeFilingText(_ n: Int) -> String {
        let day = String(format: "%02d", n)
        let filler = String(repeating: "The maintenance ledger for the switching yard remains under review by counsel. ", count: 8)
        return "Brake filing \(n) recorded on 2024-01-\(day) at the yard. " + filler
    }

    /// A route whose 4,096-token context and 1,024-token output reserve yield a
    /// 2,816-token prompt budget (11,264 estimated serialized UTF-8 bytes before
    /// the system prompt) — small enough to force multiple batches.
    private static func tinyBatchRoute() -> ModelRoute {
        ModelRoute(
            mode: .legalResearch,
            role: .legalReasoning,
            modelIdentifier: "synthetic-test-model",
            options: GenerationOptions(preset: .legalResearch, maxContextTokens: 4_096),
            requiresCourtListener: false,
            requiresCitations: true,
            requiresJurisdiction: false,
            allowUngroundedLaw: false,
            systemPrompt: "You are a legal document analysis assistant."
        )
    }

    private static func batchScriptedRuntime(log: PromptLog, appendMalformedRowsToFinalBatch: Bool = false) -> StubRuntimeClient {
        StubRuntimeClient(outcome: { request in
            log.record(request.prompt)
            let answer = Self.scriptedAnswer(for: request.prompt, appendMalformedRowsToFinalBatch: appendMalformedRowsToFinalBatch)
            return .events([
                .event(request, 0, .token, token: answer),
                .event(request, 1, .generationCompleted)
            ])
        })
    }

    /// Scripts the model per request based on which global source labels the
    /// prompt's envelope carries:
    /// - a map pass over a strict subset of the packet echoes one supported table
    ///   row per label (the row's date derives from the label number and matches
    ///   the seeded chunk text, so the verifier can establish support);
    /// - a single pass over the ENTIRE packet (both S1 and S20 in one prompt)
    ///   emulates the context-window truncation this feature exists to fix:
    ///   only the earliest three sources survive into the answer;
    /// - a prompt with no source envelope (the narrative synthesis stage)
    ///   returns a short narrative citing the packet's first and last sources.
    private nonisolated static func scriptedAnswer(for prompt: String, appendMalformedRowsToFinalBatch: Bool) -> String {
        let labels = labelNumbers(in: prompt)
        guard !labels.isEmpty else {
            return "Brake filing 1 recorded on 2024-01-01 [S1]. Brake filing 20 recorded on 2024-01-20 [S20]."
        }
        let truncatedSinglePass = labels.contains(1) && labels.contains(20)
        let effective = truncatedSinglePass ? labels.filter { $0 <= 3 } : labels
        var lines = ["| Date | Event | Source |"]
        lines.append(contentsOf: effective.map { n in
            "| 2024-01-\(String(format: "%02d", n)) | Brake filing \(n) recorded [S\(n)] | [S\(n)] |"
        })
        if appendMalformedRowsToFinalBatch, !truncatedSinglePass, labels.contains(20) {
            lines.append("| 2024-01-31 | Broken row missing its source column")
            lines.append("| Unknown")
        }
        return lines.joined(separator: "\n")
    }

    /// Extracts the numeric part of every `"label":"S<n>"` field in the prompt's
    /// JSON source envelope, sorted ascending.
    private nonisolated static func labelNumbers(in prompt: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #""label":"S(\d+)""#) else { return [] }
        let range = NSRange(prompt.startIndex..., in: prompt)
        return regex.matches(in: prompt, range: range)
            .compactMap { match in Range(match.range(at: 1), in: prompt).flatMap { Int(prompt[$0]) } }
            .sorted()
    }

    // MARK: - Helpers

    private func indexDoc(
        _ store: SupraStore,
        _ matterID: String,
        _ folderID: String?,
        _ name: String,
        _ text: String,
        metadataCreatedAt: Date? = nil,
        createdAt: Date = Date()
    ) async throws {
        let blob = try store.documentLibrary.upsertBlob(DocumentBlobRecord(sha256: name, byteSize: 1, originalExtension: "txt", managedRelativePath: "blobs/\(name)")).blob
        // `metadataCreatedAt` is persisted verbatim on insert; indexing only touches
        // index/status columns, so a seeded metadata date survives to the harvest.
        let doc = try store.documentLibrary.insertDocument(MatterDocumentRecord(
            matterID: matterID, blobID: blob.id, folderID: folderID, displayName: name,
            status: MatterDocumentStatus.indexing.rawValue, extractionStatus: DocumentExtractionStatus.extracted.rawValue,
            metadataCreatedAt: metadataCreatedAt,
            createdAt: createdAt,
            updatedAt: createdAt
        ))
        try store.documentIndex.replaceParts(documentID: doc.id, parts: [
            DocumentPagePartRecord(documentID: doc.id, partIndex: 0, sourceKind: DocumentSourceKind.text.rawValue, normalizedText: text, charCount: text.count)
        ])
        _ = try await DocumentIndexingService(store: store, embedder: nil).indexDocument(documentID: doc.id)
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChronStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}

// MARK: - Batching test doubles

/// Thread-safe capture of every prompt the controller sends, for call-count and
/// per-batch label assertions.
private struct ChronologyLedgerReconciliationTestRecord: Decodable {
    struct Pass: Decodable {
        var sourceLabels: [String]
        var coverageGap: Bool

        private enum CodingKeys: String, CodingKey {
            case sourceLabels = "source_labels"
            case coverageGap = "coverage_gap"
        }
    }

    var droppedCount: Int
    var omittedDocumentNames: [String]
    var passes: [Pass]

    private enum CodingKeys: String, CodingKey {
        case droppedCount = "dropped_count"
        case omittedDocumentNames = "omitted_document_names"
        case passes
    }
}

private final class PromptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [String] = []

    var prompts: [String] { lock.withLock { _prompts } }

    func record(_ prompt: String) {
        lock.withLock { _prompts.append(prompt) }
    }
}

/// Holds the first generation open until the test explicitly completes it. This
/// exposes the re-entry window without cancelling the owning run.
private final class ControllableFirstCallRuntimeClient: RuntimeClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var held: (
        request: GenerateRequest,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    )?
    private let firstCallStarted: XCTestExpectation
    private let loadResult = LoadModelResponse(status: .loaded, modelID: ModelID())

    init(firstCallStarted: XCTestExpectation) {
        self.firstCallStarted = firstCallStarted
    }

    func connect() async throws {}

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        loadResult
    }

    func generate(_ request: GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { held = (request, continuation) }
            firstCallStarted.fulfill()
        }
    }

    func finishSuccessfully() {
        let captured = lock.withLock { () -> (
            request: GenerateRequest,
            continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
        )? in
            defer { held = nil }
            return held
        }
        guard let captured else { return }
        captured.continuation.yield(.event(
            captured.request, 0, .token,
            token: "| Date | Event | Source |\n| 2024-01-01 | Brake filing 1 recorded [S1] | [S1] |"
        ))
        captured.continuation.yield(.event(captured.request, 1, .generationCompleted))
        captured.continuation.finish()
    }

    func cancelGeneration(_ generationID: GenerationID) async throws -> CancelGenerationResponse {
        lock.withLock { held?.continuation }?.finish()
        return CancelGenerationResponse(status: .cancelled, generationID: generationID)
    }

    func recentEvents(for generationID: GenerationID, after sequenceNumber: Int) async throws -> [GenerationEvent] { [] }
    func unloadModel() async throws -> UnloadModelResponse { UnloadModelResponse(status: .unloaded) }
    func reloadCurrentModel() async throws -> LoadModelResponse { loadResult }
    func runtimeStatus() async throws -> RuntimeStatus {
        RuntimeStatus(state: .modelLoaded, loadedModelID: loadResult.modelID, activeGenerationID: nil, message: nil, metrics: nil)
    }
    func restartRuntimeService() async throws {}
}

/// Runtime double for the cancellation test. The first generate call streams a
/// complete map answer; the second yields one token and then hangs — the stream
/// never finishes on its own. `cancelGeneration` finishes the held stream, like
/// the real runtime cancelling an active generation. This makes "cancel after
/// batch 1, during batch 2" deterministic: the controller is provably suspended
/// mid-batch-2 (the `secondCallStarted` expectation has fulfilled and the stream
/// is held open) at the moment the test cancels; there is no schedule on which
/// the run can finish early and persist.
private final class HangingSecondCallRuntimeClient: RuntimeClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var heldContinuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?
    private let secondCallStarted: XCTestExpectation
    private let loadResult = LoadModelResponse(status: .loaded, modelID: ModelID())

    init(secondCallStarted: XCTestExpectation) {
        self.secondCallStarted = secondCallStarted
    }

    func connect() async throws {}

    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse {
        loadResult
    }

    func generate(_ request: GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error> {
        let call = lock.withLock { () -> Int in
            callCount += 1
            return callCount
        }
        if call == 1 {
            return AsyncThrowingStream { continuation in
                continuation.yield(.event(request, 0, .token, token: "| Date | Event | Source |\n| 2024-01-01 | Brake filing 1 recorded [S1] | [S1] |"))
                continuation.yield(.event(request, 1, .generationCompleted))
                continuation.finish()
            }
        }
        return AsyncThrowingStream { continuation in
            lock.withLock { heldContinuation = continuation }
            continuation.yield(.event(request, 0, .token, token: "| Date |"))
            secondCallStarted.fulfill()
            // Deliberately left unfinished: only cancellation may end this stream.
        }
    }

    func cancelGeneration(_ generationID: GenerationID) async throws -> CancelGenerationResponse {
        lock.withLock { heldContinuation }?.finish()
        return CancelGenerationResponse(status: .cancelled, generationID: generationID)
    }

    func recentEvents(for generationID: GenerationID, after sequenceNumber: Int) async throws -> [GenerationEvent] {
        []
    }

    func unloadModel() async throws -> UnloadModelResponse {
        UnloadModelResponse(status: .unloaded)
    }

    func reloadCurrentModel() async throws -> LoadModelResponse {
        loadResult
    }

    func runtimeStatus() async throws -> RuntimeStatus {
        RuntimeStatus(state: .modelLoaded, loadedModelID: loadResult.modelID, activeGenerationID: nil, message: nil, metrics: nil)
    }

    func restartRuntimeService() async throws {}
}
