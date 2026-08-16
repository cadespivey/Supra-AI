import Foundation

public enum RAGRunRole: String, Codable, Sendable {
    case control
    case candidate
}

public enum RAGControlVariable: String, Codable, CaseIterable, Hashable, Sendable {
    case chunker
    case embeddingArtifact = "embedding_artifact"
    case retriever
    case reranker
    case packer
    case prompt
    case generationModel = "generation_model"
}

public struct RAGControlConfigurationBinding: Codable, Equatable, Sendable {
    public var chunker: String
    public var embeddingArtifact: String
    public var retriever: String
    public var reranker: String
    public var packer: String
    public var prompt: String
    public var generationModel: String

    public init(
        chunker: String,
        embeddingArtifact: String,
        retriever: String,
        reranker: String,
        packer: String,
        prompt: String,
        generationModel: String
    ) {
        self.chunker = chunker
        self.embeddingArtifact = embeddingArtifact
        self.retriever = retriever
        self.reranker = reranker
        self.packer = packer
        self.prompt = prompt
        self.generationModel = generationModel
    }

    public func value(for variable: RAGControlVariable) -> String {
        switch variable {
        case .chunker: chunker
        case .embeddingArtifact: embeddingArtifact
        case .retriever: retriever
        case .reranker: reranker
        case .packer: packer
        case .prompt: prompt
        case .generationModel: generationModel
        }
    }
}

public struct RAGHardwareBinding: Codable, Equatable, Sendable {
    public var modelIdentifier: String
    public var chip: String
    public var unifiedMemoryBytes: UInt64

    public init(modelIdentifier: String, chip: String, unifiedMemoryBytes: UInt64) {
        self.modelIdentifier = modelIdentifier
        self.chip = chip
        self.unifiedMemoryBytes = unifiedMemoryBytes
    }
}

public struct RAGToolchainBinding: Codable, Equatable, Sendable {
    public var operatingSystemBuild: String
    public var xcodeBuild: String
    public var swiftVersion: String

    public init(operatingSystemBuild: String, xcodeBuild: String, swiftVersion: String) {
        self.operatingSystemBuild = operatingSystemBuild
        self.xcodeBuild = xcodeBuild
        self.swiftVersion = swiftVersion
    }
}

public struct RAGRunBinding: Codable, Equatable, Sendable {
    public var corpusManifestSHA256: String
    public var sourceCommitSHA: String
    public var hardware: RAGHardwareBinding
    public var toolchain: RAGToolchainBinding
    public var configuration: RAGControlConfigurationBinding

    public init(
        corpusManifestSHA256: String,
        sourceCommitSHA: String,
        hardware: RAGHardwareBinding,
        toolchain: RAGToolchainBinding,
        configuration: RAGControlConfigurationBinding
    ) {
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.sourceCommitSHA = sourceCommitSHA
        self.hardware = hardware
        self.toolchain = toolchain
        self.configuration = configuration
    }
}

public enum RAGBenchmarkCellState: String, Codable, Sendable {
    case measured
    case pending
    case notApplicable = "not_applicable"
}

public struct RAGBenchmarkCell: Codable, Equatable, Sendable {
    public var metricID: String
    public var sliceID: String
    public var state: RAGBenchmarkCellState
    public var value: Double?
    public var unit: String
    public var reason: String?

    public static func measured(
        metricID: String,
        sliceID: String,
        value: Double,
        unit: String
    ) -> RAGBenchmarkCell {
        RAGBenchmarkCell(
            metricID: metricID,
            sliceID: sliceID,
            state: .measured,
            value: value,
            unit: unit,
            reason: nil
        )
    }

    public static func pending(
        metricID: String,
        sliceID: String,
        unit: String,
        reason: String
    ) -> RAGBenchmarkCell {
        RAGBenchmarkCell(
            metricID: metricID,
            sliceID: sliceID,
            state: .pending,
            value: nil,
            unit: unit,
            reason: reason
        )
    }

    public static func notApplicable(
        metricID: String,
        sliceID: String,
        unit: String,
        reason: String
    ) -> RAGBenchmarkCell {
        RAGBenchmarkCell(
            metricID: metricID,
            sliceID: sliceID,
            state: .notApplicable,
            value: nil,
            unit: unit,
            reason: reason
        )
    }
}

public enum RAGDeterministicGate: String, Codable, Sendable {
    case passed
    case failed
    case pending
}

public struct RAGBenchmarkRun: Codable, Equatable, Sendable {
    public var runID: String
    public var role: RAGRunRole
    public var binding: RAGRunBinding
    public var cells: [RAGBenchmarkCell]
    public var deterministicGate: RAGDeterministicGate

