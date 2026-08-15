import Foundation
import XCTest

/// Native presentation half of T-MUTATION-01.
///
/// The controller/Store gate proves rollback. This suite proves that the real
/// SwiftUI callers consume that typed outcome: failure keeps the user's exact
/// draft or selection in place, prevents success-dependent dismissal/routing,
/// and exposes keyboard- and VoiceOver-reachable Retry/Correct actions.
///
/// Expected RED: feature views still call compatibility wrappers (or `try?`),
/// do not render `lastMutationFailure`, and the shared feature-local failure
/// banner plus hermetic matter-create/edit fixture do not yet exist.
@MainActor
final class ArchitectureUXTMutationNativeTests: XCTestCase {
    private enum Wire {
        static let scenario = "-uiTestMutationFailureTruth"
        static let createName = "Aster Harbor Mutation Draft 967"
        static let createFailure = "T_MUTATION_NATIVE_CREATE_FAILURE_971"
        static let editMatterID = "matter-mutation-native-977"
        static let editOriginalName = "Northline Rail Matter 977"
        static let editName = "Northline Rail Edited Draft 983"
        static let editFailure = "T_MUTATION_NATIVE_EDIT_FAILURE_991"
        static let forbiddenDefault = "DEFAULT-000"
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func test00AccessibleFailureBannerIsPresentationOnlyNotAWorkflowCoordinator() throws {
        let banner = try XCTUnwrap(
            try? appSource(relativePath: "SupraAI/UserMutationFailureBanner.swift"),
            "Expected RED: UserMutationFailureBanner.swift does not exist"
        )
        for contract in [
            "UserMutationFailure",
            "failure.userMessage",
            "failure.recoveryActions.contains(.retry)",
            "failure.recoveryActions.contains(.correctInput)",
            "Button(\"Retry\")",
            "Button(\"Correct\")",
            "mutation.failure.",
            "mutation.failure.retry.",
            "mutation.failure.correct.",
            "@AccessibilityFocusState",
            ".accessibilityFocused",
        ] {
            XCTAssertTrue(
                banner.contains(contract),
                "Expected RED: accessible mutation-failure presentation is missing \(contract)"
            )
        }
        for forbiddenOwner in [
            "MattersController",
            "SettingsController",
            "MatterDocumentsController",
            "ResearchSessionController",
            "StructuredOutputController",
            "RecycleBinController",
            "SupraStore",
            "NavigationPath",
            "NotificationCenter",
        ] {
            XCTAssertFalse(
                banner.contains(forbiddenOwner),
                "the shared view may present typed failure, but cannot coordinate \(forbiddenOwner)"
            )
        }
    }

    func test00MatterCreateAndEditConsumeTypedOutcomesBeforeDismissOrNavigation() throws {
        let editor = try appSource(relativePath: "SupraAI/Matters/MatterEditorSheet.swift")
        for contract in [
            "UserMutationOutcome<String>",
            "@State private var lastMutationFailure: UserMutationFailure?",
            "UserMutationFailureBanner",
            "outcome.allowsSuccessPresentation",
            "retry: save",
            "correct:",
            "matter.editor.sheet",
            "matter.editor.name",
            "matter.editor.commit",
        ] {
            XCTAssertTrue(
                editor.contains(contract),
                "Expected RED: Matter editor is missing typed failure contract \(contract)"
            )
        }
        let saveBody = try functionBody(containing: "private func save()", in: editor)
        XCTAssertTrue(saveBody.contains("lastMutationFailure = outcome.failure"))
        XCTAssertTrue(saveBody.contains("outcome.allowsSuccessPresentation"))
        XCTAssertFalse(
            saveBody.contains("try onSave("),
            "the editor must consume the typed result rather than convert it back to an untyped throw"
        )

        let shell = try appSource(relativePath: "SupraAI/MainShellView.swift")
        let createSheet = try sourceSlice(
            shell,
            from: ".sheet(isPresented: $showNewMatter)",
            through: "/// Pins the shell"
        )
        for contract in [
            "attemptCreateMatter(",
            "identity: submission",
            "allowsDependentNavigation",
            "committedValue",
        ] {
            XCTAssertTrue(
                createSheet.contains(contract),
                "Expected RED: create flow is missing typed commit gate \(contract)"
            )
        }
        XCTAssertFalse(createSheet.contains("try environment.mattersController.createMatter("))

        let workspace = try appSource(relativePath: "SupraAI/Matters/MatterWorkspaceView.swift")
        let editSheet = try sourceSlice(
            workspace,
            from: ".sheet(isPresented: $showEditor)",
            through: ".sheet(isPresented: $showDraftSheet)"
        )
        XCTAssertTrue(editSheet.contains("attemptUpdateMatter(identity:"))
        XCTAssertTrue(editSheet.contains("allowsSuccessPresentation"))
        XCTAssertFalse(editSheet.contains("try controller.updateMatter(identity:"))
    }

