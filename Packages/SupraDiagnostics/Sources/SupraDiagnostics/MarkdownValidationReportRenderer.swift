import Foundation
import SupraRuntimeInterface

public struct MarkdownValidationReportRenderer: Sendable {
    private let redactionPolicy: RedactionPolicy

    public init(redactionPolicy: RedactionPolicy = .default) {
        self.redactionPolicy = redactionPolicy
    }

    public func render(_ report: ValidationReport) -> String {
        let body = [
            "# Supra AI Milestone 1 Validation Report",
            "",
            "## Summary",
            "- Generated: \(report.generatedAt.formatted(.iso8601))",
            "- Overall status: \(report.overallStatus.rawValue)",
            "",
            "## App / Runtime",
            "- App: \(report.appName)",
            "- Version: \(report.appVersion)",
            "- Runtime state: \(report.runtimeState)",
            "",
            "## Model",
            "- Model: \(report.modelName)",
            "- Path: \(report.modelPath ?? "Not recorded")",
            "",
            "## Validation Suite",
            "- Suite: \(report.suiteName)",
            "- ID: \(report.suiteID)",
            "- Version: \(report.suiteVersion)",
            "",
            "## Runtime Metrics",
            runtimeMetricsMarkdown(report.metrics),
            "",
            "## Test Results",
            testResultsMarkdown(report.testResults),
            "",
            "## Warnings",
            listMarkdown(report.warnings, emptyText: "None"),
            "",
            "## Errors",
            listMarkdown(report.errors, emptyText: "None"),
            "",
            "## Technical Notes",
            listMarkdown(report.technicalNotes, emptyText: "None"),
            "",
            "## Next Steps",
            listMarkdown(report.nextSteps, emptyText: "None"),
            ""
        ].joined(separator: "\n")

        return redactionPolicy.redact(body)
    }

    private func runtimeMetricsMarkdown(_ metrics: RuntimeMetrics?) -> String {
        guard let metrics else { return "Not recorded" }

        return [
            "- Load time: \(formatted(metrics.loadTimeMs, suffix: " ms"))",
            "- First-token latency: \(formatted(metrics.firstTokenLatencyMs, suffix: " ms"))",
            "- Tokens/sec: \(metrics.tokensPerSecond.map { String(format: "%.2f", $0) } ?? "n/a")",
            "- Cancellation latency: \(formatted(metrics.cancellationLatencyMs, suffix: " ms"))",
            "- Generated tokens: \(formatted(metrics.generatedTokenCount, suffix: ""))"
        ].joined(separator: "\n")
    }

    private func testResultsMarkdown(_ results: [ValidationReportTestResult]) -> String {
        guard !results.isEmpty else { return "No tests recorded" }

        return results.map { result in
            [
                "### \(result.name)",
                "- ID: \(result.id)",
                "- Status: \(result.status.rawValue)",
                "- Output excerpt: \(result.outputExcerpt.isEmpty ? "None" : result.outputExcerpt)",
                "- Warnings: \(result.warnings.isEmpty ? "None" : result.warnings.joined(separator: "; "))",
                "- Errors: \(result.errors.isEmpty ? "None" : result.errors.joined(separator: "; "))"
            ].joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func listMarkdown(_ values: [String], emptyText: String) -> String {
        guard !values.isEmpty else { return emptyText }
        return values.map { "- \($0)" }.joined(separator: "\n")
    }

    private func formatted(_ value: Int?, suffix: String) -> String {
        guard let value else { return "n/a" }
        return "\(value)\(suffix)"
    }
}
