import Foundation
import XCTest

/// Native Documents boundary for T-DATA-READY-01, -02, and -03.
///
/// Expected RED: the Documents badge still reads `MatterDocumentRecord.status`,
/// the DEBUG app has no canonical ready/stale/model-missing fixture, and the
/// production demo seeder writes three raw `ready` rows without revision, FTS,
/// semantic-index, active-model, or derived-receipt evidence. Every live test
/// checks that source contract first, so a locked desktop reports the intended
/// missing wire instead of timing out while trying to launch the app.
@MainActor
final class ArchitectureUXTDataReady01Tests: XCTestCase {
    private enum Wire {
        static let scenario = "-uiTestCanonicalDocumentReadiness"
        static let demoScenario = "-uiTestCanonicalDemoReadiness"
        static let readyDocumentID = "readiness-ready-ui-document-743"
        static let staleDocumentID = "readiness-raw-green-stale-ui-document-751"
        static let modelMissingDocumentID = "readiness-raw-green-model-missing-ui-document-757"
        static let forbiddenDefault = "DEFAULT-000"
    }

    private static let demoDocumentNames = [
        "Master Services Agreement (2024).pdf",
        "Deposition Tr. — R. Calloway (Vol. I).pdf",
        "Insurance Coverage Letter.docx",
    ]

    override func setUp() {
        continueAfterFailure = false
    }

    func test00ShippingDocumentsBadgeUsesCanonicalProjectionNotRawStatus() throws {
        let view = try appSource(relativePath: "SupraAI/Documents/MatterDocumentsView.swift")
        let badgeBody = try functionBody(
            containing: "private func statusBadge(_ document: MatterDocumentRecord)",
            in: view
        )

        XCTAssertTrue(
            badgeBody.contains("controller.readiness(documentID: document.id)"),
            "Expected RED: the shipping badge does not fetch the Documents consumer projection"
        )
        XCTAssertFalse(
            badgeBody.contains("document.status"),
            "a raw-green record must never bypass the canonical receipt"
        )
        XCTAssertTrue(
            badgeBody.contains(#"documents.readinessBadge.\(document.id)"#),
            "the exact rendered receipt result needs a stable native-test identity"
        )
        XCTAssertTrue(
            view.contains("DocumentReadinessConsumerProjection"),
            "the appearance boundary must accept the typed projection"
        )
        XCTAssertTrue(view.contains("isBaseReady"))
        XCTAssertTrue(view.contains("primaryBaseExclusion"))
    }

    func testCanonicalReadyStaleAndMissingModelTableNeverShowsAStaleGreenBadge() throws {
        try requireImplementedLiveSourceContract()
        let app = launch(scenario: Wire.scenario)
        defer { app.terminate() }

        let ready = badge(documentID: Wire.readyDocumentID, in: app)
        XCTAssertTrue(ready.waitForExistence(timeout: 20))
        XCTAssertEqual(ready.label, "Ready")
        XCTAssertFalse(renderedText(of: ready).contains(Wire.forbiddenDefault))

        let cases = [
            (
                documentID: Wire.staleDocumentID,
                expectedExplanationFragments: ["reindex", "stale"]
            ),
            (
                documentID: Wire.modelMissingDocumentID,
                expectedExplanationFragments: ["setup", "model"]
            ),
        ]
        for item in cases {
            let projected = badge(documentID: item.documentID, in: app)
            XCTAssertTrue(projected.waitForExistence(timeout: 20), item.documentID)
            XCTAssertNotEqual(
                projected.label.localizedLowercase,
                "ready",
                "a raw status of ready cannot leave a green Ready badge when the receipt excludes it"
            )
            let rendered = renderedText(of: projected)
            XCTAssertTrue(
                item.expectedExplanationFragments.contains {
                    rendered.localizedCaseInsensitiveContains($0)
                },
                "the receipt-backed badge must explain its corrective state: \(rendered)"
            )
            XCTAssertFalse(rendered.contains(Wire.forbiddenDefault), item.documentID)
        }
    }

    func testDemoSeederBuildsTheExactThreeCanonicalReceiptGraphs() throws {
        try requireCanonicalDemoSeederContract()
    }

    private func requireCanonicalDemoSeederContract() throws {
        let environment = try appSource(relativePath: "SupraAI/AppEnvironment.swift")
        let demoSeeder = try functionBody(
            containing: "private func seedDemoFixturesIfNeeded()",
            in: environment
        )
        let documentSeeder = try functionBody(
            containing: "private func seedDemoDocument(",
            in: environment
        )

        for name in Self.demoDocumentNames {
            XCTAssertEqual(
                occurrences(of: name, in: demoSeeder),
                1,
                "the production demo must seed the exact non-default source once: \(name)"
            )
        }
        // The producer may reuse the real indexing service or a narrow shared
        // synthetic factory. Its invariant is behavioral: it must derive the
        // Store receipt after graph creation and fail closed unless it is ready.
        for canonicalGraphMarker in ["documentReadiness.fetchReceipt", "isBaseReady"] {
            XCTAssertTrue(
                documentSeeder.contains(canonicalGraphMarker),
                "Expected RED: demo document producer omits \(canonicalGraphMarker)"
            )
        }
        XCTAssertFalse(
            documentSeeder.contains("status: MatterDocumentStatus.ready.rawValue"),
            "a raw ready insert is not a completion receipt"
        )
    }

    func testSyntheticDemoReportsExactlyThreeReadyDocumentsInEveryConsumer() throws {
        try requireImplementedLiveSourceContract(includeDemo: true)
        let app = launch(scenario: Wire.demoScenario)
        defer { app.terminate() }

        for name in Self.demoDocumentNames {
            XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 20), name)
        }

