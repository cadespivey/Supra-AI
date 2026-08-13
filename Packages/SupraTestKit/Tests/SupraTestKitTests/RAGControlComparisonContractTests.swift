import XCTest
@testable import SupraTestKit

final class RAGControlComparisonContractTests: XCTestCase {
    func testControlAndCandidateBindExactCorpusConfigurationHardwareAndToolchain() {
        // T-RAG-BASELINE-01 expected RED: no native RAG run binding or
        // one-variable comparison validator exists.
        let control = makeRun(role: .control, configuration: controlConfiguration())
        var challengerConfiguration = controlConfiguration()
        challengerConfiguration.reranker = "native-reranker-v2-candidate-719"
        let candidate = makeRun(role: .candidate, configuration: challengerConfiguration)

        let validation = RAGControlComparisonValidator.validate(
            control: control,
            candidate: candidate,
            declaredVariable: .reranker,
            advisoryJudge: nil
        )

        XCTAssertEqual(validation.disposition, .passed)
        XCTAssertEqual(validation.changedVariables, [.reranker])
        XCTAssertEqual(validation.issues, [])
        XCTAssertEqual(control.binding.corpusManifestSHA256, candidate.binding.corpusManifestSHA256)
        XCTAssertEqual(control.binding.hardware, candidate.binding.hardware)
        XCTAssertEqual(control.binding.toolchain, candidate.binding.toolchain)
        XCTAssertNotEqual(control.binding.sourceCommitSHA, candidate.binding.sourceCommitSHA)
    }

    func testZeroOrTwoConfigurationChangesRejectTheDeclaredOneVariableComparison() throws {
        // T-RAG-BASELINE-01 expected RED: no validator rejects a challenger
        // whose declared independent variable is unchanged or accompanied by drift.
        let control = makeRun(role: .control, configuration: controlConfiguration())
        let unchanged = makeRun(role: .candidate, configuration: controlConfiguration())
        let zeroChange = RAGControlComparisonValidator.validate(
            control: control,
            candidate: unchanged,
            declaredVariable: .reranker,
            advisoryJudge: nil
        )

        XCTAssertEqual(zeroChange.disposition, .failed)
        XCTAssertTrue(zeroChange.issues.contains(.declaredVariableDidNotChange(.reranker)))

        var twoChangeConfiguration = controlConfiguration()
        twoChangeConfiguration.reranker = "native-reranker-v2-candidate-719"
        twoChangeConfiguration.packer = "token-packer-v8-candidate-727"
        let twoChange = RAGControlComparisonValidator.validate(
            control: control,
            candidate: makeRun(role: .candidate, configuration: twoChangeConfiguration),
            declaredVariable: .reranker,
            advisoryJudge: nil
        )
        let changed = try XCTUnwrap(twoChange.issues.compactMap { issue -> [RAGControlVariable]? in
            if case let .multipleConfigurationVariablesChanged(variables) = issue { return variables }
            return nil
        }.first)

        XCTAssertEqual(twoChange.disposition, .failed)
        XCTAssertEqual(Set(changed), Set<RAGControlVariable>([.reranker, .packer]))
    }

    func testAdvisoryJudgeCannotOverrideTheDeterministicGate() {
        // T-RAG-BASELINE-01 expected RED: no comparison result separates an
        // advisory evaluator from the deterministic human-labeled authority.
        let control = makeRun(role: .control, configuration: controlConfiguration())
        var challengerConfiguration = controlConfiguration()
        challengerConfiguration.reranker = "native-reranker-v2-candidate-719"

        let deterministicFailure = RAGControlComparisonValidator.validate(
            control: control,
            candidate: makeRun(
                role: .candidate,
                configuration: challengerConfiguration,
                deterministicGate: .failed
            ),
            declaredVariable: .reranker,
            advisoryJudge: RAGAdvisoryJudgeResult(
                evaluatorID: "synthetic-advisory-judge-733",
                verdict: .passed
            )
        )
        XCTAssertEqual(deterministicFailure.disposition, .failed)
        XCTAssertEqual(deterministicFailure.advisoryVerdict, .passed)
        XCTAssertTrue(
            deterministicFailure.issues.contains(
                .deterministicGateFailed(runID: "candidate-run-719")
            )
        )

        let advisoryFailure = RAGControlComparisonValidator.validate(
            control: control,
            candidate: makeRun(role: .candidate, configuration: challengerConfiguration),
            declaredVariable: .reranker,
            advisoryJudge: RAGAdvisoryJudgeResult(
                evaluatorID: "synthetic-advisory-judge-733",
                verdict: .failed
            )
        )
        XCTAssertEqual(advisoryFailure.disposition, .passed)
        XCTAssertEqual(advisoryFailure.advisoryVerdict, .failed)
        XCTAssertFalse(advisoryFailure.issues.contains(.advisoryJudgeChangedDisposition))
    }