    func test00SidebarPinReorderAndSortRenderOneTypedFeatureLocalFailure() throws {
        let sidebar = try appSource(relativePath: "SupraAI/SidebarView.swift")
        for contract in [
            "matters.attemptSetPinned(",
            "matters.attemptMoveMatters(",
            "matters.attemptSetSortMode(",
            "matters.lastMutationFailure",
            "UserMutationFailureBanner",
            "mutation.failure.sidebar",
        ] {
            XCTAssertTrue(
                sidebar.contains(contract),
                "Expected RED: Sidebar mutation path is missing \(contract)"
            )
        }
        for swallowedWrapper in [
            "matters.setPinned(",
            "matters.moveMatters(",
            "matters.setSortMode(",
        ] {
            XCTAssertFalse(
                sidebar.contains(swallowedWrapper),
                "Sidebar must inspect the typed outcome instead of calling \(swallowedWrapper)"
            )
        }

        let controller = try packageSource(
            package: "SupraSessions",
            relativePath: "Sources/SupraSessions/MattersController.swift"
        )
        XCTAssertTrue(
            controller.contains("public func attemptSetSortMode("),
            "Expected RED: the manual-sort seed has no typed commit boundary"
        )
        XCTAssertFalse(
            controller.contains("try? store.matters.updateMatterSortOrder"),
            "setSortMode still swallows the first manual-order Store failure"
        )
    }

    func test00ImportKeepsExactURLsAndFolderAvailableForRetry() throws {
        let source = try appSource(relativePath: "SupraAI/Documents/MatterDocumentsView.swift")
        for contract in [
            "controller.attemptImportItems(",
            "controller.lastMutationFailure",
            "UserMutationFailureBanner",
            "pendingImportURLs",
            "pendingImportFolderID",
            "documents.mutationFailure",
        ] {
            XCTAssertTrue(
                source.contains(contract),
                "Expected RED: import presentation is missing \(contract)"
            )
        }
        XCTAssertFalse(
            source.contains("controller.importItems("),
            "picker and drop paths may not discard the typed import outcome"
        )
    }

    func test00ResearchSaveKeepsPlannerOpenAndSuppressesRouteOnFailure() throws {
        let source = try appSource(relativePath: "SupraAI/Research/ResearchPlannerView.swift")
        for contract in [
            "controller.attemptSavePlan(draft: draft)",
            "controller.lastMutationFailure",
            "UserMutationFailureBanner",
            "outcome.allowsDependentNavigation",
            "planner.mutationFailure",
        ] {
            XCTAssertTrue(
                source.contains(contract),
                "Expected RED: Research planner is missing \(contract)"
            )
        }
        XCTAssertFalse(source.contains("try? controller.savePlan(draft: draft)"))
        let saveAndRun = try functionBody(containing: "private func saveAndRun()", in: source)
        XCTAssertTrue(saveAndRun.contains("outcome.allowsDependentNavigation"))
        XCTAssertTrue(saveAndRun.contains("outcome.committedValue"))
        XCTAssertFalse(saveAndRun.contains("guard let sessionID = try?"))
    }

    func test00ExportOpensFinderOnlyAfterTypedCommittedURL() throws {
        let source = try appSource(relativePath: "SupraAI/Outputs/OutputDetailView.swift")
        for contract in [
            "controller.attemptExportOutput(",
            "controller.lastMutationFailure",
            "UserMutationFailureBanner",
            "outcome.allowsSuccessPresentation",
            "output.mutationFailure",
        ] {
            XCTAssertTrue(
                source.contains(contract),
                "Expected RED: export presentation is missing \(contract)"
            )
        }
        XCTAssertFalse(
            source.contains("controller.exportOutput("),
            "Finder reveal must be driven only by the typed committed URL"
        )
    }