        let badges = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "documents.readinessBadge.")
        )
        XCTAssertEqual(badges.count, 3)
        for index in 0..<badges.count {
            let item = badges.element(boundBy: index)
            XCTAssertEqual(item.label, "Ready", renderedText(of: item))
            XCTAssertFalse(renderedText(of: item).contains(Wire.forbiddenDefault))
        }

        for consumer in ["documents", "ask", "chronology", "drafting"] {
            let summary = app.descendants(matching: .any)[
                "readiness.demo.consumer.\(consumer)"
            ]
            XCTAssertTrue(summary.waitForExistence(timeout: 10), consumer)
            let rendered = renderedText(of: summary)
            XCTAssertTrue(
                rendered.localizedCaseInsensitiveContains("3 of 3 base ready"),
                "\(consumer) disagrees with the exact synthetic demo denominator: \(rendered)"
            )
            XCTAssertFalse(rendered.contains(Wire.forbiddenDefault), consumer)
        }
    }

    /// Makes the intended missing production wire fail before `XCUIApplication`
    /// is created. This is required for deterministic RED evidence when the
    /// desktop session is locked and native interaction cannot begin.
    private func requireImplementedLiveSourceContract(includeDemo: Bool = false) throws {
        let view = try appSource(relativePath: "SupraAI/Documents/MatterDocumentsView.swift")
        let badgeBody = try functionBody(
            containing: "private func statusBadge(_ document: MatterDocumentRecord)",
            in: view
        )
        _ = try XCTUnwrap(
            badgeBody.range(of: "controller.readiness(documentID: document.id)"),
            "Expected RED: Documents badge still bypasses the canonical projection"
        )
        _ = try XCTUnwrap(
            badgeBody.range(of: #"documents.readinessBadge.\(document.id)"#),
            "Expected RED: receipt-backed native badge identity is absent"
        )
        XCTAssertFalse(badgeBody.contains("document.status"))

        let environment = try appSource(relativePath: "SupraAI/AppEnvironment.swift")
        _ = try XCTUnwrap(
            environment.range(of: Wire.scenario),
            "Expected RED: canonical ready/stale/model-missing DEBUG fixture is absent"
        )
        for fixtureID in [
            Wire.readyDocumentID,
            Wire.staleDocumentID,
            Wire.modelMissingDocumentID,
        ] {
            _ = try XCTUnwrap(
                environment.range(of: fixtureID),
                "Expected RED: missing non-default readiness fixture \(fixtureID)"
            )
        }

        guard includeDemo else { return }
        _ = try XCTUnwrap(
            environment.range(of: Wire.demoScenario),
            "Expected RED: canonical production-demo DEBUG fixture is absent"
        )
        _ = try XCTUnwrap(
            view.range(of: "readiness.demo.consumer."),
            "Expected RED: downstream demo qualification summaries are absent"
        )
        try requireCanonicalDemoSeederContract()
    }

    private func launch(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestSelectFirstMatter",
            "-uiTestInitialMatterTab", "Documents",
            scenario,
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func badge(documentID: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["documents.readinessBadge.\(documentID)"]
    }

    private func renderedText(of element: XCUIElement) -> String {
        [element.label, element.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func appSource(relativePath: String) throws -> String {
        try String(
            contentsOf: appRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func functionBody(containing marker: String, in source: String) throws -> String {
        let markerRange = try XCTUnwrap(
            source.range(of: marker),
            "missing source function marker: \(marker)"
        )
        let openingBrace = try XCTUnwrap(
            source[markerRange.upperBound...].firstIndex(of: "{"),
            "missing opening brace after: \(marker)"
        )
        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[markerRange.lowerBound...cursor])
                }
            default: break
            }
            cursor = source.index(after: cursor)
        }
        XCTFail("missing closing brace after: \(marker)")
        return ""
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var remaining = haystack[...]
        while let range = remaining.range(of: needle) {
            count += 1
            remaining = remaining[range.upperBound...]
        }
        return count
    }
}
