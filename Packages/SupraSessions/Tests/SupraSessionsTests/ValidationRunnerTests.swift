import Foundation
import SupraCore
import SupraDiagnostics
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore
import XCTest

final class ValidationRunnerTests: XCTestCase {

    func testPassingSuiteRecordsRunAndTests() async throws {
        let store = try makeStore()
        let suite = ValidationSuite(
            id: "test-suite",
            version: 1,
            name: "Test Suite",
            description: "",
            passPolicy: "core_pass",
            tests: [basicTest, cancellationTest]
        )
        let stub = StubRuntimeClient { request in
            switch request.prompt {
            case "CANCEL":
                return .events([
                    .event(request, 1, .generationStarted),
                    .event(request, 2, .token, token: "Partial output"),
                    .event(request, 3, .generationCancelled, metrics: RuntimeMetrics(cancellationLatencyMs: 0))
                ])
            default:
                return .events([
                    .event(request, 1, .generationStarted),
                    .event(request, 2, .token, token: "Supra AI runtime is working."),
                    .event(request, 3, .generationCompleted, metrics: RuntimeMetrics(generatedTokenCount: 5))
                ])
            }
        }
        let runner = ValidationRunner(
            runtimeClient: stub,
            store: store,
            appVersion: AppVersion(marketingVersion: "1.0", buildNumber: "1")
        )

        let result = try await runner.run(
            suite: suite,
            modelID: try seedModel(store),
            modelName: "Test Model",
            modelPath: "/tmp/model"
        )

        XCTAssertEqual(result.report.overallStatus, .passed)
        XCTAssertEqual(result.report.testResults.count, 2)
        XCTAssertEqual(result.report.testResults.first { $0.id == "basic" }?.status, .passed)
        XCTAssertEqual(result.report.testResults.first { $0.id == "cancel" }?.status, .passed)

        let runs = try store.validation.fetchValidationRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, ValidationRunStatus.passed.rawValue)
        XCTAssertEqual(try store.validation.fetchValidationTests(runID: result.runID).count, 2)

        XCTAssertTrue(result.markdown.contains("Test Suite"))
        XCTAssertFalse(result.json.isEmpty)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: result.json))
    }

    func testWarningProducesPartialRun() async throws {
        let store = try makeStore()
        let suite = ValidationSuite(
            id: "s",
            version: 1,
            name: "Warnings",
            description: "",
            passPolicy: "core_pass",
            tests: [
                ValidationTest(
                    id: "short",
                    name: "Short",
                    prompt: "SHORT",
                    expectedBehavior: "",
                    mechanicalChecks: [.generationStarted, .streamingStarted, .nonemptyOutput, .completedWithoutCrash],
                    ruleChecks: [ValidationRuleCheck(type: .roughSentenceLimit, severity: .warning, maxSentences: 1)]
                )
            ]
        )
        let stub = StubRuntimeClient { request in
            .events([
                .event(request, 1, .generationStarted),
                .event(request, 2, .token, token: "First sentence. Second sentence."),
                .event(request, 3, .generationCompleted)
            ])
        }
        let runner = ValidationRunner(runtimeClient: stub, store: store)

        let result = try await runner.run(suite: suite, modelID: try seedModel(store), modelName: "M", modelPath: nil)

        XCTAssertEqual(result.report.testResults.first?.status, .warning)
        XCTAssertEqual(result.report.overallStatus, .partial)
        XCTAssertFalse(result.report.warnings.isEmpty)
    }

    func testRejectedGenerationProducesFailedRun() async throws {
        let store = try makeStore()
        let suite = ValidationSuite(
            id: "s",
            version: 1,
            name: "Failing",
            description: "",
            passPolicy: "core_pass",
            tests: [basicTest]
        )
        let stub = StubRuntimeClient { _ in
            .reject(RuntimeClientError.remoteProxyUnavailable)
        }
        let runner = ValidationRunner(runtimeClient: stub, store: store)

        let result = try await runner.run(suite: suite, modelID: try seedModel(store), modelName: "M", modelPath: nil)

        XCTAssertEqual(result.report.testResults.first?.status, .failed)
        XCTAssertEqual(result.report.overallStatus, .failed)
        XCTAssertEqual(try store.validation.fetchValidationRuns().first?.status, ValidationRunStatus.failed.rawValue)
    }

    // MARK: - Fixtures

    private var basicTest: ValidationTest {
        ValidationTest(
            id: "basic",
            name: "Basic",
            prompt: "BASIC",
            expectedBehavior: "",
            mechanicalChecks: [.generationStarted, .streamingStarted, .nonemptyOutput, .completedWithoutCrash],
            ruleChecks: []
        )
    }

    private var cancellationTest: ValidationTest {
        ValidationTest(
            id: "cancel",
            name: "Cancellation",
            prompt: "CANCEL",
            expectedBehavior: "",
            mechanicalChecks: [.generationStarted, .streamingStarted, .cancelRequestSent, .generationCancelled, .partialOutputPreserved],
            ruleChecks: []
        )
    }

    private func seedModel(_ store: SupraStore) throws -> ModelID {
        let modelID = ModelID()
        try store.models.upsertModel(
            ModelRecord(id: modelID.rawValue.uuidString, displayName: "Test Model", path: "/tmp/model")
        )
        return modelID
    }

    private func makeStore() throws -> SupraStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ValidationRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try SupraStore(url: directoryURL.appendingPathComponent("test.sqlite"))
    }
}