    func testMissingOrNotApplicableCriticalCellsRemainPendingAndCannotPassRelease() throws {
        // T-RAG-BASELINE-01 expected RED: no fail-closed cell matrix prevents
        // a partial critical-slice/resource report from passing release.
        let control = makeRun(role: .control, configuration: controlConfiguration())
        var challengerConfiguration = controlConfiguration()
        challengerConfiguration.reranker = "native-reranker-v2-candidate-719"

        var missingCellCandidate = makeRun(role: .candidate, configuration: challengerConfiguration)
        missingCellCandidate.cells.removeAll {
            $0.metricID == "citation_recall" && $0.sliceID == "ocr"
        }
        let missingCell = RAGControlComparisonValidator.validate(
            control: control,
            candidate: missingCellCandidate,
            declaredVariable: .reranker,
            advisoryJudge: nil
        )
        XCTAssertEqual(missingCell.disposition, .pending)
        XCTAssertTrue(
            missingCell.issues.contains(
                .missingCriticalCell(
                    runID: "candidate-run-719",
                    metricID: "citation_recall",
                    sliceID: "ocr"
                )
            )
        )

        var notApplicableCandidate = makeRun(role: .candidate, configuration: challengerConfiguration)
        let resourceIndex = notApplicableCandidate.cells.firstIndex {
            $0.metricID == "combined_peak_phys_footprint_bytes" && $0.sliceID == "overall"
        }
        let exactResourceIndex = try XCTUnwrap(resourceIndex)
        notApplicableCandidate.cells[exactResourceIndex] = .notApplicable(
            metricID: "combined_peak_phys_footprint_bytes",
            sliceID: "overall",
            unit: "bytes",
            reason: "Synthetic installed-run capture is intentionally absent."
        )
        let notApplicable = RAGControlComparisonValidator.validate(
            control: control,
            candidate: notApplicableCandidate,
            declaredVariable: .reranker,
            advisoryJudge: nil
        )
        XCTAssertEqual(notApplicable.disposition, .pending)
        XCTAssertTrue(
            notApplicable.issues.contains(
                .nonMeasuredCriticalCell(
                    runID: "candidate-run-719",
                    metricID: "combined_peak_phys_footprint_bytes",
                    sliceID: "overall",
                    state: .notApplicable
                )
            )
        )
    }

    private func makeRun(
        role: RAGRunRole,
        configuration: RAGControlConfigurationBinding,
        deterministicGate: RAGDeterministicGate = .passed
    ) -> RAGBenchmarkRun {
        RAGBenchmarkRun(
            runID: role == .control ? "control-run-713" : "candidate-run-719",
            role: role,
            binding: RAGRunBinding(
                corpusManifestSHA256: "6fa99ce95733c4d0af62035393ea7b5d3635f7cc47e5580547bfdfaee5aca598",
                sourceCommitSHA: role == .control
                    ? "c985f954afcee2dcf444184ba4c93d5a5a48c9a7"
                    : "7197197197197197197197197197197197197197",
                hardware: RAGHardwareBinding(
                    modelIdentifier: "Mac16,7",
                    chip: "Apple M4 Pro",
                    unifiedMemoryBytes: 51_539_607_552
                ),
                toolchain: RAGToolchainBinding(
                    operatingSystemBuild: "26A5406e",
                    xcodeBuild: "27A5194q",
                    swiftVersion: "6.4"
                ),
                configuration: configuration
            ),
            cells: completeCriticalCells(),
            deterministicGate: deterministicGate
        )
    }

    private func controlConfiguration() -> RAGControlConfigurationBinding {
        RAGControlConfigurationBinding(
            chunker: "document-chunker-v2",
            embeddingArtifact: "qwen3-embedding-0.6b-revision-713",
            retriever: "sqlite-fts5-dense-rrf-v1",
            reranker: "shared-chat-reranker-v1-control",
            packer: "runtime-token-packer-v7",
            prompt: "grounded-document-prompt-v11",
            generationModel: "qwen3-14b-revision-727"
        )
    }

    private func completeCriticalCells() -> [RAGBenchmarkCell] {
        let qualityMetricIDs = [
            "recall_at_k",
            "full_evidence_set_recall_at_k",
            "ndcg_at_k",
            "mean_reciprocal_rank",
            "context_precision",
            "context_recall",
            "citation_precision",
            "citation_recall",
            "citation_coverage",
            "zero_result_accuracy",
        ]
        let criticalSliceIDs = [
            "overall",
            "ocr",
            "table",
            "revision",
            "contrary_evidence",
            "no_answer",
            "corpus_small",
            "corpus_medium",
            "corpus_large",
        ]
        let operationalMetricIDs = [
            "time_to_first_token_ms",
            "p50_total_latency_ms",
            "p95_total_latency_ms",
            "vectors_scanned",
            "vector_bytes_scanned",
            "maximum_live_page_rows",
            "maximum_live_heap_rows",
            "maximum_live_cache_bytes",
            "app_current_phys_footprint_bytes",
            "app_peak_phys_footprint_bytes",
            "xpc_current_phys_footprint_bytes",
            "xpc_peak_phys_footprint_bytes",
            "combined_current_phys_footprint_bytes",
            "combined_peak_phys_footprint_bytes",
        ]

        XCTAssertEqual(
            Set(RAGControlComparisonValidator.requiredQualityMetricIDs),
            Set(qualityMetricIDs)
        )
        XCTAssertEqual(
            Set(RAGControlComparisonValidator.requiredCriticalSliceIDs),
            Set(criticalSliceIDs)
        )
        XCTAssertEqual(
            Set(RAGControlComparisonValidator.requiredOperationalMetricIDs),
            Set(operationalMetricIDs)
        )

        var cells: [RAGBenchmarkCell] = []
        for (sliceOffset, sliceID) in criticalSliceIDs.enumerated() {
            for (metricOffset, metricID) in qualityMetricIDs.enumerated() {
                cells.append(
                    .measured(
                        metricID: metricID,
                        sliceID: sliceID,
                        value: 0.701 + Double(sliceOffset * 10 + metricOffset) / 10_000,
                        unit: "ratio"
                    )
                )
            }
        }
        for (offset, metricID) in operationalMetricIDs.enumerated() {
            cells.append(
                .measured(
                    metricID: metricID,
                    sliceID: "overall",
                    value: 713 + Double(offset * 17),
                    unit: metricID.hasSuffix("_bytes") ? "bytes" : "count_or_milliseconds"
                )
            )
        }
        return cells
    }
}