    func test00RecycleRestoreReloadsDependentsOnlyAfterCommit() throws {
        let source = try appSource(relativePath: "SupraAI/RecycleBinView.swift")
        for contract in [
            "controller.attemptRestoreMatter(",
            "controller.attemptRestoreChat(",
            "controller.attemptRestoreDocument(",
            "controller.lastMutationFailure",
            "UserMutationFailureBanner",
            "outcome.allowsSuccessPresentation",
            "recycleBin.mutationFailure",
        ] {
            XCTAssertTrue(
                source.contains(contract),
                "Expected RED: Recycle Bin presentation is missing \(contract)"
            )
        }
        for discardedWrapper in [
            "controller.restoreMatter(",
            "controller.restoreChat(",
            "controller.restoreDocument(",
        ] {
            XCTAssertFalse(source.contains(discardedWrapper))
        }
    }

    func test00SettingsRetainsCandidateAndCredentialTextWithCorrectionAction() throws {
        let source = try appSource(relativePath: "SupraAI/SettingsView.swift")
        for contract in [
            "settings.attemptSetTemperature(",
            "settings.attemptSaveAPIKey(",
            "settings.attemptSaveCourtListenerToken(",
            "settings.lastMutationFailure",
            "UserMutationFailureBanner",
            "settings.mutationFailure",
            ".correctInput",
        ] {
            XCTAssertTrue(
                source.contains(contract),
                "Expected RED: Settings mutation presentation is missing \(contract)"
            )
        }
        XCTAssertFalse(source.contains("save: { settings.saveAPIKey("))
        XCTAssertFalse(source.contains("save: { settings.saveCourtListenerToken("))
    }

