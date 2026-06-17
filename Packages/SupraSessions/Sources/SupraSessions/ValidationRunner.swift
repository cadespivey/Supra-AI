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
            // A cooperative cancellation is recorded as .cancelled; any other
            // error (including a fail-fast runtime disconnect) as .failed.
            let cancelled = error is CancellationError
            try? store.validation.completeValidationRun(
                runID: run.id,
                status: cancelled ? .cancelled : .failed,
                summary: cancelled
                    ? "Validation run cancelled before completion."
                    : "Validation run aborted: \(error.localizedDescription)"
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
            // Cooperative cancellation point between tests: a cancelled run
            // throws here and is finalized as .cancelled by run()'s catch,
            // rather than being torn down silently mid-suite.
            try Task.checkCancellation()

            let collected = try await collect(
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

            // Surface any generation/stream error that the per-test collection
            // swallowed, so a failed test isn't silently empty.
            var testErrors = evaluation.errors
            if let streamError = collected.streamErrorMessage {
                testErrors.append("Generation error: \(streamError)")
            }

            _ = try store.validation.appendValidationTest(
                runID: run.id,
                testID: test.id,
                name: test.name,
                status: evaluation.status,
                outputExcerpt: excerpt,
                warnings: evaluation.warnings,
                errors: testErrors
            )

            testResults.append(
                ValidationReportTestResult(
                    id: test.id,
                    name: test.name,
                    status: evaluation.status,
                    outputExcerpt: excerpt,
                    warnings: evaluation.warnings,
                    errors: testErrors
                )
            )
            allWarnings.append(contentsOf: evaluation.warnings)
            allErrors.append(contentsOf: testErrors)
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
        var streamErrorMessage: String?
    }

    private func collect(
        test: ValidationTest,
        modelID: ModelID,
        systemPrompt: String?,
        options: GenerationOptions
    ) async throws -> Collected {
        let isCancellationTest = test.mechanicalChecks.contains(.cancelRequestSent)
            || test.mechanicalChecks.contains(.generationCancelled)
        let generationID = GenerationID()
        var input = ValidationEvaluationInput()
        var output = ""
        var metrics: RuntimeMetrics?
        var cancelIssued = false
        var streamErrorMessage: String?

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
        } catch is CancellationError {
            // Let a cooperative cancel abort the whole run (run() records it).
            throw CancellationError()
        } catch {
            // A rejected/failed stream leaves completedWithoutCrash false, which the
            // mechanical checks surface as a failed test; record why so the
            // failed test isn't silently empty.
            streamErrorMessage = error.localizedDescription
        }

        // Grade the user-facing answer, not the model's chain-of-thought: a
        // reasoning model streams "<reasoning></think><answer>", and counting
        // sentences/bullets over the reasoning trace would make the rule checks
        // un-gradeable. Non-reasoning output has no </think> and passes through.
        input.output = ReasoningContent.answer(from: output)
        // Partial-output preservation is about whether the cancelled generation
        // produced *anything*, so it inspects the raw stream (which may be all
        // reasoning at the point of cancellation).
        input.partialOutputPreserved = input.generationCancelled
            && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Collected(input: input, metrics: metrics, streamErrorMessage: streamErrorMessage)
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
