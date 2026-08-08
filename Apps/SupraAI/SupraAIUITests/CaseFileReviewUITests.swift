import Foundation
import XCTest

/// Source/composition gates for the first visible Case File Review slice.
/// Hosted interaction coverage follows once the production surface and its
/// deterministic fixture exist; these tests first pin the approved native shape.
final class CaseFileReviewCompositionUITests: XCTestCase {
    func testTRPUI01MatterWorkspaceComposesReviewTabAndScopedController() throws {
        // T-RP-UI-01 expected RED: MatterWorkspaceView has no Review tab or
        // CaseFileReviewView destination, and MattersController does not yet vend a
        // matter-scoped CaseFileReviewController.
        let workspace = try appSource(
            relativePath: "SupraAI/Matters/MatterWorkspaceView.swift"
        )
        let mattersController = try packageSource(
            relativePath: "Packages/SupraSessions/Sources/SupraSessions/MattersController.swift"
        )

        XCTAssertEqual(
            try matchCount(#"\bcase\s+review\s*=\s*"Review""#, in: workspace),
            1,
            "the existing matter tab set must gain one literal Review tab"
        )
        XCTAssertTrue(
            workspace.contains("CaseFileReviewView("),
            "the Review tab must render the dedicated native review surface"
        )
        XCTAssertTrue(
            workspace.contains("controller.caseFileReviewController"),
            "the workspace must use the selected matter's scoped review controller"
        )
        XCTAssertTrue(
            mattersController.contains(
                "@Published public private(set) var caseFileReviewController: CaseFileReviewController?"
            ),
            "MattersController must publish the scoped review controller"
        )
        XCTAssertTrue(
            mattersController.contains("caseFileReviewController = nil"),
            "clearing the selected matter must clear the review controller"
        )
        XCTAssertTrue(
            mattersController.contains("CaseFileReviewController("),
            "selecting a matter must compose a CaseFileReviewController"
        )
    }

    func testTRPUI02ReviewMatrixHasExactlyFourLiteralColumns() throws {
        // T-RP-UI-02 expected RED: CaseFileReviewView.swift does not exist, so no
        // native Table exposes the approved Finding / Generated value / Sources /
        // Review matrix.
        let review = try caseFileReviewSource()
        let expectedColumns = ["Finding", "Generated value", "Sources", "Review"]

        XCTAssertGreaterThanOrEqual(
            try matchCount(#"\bTable\s*\("#, in: review),
            1,
            "the matrix must use SwiftUI Table for the first native implementation"
        )
        for column in expectedColumns {
            XCTAssertEqual(
                try matchCount(
                    "TableColumn\\s*\\(\\s*\"\(NSRegularExpression.escapedPattern(for: column))\"",
                    in: review
                ),
                1,
                "the matrix must contain one literal \(column) column"
            )
        }
        XCTAssertEqual(
            try matchCount(#"\bTableColumn\s*\("#, in: review),
            expectedColumns.count,
            "the smallest matrix slice must not add, hide, or synthesize extra columns"
        )
        XCTAssertTrue(
            review.contains(#".accessibilityIdentifier("review.matrix")"#),
            "the matrix must expose its stable native accessibility surface"
        )
    }

    func testTRPUI03SourcesInspectorSeparatesEvidenceAndPinsAccessibilityContract() throws {
        // T-RP-UI-03 expected RED: there is no trailing Sources inspector, no
        // Supporting/Contrary evidence separation, and none of the review-specific
        // accessibility identifiers exist.
        let review = try caseFileReviewSource()

        XCTAssertTrue(
            review.contains("SlideOverPanel("),
            "Sources must reuse Supra's trailing native inspector chrome"
        )
        XCTAssertTrue(
            review.contains("DocumentPreviewView("),
            "an inspectable source must continue into Supra's revision-aware document preview"
        )
        XCTAssertTrue(
            review.contains("Supporting evidence"),
            "supporting evidence must be named rather than folded into one source count"
        )
        XCTAssertTrue(
            review.contains("Contrary evidence"),
            "contrary evidence must remain visibly distinct from supporting evidence"
        )

        let exactIdentifiers = ["review.sourcesInspector"]
        for identifier in exactIdentifiers {
            XCTAssertTrue(
                review.contains(".accessibilityIdentifier(\"\(identifier)\")"),
                "missing exact accessibility identifier \(identifier)"
            )
        }

        let dynamicIdentifierPrefixes = [
            "review.row.",
            "review.sources.",
            "review.markReviewed.",
            "review.reviewed.",
            "review.evidence.",
        ]
        for prefix in dynamicIdentifierPrefixes {
            XCTAssertTrue(
                review.contains(".accessibilityIdentifier(\"\(prefix)\\("),
                "missing dynamic accessibility identifier prefix \(prefix)"
            )
        }
    }

    func testTRPUI04EvidenceRailUsesApprovedTokensAndStartReviewRemainsDeferred() throws {
        // T-RP-UI-04 expected RED: the selected-row-to-Sources evidence rail and
        // its approved light/dark gold tokens do not exist. This first slice also
        // must not advertise a Start/New Review button before that workflow works.
        let review = try caseFileReviewSource()
        let workspace = try appSource(
            relativePath: "SupraAI/Matters/MatterWorkspaceView.swift"
        )
        let documents = try appSource(
            relativePath: "SupraAI/Documents/MatterDocumentsView.swift"
        )
        let outputDetail = try appSource(
            relativePath: "SupraAI/Outputs/OutputDetailView.swift"
        )

        XCTAssertTrue(
            review.contains("A77920"),
            "the light evidence-rail token must retain the approved mock-up value"
        )
        XCTAssertTrue(
            review.contains("D2AC5C"),
            "the dark evidence-rail token must retain the approved mock-up value"
        )
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(of: "evidenceRailColor", in: review),
            3,
            "the semantic rail color must be declared and used by both matrix selection and inspector"
        )
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(of: "evidenceRailWidth", in: review),
            3,
            "the semantic rail width must be declared and used by both sides of the evidence connection"
        )

        let deferredControlLiterals = [
            #""Start Review""#,
            #""Start new review""#,
            #""Start a new review""#,
            #""New Review""#,
        ]
        let visibleReviewComposition = [review, workspace, documents, outputDetail]
            .joined(separator: "\n")
        for literal in deferredControlLiterals {
            XCTAssertFalse(
                visibleReviewComposition.contains(literal),
                "the visible first slice must not expose the deferred control titled \(literal)"
            )
        }
    }

    func testTRPUI05StaleProjectStateRemainsPersistentlyVisible() throws {
        // T-RP-UI-05 expected RED: deletion can mark a durable Review Project
        // stale, but the first view draft only reveals unavailable state after
        // opening an individual source. The matrix itself must keep a literal,
        // accessible project-level notice visible.
        let review = try caseFileReviewSource()

        XCTAssertTrue(
            review.contains(#"project.status == "stale""#),
            "the view must derive its notice from the persisted project state"
        )
        XCTAssertTrue(
            review.contains("Review source changed"),
            "stale state needs concise, literal user-facing copy"
        )
        XCTAssertTrue(
            review.contains("Frozen findings and excerpts remain available"),
            "the notice must distinguish retained review work from unavailable live proof"
        )
        XCTAssertTrue(
            review.contains(#".accessibilityIdentifier("review.staleNotice")"#),
            "the persistent stale notice needs a stable native accessibility surface"
        )
    }

    private func caseFileReviewSource() throws -> String {
        try appSource(relativePath: "SupraAI/Review/CaseFileReviewView.swift")
    }

    private func appSource(relativePath: String) throws -> String {
        try source(at: appRootURL.appendingPathComponent(relativePath))
    }

    private func packageSource(relativePath: String) throws -> String {
        try source(at: repositoryRootURL.appendingPathComponent(relativePath))
    }

    private func source(at url: URL) throws -> String {
        let data = try XCTUnwrap(
            FileManager.default.contents(atPath: url.path),
            "required source file is missing: \(url.path)"
        )
        return try XCTUnwrap(
            String(data: data, encoding: .utf8),
            "required source file is not UTF-8: \(url.path)"
        )
    }

    private var appRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var repositoryRootURL: URL {
        appRootURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func matchCount(_ pattern: String, in source: String) throws -> Int {
        let expression = try NSRegularExpression(pattern: pattern)
        return expression.numberOfMatches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        )
    }

    private func occurrenceCount(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
