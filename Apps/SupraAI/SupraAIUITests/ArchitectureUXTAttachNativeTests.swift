import Foundation
import XCTest

/// Native WP-2.4 disclosure and handoff boundary.
///
/// Expected RED: quick-attachment metadata is typed in SupraSessions, but the
/// shipping chat still renders a filename-only composer chip, renders no
/// attachment disclosure beside either persisted message, and exposes no
/// explicit Add to Matter action wired to the ordinary import/readiness path.
@MainActor
final class ArchitectureUXTAttachNativeTests: XCTestCase {
    private enum Wire {
        static let scenario = "-uiTestQuickAttachmentTruth"
        static let truncatedID = "quick-attachment-native-941"
        static let fullID = "quick-attachment-native-947"
        static let matterID = "matter-quick-attachment-native-953"
        static let matterName = "Aster Harbor Attachment Matter 953"
        static let forbiddenDefault = "DEFAULT-000"
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func test00ShippingChatRendersTypedQuickAttachmentDisclosuresAndExplicitHandoff() throws {
        let source = try appSource(relativePath: "SupraAI/GlobalChatsView.swift")
        for contract in [
            "QuickAttachmentPresentation",
            "Quick attachment",
            "contentStatus",
            "durabilityStatus",
            "verificationStatus",
            "controller.quickAttachmentPresentations(messageID:",
            "controller.quickAttachmentContext(messageID:",
            "QuickAttachmentMatterHandoff",
            ".addToMatter(",
            "chat.quickAttachment.composer.",
            "chat.quickAttachment.answer.",
            "chat.quickAttachment.addToMatter.",
            "chat.quickAttachment.handoff.",
        ] {
            XCTAssertTrue(
                source.contains(contract),
                "Expected RED: shipping chat is missing quick-attachment contract \(contract)"
            )
        }

        XCTAssertFalse(
            source.contains("Text(attachment.name).lineLimit(1)"),
            "a filename-only chip must not be the complete attachment disclosure"
        )
        XCTAssertFalse(
            source.contains("artifactActions.contains(.saveToOutputs) && quickAttachments"),
            "quick-attachment output must never inherit the durable promotion action"
        )
        let canSend = try sourceSlice(
            source,
            from: "private var canSend: Bool",
            through: "private func send()"
        )
        XCTAssertTrue(
            canSend.contains("!attachments.isEmpty"),
            "attachment-only questions must remain sendable from the shipping composer"
        )
    }

    func testCompositionAndAnswerShowPartialSessionOnlyUnverifiedState() throws {
        try requireImplementedSourceContract()
        let app = launch()
        defer { app.terminate() }

        let composer = app.descendants(matching: .any)[
            "chat.quickAttachment.composer.\(Wire.truncatedID)"
        ]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        assertDisclosure(
            composer,
            contains: [
                "Quick attachment",
                "Partial content",
                "Included 40000 of 40001 characters",
                "Session only",
                "Unverified",
            ]
        )

        let answer = app.descendants(matching: .any)[
            "chat.quickAttachment.answer.\(Wire.fullID)"
        ]
        XCTAssertTrue(answer.waitForExistence(timeout: 20))
        assertDisclosure(
            answer,
            contains: [
                "Quick attachment",
                "Full content",
                "Included 731 of 731 characters",
                "Session only",
                "Unverified",
            ]
        )

        let rendered = app.windows.firstMatch.debugDescription
        XCTAssertFalse(rendered.contains(Wire.forbiddenDefault))
    }

    func testAddToMatterUsesTheExplicitReadinessHandoffAndNeverClaimsEarlyCompletion() throws {
        try requireImplementedSourceContract()
        let app = launch()
        defer { app.terminate() }

        let action = app.buttons[
            "chat.quickAttachment.addToMatter.\(Wire.fullID)"
        ]
        XCTAssertTrue(action.waitForExistence(timeout: 20))
        XCTAssertEqual(action.label, "Add to Matter")
        action.click()

        let target = app.buttons["chat.quickAttachment.target.\(Wire.matterID)"]
        if target.waitForExistence(timeout: 5) {
            target.click()
        }

        let outcome = app.descendants(matching: .any)[
            "chat.quickAttachment.handoff.\(Wire.fullID)"
        ]
        XCTAssertTrue(outcome.waitForExistence(timeout: 30))
        let value = stringValue(outcome)
        XCTAssertTrue(
            value.contains(Wire.matterName),
            "the exact non-default matter must own the handoff: \(value)"
        )
        XCTAssertTrue(
            value.contains("Ready in matter") || value.contains("Still preparing in matter"),
            "the UI must report the canonical readiness outcome without inventing completion: \(value)"
        )
        XCTAssertFalse(value.contains(Wire.forbiddenDefault))
    }

    private func requireImplementedSourceContract() throws {
        try test00ShippingChatRendersTypedQuickAttachmentDisclosuresAndExplicitHandoff()
        let environment = try appSource(relativePath: "SupraAI/AppEnvironment.swift")
        for wire in [
            Wire.scenario,
            Wire.truncatedID,
            Wire.fullID,
            Wire.matterID,
            Wire.matterName,
        ] {
            XCTAssertTrue(
                environment.contains(wire),
                "Expected RED: missing hermetic native attachment wire \(wire)"
            )
        }
    }

    private func assertDisclosure(
        _ element: XCUIElement,
        contains fragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let value = stringValue(element)
        for fragment in fragments {
            XCTAssertTrue(
                value.contains(fragment),
                "missing disclosure \(fragment) in \(value)",
                file: file,
                line: line
            )
        }
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            Wire.scenario,
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func stringValue(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    private func appSource(relativePath: String) throws -> String {
        try String(
            contentsOf: appRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSlice(
        _ source: String,
        from start: String,
        through end: String
    ) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(
            source.range(of: end, range: startRange.upperBound..<source.endIndex)
        )
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
