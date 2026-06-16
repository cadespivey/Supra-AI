import Foundation
import SupraCore
import SupraDiagnostics
import SupraRuntimeClient
import SupraRuntimeInterface
import SupraStore

/// The outcome of running a validation suite: the persisted run id, the
/// assembled report, and both rendered forms.
public struct ValidationRunResult: Sendable {
    public let runID: String
    public let report: ValidationReport
    public let markdown: String
    public let json: Data
}

/// Executes a `ValidationSuite` end-to-end against the loaded model: it streams
/// each prompt through the runtime, gathers the mechanical signals the
/// `ValidationEvaluator` needs, persists the run/tests, and renders the report.
///
/// Generation failures for an individual test are recorded as a failed test and
/// do not abort the suite; only store errors propagate.
public struct ValidationRunner: Sendable {
    private let runtimeClient: any RuntimeClientProtocol
    private let store: SupraStore
    private let appVersion: AppVersion
    private let evaluator = ValidationEvaluator()
    private let markdownRenderer = MarkdownValidationReportRenderer()
    private let jsonRenderer = JSONValidationReportRenderer()

    public init(
        runtimeClient: any RuntimeClientProtocol,
        store: SupraStore,
        appVersion: AppVersion = .unknown
    ) {
        self.runtimeClient = runtimeClient
        self.store = store
        self.appVersion = appVersion
    }

