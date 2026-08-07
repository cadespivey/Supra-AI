import Foundation
import XCTest

final class CorpusReviewQueueCompositionUITests: XCTestCase {
    func testTQUEUE03ShippingAppInjectsLiveCorpusRunnerIntoBootstrappedQueue() throws {
        // T-QUEUE-03 expected RED: AppEnvironment constructs and bootstraps the
        // document FIFO without a corpusAnalysisRunner, so user-enqueued review
        // work cannot reach model resolution or generation after relaunch.
        let testFile = URL(fileURLWithPath: #filePath)
        let appEnvironmentURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SupraAI/AppEnvironment.swift")
        let source = try String(contentsOf: appEnvironmentURL, encoding: .utf8)
        let liveRunnerPattern = #"let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*CorpusAnalysisQueueRunner\.live\s*\("#
        let expression = try NSRegularExpression(pattern: liveRunnerPattern)
        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let match = try XCTUnwrap(expression.firstMatch(in: source, range: sourceRange))
        let runnerNameRange = try XCTUnwrap(Range(match.range(at: 1), in: source))
        let runnerName = String(source[runnerNameRange])
        let queueStart = try XCTUnwrap(source.range(of: "let queue = DocumentProcessingQueue("))
        let queueEnd = try XCTUnwrap(
            source.range(of: "self.documentQueue = queue", range: queueStart.lowerBound..<source.endIndex)
        )
        let composition = String(source[queueStart.lowerBound..<queueEnd.upperBound])

        XCTAssertTrue(composition.contains("corpusAnalysisRunner:"))
        XCTAssertTrue(
            composition.contains("\(runnerName).run"),
            "the DocumentProcessingQueue initializer must receive the exact live runner constructed above it"
        )
        XCTAssertTrue(source.contains("documentQueue.bootstrap()"))
    }
}
