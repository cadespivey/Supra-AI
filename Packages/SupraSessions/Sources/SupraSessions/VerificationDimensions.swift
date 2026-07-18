import Foundation
import SupraCore
import SupraDocuments

/// A parity-preserving factorization of the deterministic document support
/// verifier. It records independent questions without changing the established
/// aggregate verification status.
public enum VerificationDimensionsMapper {
    public static func dimensions(for report: DocumentSupportReport) -> VerificationDimensions {
        dimensions(
            verificationResults: report.results,
            usedLabels: report.usedLabels,
            unresolvedLabels: report.unresolvedLabels,
            warnings: report.warnings
        )
    }

    public static func dimensions(
        verificationResults results: [PropositionSupportResult],
        usedLabels: [String] = [],
        unresolvedLabels: [String] = [],
        warnings: [String] = []
    ) -> VerificationDimensions {
        let evidence = orderedUnique(results.flatMap(\.evidence).map { item in
            VerificationDimensionEvidence(
                sourceID: item.sourceID,
                sourceLabel: item.sourceLabel,
                locator: item.locator,
                excerpt: item.retainedExcerpt
            )
        })
        let reasons = orderedUnique(results.flatMap(\.reasons) + warnings)
        let reasonText = reasons.joined(separator: " ")
        let allSupported = !results.isEmpty && results.allSatisfy { $0.status == .supported }
        let hasUnsupported = results.contains { $0.status == .unsupported }
        let citationsResolved = unresolvedLabels.isEmpty && (!usedLabels.isEmpty || !evidence.isEmpty)
        let lowConfidenceReasons = reasons.filter {
            $0.localizedCaseInsensitiveContains("low-confidence")
                || $0.localizedCaseInsensitiveContains("low confidence")
        }

        let proposition = VerificationDimensionResult(
            dimension: .propositionSupport,
            status: allSupported ? .satisfied : .failed,
            reason: allSupported
                ? "Every extracted proposition is supported by retained source evidence."
                : (reasonText.isEmpty ? "Proposition support was not established." : reasonText),
            evidence: evidence
        )
        let citation = VerificationDimensionResult(
            dimension: .citationResolution,
            status: citationsResolved ? .satisfied : .failed,
            reason: citationsResolved
                ? "Every used citation label resolves to retained source evidence."
                : citationFailureReason(
                    usedLabels: usedLabels,
                    unresolvedLabels: unresolvedLabels,
                    reasons: reasons
                ),
            evidence: evidence
        )
        let critical: VerificationDimensionResult
        if allSupported {
            critical = .init(
                dimension: .criticalValueFidelity,
                status: .satisfied,
                reason: "Critical values in every supported proposition match the cited source text.",
                evidence: evidence
            )
        } else if hasUnsupported {
            critical = .init(
                dimension: .criticalValueFidelity,
                status: .failed,
                reason: "At least one resolved proposition failed source-text or critical-value fidelity.",
                evidence: evidence
            )
        } else {
            critical = .init(
                dimension: .criticalValueFidelity,
                status: .notRun,
                reason: "Critical-value fidelity was not run because proposition evidence was unresolved or unverifiable."
            )
        }
        let lowConfidence = VerificationDimensionResult(
            dimension: .lowConfidenceHandling,
            status: lowConfidenceReasons.isEmpty && citationsResolved ? .satisfied : (lowConfidenceReasons.isEmpty ? .notRun : .failed),
            reason: lowConfidenceReasons.isEmpty
                ? (citationsResolved
                    ? "No used citation depended on low-confidence source text."
                    : "Low-confidence handling was not run because citation evidence did not resolve.")
                : lowConfidenceReasons.joined(separator: " "),
            evidence: lowConfidenceReasons.isEmpty ? evidence : []
        )

        return .complete(overrides: [proposition, citation, critical, lowConfidence])
    }

    private static func citationFailureReason(
        usedLabels: [String],
        unresolvedLabels: [String],
        reasons: [String]
    ) -> String {
        if !unresolvedLabels.isEmpty {
            return "Unresolved citation labels: \(unresolvedLabels.joined(separator: ", "))."
        }
        if usedLabels.isEmpty {
            return "The output contains no resolvable inline citation labels."
        }
        return reasons.first(where: {
            $0.localizedCaseInsensitiveContains("citation")
                || $0.localizedCaseInsensitiveContains("source")
        }) ?? "Citation resolution was not established."
    }

    private static func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

public struct VerificationDimensionRow: Equatable, Sendable {
    public let dimension: VerificationDimensionName
    public let title: String
    public let status: VerificationDimensionStatus
    public let statusLabel: String
    public let reason: String?
    public let displayText: String
}

public enum VerificationDimensionPresenter {
    public static func rows(from dimensions: VerificationDimensions) -> [VerificationDimensionRow] {
        VerificationDimensionName.allCases.map { dimension in
            let result = dimensions.result(for: dimension)
            let title = title(for: dimension)
            let label = label(for: result.status)
            let detail = result.reason.map { " \($0)" } ?? ""
            return VerificationDimensionRow(
                dimension: dimension,
                title: title,
                status: result.status,
                statusLabel: label,
                reason: result.reason,
                displayText: "\(title): \(label).\(detail)"
            )
        }
    }

