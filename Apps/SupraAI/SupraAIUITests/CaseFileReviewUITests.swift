import Foundation
import XCTest

/// T-RP-UI-07...09 exercise the native Review workbench against a hermetic,
/// synthetic Review Project. The dedicated launch flag is intentionally separate
/// from base `-uiTestMode` so unrelated hosted tests keep their smallest fixture.
@MainActor
final class CaseFileReviewHostedUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTRPUI07ReviewProjectRendersFourColumnMatrixAndTwoExactRows() throws {
        // T-RP-UI-07 expected RED: `-uiTestReviewProject` is not handled, so the
        // hermetic matter has no Review Project and `review.matrix` never appears.
        let app = launchReviewProject()
        let matrix = app.descendants(matching: .any)["review.matrix"]
        XCTAssertTrue(
            matrix.waitForExistence(timeout: 20),
            "The dedicated Review fixture must render the native four-column matrix"
        )

        for header in ["Finding", "Generated value", "Sources", "Review"] {
            XCTAssertEqual(
                renderedElements(label: header, in: matrix).count,
                1,
                "The hosted matrix must render one exact \(header) column header"
            )
        }

        let findingRows = elements(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        XCTAssertEqual(findingRows.count, 2, "The synthetic Review Project must render two rows")

        let alphaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.alphaFinding
        )
        let betaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.betaFinding
        )
        XCTAssertTrue(alphaFinding.exists, "The non-default alpha finding is missing")
        XCTAssertTrue(betaFinding.exists, "The non-default beta finding is missing")

        let alphaCellID = try cellID(
            of: alphaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        let betaCellID = try cellID(
            of: betaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        XCTAssertNotEqual(alphaCellID, betaCellID, "Each Review row needs a stable, distinct cell identity")

        XCTAssertEqual(
            renderedElements(label: Fixture.alphaGeneratedValue, in: matrix).count,
            1,
            "The alpha row must render its exact persisted generated value"
        )
        XCTAssertEqual(
            renderedElements(label: Fixture.betaGeneratedValue, in: matrix).count,
            1,
            "The beta row must render its exact persisted generated value"
        )
        XCTAssertTrue(app.buttons["review.sources.\(alphaCellID)"].exists)
        XCTAssertTrue(app.buttons["review.sources.\(betaCellID)"].exists)
        XCTAssertTrue(app.buttons["review.markReviewed.\(alphaCellID)"].exists)
        XCTAssertTrue(app.buttons["review.markReviewed.\(betaCellID)"].exists)

        XCTAssertFalse(
            renderedElements(label: Fixture.defaultSourceCountCanary, in: matrix).firstMatch.exists,
            "Both exact rows have retained evidence; a zero-source default must stay absent"
        )
    }

    func testTRPUI08BetaSourcesOpensDistinctSupportingAndContraryEvidence() throws {
        // T-RP-UI-08 expected RED: without the dedicated Review Project seed,
        // there is no beta Sources control and no inspector/evidence to inspect.
        let app = launchReviewProject()
        let matrix = app.descendants(matching: .any)["review.matrix"]
        XCTAssertTrue(matrix.waitForExistence(timeout: 20), "Review matrix did not appear")

        let betaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.betaFinding
        )
        XCTAssertTrue(betaFinding.exists, "The beta row did not appear")
        let betaCellID = try cellID(
            of: betaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        let sources = app.buttons["review.sources.\(betaCellID)"]
        XCTAssertTrue(sources.exists, "The beta Sources control is missing")
        XCTAssertEqual(
            sources.label,
            Fixture.betaSourceSummary,
            "The beta source count must distinguish supporting from contrary proof"
        )
        sources.click()

        let inspector = app.scrollViews["review.sourcesInspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 10), "The beta Sources inspector did not open")
        XCTAssertGreaterThan(
            inspector.frame.midX,
            app.windows.firstMatch.frame.midX,
            "Sources must open as a trailing inspector"
        )

        for heading in ["Supporting evidence", "Contrary evidence"] {
            XCTAssertEqual(
                renderedElements(label: heading, in: inspector).count,
                1,
                "The inspector must render one exact \(heading) section"
            )
        }
        let expectedEvidence = [
            (Fixture.betaSupportingLabel, Fixture.betaSupportingExcerpt),
            (Fixture.betaContraryLabel, Fixture.betaContraryExcerpt),
        ]
        XCTAssertEqual(
            elements(in: inspector, identifierPrefix: Fixture.evidenceIdentifierPrefix).count,
            2,
            "The beta inspector must contain exactly its supporting and contrary proof cards"
        )
        for (label, excerpt) in expectedEvidence {
            XCTAssertEqual(
                evidenceElements(
                    citationLabel: label,
                    excerpt: excerpt,
                    in: inspector
                ).count,
                1,
                "The inspector is missing exact frozen evidence card \(label)"
            )
        }

        XCTAssertEqual(
            evidenceElements(
                citationLabel: Fixture.alphaCitationLabel,
                in: inspector
            ).count,
            0,
            "Opening beta Sources must not leak evidence from the alpha row"
        )
        XCTAssertFalse(
            renderedElements(label: Fixture.emptySupportingCanary, in: inspector).firstMatch.exists,
            "The supporting section must not silently render its empty-state default"
        )
        XCTAssertFalse(
            renderedElements(label: Fixture.emptyContraryCanary, in: inspector).firstMatch.exists,
            "The contrary section must not silently render its empty-state default"
        )
    }

    func testTRPUI09MarkReviewedAttestsOnlyTheBetaRow() throws {
        // T-RP-UI-09 expected RED: without the dedicated Review Project seed,
        // neither row-level Mark Reviewed control exists to drive the attestation.
        let app = launchReviewProject()
        let matrix = app.descendants(matching: .any)["review.matrix"]
        XCTAssertTrue(matrix.waitForExistence(timeout: 20), "Review matrix did not appear")

        let alphaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.alphaFinding
        )
        let betaFinding = element(
            in: matrix,
            identifierPrefix: Fixture.findingIdentifierPrefix,
            value: Fixture.betaFinding
        )
        XCTAssertTrue(alphaFinding.exists, "The alpha row did not appear")
        XCTAssertTrue(betaFinding.exists, "The beta row did not appear")
        let alphaCellID = try cellID(
            of: alphaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )
        let betaCellID = try cellID(
            of: betaFinding,
            identifierPrefix: Fixture.findingIdentifierPrefix
        )

        let alphaMark = app.buttons["review.markReviewed.\(alphaCellID)"]
        let betaMark = app.buttons["review.markReviewed.\(betaCellID)"]
        let alphaReviewed = app.descendants(matching: .any)["review.reviewed.\(alphaCellID)"]
        let betaReviewed = app.descendants(matching: .any)["review.reviewed.\(betaCellID)"]
        XCTAssertTrue(alphaMark.exists, "Alpha must begin in the needs-review state")
        XCTAssertTrue(betaMark.exists, "Beta must begin in the needs-review state")
        XCTAssertFalse(alphaReviewed.exists, "Alpha must not begin with a reviewed attestation")
        XCTAssertFalse(betaReviewed.exists, "Beta must not begin with a reviewed attestation")

        betaMark.click()

        XCTAssertTrue(
            betaReviewed.waitForExistence(timeout: 10),
            "Mark Reviewed must replace beta's action with a reviewed attestation"
        )
        XCTAssertEqual(
            renderedElements(label: "Reviewed", in: matrix).count,
            1,
            "The beta attestation must visibly read Reviewed"
        )
        XCTAssertTrue(alphaMark.exists, "Reviewing beta must leave alpha actionable")
        XCTAssertFalse(alphaReviewed.exists, "Reviewing beta must not attest alpha")
        XCTAssertTrue(betaMark.waitForNonExistence(timeout: 5))
        XCTAssertEqual(
            elements(in: app, identifierPrefix: "review.reviewed.").count,
            1,
            "Exactly one row may become reviewed"
        )
        XCTAssertEqual(
            elements(in: app, identifierPrefix: "review.markReviewed.").count,
            1,
            "Exactly one other row must remain pending"
        )
        XCTAssertEqual(renderedElements(label: Fixture.alphaGeneratedValue, in: matrix).count, 1)
        XCTAssertEqual(renderedElements(label: Fixture.betaGeneratedValue, in: matrix).count, 1)
    }

    private func launchReviewProject() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestReviewProject",
            "-uiTestSelectFirstMatter",
            "-uiTestInitialMatterTab", "Review",
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Main window did not appear")
        XCTAssertTrue(
            app.staticTexts["McKernon Motors v. Liberty Rail"].waitForExistence(timeout: 20),
            "The synthetic matter did not open"
        )
        return app
    }

    private func elements(
        in scope: XCUIElement,
        identifierPrefix: String
    ) -> XCUIElementQuery {
        scope.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix)
        )
    }

    private func element(
        in scope: XCUIElement,
        identifierPrefix: String,
        value: String
    ) -> XCUIElement {
        scope.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND value == %@",
                identifierPrefix,
                value
            )
        ).firstMatch
    }

    private func renderedElements(label: String, in scope: XCUIElement) -> XCUIElementQuery {
        scope.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ OR value == %@ OR title == %@",
                label,
                label,
                label
            )
        )
    }

    private func evidenceElements(
        citationLabel: String,
        excerpt: String? = nil,
        in scope: XCUIElement
    ) -> XCUIElementQuery {
        let base = scope.descendants(matching: .button).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                Fixture.evidenceIdentifierPrefix,
                "\(citationLabel),"
            )
        )
        guard let excerpt else { return base }
        return base.matching(NSPredicate(format: "label CONTAINS %@", excerpt))
    }

    private func cellID(
        of element: XCUIElement,
        identifierPrefix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        XCTAssertTrue(
            element.identifier.hasPrefix(identifierPrefix),
            "Review row is missing the stable accessibility prefix",
            file: file,
            line: line
        )
        let suffix = String(element.identifier.dropFirst(identifierPrefix.count))
        XCTAssertFalse(
            suffix.isEmpty,
            "Review row accessibility identity must not use the empty/default suffix",
            file: file,
            line: line
        )
        return try XCTUnwrap(
            suffix.isEmpty ? nil : suffix,
            "Review row accessibility identity is missing",
            file: file,
            line: line
        )
    }

    private enum Fixture {
        static let findingIdentifierPrefix = "review.row."
        static let evidenceIdentifierPrefix = "review.evidence."

        static let alphaFinding = "synthetic payment deadline"
        static let alphaGeneratedValue = "March 18, 2031"
        static let alphaCitationLabel = "E1"

        static let betaFinding = "synthetic renewal notice period"
        static let betaGeneratedValue = "120 calendar days"
        static let betaSourceSummary = "1 supporting · 1 contrary"
        static let betaSupportingLabel = "E2"
        static let betaContraryLabel = "E3"
        static let betaSupportingExcerpt =
            "The fictional Atlas Supply Agreement requires renewal notice at least 120 calendar days before expiration."
        static let betaContraryExcerpt =
            "A fictional amendment states that either party may give renewal notice 90 calendar days before expiration."

        static let defaultSourceCountCanary = "0 supporting"
        static let emptySupportingCanary =
            "No supporting evidence is recorded for this finding."
        static let emptyContraryCanary =
            "No contrary evidence is recorded for this finding."
    }
}

/// Source/composition gates for the first visible Case File Review slice.
/// The hosted gates above drive the native surface; these source checks retain
/// the approved composition contract without replacing interaction coverage.
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

    func testTRPUI06ReviewAttestationCopyAndActorRemainTruthful() throws {
        // T-RP-UI-06 expected RED: Mark Reviewed is available before Sources are
        // opened, but its hint currently claims the sources were reviewed and the
        // action writes the literal actor "user".
        let review = try caseFileReviewSource()

        XCTAssertTrue(
            review.contains("Record that this finding was reviewed"),
            "the first attestation must describe only the finding-level action it records"
        )
        XCTAssertFalse(
            review.contains("finding and its sources were reviewed"),
            "the UI must not claim source review without requiring a Sources inspection"
        )
        XCTAssertFalse(
            review.contains(#"reviewedBy: "user""#),
            "review identity must come from the local profile rather than a literal placeholder"
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
