import CryptoKit
import Foundation
import SupraSessions

public enum NativeRAGOwnerJudgmentStatus: String, Codable, Equatable, Sendable {
    case pendingOwnerReview = "pending_owner_review"
    case approved
}

public enum NativeRAGControlScoringError: Error, Equatable, LocalizedError {
    case invalidRetrievalK
    case invalidManifest(issueCount: Int)
    case manifestDigestMismatch
    case runIdentityMismatch
    case querySetMismatch
    case queryScopeMismatch(queryID: String)
    case unknownArtifactID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRetrievalK: "Native RAG retrieval K must be positive."
        case .invalidManifest(let count): "Native RAG manifest has \(count) validation issue(s)."
        case .manifestDigestMismatch: "Raw run and corpus manifest digests do not match."
        case .runIdentityMismatch: "Raw run and corpus identities do not match."
        case .querySetMismatch: "Raw run and corpus query sets do not match."
        case .queryScopeMismatch(let queryID): "Raw run scope does not match query \(queryID)."
        case .unknownArtifactID(let artifactID): "Raw run references unknown artifact \(artifactID)."
        }
    }
}

public struct NativeRAGControlQueryEvaluation: Codable, Equatable, Sendable {
    public var queryID: String
    public var slices: [String]
    public var expectedNoResult: Bool
    public var recallAtK: BenchmarkResult
    public var fullEvidenceSetRecallAtK: BenchmarkResult
    public var normalizedDiscountedCumulativeGainAtK: BenchmarkResult
    public var reciprocalRankAtK: BenchmarkResult
    public var contextPrecision: BenchmarkResult
    public var contextRecall: BenchmarkResult
    public var citationPrecision: BenchmarkResult
    public var citationRecall: BenchmarkResult
    public var citationCoverage: BenchmarkResult
    public var zeroResultCorrect: Bool
}

public struct NativeRAGControlEvaluation: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var runID: String
    public var sourceCommitSHA: String
    public var corpusManifestSHA256: String
    public var evaluatorGranularity: String
    public var retrievalK: Int
    public var ownerJudgmentStatus: NativeRAGOwnerJudgmentStatus
    public var deterministicGate: RAGDeterministicGate
    public var queries: [NativeRAGControlQueryEvaluation]
    public var cells: [RAGBenchmarkCell]

    public init(
        runID: String,
        sourceCommitSHA: String,
        corpusManifestSHA256: String,
        evaluatorGranularity: String,
        retrievalK: Int,
        ownerJudgmentStatus: NativeRAGOwnerJudgmentStatus,
        deterministicGate: RAGDeterministicGate,
        queries: [NativeRAGControlQueryEvaluation],
        cells: [RAGBenchmarkCell]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.sourceCommitSHA = sourceCommitSHA
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.evaluatorGranularity = evaluatorGranularity
        self.retrievalK = retrievalK
        self.ownerJudgmentStatus = ownerJudgmentStatus
        self.deterministicGate = deterministicGate
        self.queries = queries
        self.cells = cells
    }
}

