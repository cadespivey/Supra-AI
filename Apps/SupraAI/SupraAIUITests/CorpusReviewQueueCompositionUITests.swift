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

    func testTQUEUE03ContentBoundLoadAndCorpusGenerationShareTaskRuntimeClient() throws {
        // T-QUEUE-03 expected RED: guided UI-test composition loads the pinned
        // model through taskRuntimeClient but gives the live corpus runner the
        // separate real XPC client, splitting load from generation/cancellation.
        let source = try appEnvironmentSource()
        let modelLibrary = try initializerSource(
            named: "let modelLibrary = ModelLibrary(",
            in: source
        )
        let corpusRunner = try initializerSource(
            named: "let corpusAnalysisRunner = CorpusAnalysisQueueRunner.live(",
            in: source
        )

        XCTAssertTrue(modelLibrary.contains("runtimeClient: taskRuntimeClient"))
        XCTAssertTrue(
            corpusRunner.contains("runtimeClient: taskRuntimeClient"),
            "content-bound load and corpus generation must use the identical runtime client"
        )
    }

    func testTDELUI01BothDocumentTrashSurfacesShareConfirmationAndRenderFailure() throws {
        // Expected RED: MatterDocumentsView hard-deletes directly from its trash
        // row and never renders the controller's deletion-specific notice.
        // Follow-on RED: the shared dialog must identify the selected target and
        // must not imply that document-owned classifications/relations survive.
        let matterDocuments = try appSource(
            relativePath: "SupraAI/Documents/MatterDocumentsView.swift"
        )
        let recycleBin = try appSource(relativePath: "SupraAI/RecycleBinView.swift")

        XCTAssertTrue(matterDocuments.contains(".permanentDeletionConfirmation("))
        XCTAssertTrue(recycleBin.contains(".permanentDeletionConfirmation("))
        XCTAssertTrue(matterDocuments.contains("controller.permanentDeletionNotice"))
        XCTAssertTrue(matterDocuments.contains("controller.clearPermanentDeletionNotice()"))
        XCTAssertFalse(
            matterDocuments.contains(
                "Button(\"Delete Permanently\", role: .destructive) { controller.permanentlyDelete"
            ),
            "a trash-row click must select a pending item, not perform deletion"
        )
        XCTAssertTrue(
            recycleBin.contains("Remove “\\(name)” permanently?")
        )
        XCTAssertTrue(
            recycleBin.contains(
                "Saved output text, citation display excerpts and locators, and retained corpus-analysis proof records"
            )
        )
        XCTAssertFalse(
            recycleBin.contains("Saved analysis"),
            "document-owned classification and relation records are deleted, not retained"
        )
    }

    private func appEnvironmentSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appEnvironmentURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SupraAI/AppEnvironment.swift")
        return try String(contentsOf: appEnvironmentURL, encoding: .utf8)
    }

    private func appSource(relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: appRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func initializerSource(named marker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: marker))
        let end = try XCTUnwrap(
            source.range(of: "\n        )", range: start.lowerBound..<source.endIndex)
        )
        return String(source[start.lowerBound..<end.upperBound])
    }
}