    public func run(
        suite: ValidationSuite,
        modelID: ModelID,
        modelName: String,
        modelPath: String?,
        systemPrompt: String? = nil,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> ValidationRunResult {
        let run = try store.validation.createValidationRun(
            modelID: modelID.rawValue.uuidString,
            suiteID: suite.id,
            suiteVersion: suite.version
        )

        do {
            return try await execute(
                run: run,
                suite: suite,
                modelID: modelID,
                modelName: modelName,
                modelPath: modelPath,
                systemPrompt: systemPrompt,
                options: options
            )
        } catch {
            // Never leave the run row stranded at its initial 'partial' status.
            try? store.validation.completeValidationRun(
                runID: run.id,
                status: .failed,
                summary: "Validation run aborted: \(error.localizedDescription)"
            )
            throw error
        }
    }

    private func execute(
        run: ModelValidationRunRecord,
        suite: ValidationSuite,
        modelID: ModelID,
        modelName: String,
        modelPath: String?,
        systemPrompt: String?,
        options: GenerationOptions
    ) async throws -> ValidationRunResult {
        var testResults: [ValidationReportTestResult] = []
        var allWarnings: [String] = []
        var allErrors: [String] = []
        var representativeMetrics: RuntimeMetrics?

        for test in suite.tests {
            let collected = await collect(
                test: test,
                modelID: modelID,
                systemPrompt: systemPrompt,
                options: options
            )
            if representativeMetrics == nil {
                representativeMetrics = collected.metrics
            }

            let evaluation = evaluator.evaluate(test: test, input: collected.input)
            let excerpt = outputExcerpt(collected.input.output)

            _ = try store.validation.appendValidationTest(
                runID: run.id,
                testID: test.id,
                name: test.name,
                status: evaluation.status,
                outputExcerpt: excerpt,
                warnings: evaluation.warnings,
                errors: evaluation.errors
            )

            testResults.append(
                ValidationReportTestResult(
                    id: test.id,
                    name: test.name,
                    status: evaluation.status,
                    outputExcerpt: excerpt,
                    warnings: evaluation.warnings,
                    errors: evaluation.errors
                )
            )
            allWarnings.append(contentsOf: evaluation.warnings)
            allErrors.append(contentsOf: evaluation.errors)
        }

        let overallStatus = overallStatus(for: testResults.map(\.status))
        try store.validation.completeValidationRun(
            runID: run.id,
            status: overallStatus,
            summary: summary(for: overallStatus, suite: suite),
            warnings: allWarnings,
            errors: allErrors
        )

        let runtimeState = (try? await runtimeClient.runtimeStatus())?.state.rawValue ?? "unknown"

        let report = ValidationReport(
            appVersion: "\(appVersion.marketingVersion) (\(appVersion.buildNumber))",
            runtimeState: runtimeState,
            modelName: modelName,
            modelPath: modelPath,
            suiteID: suite.id,
            suiteVersion: suite.version,
            suiteName: suite.name,
            overallStatus: overallStatus,
            metrics: representativeMetrics,
            testResults: testResults,
            warnings: allWarnings,
            errors: allErrors,
            technicalNotes: [
                "Suite executed against the loaded model through the runtime XPC service.",
                "Pass policy: \(suite.passPolicy)."
            ],
            nextSteps: nextSteps(for: overallStatus)
        )

        return ValidationRunResult(
            runID: run.id,
            report: report,
            markdown: markdownRenderer.render(report),
            json: try jsonRenderer.render(report)
        )
    }

    // MARK: - Per-test execution

    private struct Collected {
        var input: ValidationEvaluationInput
        var metrics: RuntimeMetrics?
    }

    private func collect(
        test: ValidationTest,
        modelID: ModelID,
        systemPrompt: String?,
        options: GenerationOptions
    ) async -> Collected {
        let isCancellationTest = test.mechanicalChecks.contains(.cancelRequestSent)
            || test.mechanicalChecks.contains(.generationCancelled)
        let generationID = GenerationID()
        var input = ValidationEvaluationInput()
        var output = ""
        var metrics: RuntimeMetrics?
        var cancelIssued = false

        do {
            let request = GenerateRequest(
                generationID: generationID,
                modelID: modelID,
                prompt: test.prompt,
                systemPrompt: systemPrompt,
                options: options
            )

            for try await event in try runtimeClient.generate(request) {
                switch event.type {
                case .generationStarted:
                    input.generationStarted = true

                case .token:
                    input.streamingStarted = true
                    if let token = event.tokenText {
                        output += token
                    }
                    if isCancellationTest, !cancelIssued {
                        cancelIssued = true
                        input.cancelRequestSent = true
                        _ = try? await runtimeClient.cancelGeneration(generationID)
                    }

                case .metrics:
                    metrics = event.metrics ?? metrics

                case .generationCompleted:
                    metrics = event.metrics ?? metrics
                    input.completedWithoutCrash = true

                case .generationCancelled:
                    metrics = event.metrics ?? metrics
                    input.generationCancelled = true
                    input.completedWithoutCrash = true

                case .generationFailed, .queued, .modelLoading, .modelLoaded:
                    break
                }
            }
        } catch {
            // A rejected/failed stream leaves completedWithoutCrash false, which the
            // mechanical checks surface as a failed test.
        }

        input.output = output
        input.partialOutputPreserved = input.generationCancelled
            && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Collected(input: input, metrics: metrics)
    }

    // MARK: - Helpers

    private func overallStatus(for statuses: [ValidationTestStatus]) -> ValidationRunStatus {
        if statuses.contains(.failed) {
            return .failed
        }
        if statuses.contains(.warning) {
            return .partial
        }
        return .passed
    }

    private func outputExcerpt(_ output: String, limit: Int = 280) -> String {
        let collapsed = output
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= limit {
            return collapsed
        }
        return String(collapsed.prefix(limit)) + "…"
    }

    private func summary(for status: ValidationRunStatus, suite: ValidationSuite) -> String {
        "\(suite.name) (v\(suite.version)) completed with status: \(status.rawValue)."
    }

    private func nextSteps(for status: ValidationRunStatus) -> [String] {
        switch status {
        case .passed:
            ["Runtime is ready for the Milestone 1 vertical slice."]
        case .partial:
            ["Review warnings; the model meets core checks but has soft deviations."]
        case .failed:
            ["Investigate failing checks before relying on this model."]
        case .cancelled:
            ["Re-run the suite; the previous run did not complete."]
        }
    }
}
