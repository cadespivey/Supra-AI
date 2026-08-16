import Foundation
import XCTest

/// T-UX-SETUP-01 hosted native wire proof.
///
/// Expected RED: the shared typed requirement/navigation contract and focused
/// setup rows do not exist. Models is still user-facing “Models”; blockers are
/// dead-end prose (several point to the wrong Settings destination); and route
/// replacement has no exact return context. Every live test first checks that
/// source contract, so the pre-implementation RED is an immediate invariant
/// failure rather than an app-launch timeout on a locked desktop.
@MainActor
final class ArchitectureUXTUxSetup01Tests: XCTestCase {
    private enum Wire {
        static let requestID = "wire-731"
        static let input = "T_UX_SETUP_01_WIRE_731"
        static let matterID = "matter-713"
        static let intent = "draftMotion"
        static let sourceSetID = "source-719"
        static let sourceSetVersion = "7"
        static let authorityPacketID = "packet-727"
        static let authorityPacketVersion = "11"
        static let checkpointID = "checkpoint-733"
        static let forbiddenDefault = "DEFAULT-000"
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func test00ShippingSourceOwnsTypedTargetsAndStableFocusedRows() throws {
        try requireImplementedSourceContract()

        let route = try appSource(relativePath: "SupraAI/Navigation/AppRoute.swift")
        let models = try appSource(relativePath: "SupraAI/ModelsView.swift")
        let settings = try appSource(relativePath: "SupraAI/SettingsView.swift")

        XCTAssertTrue(route.contains("case models"), "retain the stable internal route identity")
        XCTAssertTrue(route.contains("\"AI Setup\""), "the user-facing destination is AI Setup")
        for identifier in Self.aiSetupRowIDs {
            XCTAssertTrue(models.contains(identifier), identifier)
            XCTAssertFalse(identifier.contains(Wire.forbiddenDefault), identifier)
        }
        for identifier in Self.settingsRowIDs {
            XCTAssertTrue(settings.contains(identifier), identifier)
            XCTAssertFalse(identifier.contains(Wire.forbiddenDefault), identifier)
        }
    }

    func testLocalAssistantAndDocumentSearchOpenAndFocusExactAISetupRows() throws {
        try requireImplementedSourceContract()

        let requirements = [
            ("localAssistant.drafting", "aiSetup.requirement.localAssistant.drafting", "Set Up Local Assistant"),
            ("documentSearch.embeddingModel", "aiSetup.requirement.documentSearch.embeddingModel", "Set Up Document Search"),
            ("documentSearch.extractionToolchain", "aiSetup.requirement.documentSearch.extractionToolchain", "Set Up Document Search"),
            ("documentSearch.storage", "aiSetup.requirement.documentSearch.storage", "Set Up Document Search"),
        ]

        for (requirementID, rowID, actionTitle) in requirements {
            let app = launch(requirementID: requirementID)
            defer { app.terminate() }

            assertFixtureContext(in: app)
            let blockedAction = app.descendants(matching: .any)["setup.fixture.blockedAction"]
            XCTAssertTrue(blockedAction.waitForExistence(timeout: 10), requirementID)
            XCTAssertFalse(blockedAction.isEnabled, requirementID)

            let correction = app.buttons["setup.blocker.action.\(requirementID)"]
            XCTAssertTrue(correction.waitForExistence(timeout: 10), requirementID)
            XCTAssertEqual(correction.label, actionTitle, requirementID)
            assertProblemConsequenceAndCorrection(on: correction, requirementID: requirementID)
            correction.click()

            let destination = app.descendants(matching: .any)["sidebar.route.models"]
            XCTAssertTrue(destination.waitForExistence(timeout: 10), requirementID)
            let row = focusedElement(identifier: rowID, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 10), requirementID)
        }
    }