    public init(
        runID: String,
        role: RAGRunRole,
        binding: RAGRunBinding,
        cells: [RAGBenchmarkCell],
        deterministicGate: RAGDeterministicGate
    ) {
        self.runID = runID
        self.role = role
        self.binding = binding
        self.cells = cells
        self.deterministicGate = deterministicGate
    }
}

public enum RAGAdvisoryJudgeVerdict: String, Codable, Sendable {
    case passed
    case failed
    case pending
}

public struct RAGAdvisoryJudgeResult: Codable, Equatable, Sendable {
    public var evaluatorID: String
    public var verdict: RAGAdvisoryJudgeVerdict

    public init(evaluatorID: String, verdict: RAGAdvisoryJudgeVerdict) {
        self.evaluatorID = evaluatorID
        self.verdict = verdict
    }
}

public enum RAGComparisonDisposition: String, Codable, Sendable {
    case passed
    case failed
    case pending
}

public enum RAGComparisonIssue: Equatable, Sendable {
    case invalidRunRole(runID: String, expected: RAGRunRole, actual: RAGRunRole)
    case invalidCorpusManifestDigest(runID: String)
    case invalidSourceCommitSHA(runID: String)
    case invalidHardwareBinding(runID: String)
    case invalidToolchainBinding(runID: String)
    case blankConfigurationValue(runID: String, variable: RAGControlVariable)
    case corpusManifestMismatch
    case hardwareMismatch
    case toolchainMismatch
    case declaredVariableDidNotChange(RAGControlVariable)
    case multipleConfigurationVariablesChanged([RAGControlVariable])
    case declaredVariableMismatch(declared: RAGControlVariable, actual: RAGControlVariable)
    case duplicateCell(runID: String, metricID: String, sliceID: String)
    case missingCriticalCell(runID: String, metricID: String, sliceID: String)
    case nonMeasuredCriticalCell(
        runID: String,
        metricID: String,
        sliceID: String,
        state: RAGBenchmarkCellState
    )
    case invalidMeasuredCell(runID: String, metricID: String, sliceID: String)
    case deterministicGateFailed(runID: String)
    case deterministicGatePending(runID: String)
    case advisoryJudgeChangedDisposition
}

public struct RAGComparisonValidation: Equatable, Sendable {
    public var disposition: RAGComparisonDisposition
    public var changedVariables: [RAGControlVariable]
    public var advisoryVerdict: RAGAdvisoryJudgeVerdict?
    public var issues: [RAGComparisonIssue]
}