    func testMatterCreateFailureKeepsExactDraftAndGlobalRouteVisible() throws {
        try requireImplementedMatterLiveContract()
        let app = launch(
            operation: "matterCreate",
            draftName: Wire.createName,
            failure: Wire.createFailure
        )
        defer { app.terminate() }

        let sheet = app.descendants(matching: .any)["matter.editor.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20))
        let name = app.textFields["matter.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(stringValue(name), Wire.createName)

        app.buttons["matter.editor.commit"].click()

        let failure = app.descendants(matching: .any)["mutation.failure.matterCreate"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        assertFailureMarker(Wire.createFailure, in: app)
        XCTAssertTrue(sheet.exists, "failed create must keep the sheet open")
        XCTAssertEqual(stringValue(name), Wire.createName, "failed create must retain the exact draft")
        XCTAssertFalse(app.descendants(matching: .any)["matter.row.\(Wire.createName)"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["chat.new"].exists,
            "failed create must leave the global Chats destination mounted"
        )
        assertRecoveryActions(operation: "matterCreate", in: app, corrects: "matter.editor.name")
        XCTAssertFalse(app.windows.firstMatch.debugDescription.contains(Wire.forbiddenDefault))
    }

    func testMatterEditFailureKeepsExactDraftSheetAndOriginalSelection() throws {
        try requireImplementedMatterLiveContract()
        let app = launch(
            operation: "matterEdit",
            draftName: Wire.editName,
            failure: Wire.editFailure,
            matterID: Wire.editMatterID,
            originalName: Wire.editOriginalName
        )
        defer { app.terminate() }

        let originalRow = app.descendants(matching: .any)["matter.row.\(Wire.editOriginalName)"]
        XCTAssertTrue(originalRow.waitForExistence(timeout: 20))
        let sheet = app.descendants(matching: .any)["matter.editor.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        let name = app.textFields["matter.editor.name"]
        XCTAssertEqual(stringValue(name), Wire.editName)

        app.buttons["matter.editor.commit"].click()

        let failure = app.descendants(matching: .any)["mutation.failure.matterEdit"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        assertFailureMarker(Wire.editFailure, in: app)
        XCTAssertTrue(sheet.exists, "failed edit must keep the sheet open")
        XCTAssertEqual(stringValue(name), Wire.editName, "failed edit must retain the exact draft")
        XCTAssertTrue(originalRow.exists)
        XCTAssertFalse(app.descendants(matching: .any)["matter.row.\(Wire.editName)"].exists)
        assertRecoveryActions(operation: "matterEdit", in: app, corrects: "matter.editor.name")
        XCTAssertFalse(app.windows.firstMatch.debugDescription.contains(Wire.forbiddenDefault))
    }

    private func requireImplementedMatterLiveContract() throws {
        try test00MatterCreateAndEditConsumeTypedOutcomesBeforeDismissOrNavigation()
        let environment = try appSource(relativePath: "SupraAI/AppEnvironment.swift")
        let shell = try appSource(relativePath: "SupraAI/MainShellView.swift")
        for contract in [
            Wire.scenario,
            "-uiTestMutationOperation",
            "-uiTestMutationDraftName",
            "-uiTestMutationFailureMarker",
            "-uiTestMutationMatterID",
            "-uiTestMutationOriginalName",
        ] {
            XCTAssertTrue(
                environment.contains(contract) || shell.contains(contract),
                "Expected RED: hermetic native mutation fixture is missing \(contract)"
            )
        }
        for testOwnedValue in [
            Wire.createName,
            Wire.createFailure,
            Wire.editMatterID,
            Wire.editOriginalName,
            Wire.editName,
            Wire.editFailure,
        ] {
            XCTAssertFalse(
                environment.contains(testOwnedValue) || shell.contains(testOwnedValue),
                "production must parse the test wire, not hardcode \(testOwnedValue)"
            )
        }
    }

    private func assertRecoveryActions(
        operation: String,
        in app: XCUIApplication,
        corrects fieldIdentifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let retry = app.buttons["mutation.failure.retry.\(operation)"]
        let correct = app.buttons["mutation.failure.correct.\(operation)"]
        XCTAssertTrue(retry.exists, file: file, line: line)
        XCTAssertEqual(retry.label, "Retry", file: file, line: line)
        XCTAssertTrue(correct.exists, file: file, line: line)
        XCTAssertEqual(correct.label, "Correct", file: file, line: line)
        correct.click()
        let focused = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@ AND hasKeyboardFocus == true",
                fieldIdentifier
            )
        ).firstMatch
        XCTAssertTrue(
            focused.waitForExistence(timeout: 5),
            "Correct must focus the exact retained input",
            file: file,
            line: line
        )
    }

    private func launch(
        operation: String,
        draftName: String,
        failure: String,
        matterID: String? = nil,
        originalName: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            Wire.scenario,
            "-uiTestMutationOperation", operation,
            "-uiTestMutationDraftName", draftName,
            "-uiTestMutationFailureMarker", failure,
        ]
        if let matterID {
            app.launchArguments += ["-uiTestMutationMatterID", matterID]
        }
        if let originalName {
            app.launchArguments += ["-uiTestMutationOriginalName", originalName]
        }
        app.launchArguments.append("-uiTestEnsureFreshWindow")
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 25))
        return app
    }

    private func stringValue(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    private func assertFailureMarker(
        _ marker: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // The banner intentionally uses progressive disclosure: its root value
        // is the attorney-facing summary, while the exact synthetic Store error
        // lives in the Technical Details child.
        let detail = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                marker,
                marker
            )
        ).firstMatch
        XCTAssertTrue(
            detail.waitForExistence(timeout: 5),
            "Technical Details must retain the exact failure marker",
            file: file,
            line: line
        )
    }

    private func appSource(relativePath: String) throws -> String {
        try String(
            contentsOf: appRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func packageSource(package: String, relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Packages")
                .appendingPathComponent(package)
                .appendingPathComponent(relativePath),
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

    private func functionBody(containing marker: String, in source: String) throws -> String {
        let markerRange = try XCTUnwrap(source.range(of: marker))
        let openingBrace = try XCTUnwrap(source[markerRange.upperBound...].firstIndex(of: "{"))
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
        XCTFail("missing closing brace after \(marker)")
        return ""
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var repositoryRoot: URL {
        appRoot.deletingLastPathComponent().deletingLastPathComponent()
    }
}