public enum NativeRAGControlScorer {
    public static func score(
        run: NativeRAGControlRunRecord,
        manifest: RAGBenchmarkCorpusManifest,
        manifestSHA256: String,
        retrievalK: Int
    ) throws -> NativeRAGControlEvaluation {
        guard retrievalK > 0 else { throw NativeRAGControlScoringError.invalidRetrievalK }
        let manifestIssues = RAGCorpusValidator.validate(manifest)
        guard manifestIssues.isEmpty else {
            throw NativeRAGControlScoringError.invalidManifest(issueCount: manifestIssues.count)
        }
        guard run.corpusManifestSHA256 == manifestSHA256 else {
            throw NativeRAGControlScoringError.manifestDigestMismatch
        }
        guard run.schemaVersion == NativeRAGControlRunRecord.currentSchemaVersion,
              run.corpusID == manifest.corpusID,
              run.corpusVersion == manifest.corpusVersion else {
            throw NativeRAGControlScoringError.runIdentityMismatch
        }

        let manifestQueryIDs = Set(manifest.queries.map(\.queryID))
        let runQueryIDs = Set(run.queries.map(\.queryID))
        guard manifestQueryIDs.count == manifest.queries.count,
              runQueryIDs.count == run.queries.count,
              manifestQueryIDs == runQueryIDs else {
            throw NativeRAGControlScoringError.querySetMismatch
        }

        let artifacts = Dictionary(uniqueKeysWithValues: manifest.artifacts.map { ($0.artifactID, $0) })
        func canonicalArtifactID(_ artifactID: String) throws -> String {
            guard var artifact = artifacts[artifactID] else {
                throw NativeRAGControlScoringError.unknownArtifactID(artifactID)
            }
            var visited = Set([artifactID])
            while let parentID = artifact.duplicateOfArtifactID {
                guard visited.insert(parentID).inserted,
                      let parent = artifacts[parentID] else {
                    throw NativeRAGControlScoringError.unknownArtifactID(parentID)
                }
                artifact = parent
            }
            return artifact.artifactID
        }

        let runQueries = Dictionary(uniqueKeysWithValues: run.queries.map { ($0.queryID, $0) })
        var evaluations: [NativeRAGControlQueryEvaluation] = []
        for query in manifest.queries {
            guard let observation = runQueries[query.queryID] else {
                throw NativeRAGControlScoringError.querySetMismatch
            }
            guard Set(observation.scopeArtifactIDs) == Set(query.scopeArtifactIDs),
                  observation.scopeArtifactIDs.count == query.scopeArtifactIDs.count else {
                throw NativeRAGControlScoringError.queryScopeMismatch(queryID: query.queryID)
            }

            var relevanceGrades: [String: Int] = [:]
            var artifactByEvidenceID: [String: String] = [:]
            for judgment in query.judgments {
                let artifactID = try canonicalArtifactID(judgment.artifactID)
                relevanceGrades[artifactID] = max(relevanceGrades[artifactID] ?? 0, judgment.grade)
                artifactByEvidenceID[judgment.evidenceID] = artifactID
            }

            var bestCandidateScore: [String: Double] = [:]
            for candidate in observation.coldCandidates {
                guard let rawArtifactID = candidate.artifactID else { continue }
                let artifactID = try canonicalArtifactID(rawArtifactID)
                bestCandidateScore[artifactID] = max(
                    bestCandidateScore[artifactID] ?? -.infinity,
                    candidate.score
                )
            }
            let ranking = BenchmarkMetrics.ragRankingScore(
                relevanceGrades: relevanceGrades,
                ranked: bestCandidateScore.map { BenchmarkRankedItem(id: $0.key, score: $0.value) },
                k: retrievalK
            )

            let relevantArtifacts = Set(relevanceGrades.keys)
            let packedArtifacts = try observation.packedSources.compactMap { source -> String? in
                guard let artifactID = source.artifactID else { return nil }
                return try canonicalArtifactID(artifactID)
            }
            let context = BenchmarkMetrics.ragContextScore(
                relevantEvidenceIDs: relevantArtifacts,
                packedEvidenceIDs: packedArtifacts
            )

            let expectedEdges = Set(query.claims.flatMap { claim in
                claim.expectedEvidenceIDs.compactMap { evidenceID -> BenchmarkCitationEdge? in
                    guard let artifactID = artifactByEvidenceID[evidenceID] else { return nil }
                    return BenchmarkCitationEdge(claimID: claim.claimID, evidenceID: artifactID)
                }
            })
            let citedLabels = Set(observation.citationLabels)
            let citedArtifacts = Set(try observation.packedSources.compactMap { source -> String? in
                guard citedLabels.contains(source.citationLabel),
                      let artifactID = source.artifactID else { return nil }
                return try canonicalArtifactID(artifactID)
            })
            var predictedEdges: [BenchmarkCitationEdge] = []
            for citedArtifact in citedArtifacts.sorted() {
                let supportedEdges = expectedEdges.filter { $0.evidenceID == citedArtifact }
                if supportedEdges.isEmpty {
                    predictedEdges.append(BenchmarkCitationEdge(
                        claimID: "__unmatched_artifact__",
                        evidenceID: citedArtifact
                    ))
                } else {
                    predictedEdges.append(contentsOf: supportedEdges)
                }
            }
            let citation = BenchmarkMetrics.ragCitationScore(
                expectedEdges: expectedEdges,
                predictedEdges: predictedEdges,
                claimIDsRequiringCitation: Set(query.claims.map(\.claimID))
            )

            let hasAnswerText = observation.answerMarkdown?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let producedSupportedAnswer = hasAnswerText
                && !observation.unsupported
                && !citedArtifacts.isEmpty
            let zeroResultCorrect = query.expectedNoResult
                ? observation.packedSources.isEmpty && !producedSupportedAnswer
                : !observation.packedSources.isEmpty && producedSupportedAnswer

            evaluations.append(NativeRAGControlQueryEvaluation(
                queryID: query.queryID,
                slices: query.slices,
                expectedNoResult: query.expectedNoResult,
                recallAtK: ranking.recallAtK,
                fullEvidenceSetRecallAtK: ranking.fullEvidenceSetRecallAtK,
                normalizedDiscountedCumulativeGainAtK: ranking.normalizedDiscountedCumulativeGainAtK,
                reciprocalRankAtK: ranking.reciprocalRankAtK,
                contextPrecision: context.precision,
                contextRecall: context.recall,
                citationPrecision: citation.precision,
                citationRecall: citation.recall,
                citationCoverage: citation.coverage,
                zeroResultCorrect: zeroResultCorrect
            ))
        }

        let ownerStatus: NativeRAGOwnerJudgmentStatus = manifest.queries.allSatisfy {
            $0.humanReview.status == .approved
        } ? .approved : .pendingOwnerReview
        // EML artifacts may expand into imported or unsupported child attachments.
        // The signed runner has already failed if any manifest artifact is absent;
        // require every discovered row to be accounted for and every admitted row
        // to be indexed without assuming one import row per top-level artifact.
        let importRowsAccounted = run.importSummary.discovered >= run.importSummary.imported
            && run.importSummary.failed
                == run.importSummary.discovered - run.importSummary.imported
        let rawRunComplete = run.importSummary.imported >= manifest.artifacts.count
            && run.importSummary.indexedDocuments == run.importSummary.imported
            && importRowsAccounted
            && run.queries.allSatisfy { $0.failure == nil }
        let gate: RAGDeterministicGate = if !rawRunComplete {
            .failed
        } else if ownerStatus == .approved {
            .passed
        } else {
            .pending
        }

        return NativeRAGControlEvaluation(
            runID: run.controlID,
            sourceCommitSHA: run.sourceCommitSHA,
            corpusManifestSHA256: run.corpusManifestSHA256,
            evaluatorGranularity: "artifact",
            retrievalK: retrievalK,
            ownerJudgmentStatus: ownerStatus,
            deterministicGate: gate,
            queries: evaluations,
            cells: qualityCells(evaluations: evaluations, manifest: manifest)
                + operationalCells(run: run)
        )
    }

