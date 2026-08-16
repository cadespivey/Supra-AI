import Foundation
import SupraSessions
@testable import SupraTestKit
import XCTest

/// T-RAG-BASELINE-02 freezes the deterministic bridge from the signed app's
/// content-complete raw record to slice-level release evidence.
final class NativeRAGControlScorerTests: XCTestCase {
    func testScoresArtifactLevelQualityCollapsesDuplicatesAndKeepsUndefinedCellsExplicit() throws {
        let fixture = makeFixture(noAnswerPackedArtifactID: nil)

        let evaluation = try NativeRAGControlScorer.score(
            run: fixture.run,
            manifest: fixture.manifest,
            manifestSHA256: fixture.run.corpusManifestSHA256,
            retrievalK: 8
        )

        XCTAssertEqual(evaluation.evaluatorGranularity, "artifact")
        XCTAssertEqual(evaluation.retrievalK, 8)
        XCTAssertEqual(evaluation.ownerJudgmentStatus, .pendingOwnerReview)
        XCTAssertEqual(evaluation.deterministicGate, .pending)

        let answerable = try XCTUnwrap(evaluation.queries.first { $0.queryID == "answerable" })
        XCTAssertEqual(try measured(answerable.recallAtK), 1)
        XCTAssertEqual(try measured(answerable.fullEvidenceSetRecallAtK), 1)
        XCTAssertEqual(try measured(answerable.normalizedDiscountedCumulativeGainAtK), 0.630_930, accuracy: 0.000_001)
        XCTAssertEqual(try measured(answerable.reciprocalRankAtK), 0.5)
        XCTAssertEqual(try measured(answerable.contextPrecision), 1)
        XCTAssertEqual(try measured(answerable.contextRecall), 1)
        XCTAssertEqual(try measured(answerable.citationPrecision), 1)
        XCTAssertEqual(try measured(answerable.citationRecall), 1)
        XCTAssertEqual(try measured(answerable.citationCoverage), 1)
        XCTAssertTrue(answerable.zeroResultCorrect)

        let noAnswer = try XCTUnwrap(evaluation.queries.first { $0.queryID == "no-answer" })
        XCTAssertEqual(noAnswer.recallAtK.status, .notApplicable)
        XCTAssertEqual(noAnswer.citationPrecision.status, .notApplicable)
        XCTAssertTrue(noAnswer.zeroResultCorrect)

        XCTAssertEqual(try measured(cell("recall_at_k", "overall", in: evaluation)), 1)
        XCTAssertEqual(try measured(cell("zero_result_accuracy", "overall", in: evaluation)), 1)
        XCTAssertEqual(cell("recall_at_k", "no_answer", in: evaluation).state, .notApplicable)
        XCTAssertEqual(try measured(cell("zero_result_accuracy", "no_answer", in: evaluation)), 1)
        XCTAssertEqual(try measured(cell("time_to_first_token_ms", "overall", in: evaluation)), 25)
        XCTAssertEqual(try measured(cell("p50_total_latency_ms", "overall", in: evaluation)), 90)
        XCTAssertEqual(cell("vectors_scanned", "overall", in: evaluation).state, .pending)
        XCTAssertEqual(
            try measured(cell("maximum_live_cache_bytes", "overall", in: evaluation)),
            512
        )
        XCTAssertEqual(
            try measured(cell("combined_peak_phys_footprint_bytes", "overall", in: evaluation)),
            60
        )
    }

    func testNoAnswerRequiresBothNoPackedEvidenceAndNoSupportedAnswer() throws {
        let fixture = makeFixture(noAnswerPackedArtifactID: "irrelevant")

        let evaluation = try NativeRAGControlScorer.score(
            run: fixture.run,
            manifest: fixture.manifest,
            manifestSHA256: fixture.run.corpusManifestSHA256,
            retrievalK: 8
        )

        let noAnswer = try XCTUnwrap(evaluation.queries.first { $0.queryID == "no-answer" })
        XCTAssertFalse(noAnswer.zeroResultCorrect)
        XCTAssertEqual(try measured(cell("zero_result_accuracy", "no_answer", in: evaluation)), 0)
        XCTAssertEqual(try measured(cell("zero_result_accuracy", "overall", in: evaluation)), 0.5)
    }

    func testGateAcceptsFullyAccountedEmailAttachmentExpansion() throws {
        var fixture = makeFixture(noAnswerPackedArtifactID: nil)
        fixture.run.importSummary = .init(
            discovered: 5,
            imported: 4,
            failed: 1,
            indexedDocuments: 4
        )

        let evaluation = try NativeRAGControlScorer.score(
            run: fixture.run,
            manifest: fixture.manifest,
            manifestSHA256: fixture.run.corpusManifestSHA256,
            retrievalK: 8
        )

        XCTAssertEqual(evaluation.deterministicGate, .pending)
    }

