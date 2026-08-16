import Foundation
import XCTest

/// Native WP-1.1 boundary for canonical court, party, and representation identity.
///
/// Expected RED: Matter Edit still resolves persisted legal identity through
/// fuzzy `bestMatch`, the workspace displays legacy strings as if resolved, and
/// Draft still seeds hardcoded plaintiff/defendant/counsel values instead of the
/// Store-owned identity graph. Source gates fail before launch on a locked Mac;
/// the live journeys become the final native proof after the production wire lands.
@MainActor
final class CanonicalMatterIdentityUITests: XCTestCase {
    private enum Wire {
        static let scenario = "-uiTestCanonicalMatterIdentity"
        static let unresolvedMatterID = "matter-identity-unresolved-971"
        static let plaintiffMatterID = "matter-identity-plaintiff-977"
        static let defendantMatterID = "matter-identity-defendant-983"
        static let unresolvedCourt = "Fictional Maritime Claims Tribunal 971"
        static let plaintiffClient = "Aster Harbor Fabrication 977"
        static let plaintiffOpponent = "Northline Rail Logistics 979"
        static let plaintiffCounsel = "Counsel for Defendant"
        static let defendantClient = "Northline Rail Logistics 983"
        static let defendantOpponent = "Aster Harbor Fabrication 991"
        static let defendantCounsel = "Counsel for Plaintiff"
        static let forbiddenDefault = "DEFAULT-000"
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func test00MatterEditorPersistsSelectedStableIdentityWithoutFuzzyFallback() throws {
        let source = try appSource(relativePath: "SupraAI/Matters/MatterEditorSheet.swift")
        XCTAssertFalse(
            source.contains("bestMatch"),
            "Expected RED: Matter Edit still turns a fuzzy suggestion into persisted identity"
        )
        XCTAssertEqual(
            occurrences(of: "LabeledTextField(label: \"Court\"", in: source),
            0,
            "the second free-text Court field must not bypass the selected stable ID"
        )
        for contract in [
            "MatterIdentityEditorSubmission",
            "CanonicalJurisdictionID",
            "CanonicalCourtID",
            "MatterCourtResolutionState",
            "Choose Court",
        ] {
            XCTAssertTrue(source.contains(contract), "Expected RED: missing editor contract \(contract)")
        }
    }

    func test00WorkspaceAndDraftSheetConsumeCanonicalIdentityProjections() throws {
        let workspace = try appSource(relativePath: "SupraAI/Matters/MatterWorkspaceView.swift")
        for contract in [
            "controller.courtPresentation(forMatter:",
            "canDraftCourtFiling",
            "matter.identity.court.savedText",
            "matter.identity.court.action",
        ] {
            XCTAssertTrue(workspace.contains(contract), "Expected RED: missing workspace wire \(contract)")
        }
        XCTAssertFalse(
            workspace.contains("var parts = [matter.jurisdiction]"),
            "legacy jurisdiction text cannot remain the shipping resolved subtitle"
        )

        let drafting = try appSource(relativePath: "SupraAI/Matters/MatterDraftingView.swift")
        XCTAssertTrue(
            drafting.contains("controller.draftPartyDefaults(matterID:"),
            "Expected RED: Draft does not load canonical party/representation defaults"
        )
        for forbidden in [
            "PartyDraft(name: \"\", designation: \"Plaintiff,\")",
            "PartyDraft(name: \"\", designation: \"Defendant.\")",
            "var role = \"Counsel for Plaintiff\"",
            "_partyRepresented = State(initialValue: \"Defendant\")",
        ] {
            XCTAssertFalse(drafting.contains(forbidden), "remove hardcoded identity: \(forbidden)")
        }
    }

