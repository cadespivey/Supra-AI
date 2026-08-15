import Foundation
import XCTest

@MainActor
final class ArchitectureUXPhase5ContractTests: XCTestCase {
    func testParityEnvironmentFailsClosedInSignedRelease() throws {
        let environment = try appSource("SupraAI/AppEnvironment.swift")
        let uiTestMode = try slice(from: "static var isUITestMode: Bool {", through: "static var isDemoMode: Bool {", in: environment)
        XCTAssertTrue(uiTestMode.contains("#if DEBUG"))
        XCTAssertTrue(uiTestMode.contains("#else\n        false"))
        XCTAssertTrue(environment.contains("headlessProbeRequiresIsolatedStore"))
        XCTAssertTrue(environment.contains("normal launch side"))
        XCTAssertTrue(environment.contains("effects — Sparkle"))
    }

    func testChatStartersAndCitationsRemainGovernedAndReachable() throws {
        let chat = try appSource("SupraAI/GlobalChatsView.swift")
        let suggestions = try packageSource("SupraSessions", "Sources/SupraSessions/ChatSuggestions.swift")
        let cards = try slice(from: "private func suggestionCard", through: "private func errorBanner", in: chat)
        XCTAssertTrue(cards.contains("draft = suggestion.prompt"))
        XCTAssertFalse(cards.contains("controller.send"))
        XCTAssertTrue(cards.contains("chat.starter."))
        XCTAssertTrue(suggestions.contains("public static let starters"))
        XCTAssertFalse(suggestions.lowercased().contains("sampling establishes legal accuracy"))

        let sources = try slice(from: "private var sourcesBlock", through: "private func sourceLine", in: chat)
        XCTAssertTrue(sources.contains("Button"))
        XCTAssertTrue(sources.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(sources.contains(".accessibilityAddTraits(.isButton)"))
        XCTAssertTrue(sources.contains("message.source."))
        XCTAssertTrue(chat.contains("SupraPopoverFrame(\"Generation\", width: 340)"))
        XCTAssertTrue(chat.contains("SupraPopoverFrame(\"Jurisdiction\")"))
    }

    func testDraftingSavedWorkAndTrustSurfacesStateTheirLimits() throws {
        let drafting = try appSource("SupraAI/Matters/MatterDraftingView.swift")
        let savedWork = try appSource("SupraAI/Outputs/MatterOutputsView.swift")
        let outputDetail = try appSource("SupraAI/Outputs/OutputDetailView.swift")

        XCTAssertTrue(drafting.contains("Section(\"Coming Soon\")"))
        XCTAssertTrue(drafting.contains("availableKinds.filter(\\.isEnabled)"))
        XCTAssertFalse(drafting.contains("not wired"))
        XCTAssertFalse(drafting.contains("pre-file gate"))
        XCTAssertFalse(drafting.contains("saved lineage"))
        XCTAssertFalse(drafting.contains("reviewed-authority bindings"))
        XCTAssertTrue(drafting.contains("only the fact excerpts and reviewed authorities you select"))
        XCTAssertTrue(drafting.contains("does not decide whether a fact supports a legal ground"))

        for text in ["Lifecycle:", "Review:", "Author: Not recorded", "Reviewer: Not recorded", "Last reviewed: Not recorded"] {
            XCTAssertTrue(savedWork.contains(text), text)
        }
        XCTAssertTrue(savedWork.contains("AssuranceBadge(state:"))
        XCTAssertTrue(outputDetail.contains("OutputAssurancePresentation.text(for: state)"))
        XCTAssertTrue(outputDetail.contains(".accessibilityLabel(OutputAssurancePresentation.text(for: state))"))
    }

    func testDocumentRelationOverrideRequiresAndPersistsReason() throws {
        let review = try appSource("SupraAI/Documents/DocumentRelationReviewSheet.swift")
        let repository = try packageSource("SupraStore", "Sources/SupraStore/Repositories/DocumentRelationRepository.swift")
        for action in ["Button(\"Confirm\")", "Button(\"Reject\"", "Button(\"Override\")"] {
            XCTAssertTrue(review.contains(action), action)
        }
        XCTAssertTrue(review.contains("TextField(\"Reason for override\""))
        XCTAssertTrue(review.contains("\"reason\": trimmedReason"))
        XCTAssertTrue(review.contains(".disabled(reason.trimmingCharacters"))
        XCTAssertTrue(repository.contains("document_relation_reviewed"))
        XCTAssertTrue(repository.contains("document_relation_override_created"))
        XCTAssertTrue(repository.contains("evidence_json"))
    }

    func testErrorsRecoveryAndComponentsUseProgressiveDisclosure() throws {
        let failure = try appSource("SupraAI/UserMutationFailureBanner.swift")
        let environment = try appSource("SupraAI/AppEnvironment.swift")
        let output = try packageSource("SupraSessions", "Sources/SupraSessions/StructuredOutputController.swift")
        let recovery = try appSource("SupraAI/RootView.swift")
        let theme = try appSource("SupraAI/SupraTheme.swift")

        XCTAssertTrue(output.contains("Save a New Copy or choose another location, then retry"))
        XCTAssertTrue(failure.contains("DisclosureGroup(\"Technical Details\""))
        XCTAssertTrue(failure.contains("mutation.failure.technicalDetails"))
        XCTAssertTrue(environment.contains("var recoveryActionTitle: String { \"Show Recovery Folder\" }"))
        for action in ["Copy Diagnostic Report", "Quit Without Changes"] {
            XCTAssertTrue(recovery.contains(action), action)
        }
        XCTAssertTrue(recovery.contains("Button(state.recoveryActionTitle)"))
        XCTAssertTrue(recovery.contains("DisclosureGroup(\"Support Details\""))
        XCTAssertTrue(recovery.contains("restore.recovery.technicalFacts"))
        XCTAssertTrue(theme.contains("struct SlideOverPanel"))
        XCTAssertTrue(theme.contains("struct SupraPopoverFrame"))
        XCTAssertTrue(theme.contains("struct GhostSegmentedControl"))
    }

    func testAccessibilityContrastTermsAndPublicRecordsStayLiteral() throws {
        let chat = try appSource("SupraAI/GlobalChatsView.swift")
        let billing = try appSource("SupraAI/ScratchPad/BillingDraftView.swift")
        let diagnostics = try appSource("SupraAI/DiagnosticsView.swift")
        let routes = try appSource("SupraAI/Navigation/AppRoute.swift")
        let publicRecords = try appSource("SupraAI/PublicRecordsView.swift")

        XCTAssertTrue(chat.contains("Always-visible action affordance"))
        XCTAssertTrue(chat.contains(".accessibilityIdentifier(\"chat.menu."))
        XCTAssertTrue(chat.contains(".accessibilityAddTraits(.isButton)"))
        XCTAssertTrue(billing.contains("confidence.rawValue"))
        XCTAssertTrue(billing.contains(".font(.supraCaption)"))
        XCTAssertTrue(diagnostics.contains("Section(\"System Status\"") || diagnostics.contains("Text(\"System Status\"") )
        XCTAssertTrue(diagnostics.contains("Toggle(\"Advanced\""))
        XCTAssertTrue(routes.contains("\"System Status\""))
        XCTAssertFalse(routes.contains("\"Diagnostics\""))

        for text in ["What these sources mean", "SEC EDGAR", "CIK", "CFPB", "NLRB", "not findings or conclusions"] {
            XCTAssertTrue(publicRecords.contains(text), text)
        }
        XCTAssertFalse(publicRecords.contains(".task {"))
        XCTAssertFalse(publicRecords.contains(".onAppear"))
        XCTAssertTrue(publicRecords.contains("Button(\"Search Filings\")"))
        XCTAssertTrue(publicRecords.contains("Button(\"Search Complaints\")"))
    }

    private func appSource(_ relativePath: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func packageSource(_ package: String, _ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent("Packages/\(package)/\(relativePath)"), encoding: .utf8)
    }

    private func slice(from start: String, through end: String, in source: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private var repositoryRoot: URL {
        appRoot.deletingLastPathComponent().deletingLastPathComponent()
    }
}