    private static func qualityCells(
        evaluations: [NativeRAGControlQueryEvaluation],
        manifest: RAGBenchmarkCorpusManifest
    ) -> [RAGBenchmarkCell] {
        let metrics: [(String, KeyPath<NativeRAGControlQueryEvaluation, BenchmarkResult>)] = [
            ("recall_at_k", \NativeRAGControlQueryEvaluation.recallAtK),
            ("full_evidence_set_recall_at_k", \NativeRAGControlQueryEvaluation.fullEvidenceSetRecallAtK),
            ("ndcg_at_k", \NativeRAGControlQueryEvaluation.normalizedDiscountedCumulativeGainAtK),
            ("mean_reciprocal_rank", \NativeRAGControlQueryEvaluation.reciprocalRankAtK),
            ("context_precision", \NativeRAGControlQueryEvaluation.contextPrecision),
            ("context_recall", \NativeRAGControlQueryEvaluation.contextRecall),
            ("citation_precision", \NativeRAGControlQueryEvaluation.citationPrecision),
            ("citation_recall", \NativeRAGControlQueryEvaluation.citationRecall),
            ("citation_coverage", \NativeRAGControlQueryEvaluation.citationCoverage),
        ]
        var sliceIDs = ["overall"]
        for slice in manifest.requiredSlices + RAGControlComparisonValidator.requiredCriticalSliceIDs
            where !sliceIDs.contains(slice) {
            sliceIDs.append(slice)
        }
        var cells: [RAGBenchmarkCell] = []
        for sliceID in sliceIDs {
            let selected = evaluations.filter {
                sliceID == "overall" || $0.slices.contains(sliceID)
            }
            for (metricID, keyPath) in metrics {
                let values = selected.compactMap { evaluation -> Double? in
                    let result = evaluation[keyPath: keyPath]
                    return result.status == .measured ? result.value : nil
                }
                if values.isEmpty {
                    cells.append(.notApplicable(
                        metricID: metricID,
                        sliceID: sliceID,
                        unit: "ratio",
                        reason: selected.isEmpty
                            ? "No manifest query belongs to this slice."
                            : "No query in this slice has an applicable golden evidence set."
                    ))
                } else {
                    cells.append(.measured(
                        metricID: metricID,
                        sliceID: sliceID,
                        value: values.reduce(0, +) / Double(values.count),
                        unit: "ratio"
                    ))
                }
            }
            if selected.isEmpty {
                cells.append(.notApplicable(
                    metricID: "zero_result_accuracy",
                    sliceID: sliceID,
                    unit: "ratio",
                    reason: "No manifest query belongs to this slice."
                ))
            } else {
                cells.append(.measured(
                    metricID: "zero_result_accuracy",
                    sliceID: sliceID,
                    value: Double(selected.filter(\.zeroResultCorrect).count) / Double(selected.count),
                    unit: "ratio"
                ))
            }
        }
        return cells
    }