    func testRejectsDigestAndQuerySetMismatchesBeforeScoring() throws {
        let fixture = makeFixture(noAnswerPackedArtifactID: nil)

        XCTAssertThrowsError(try NativeRAGControlScorer.score(
            run: fixture.run,
            manifest: fixture.manifest,
            manifestSHA256: String(repeating: "f", count: 64),
            retrievalK: 8
        )) { error in
            XCTAssertEqual(error as? NativeRAGControlScoringError, .manifestDigestMismatch)
        }

        var incomplete = fixture.run
        incomplete.queries.removeLast()
        XCTAssertThrowsError(try NativeRAGControlScorer.score(
            run: incomplete,
            manifest: fixture.manifest,
            manifestSHA256: fixture.run.corpusManifestSHA256,
            retrievalK: 8
        )) { error in
            XCTAssertEqual(error as? NativeRAGControlScoringError, .querySetMismatch)
        }
    }

    func testFileCommandRecomputesManifestDigestAndWritesCanonicalEvaluation() throws {
        var fixture = makeFixture(noAnswerPackedArtifactID: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(fixture.manifest)
        fixture.run.corpusManifestSHA256 = NativeRAGControlScoreFileCommand.sha256(manifestData)

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NativeRAGControlScorerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let rawURL = temporary.appendingPathComponent("raw.json")
        let manifestURL = temporary.appendingPathComponent("manifest.json")
        let outputURL = temporary.appendingPathComponent("evaluation.json")
        try encoder.encode(fixture.run).write(to: rawURL)
        try manifestData.write(to: manifestURL)

        try NativeRAGControlScoreFileCommand.run(
            rawURL: rawURL,
            manifestURL: manifestURL,
            outputURL: outputURL,
            retrievalK: 8
        )

        let output = try Data(contentsOf: outputURL)
        let decoded = try JSONDecoder().decode(NativeRAGControlEvaluation.self, from: output)
        XCTAssertEqual(decoded.corpusManifestSHA256, fixture.run.corpusManifestSHA256)
        XCTAssertEqual(decoded.queries.count, 2)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).hasSuffix("\n"))
    }

    private func makeFixture(
        noAnswerPackedArtifactID: String?
    ) -> (manifest: RAGBenchmarkCorpusManifest, run: NativeRAGControlRunRecord) {
        let pending = RAGCorpusHumanReview(
            status: .pendingOwnerReview,
            reviewerRole: "repository_owner_attorney",
            reviewBasis: "synthetic fixture",
            reviewedBy: nil,
            reviewedAt: nil
        )
        let manifest = RAGBenchmarkCorpusManifest(
            schemaVersion: 1,
            corpusID: "synthetic-legal",
            corpusVersion: "1.0.0",
            dataClassification: .syntheticFictionalNonprivileged,
            containsRealClientData: false,
            artifactRoot: "TestData/Synthetic Document Intelligence Benchmark",
            requiredSlices: ["ocr", "no_answer", "corpus_small", "corpus_large"],
            artifacts: [
                .init(artifactID: "relevant", path: "relevant.txt", sha256: String(repeating: "1", count: 64), documentType: "txt", duplicateOfArtifactID: nil),
                .init(artifactID: "relevant-copy", path: "relevant-copy.txt", sha256: String(repeating: "1", count: 64), documentType: "txt", duplicateOfArtifactID: "relevant"),
                .init(artifactID: "irrelevant", path: "irrelevant.txt", sha256: String(repeating: "2", count: 64), documentType: "txt", duplicateOfArtifactID: nil),
            ],
            queries: [
                .init(
                    queryID: "answerable",
                    prompt: "What is the synthetic fact?",
                    expectedAnswer: "The synthetic fact.",
                    queryType: .factLookup,
                    corpusSize: .small,
                    slices: ["ocr", "corpus_small"],
                    scopeArtifactIDs: ["relevant", "relevant-copy", "irrelevant"],
                    expectedNoResult: false,
                    humanReview: pending,
                    judgments: [
                        .init(evidenceID: "relevant.fact", artifactID: "relevant", locator: "line 1", grade: 3),
                    ],
                    claims: [
                        .init(claimID: "synthetic-fact", expectedEvidenceIDs: ["relevant.fact"]),
                    ]
                ),
                .init(
                    queryID: "no-answer",
                    prompt: "What is absent?",
                    expectedAnswer: nil,
                    queryType: .noAnswer,
                    corpusSize: .large,
                    slices: ["no_answer", "corpus_large"],
                    scopeArtifactIDs: ["relevant", "irrelevant"],
                    expectedNoResult: true,
                    humanReview: pending,
                    judgments: [],
                    claims: []
                ),
            ]
        )
        let noAnswerSources = noAnswerPackedArtifactID.map {
            [NativeRAGControlPackedSource(
                artifactID: $0,
                citationLabel: "S9",
                locator: "line 9",
                excerpt: "Irrelevant synthetic source."
            )]
        } ?? []
        let run = NativeRAGControlRunRecord(
            controlID: "native-rag-control-v1",
            sourceCommitSHA: String(repeating: "a", count: 40),
            corpusManifestSHA256: String(repeating: "b", count: 64),
            corpusID: manifest.corpusID,
            corpusVersion: manifest.corpusVersion,
            chatModel: .init(repositoryID: "synthetic/chat", revision: "chat-revision", artifactIdentitySHA256: String(repeating: "c", count: 64)),
            embeddingModel: .init(repositoryID: "synthetic/embed", revision: "embed-revision", artifactIdentitySHA256: String(repeating: "d", count: 64)),
            startedAt: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 110),
            importSummary: .init(discovered: 3, imported: 3, failed: 0, indexedDocuments: 3),
            queries: [
                .init(
                    queryID: "answerable",
                    scopeArtifactIDs: ["relevant", "relevant-copy", "irrelevant"],
                    coldRetrievalMilliseconds: 20,
                    warmRetrievalMilliseconds: 5,
                    coldExecutionReceipt: nil,
                    warmExecutionReceipt: nil,
                    coldCandidates: [
                        .init(artifactID: "irrelevant", documentName: "irrelevant.txt", locator: "line 1", excerpt: "Other.", rank: 1, score: 0.9, ftsMatched: true, semanticBucket: "high"),
                        .init(artifactID: "relevant-copy", documentName: "relevant-copy.txt", locator: "line 1", excerpt: "Fact.", rank: 2, score: 0.8, ftsMatched: true, semanticBucket: "high"),
                        .init(artifactID: "relevant", documentName: "relevant.txt", locator: "line 1", excerpt: "Fact.", rank: 3, score: 0.7, ftsMatched: true, semanticBucket: "medium"),
                    ],
                    warmCandidates: [],
                    totalLatencyMilliseconds: 90,
                    timeToFirstTokenMilliseconds: 25,
                    answerMarkdown: "The synthetic fact [S1].",
                    status: "complete",
                    unsupported: false,
                    failure: nil,
                    warnings: [],
                    citationLabels: ["S1"],
                    packedSources: [
                        .init(artifactID: "relevant", citationLabel: "S1", locator: "line 1", excerpt: "Fact."),
                    ]
                ),
                .init(
                    queryID: "no-answer",
                    scopeArtifactIDs: ["relevant", "irrelevant"],
                    coldRetrievalMilliseconds: 22,
                    warmRetrievalMilliseconds: 4,
                    coldExecutionReceipt: nil,
                    warmExecutionReceipt: nil,
                    coldCandidates: [],
                    warmCandidates: [],
                    totalLatencyMilliseconds: nil,
                    timeToFirstTokenMilliseconds: nil,
                    answerMarkdown: noAnswerPackedArtifactID == nil ? nil : "Unsupported answer [S9].",
                    status: "insufficient_evidence",
                    unsupported: noAnswerPackedArtifactID == nil,
                    failure: nil,
                    warnings: [],
                    citationLabels: noAnswerPackedArtifactID == nil ? [] : ["S9"],
                    packedSources: noAnswerSources
                ),
            ],
            memory: .init(
                appCurrentPhysFootprintBytes: 10,
                appPeakPhysFootprintBytes: 20,
                xpcCurrentPhysFootprintBytes: 30,
                xpcPeakPhysFootprintBytes: 40,
                combinedCurrentPhysFootprintBytes: 40,
                combinedPeakPhysFootprintBytes: 60,
                maximumLiveSemanticCacheBytes: 512
            )
        )
        return (manifest, run)
    }

    private func cell(
        _ metricID: String,
        _ sliceID: String,
        in evaluation: NativeRAGControlEvaluation
    ) -> RAGBenchmarkCell {
        evaluation.cells.first { $0.metricID == metricID && $0.sliceID == sliceID }!
    }

    private func measured(
        _ result: BenchmarkResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Double {
        XCTAssertEqual(result.status, .measured, file: file, line: line)
        return try XCTUnwrap(result.value, file: file, line: line)
    }

    private func measured(
        _ cell: RAGBenchmarkCell,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Double {
        XCTAssertEqual(cell.state, .measured, file: file, line: line)
        return try XCTUnwrap(cell.value, file: file, line: line)
    }
}
