import Foundation
import XCTest

/// Exact absence and parity gates for the Case File Review retirement. These
/// tests deliberately distinguish the retired product vertical from ordinary
/// legal review concepts that remain part of Supra.
@MainActor
final class ArchitectureUXRetirementUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTReviewRetireUI01MatterWorkspaceHasExactRemainingDestinations() throws {
        // T-REVIEW-RETIRE-UI-01 expected RED: MatterWorkspaceView still declares
        // and renders the Case File Review destination between Outputs and Documents.
        let source = try appSource(relativePath: "SupraAI/Matters/MatterWorkspaceView.swift")
        let enumBody = try sourceSlice(
            from: "enum MatterTab: String, CaseIterable, Identifiable {",
            through: "var id: String { rawValue }",
            in: source
        )
        let expectedCases = [
            "chat", "research", "authorities", "outputs", "documents", "billing", "audit",
        ]
        let actualCases = enumBody
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
            .map { line in
                String(line.dropFirst("case ".count).split(separator: " ", maxSplits: 1)[0])
            }

        XCTAssertEqual(actualCases, expectedCases)
        XCTAssertFalse(source.contains("case .review:"))
        XCTAssertFalse(source.contains("CaseFileReviewView("))
        XCTAssertFalse(source.contains("matterTab.Review"))
        XCTAssertTrue(source.contains("@State private var tab: MatterTab = .chat"))
    }

    func testTReviewTerms01OrdinaryReviewWorkflowsRemainOwned() throws {
        // T-REVIEW-TERMS-01 standing guard: feature retirement must not erase
        // reviewed authorities, relation review, citation-review state, generic
        // needs-review status, or Chat's governed /critique workflow.
        let coreRoot = packageRoot("SupraCore")
        let sessionsRoot = packageRoot("SupraSessions")
        let storeRoot = packageRoot("SupraStore")
        let routing = try source(at: coreRoot.appendingPathComponent("Sources/SupraCore/ModelRouting.swift"))
        let slashCommands = try source(at: coreRoot.appendingPathComponent("Sources/SupraCore/SlashCommandCatalog.swift"))
        let authority = try source(at: storeRoot.appendingPathComponent("Sources/SupraStore/Repositories/AuthorityRepository.swift"))
        let relation = try source(at: storeRoot.appendingPathComponent("Sources/SupraStore/Repositories/DocumentRelationRepository.swift"))
        let chat = try source(at: sessionsRoot.appendingPathComponent("Sources/SupraSessions/GlobalChatController.swift"))

        XCTAssertTrue(routing.contains("case legalCritique"))
        XCTAssertTrue(routing.contains("case \"/critique\""))
        XCTAssertTrue(routing.contains("LegalPromptTemplates.critiqueSystemPrompt"))
        XCTAssertTrue(slashCommands.contains("SlashCommand(command: \"/critique\""))
        XCTAssertTrue(chat.contains("route?.mode == .legalCritique"))
        XCTAssertTrue(authority.contains("reviewedPropositionState"))
        XCTAssertTrue(relation.contains("A relation review cannot transition"))
        XCTAssertTrue(relation.contains("StructuredOutputStatus.needsReview.rawValue"))
    }

    func testTReviewRetireUI01RemainingTabsReflowAtSupportedWidths() {
        // T-REVIEW-RETIRE-UI-01 expected RED: the shipping matter tab bar still
        // exposes Review. The non-default widths also prove the surviving segment
        // set remains visible and hittable after removal.
        for width in [880, 1_100, 1_420] {
            let app = XCUIApplication()
            app.launchArguments += [
                "-ApplePersistenceIgnoreState", "YES",
                "-uiTestMode",
                "-uiTestEnsureFreshWindow",
                "-uiTestSelectFirstMatter",
                "-uiTestWindowWidth", String(width),
            ]
            app.launch()
            app.activate()

            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 15), "Missing window at width \(width)")
            let expected = ["Chat", "Research", "Authorities", "Outputs", "Documents", "Billing", "Audit"]
            for label in expected {
                let tab = app.buttons["matterTab.\(label)"]
                XCTAssertTrue(tab.waitForExistence(timeout: 20), "Missing \(label) at width \(width)")
                XCTAssertTrue(tab.isHittable, "Clipped \(label) at width \(width)")
            }
            XCTAssertFalse(app.buttons["matterTab.Review"].exists)
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "matterTab.")).count, expected.count)
            app.terminate()
        }
    }

    func testTDELUI01BothDocumentTrashSurfacesShareConfirmationAndRenderFailure() throws {
        // Preserved ordinary deletion coverage extracted from the Review-composition
        // test file before that obsolete composition is removed.
        let matterDocuments = try appSource(relativePath: "SupraAI/Documents/MatterDocumentsView.swift")
        let recycleBin = try appSource(relativePath: "SupraAI/RecycleBinView.swift")
        let deletionPresentation = try source(
            at: packageRoot("SupraSessions")
                .appendingPathComponent("Sources/SupraSessions/DeletionPresentation.swift")
        )

        XCTAssertTrue(matterDocuments.contains(".permanentDeletionConfirmation("))
        XCTAssertTrue(recycleBin.contains(".permanentDeletionConfirmation("))
        XCTAssertTrue(matterDocuments.contains("controller.permanentDeletionNotice"))
        XCTAssertTrue(matterDocuments.contains("controller.clearPermanentDeletionNotice()"))
        XCTAssertFalse(
            matterDocuments.contains(
                "Button(\"Delete Permanently\", role: .destructive) { controller.permanentlyDelete"
            )
        )
        XCTAssertTrue(recycleBin.contains("item.presentation.actionTitle"))
        XCTAssertTrue(recycleBin.contains("item.presentation.message"))
        XCTAssertTrue(recycleBin.contains("permanentPresentation.tone.buttonRole"))
        XCTAssertTrue(recycleBin.contains("deletionButtonStyle(permanentPresentation.tone)"))
        XCTAssertFalse(recycleBin.contains("Button(action: delete)"))
        XCTAssertFalse(recycleBin.contains(".accessibilityLabel(\"Delete Permanently\")"))
        XCTAssertTrue(matterDocuments.contains("RecycleBinNavigationPresentation.standard.title"))
        XCTAssertTrue(matterDocuments.contains("target.presentation.actionTitle"))
        XCTAssertTrue(matterDocuments.contains("softDeletePresentation"))
        XCTAssertFalse(matterDocuments.contains("Button(\"Delete Permanently\", role: .destructive)"))
        XCTAssertFalse(matterDocuments.contains("Label(\"Move to Recycle Bin\", systemImage: \"trash\")"))
        XCTAssertTrue(deletionPresentation.contains("case folder"))
        XCTAssertFalse(matterDocuments.contains("SupraToolbarIconButton(\"Trash\", systemImage: \"trash\", role: .destructive)"))
        XCTAssertTrue(
            deletionPresentation.contains(
                "Saved output text, citation display excerpts and locators, and retained proof records"
            )
        )
        XCTAssertFalse(deletionPresentation.contains("corpus-analysis"))
        XCTAssertFalse(recycleBin.contains("Saved analysis"))
    }

    func testTXPCReviewRemove01OrdinaryRuntimeRecoveryHasAnOwnedAppSurface() throws {
        // T-XPC-REVIEW-REMOVE-01 expected RED: RuntimeSafetyClient can quarantine
        // uncertain cancellation, but RuntimeStatusController and Diagnostics do
        // not observe that state or expose its owner-operated idle recovery.
        let status = try appSource(relativePath: "SupraAI/Status/RuntimeStatusController.swift")
        let environment = try appSource(relativePath: "SupraAI/AppEnvironment.swift")
        let diagnostics = try appSource(relativePath: "SupraAI/DiagnosticsView.swift")

        XCTAssertTrue(status.contains("private let runtimeClient: RuntimeSafetyClient"))
        XCTAssertTrue(status.contains("@Published private(set) var recoverySnapshot"))
        XCTAssertTrue(status.contains("func recoverRuntime() async"))
        XCTAssertTrue(status.contains("try await runtimeClient.recoverRuntime()"))
        XCTAssertTrue(status.contains("runtimeClient.currentRecoverySnapshot()"))
        XCTAssertTrue(environment.contains("@Published private(set) var runtimeRecoverySnapshot"))
        XCTAssertTrue(environment.contains("func recoverRuntime() async"))
        XCTAssertTrue(diagnostics.contains("runtime.recovery.required"))
        XCTAssertTrue(diagnostics.contains("runtime.recovery.action"))
        XCTAssertTrue(diagnostics.contains("Recover Local Runtime"))
        XCTAssertTrue(diagnostics.contains("Recovery waits for admitted work, restarts the local runtime connection, and confirms it is idle before new model work can begin."))
        XCTAssertFalse(status.contains("Case File Review"))
        XCTAssertFalse(diagnostics.contains("Case File Review"))
    }

    private func appSource(relativePath: String) throws -> String {
        try source(at: appRoot.appendingPathComponent(relativePath))
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func packageRoot(_ name: String) -> URL {
        appRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packages/\(name)", isDirectory: true)
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceSlice(from startMarker: String, through endMarker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.upperBound])
    }
}