    private static func operationalCells(run: NativeRAGControlRunRecord) -> [RAGBenchmarkCell] {
        var cells: [RAGBenchmarkCell] = []
        func measured(_ metricID: String, _ value: Double, unit: String) {
            cells.append(.measured(metricID: metricID, sliceID: "overall", value: value, unit: unit))
        }
        func pending(_ metricID: String, unit: String, reason: String) {
            cells.append(.pending(metricID: metricID, sliceID: "overall", unit: unit, reason: reason))
        }

        let firstToken = run.queries.compactMap(\.timeToFirstTokenMilliseconds).sorted()
        if let value = percentile(firstToken, probability: 0.5) {
            measured("time_to_first_token_ms", Double(value), unit: "milliseconds")
        } else {
            pending("time_to_first_token_ms", unit: "milliseconds", reason: "No answer token was observed.")
        }
        let totalLatency = run.queries.compactMap(\.totalLatencyMilliseconds).sorted()
        if let value = percentile(totalLatency, probability: 0.5) {
            measured("p50_total_latency_ms", Double(value), unit: "milliseconds")
        } else {
            pending("p50_total_latency_ms", unit: "milliseconds", reason: "No completed answer latency was observed.")
        }
        if let value = percentile(totalLatency, probability: 0.95) {
            measured("p95_total_latency_ms", Double(value), unit: "milliseconds")
        } else {
            pending("p95_total_latency_ms", unit: "milliseconds", reason: "No completed answer latency was observed.")
        }

        let receipts = run.queries.flatMap { [$0.coldExecutionReceipt, $0.warmExecutionReceipt] }.compactMap { $0 }
        if receipts.isEmpty {
            for (metricID, unit) in [
                ("vectors_scanned", "rows"),
                ("vector_bytes_scanned", "bytes"),
                ("maximum_live_page_rows", "rows"),
                ("maximum_live_heap_rows", "rows"),
            ] {
                pending(metricID, unit: unit, reason: "The raw run contains no retrieval execution receipt.")
            }
        } else {
            measured(
                "vectors_scanned",
                Double(receipts.map(\.semantic.scannedRows).max() ?? 0),
                unit: "rows"
            )
            let byteScans = receipts.map { receipt -> Double in
                guard receipt.semantic.maximumLivePageRows > 0 else { return 0 }
                let bytesPerRow = Double(receipt.semantic.maximumLiveVectorBytes)
                    / Double(receipt.semantic.maximumLivePageRows)
                return Double(receipt.semantic.scannedRows) * bytesPerRow
            }
            measured("vector_bytes_scanned", byteScans.max() ?? 0, unit: "bytes")
            measured(
                "maximum_live_page_rows",
                Double(receipts.map(\.semantic.maximumLivePageRows).max() ?? 0),
                unit: "rows"
            )
            measured(
                "maximum_live_heap_rows",
                Double(receipts.map(\.semantic.maximumHeapEntries).max() ?? 0),
                unit: "rows"
            )
        }

        measured(
            "maximum_live_cache_bytes",
            Double(run.memory.maximumLiveSemanticCacheBytes),
            unit: "bytes"
        )
        measured("app_current_phys_footprint_bytes", Double(run.memory.appCurrentPhysFootprintBytes), unit: "bytes")
        measured("app_peak_phys_footprint_bytes", Double(run.memory.appPeakPhysFootprintBytes), unit: "bytes")
        measured("xpc_current_phys_footprint_bytes", Double(run.memory.xpcCurrentPhysFootprintBytes), unit: "bytes")
        measured("xpc_peak_phys_footprint_bytes", Double(run.memory.xpcPeakPhysFootprintBytes), unit: "bytes")
        measured("combined_current_phys_footprint_bytes", Double(run.memory.combinedCurrentPhysFootprintBytes), unit: "bytes")
        measured("combined_peak_phys_footprint_bytes", Double(run.memory.combinedPeakPhysFootprintBytes), unit: "bytes")
        return cells
    }

    private static func percentile(_ sorted: [Int], probability: Double) -> Int? {
        guard !sorted.isEmpty else { return nil }
        let rank = max(1, Int(ceil(probability * Double(sorted.count))))
        return sorted[min(sorted.count - 1, rank - 1)]
    }
}

/// File-backed entry point shared by tests and SupraBench. It recomputes the
/// manifest digest from the exact input bytes and writes canonical, newline-
/// terminated JSON so a score can be reproduced without the signed app.
public enum NativeRAGControlScoreFileCommand {
    public static func run(
        rawURL: URL,
        manifestURL: URL,
        outputURL: URL,
        retrievalK: Int = 8
    ) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rawData = try Data(contentsOf: rawURL)
        let manifestData = try Data(contentsOf: manifestURL)
        let run = try decoder.decode(NativeRAGControlRunRecord.self, from: rawData)
        let manifest = try decoder.decode(RAGBenchmarkCorpusManifest.self, from: manifestData)
        let evaluation = try NativeRAGControlScorer.score(
            run: run,
            manifest: manifest,
            manifestSHA256: sha256(manifestData),
            retrievalK: retrievalK
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var output = try encoder.encode(evaluation)
        output.append(0x0a)
        try output.write(to: outputURL, options: .atomic)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