public enum RAGControlComparisonValidator {
    public static let requiredQualityMetricIDs = [
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

    public static let requiredCriticalSliceIDs = [
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

    public static let requiredOperationalMetricIDs = [
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

    public static func validate(
        control: RAGBenchmarkRun,
        candidate: RAGBenchmarkRun,
        declaredVariable: RAGControlVariable,
        advisoryJudge: RAGAdvisoryJudgeResult?
    ) -> RAGComparisonValidation {
        var issues: [RAGComparisonIssue] = []
        var hasFailure = false
        var hasPending = false

        if control.role != .control {
            issues.append(.invalidRunRole(runID: control.runID, expected: .control, actual: control.role))
            hasFailure = true
        }
        if candidate.role != .candidate {
            issues.append(.invalidRunRole(runID: candidate.runID, expected: .candidate, actual: candidate.role))
            hasFailure = true
        }

        for run in [control, candidate] {
            if !isLowercaseHex(run.binding.corpusManifestSHA256, count: 64) {
                issues.append(.invalidCorpusManifestDigest(runID: run.runID))
                hasFailure = true
            }
            if !isLowercaseHex(run.binding.sourceCommitSHA, count: 40) {
                issues.append(.invalidSourceCommitSHA(runID: run.runID))
                hasFailure = true
            }
            if isBlank(run.binding.hardware.modelIdentifier)
                || isBlank(run.binding.hardware.chip)
                || run.binding.hardware.unifiedMemoryBytes == 0
            {
                issues.append(.invalidHardwareBinding(runID: run.runID))
                hasFailure = true
            }
            if isBlank(run.binding.toolchain.operatingSystemBuild)
                || isBlank(run.binding.toolchain.xcodeBuild)
                || isBlank(run.binding.toolchain.swiftVersion)
            {
                issues.append(.invalidToolchainBinding(runID: run.runID))
                hasFailure = true
            }
            for variable in RAGControlVariable.allCases
                where isBlank(run.binding.configuration.value(for: variable))
            {
                issues.append(.blankConfigurationValue(runID: run.runID, variable: variable))
                hasFailure = true
            }
        }

        if control.binding.corpusManifestSHA256 != candidate.binding.corpusManifestSHA256 {
            issues.append(.corpusManifestMismatch)
            hasFailure = true
        }
        if control.binding.hardware != candidate.binding.hardware {
            issues.append(.hardwareMismatch)
            hasFailure = true
        }
        if control.binding.toolchain != candidate.binding.toolchain {
            issues.append(.toolchainMismatch)
            hasFailure = true
        }

        let changedVariables = RAGControlVariable.allCases.filter {
            control.binding.configuration.value(for: $0) != candidate.binding.configuration.value(for: $0)
        }
        switch changedVariables.count {
        case 0:
            issues.append(.declaredVariableDidNotChange(declaredVariable))
            hasFailure = true
        case 1:
            if changedVariables[0] != declaredVariable {
                issues.append(
                    .declaredVariableMismatch(declared: declaredVariable, actual: changedVariables[0])
                )
                hasFailure = true
            }
        default:
            issues.append(.multipleConfigurationVariablesChanged(changedVariables))
            hasFailure = true
        }

        for run in [control, candidate] {
            let result = validateCriticalCells(in: run)
            issues.append(contentsOf: result.issues)
            hasFailure = hasFailure || result.hasFailure
            hasPending = hasPending || result.hasPending

            switch run.deterministicGate {
            case .passed:
                break
            case .failed:
                issues.append(.deterministicGateFailed(runID: run.runID))
                hasFailure = true
            case .pending:
                issues.append(.deterministicGatePending(runID: run.runID))
                hasPending = true
            }
        }

        let disposition: RAGComparisonDisposition
        if hasFailure {
            disposition = .failed
        } else if hasPending {
            disposition = .pending
        } else {
            disposition = .passed
        }

        return RAGComparisonValidation(
            disposition: disposition,
            changedVariables: changedVariables,
            advisoryVerdict: advisoryJudge?.verdict,
            issues: issues
        )
    }

    private struct CellKey: Hashable {
        var metricID: String
        var sliceID: String
    }

    private struct CellValidation {
        var issues: [RAGComparisonIssue]
        var hasFailure: Bool
        var hasPending: Bool
    }

    private static func validateCriticalCells(in run: RAGBenchmarkRun) -> CellValidation {
        var issues: [RAGComparisonIssue] = []
        var hasFailure = false
        var hasPending = false
        var cellsByKey: [CellKey: RAGBenchmarkCell] = [:]

        for cell in run.cells {
            let key = CellKey(metricID: cell.metricID, sliceID: cell.sliceID)
            if cellsByKey.updateValue(cell, forKey: key) != nil {
                issues.append(
                    .duplicateCell(runID: run.runID, metricID: cell.metricID, sliceID: cell.sliceID)
                )
                hasFailure = true
            }
        }

        for sliceID in requiredCriticalSliceIDs {
            for metricID in requiredQualityMetricIDs {
                validateRequiredCell(
                    key: CellKey(metricID: metricID, sliceID: sliceID),
                    run: run,
                    cellsByKey: cellsByKey,
                    issues: &issues,
                    hasFailure: &hasFailure,
                    hasPending: &hasPending
                )
            }
        }
        for metricID in requiredOperationalMetricIDs {
            validateRequiredCell(
                key: CellKey(metricID: metricID, sliceID: "overall"),
                run: run,
                cellsByKey: cellsByKey,
                issues: &issues,
                hasFailure: &hasFailure,
                hasPending: &hasPending
            )
        }

        return CellValidation(issues: issues, hasFailure: hasFailure, hasPending: hasPending)
    }

    private static func validateRequiredCell(
        key: CellKey,
        run: RAGBenchmarkRun,
        cellsByKey: [CellKey: RAGBenchmarkCell],
        issues: inout [RAGComparisonIssue],
        hasFailure: inout Bool,
        hasPending: inout Bool
    ) {
        guard let cell = cellsByKey[key] else {
            issues.append(
                .missingCriticalCell(
                    runID: run.runID,
                    metricID: key.metricID,
                    sliceID: key.sliceID
                )
            )
            hasPending = true
            return
        }

        switch cell.state {
        case .measured:
            if cell.value?.isFinite != true || isBlank(cell.unit) || cell.reason != nil {
                issues.append(
                    .invalidMeasuredCell(
                        runID: run.runID,
                        metricID: key.metricID,
                        sliceID: key.sliceID
                    )
                )
                hasFailure = true
            }
        case .pending, .notApplicable:
            issues.append(
                .nonMeasuredCriticalCell(
                    runID: run.runID,
                    metricID: key.metricID,
                    sliceID: key.sliceID,
                    state: cell.state
                )
            )
            hasPending = true
            if cell.value != nil || isBlank(cell.unit) || isBlank(cell.reason) {
                issues.append(
                    .invalidMeasuredCell(
                        runID: run.runID,
                        metricID: key.metricID,
                        sliceID: key.sliceID
                    )
                )
                hasFailure = true
            }
        }
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }
}
