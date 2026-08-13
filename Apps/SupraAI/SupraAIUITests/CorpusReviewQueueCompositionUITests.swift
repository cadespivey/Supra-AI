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

    func testTQUEUE03CorpusBootstrapPrecedesAndSuppressesStartupModelAutoload() throws {
        // T-QUEUE-03 expected RED: startup model autoload currently begins before
        // persisted corpus work is reconciled, so two loads can race for one XPC slot.
        let source = try appEnvironmentSource()
        let bootstrap = try XCTUnwrap(source.range(of: "documentQueue.bootstrap()"))
        let guardedAutoload = try XCTUnwrap(
            source.range(of: "if !documentQueue.hasPendingCorpusAnalysisWork")
        )
        let autoload = try XCTUnwrap(
            source.range(
                of: "autoLoadStartupModelIfNeeded()",
                range: guardedAutoload.lowerBound..<source.endIndex
            )
        )

        XCTAssertLessThan(bootstrap.lowerBound, guardedAutoload.lowerBound)
        XCTAssertLessThan(guardedAutoload.lowerBound, autoload.lowerBound)
    }

    func testTQUEUE03ContentBoundLoadAndCorpusGenerationShareAdmittedRuntimeClient() throws {
        // T-QUEUE-03 lease-composition expected RED: content-bound loading and
        // generation must share the one admitted runtime facade. The historical
        // taskRuntimeClient alias is incompatible with the process-wide boundary.
        let source = try appEnvironmentSource()
        let modelLibrary = try initializerSource(
            named: "let modelLibrary = ModelLibrary(",
            in: source
        )
        let corpusRunner = try initializerSource(
            named: "let corpusAnalysisRunner = CorpusAnalysisQueueRunner.live(",
            in: source
        )

        XCTAssertTrue(modelLibrary.contains("runtimeClient: runtimeClient"))
        XCTAssertTrue(
            corpusRunner.contains("runtimeClient: runtimeClient"),
            "content-bound load and corpus generation must use the identical admitted runtime client"
        )
    }

    func testTLEASE07ShippingCompositionUsesOneExclusiveWrapperAndNoOrdinaryRawEscape() throws {
        // T-LEASE-07 expected RED: AppEnvironment currently retains and distributes
        // a raw RuntimeClient, while RuntimeStatusController can construct another.
        // The shipping app therefore has no single process-wide admission boundary.
        let source = try appEnvironmentSource()
        let rawConstructorPattern = #"\bRuntimeClient\s*\("#

        XCTAssertEqual(
            try matchCount(pattern: rawConstructorPattern, in: source),
            1,
            "AppEnvironment may construct exactly one raw base client"
        )
        XCTAssertTrue(
            source.contains("let baseRuntimeClient: any RuntimeClientProtocol"),
            "the one raw client must be held behind a protocol-typed local base"
        )
        XCTAssertTrue(
            source.contains("let runtimeClient = ExclusiveRuntimeClient(base: baseRuntimeClient)"),
            "all normal app runtime work must enter through the one admitted wrapper"
        )
        XCTAssertTrue(source.contains("private let runtimeClient: ExclusiveRuntimeClient"))
        XCTAssertEqual(
            source.components(separatedBy: "baseRuntimeClient").count - 1,
            2,
            "the raw base may appear only in its declaration and wrapper construction"
        )
        XCTAssertFalse(
            source.contains("taskRuntimeClient"),
            "a second task-client alias makes raw/wrapped composition too easy to split"
        )

        let modelLibrary = try initializerSource(
            named: "let modelLibrary = ModelLibrary(",
            in: source
        )
        let corpusRunner = try initializerSource(
            named: "let corpusAnalysisRunner = CorpusAnalysisQueueRunner.live(",
            in: source
        )
        XCTAssertTrue(modelLibrary.contains("runtimeClient: runtimeClient"))
        XCTAssertTrue(corpusRunner.contains("runtimeClient: runtimeClient"))

        let allowedDirectHosts: Set<String> = [
            // DEBUG-only hosted-XPC lifecycle probes deliberately create multiple
            // connections and replace the normal application root.
            "RuntimeXPCIntegrationView.swift",
            // The signed release-smoke entry point exits before SupraAIApp starts.
            "SignedReleaseSmokeHost.swift",
            // The sole normal-path construction immediately enters the wrapper.
            "AppEnvironment.swift",
        ]
        for url in try appSwiftSourceURLs() where !allowedDirectHosts.contains(url.lastPathComponent) {
            let candidate = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(
                try matchCount(pattern: rawConstructorPattern, in: candidate),
                0,
                "normal app source \(url.lastPathComponent) must not construct a raw RuntimeClient"
            )
        }
    }

    private func appEnvironmentSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appEnvironmentURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SupraAI/AppEnvironment.swift")
        return try String(contentsOf: appEnvironmentURL, encoding: .utf8)
    }

    private func appSwiftSourceURLs() throws -> [URL] {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SupraAI", isDirectory: true)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        var results: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }

    private func matchCount(pattern: String, in source: String) throws -> Int {
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.numberOfMatches(in: source, range: range)
    }

    private func initializerSource(named marker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: marker))
        let end = try XCTUnwrap(
            source.range(of: "\n        )", range: start.lowerBound..<source.endIndex)
        )
        return String(source[start.lowerBound..<end.upperBound])
    }
}