    func testProviderAndBackupOpenExactSettingsRowsNotAISetup() throws {
        try requireImplementedSourceContract()

        let requirements = [
            ("providerConnection.courtListener", "settings.requirement.provider.courtListener", "Connect CourtListener"),
            ("backupDestination", "settings.requirement.backup", "Set Up Backup"),
        ]

        for (requirementID, rowID, actionTitle) in requirements {
            let app = launch(requirementID: requirementID)
            defer { app.terminate() }

            assertFixtureContext(in: app)
            let correction = app.buttons["setup.blocker.action.\(requirementID)"]
            XCTAssertTrue(correction.waitForExistence(timeout: 10), requirementID)
            XCTAssertEqual(correction.label, actionTitle, requirementID)
            correction.click()

            let destination = app.descendants(matching: .any)["sidebar.route.settings"]
            XCTAssertTrue(destination.waitForExistence(timeout: 10), requirementID)
            XCTAssertFalse(
                app.descendants(matching: .any)["sidebar.route.models"].isSelected,
                requirementID
            )
            let row = focusedElement(identifier: rowID, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 10), requirementID)
        }
    }

    func testBackPreservesExactMatterTaskInputSelectionAndCheckpoint() throws {
        try requireImplementedSourceContract()

        let requirementID = "localAssistant.drafting"
        let app = launch(requirementID: requirementID)
        defer { app.terminate() }

        assertFixtureContext(in: app)
        app.buttons["setup.blocker.action.\(requirementID)"].click()
        XCTAssertTrue(
            focusedElement(
                identifier: "aiSetup.requirement.localAssistant.drafting",
                in: app
            ).waitForExistence(timeout: 10)
        )

        let returnAction = app.buttons["setup.navigation.return"]
        XCTAssertTrue(returnAction.waitForExistence(timeout: 10))
        XCTAssertTrue(returnAction.label.localizedCaseInsensitiveContains("return"))
        returnAction.click()

        assertFixtureContext(in: app)
        let input = app.descendants(matching: .any)["setup.fixture.input"]
        XCTAssertEqual(input.value as? String, Wire.input)
        XCTAssertFalse((input.value as? String)?.contains(Wire.forbiddenDefault) ?? true)
    }

    func testStorageBlockedActionEnablesOnlyAfterActualRequirementIsSatisfied() throws {
        try requireImplementedSourceContract()
        let models = try appSource(relativePath: "SupraAI/ModelsView.swift")
        let shell = try appSource(relativePath: "SupraAI/MainShellView.swift")
        XCTAssertTrue(models.contains("Button(\"Initialize Document Storage\")"))
        XCTAssertTrue(models.contains("setup.initializeStorage()"))
        XCTAssertTrue(models.contains("aiSetup.requirement.documentSearch.storage.satisfied"))
        XCTAssertTrue(shell.contains("documentSetup.storageInitialized"))
    }

    // Owner walkthrough RED (2026-08-15): the shipping Documents banner names
    // Settings even though AI Setup owns the requirement, and exposes no action.
    func testDocumentImportBlockerOpensExactAISetupRowAndReturnsToDocuments() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestSelectFirstMatter",
            "-uiTestInitialMatterTab", "Documents",
        ]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any)["documents.importUnavailableWarning"]
                .waitForExistence(timeout: 15)
        )

        let correction = app.buttons["documents.importSetupAction"]
        XCTAssertTrue(correction.waitForExistence(timeout: 10))
        XCTAssertEqual(correction.label, "Open AI Setup")
        correction.click()

        XCTAssertTrue(
            focusedElement(
                identifier: "aiSetup.requirement.localAssistant.drafting",
                in: app
            ).waitForExistence(timeout: 10)
        )
        let returnAction = app.buttons["setup.navigation.return"]
        XCTAssertTrue(returnAction.waitForExistence(timeout: 10))
        XCTAssertTrue(returnAction.label.localizedCaseInsensitiveContains("documents"))
        returnAction.click()

        let documentsTab = app.descendants(matching: .any)["matterTab.Documents"]
        XCTAssertTrue(documentsTab.waitForExistence(timeout: 10))
        XCTAssertTrue(documentsTab.isSelected, "return must restore the Documents task, not default to Chat")
        XCTAssertTrue(
            app.descendants(matching: .any)["documents.importUnavailableWarning"]
                .waitForExistence(timeout: 10)
        )
    }

    private static let aiSetupRowIDs = [
        "aiSetup.requirement.localAssistant.drafting",
        "aiSetup.requirement.documentSearch.embeddingModel",
        "aiSetup.requirement.documentSearch.extractionToolchain",
        "aiSetup.requirement.documentSearch.storage",
    ]

    private static let settingsRowIDs = [
        "settings.requirement.provider.courtListener",
        "settings.requirement.backup",
    ]

    /// Requires the production symbols/rows that make the live expectations
    /// meaningful. Before implementation, each live method stops here with the
    /// same explicit RED instead of waiting for a nonexistent UI element.
    private func requireImplementedSourceContract() throws {
        let setup = try XCTUnwrap(
            try? packageSource(
                package: "SupraSessions",
                relativePath: "Sources/SupraSessions/SetupRequirementNavigation.swift"
            ),
            "Expected RED: SetupRequirementNavigation.swift does not exist"
        )
        for symbol in [
            "public enum SetupRequirement",
            "public enum SetupNavigationTarget",
            "public struct SetupNavigationRequest",
            "public struct WorkContext",
        ] {
            _ = try XCTUnwrap(
                setup.range(of: symbol),
                "Expected RED: missing typed setup symbol \(symbol)"
            )
        }
        let route = try appSource(relativePath: "SupraAI/Navigation/AppRoute.swift")
        _ = try XCTUnwrap(
            route.range(of: "\"AI Setup\""),
            "Expected RED: Models has not been renamed AI Setup"
        )
    }

    private func launch(requirementID: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            "-uiTestEnsureFreshWindow",
            "-uiTestSetupRequirement", requirementID,
            "-uiTestSetupRequestID", Wire.requestID,
            "-uiTestSetupMatterID", Wire.matterID,
            "-uiTestSetupIntent", Wire.intent,
            "-uiTestSetupSourceSetID", Wire.sourceSetID,
            "-uiTestSetupSourceSetVersion", Wire.sourceSetVersion,
            "-uiTestSetupAuthorityPacketID", Wire.authorityPacketID,
            "-uiTestSetupAuthorityPacketVersion", Wire.authorityPacketVersion,
            "-uiTestSetupCheckpointID", Wire.checkpointID,
            "-uiTestSetupInput", Wire.input,
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func assertFixtureContext(in app: XCUIApplication) {
        let context = app.descendants(matching: .any)["setup.fixture.context"]
        XCTAssertTrue(context.waitForExistence(timeout: 10))
        let rendered = [context.label, context.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        for wireValue in [
            Wire.requestID,
            Wire.matterID,
            Wire.intent,
            Wire.sourceSetID,
            Wire.sourceSetVersion,
            Wire.authorityPacketID,
            Wire.authorityPacketVersion,
            Wire.checkpointID,
        ] {
            XCTAssertTrue(rendered.contains(wireValue), wireValue)
        }
        XCTAssertFalse(rendered.contains(Wire.forbiddenDefault))
        XCTAssertFalse(rendered.localizedCaseInsensitiveContains("current matter"))
        XCTAssertFalse(rendered.localizedCaseInsensitiveContains("default route"))
    }

    private func assertProblemConsequenceAndCorrection(
        on action: XCUIElement,
        requirementID: String
    ) {
        let announcement = [action.label, action.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(announcement.localizedCaseInsensitiveContains("required"), requirementID)
        XCTAssertTrue(announcement.localizedCaseInsensitiveContains("unavailable"), requirementID)
        XCTAssertFalse(announcement.contains(Wire.forbiddenDefault), requirementID)
    }

    private func focusedElement(identifier: String, in app: XCUIApplication) -> XCUIElement {
        let focused = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == %@ AND hasKeyboardFocus == true",
                    identifier
                )
            )
            .firstMatch
        return focused.exists ? focused : app.descendants(matching: .any)[identifier]
    }

    private func appSource(relativePath: String) throws -> String {
        try source(at: appRoot.appendingPathComponent(relativePath))
    }

    private func packageSource(package: String, relativePath: String) throws -> String {
        try source(
            at: repositoryRoot
                .appendingPathComponent("Packages/\(package)", isDirectory: true)
                .appendingPathComponent(relativePath)
        )
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var repositoryRoot: URL {
        appRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