    func test00MatterEditorOwnsMutableStructuredPartiesAndRepresentations() throws {
        let source = try appSource(relativePath: "SupraAI/Matters/MatterEditorSheet.swift")
        for contract in [
            "@State private var parties: [MatterPartyIdentity]",
            "@State private var representations: [MatterRepresentationIdentity]",
            "MatterPartyClientStatus",
            "MatterRepresentationRelationshipKind",
            "MatterServiceAddress",
            "matter.identity.party.add",
            "matter.identity.representation.add",
            "parties: parties",
            "representations: representations",
        ] {
            XCTAssertTrue(
                source.contains(contract),
                "Expected RED: Matter Edit cannot create or repair structured identity: \(contract)"
            )
        }
        for forbiddenInference in [
            "draft.clientNames.split",
            "draft.clientNames.components",
            "switch draft.partyPerspective",
        ] {
            XCTAssertFalse(
                source.contains(forbiddenInference),
                "legacy matter strings cannot manufacture structured parties: \(forbiddenInference)"
            )
        }
    }

    func testUnresolvedCourtRemainsVisibleAndBlocksCourtDependentDrafting() throws {
        try requireImplementedSourceContract()
        let app = launch(matterID: Wire.unresolvedMatterID)
        defer { app.terminate() }

        let saved = app.descendants(matching: .any)["matter.identity.court.savedText"]
        XCTAssertTrue(saved.waitForExistence(timeout: 20))
        XCTAssertEqual(saved.label, Wire.unresolvedCourt)
        let choose = app.buttons["matter.identity.court.action"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        XCTAssertEqual(choose.label, "Choose Court")
        XCTAssertFalse(app.buttons["matter.draft"].isEnabled)

        let rendered = app.windows.firstMatch.debugDescription
        for forbidden in ["Federal", "ca11", "flsd", Wire.forbiddenDefault] {
            XCTAssertFalse(rendered.contains(forbidden), forbidden)
        }
    }

    func testPlaintiffAndDefendantMattersProduceInverseCoherentDraftDefaults() throws {
        try requireImplementedSourceContract()

        let fixtures = [
            (
                id: Wire.plaintiffMatterID,
                client: Wire.plaintiffClient,
                designation: "Plaintiff",
                opponent: Wire.plaintiffOpponent,
                counsel: Wire.plaintiffCounsel
            ),
            (
                id: Wire.defendantMatterID,
                client: Wire.defendantClient,
                designation: "Defendant",
                opponent: Wire.defendantOpponent,
                counsel: Wire.defendantCounsel
            ),
        ]

        for fixture in fixtures {
            let app = launch(matterID: fixture.id, openDraft: true)
            let client = app.descendants(matching: .any)["drafting.identity.representedClient"]
            XCTAssertTrue(client.waitForExistence(timeout: 20), fixture.id)
            XCTAssertEqual(stringValue(client), "\(fixture.client)|\(fixture.designation)")
            XCTAssertEqual(
                stringValue(app.descendants(matching: .any)["drafting.identity.opponent"]),
                fixture.opponent
            )
            XCTAssertTrue(
                stringValue(app.descendants(matching: .any)["drafting.identity.serviceRecipient"])
                    .contains(fixture.counsel)
            )
            let rendered = app.windows.firstMatch.debugDescription
            XCTAssertFalse(rendered.contains(Wire.forbiddenDefault))
            app.terminate()
        }
    }

    private func requireImplementedSourceContract() throws {
        try test00MatterEditorPersistsSelectedStableIdentityWithoutFuzzyFallback()
        try test00WorkspaceAndDraftSheetConsumeCanonicalIdentityProjections()
        try test00MatterEditorOwnsMutableStructuredPartiesAndRepresentations()
        let environment = try appSource(relativePath: "SupraAI/AppEnvironment.swift")
        for wire in [
            Wire.scenario,
            Wire.unresolvedMatterID,
            Wire.plaintiffMatterID,
            Wire.defendantMatterID,
        ] {
            XCTAssertTrue(environment.contains(wire), "Expected RED: missing fixture wire \(wire)")
        }
    }

    private func launch(matterID: String, openDraft: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTestMode",
            Wire.scenario,
            "-uiTestCanonicalMatterID", matterID,
        ]
        if openDraft { app.launchArguments.append("-uiTestOpenDraftSheet") }
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

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