    private static func label(for status: VerificationDimensionStatus) -> String {
        switch status {
        case .satisfied: "Satisfied"
        case .failed: "Failed"
        case .notRun: "Not run"
        case .notApplicable: "Not applicable"
        }
    }

    private static func title(for dimension: VerificationDimensionName) -> String {
        switch dimension {
        case .propositionSupport: "Proposition support"
        case .citationResolution: "Citation resolution"
        case .criticalValueFidelity: "Critical-value fidelity"
        case .contraryEvidence: "Contrary evidence"
        case .listCompleteness: "List completeness"
        case .chronologyCoverage: "Chronology coverage"
        case .numericDateEntityReconciliation: "Numeric, date, and entity reconciliation"
        case .versionValidity: "Version validity"
        case .lowConfidenceHandling: "Low-confidence handling"
        case .corpusCoverage: "Corpus coverage"
        case .negativeValidity: "Negative validity"
        }
    }
}

/// Deterministic corpus checks layer onto proposition support without
/// promoting one contract into another. Callers provide ledger-derived reasons
/// and retained contrary evidence; this evaluator never infers success from an
/// aggregate assurance string alone.
public enum CorpusVerificationDimensionsEvaluator {
    public static func exhaustiveList(
        base: VerificationDimensions,
        coverage: CorpusAnalysisCoverage,
        listFailures: [String],
        coverageFailures: [String],
        contraryEvidence: [VerificationDimensionEvidence]
    ) -> VerificationDimensions {
        let coverageIsComplete = coverage.pendingPartitionCount == 0
            && coverage.failedPartitionCount == 0
            && coverage.cancelledPartitionCount == 0
            && coverage.excludedPartitionCount == 0
            && coverage.succeededPartitionCount == coverage.partitionCount
            && coverage.balanceErrorCount == 0
            && coverageFailures.isEmpty
        let completeListFailures = orderedUnique(coverageFailures + listFailures)
        let existing = Dictionary(
            uniqueKeysWithValues: base.results.map { ($0.dimension, $0) }
        )
        var overrides = existing
        overrides[.corpusCoverage] = .init(
            dimension: .corpusCoverage,
            status: coverageIsComplete ? .satisfied : .failed,
            reason: coverageIsComplete
                ? "Every in-scope corpus partition succeeded and the coverage ledger balances."
                : reason(
                    prefix: "Corpus coverage is incomplete.",
                    details: coverageFailures,
                    fallback: "The ledger contains failed, cancelled, pending, excluded, or unbalanced partitions."
                )
        )
        overrides[.listCompleteness] = .init(
            dimension: .listCompleteness,
            status: coverageIsComplete && completeListFailures.isEmpty ? .satisfied : .failed,
            reason: coverageIsComplete && completeListFailures.isEmpty
                ? "The exhaustive list completed across every in-scope partition without a recorded omission or conflict."
                : reason(
                    prefix: "List completeness was not established.",
                    details: completeListFailures,
                    fallback: "The exhaustive list has a coverage or reconciliation gap."
                )
        )
        if !contraryEvidence.isEmpty {
            let names = orderedUnique(contraryEvidence.compactMap(\.sourceLabel))
            overrides[.contraryEvidence] = .init(
                dimension: .contraryEvidence,
                status: .failed,
                reason: "The contrary-evidence sweep found retained contrary passages"
                    + (names.isEmpty ? "." : " in \(names.joined(separator: ", "))."),
                evidence: contraryEvidence
            )
        } else if coverageIsComplete {
            overrides[.contraryEvidence] = .init(
                dimension: .contraryEvidence,
                status: .satisfied,
                reason: "The exhaustive sweep recorded no contrary passage in the completed corpus run."
            )
        } else {
            overrides[.contraryEvidence] = .init(
                dimension: .contraryEvidence,
                status: .notRun,
                reason: "The contrary-evidence sweep cannot establish absence while corpus coverage is incomplete."
            )
        }
        overrides[.chronologyCoverage] = .init(
            dimension: .chronologyCoverage,
            status: .notApplicable,
            reason: "Chronology coverage does not apply to an exhaustive-list task."
        )
        overrides[.negativeValidity] = .init(
            dimension: .negativeValidity,
            status: .notApplicable,
            reason: "Negative validity requires a separately requested negative conclusion."
        )
        return .complete(overrides: VerificationDimensionName.allCases.compactMap { overrides[$0] })
    }

    private static func reason(prefix: String, details: [String], fallback: String) -> String {
        let details = orderedUnique(details)
        return details.isEmpty ? "\(prefix) \(fallback)" : "\(prefix) \(details.joined(separator: " "))"
    }

    private static func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
