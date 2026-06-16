import SupraCore
@testable import SupraDiagnostics
import XCTest

final class ValidationSuiteTests: XCTestCase {
    func testMilestoneSuiteDecodes() throws {
        let suite = try loadMilestoneSuite()

        XCTAssertEqual(suite.id, "milestone1-practical-legal-client-suite")
        XCTAssertEqual(suite.version, 1)
        XCTAssertEqual(suite.tests.count, 6)
        XCTAssertTrue(suite.tests.contains { $0.id == "cancellation" })
    }

    func testEvaluatorPassesBasicResponse() throws {
        let suite = try loadMilestoneSuite()
        let test = try XCTUnwrap(suite.tests.first { $0.id == "basic_response" })
        let evaluation = ValidationEvaluator().evaluate(
            test: test,
            input: ValidationEvaluationInput(
                generationStarted: true,
                streamingStarted: true,
                completedWithoutCrash: true,
                output: "Supra AI runtime is working."
            )
        )

        XCTAssertEqual(evaluation.status, .passed)
        XCTAssertTrue(evaluation.errors.isEmpty)
    }

    func testEvaluatorWarnsForWrongBulletCount() throws {
        let suite = try loadMilestoneSuite()
        let test = try XCTUnwrap(suite.tests.first { $0.id == "instruction_following" })
        let evaluation = ValidationEvaluator().evaluate(
            test: test,
            input: ValidationEvaluationInput(
                generationStarted: true,
                streamingStarted: true,
                completedWithoutCrash: true,
                output: "- Privacy\n- Accuracy"
            )
        )

        XCTAssertEqual(evaluation.status, .warning)
        XCTAssertTrue(evaluation.warnings.contains { $0.contains("Expected exactly 3") })
    }

    func testUnsupportedYesRuleFails() throws {
        let suite = try loadMilestoneSuite()
        let test = try XCTUnwrap(suite.tests.first { $0.id == "source_grounded_formatting" })
        let evaluation = ValidationEvaluator().evaluate(
            test: test,
            input: ValidationEvaluationInput(
                generationStarted: true,
                streamingStarted: true,
                completedWithoutCrash: true,
                output: "Yes, the agreement requires arbitration."
            )
        )

        XCTAssertEqual(evaluation.status, .failed)
        XCTAssertFalse(evaluation.errors.isEmpty)
    }

    func testRenderersRedactLocalPaths() throws {
        let report = ValidationReport(
            appVersion: "0.1",
            runtimeState: "modelLoaded",
            modelName: "Local Model",
            modelPath: "/Users/example/Models/model",
            suiteID: "suite",
            suiteVersion: 1,
            suiteName: "Suite",
            overallStatus: .passed,
            testResults: [
                ValidationReportTestResult(
                    id: "basic",
                    name: "Basic",
                    status: .passed,
                    outputExcerpt: "ok"
                )
            ],
            technicalNotes: ["Loaded from /Users/example/Models/model"]
        )

        let markdown = MarkdownValidationReportRenderer().render(report)
        XCTAssertFalse(markdown.contains("/Users/example"))
        XCTAssertTrue(markdown.contains("<redacted-path>"))

        let jsonData = try JSONValidationReportRenderer().render(report)
        let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
        XCTAssertFalse(json.contains("/Users/example"))
        XCTAssertTrue(json.contains("<redacted-path>"))
    }

    private func loadMilestoneSuite() throws -> ValidationSuite {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageDirectory = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoDirectory = packageDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let suiteURL = repoDirectory
            .appendingPathComponent("Resources")
            .appendingPathComponent("ValidationSuites")
            .appendingPathComponent("milestone1-practical-legal-client-suite-v1.json")
        let data = try Data(contentsOf: suiteURL)
        let decoder = JSONDecoder()
        return try decoder.decode(ValidationSuite.self, from: data)
    }
}
