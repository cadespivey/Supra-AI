import Foundation
import XCTest

/// Locked-safe native source gate for the WP-1.1 consumers below Matter Edit.
/// The app may display preserved legacy evidence in the editor, but Research and
/// Outputs may only receive resolved court/party projections.
///
/// Expected RED: ResearchPlannerView still fuzzy-matches legacy court text and
/// MatterOutputsView prepends jurisdiction, court, perspective, and clientNames
/// from `MatterSummary` directly into the model prompt.
final class ArchitectureUXTDataIdentityConsumerSourceTests: XCTestCase {
    private let forbiddenDefault = "DEFAULT-000"

    func testResearchPlannerConsumesCanonicalCourtAndPartyProjections() throws {
        let source = try appSource(relativePath: "SupraAI/Research/ResearchPlannerView.swift")

        for forbidden in [
            "bestMatch(jurisdiction: matter.jurisdiction, court: matter.court)",
            "jurisdiction: matter.jurisdiction",
            "partyPerspective: matter.partyPerspective.rawValue",
        ] {
            XCTAssertFalse(source.contains(forbidden), "Research legacy bypass: \(forbidden)")
        }
        for contract in ["MatterCourtPresentation", "DraftPartyDefaults"] {
            XCTAssertTrue(
                source.contains(contract),
                "Expected RED: Research does not receive canonical projection \(contract)"
            )
        }
        XCTAssertFalse(source.contains(forbiddenDefault))
    }

    func testOutputsBuildsMatterContextFromCanonicalIdentityBeneathTheUI() throws {
        let source = try appSource(relativePath: "SupraAI/Outputs/MatterOutputsView.swift")

        for forbidden in [
            "\"Jurisdiction: \\(matter.jurisdiction)\"",
            "\"Party perspective: \\(matter.partyPerspective.rawValue)\"",
            "nonEmpty(matter.court)",
            "nonEmpty(matter.clientNames)",
            "context: prefix + context",
        ] {
            XCTAssertFalse(source.contains(forbidden), "Outputs legacy prompt bypass: \(forbidden)")
        }
        for contract in [
            "MatterCourtPresentation",
            "DraftPartyDefaults",
            "resolvedJurisdictionName",
            "resolvedCourtName",
            "representedClientName",
            "opposingPartyName",
        ] {
            XCTAssertTrue(
                source.contains(contract),
                "Expected RED: Outputs prompt is missing canonical identity field \(contract)"
            )
        }
        XCTAssertFalse(source.contains(forbiddenDefault))
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
}
