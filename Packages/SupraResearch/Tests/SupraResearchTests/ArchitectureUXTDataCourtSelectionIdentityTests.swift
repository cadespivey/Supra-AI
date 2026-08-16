import SupraResearch
import XCTest

/// T-DATA-COURT-04 — an explicitly selected catalog option must map to its one
/// canonical parent jurisdiction by exact stable ID. This boundary is for new
/// interactive selections; persisted legacy text continues through the separate,
/// versioned alias contract and must never enter this API.
///
/// Expected RED: `JurisdictionCatalog` does not yet expose
/// `canonicalJurisdictionOption(forSelectedOptionID:)`, so this test file fails to
/// compile on the missing production API. The GREEN implementation must use exact
/// catalog relationships only; `search`, `bestMatch`, normalization, and persisted
/// aliases are not authorized inputs.
final class ArchitectureUXTDataCourtSelectionIdentityTests: XCTestCase {
    private let catalog = JurisdictionCatalog.shared

    private let southernDistrictCourtID =
        "federal-florida-united-states-district-court-for-the-southern-district-of-florida"
    private let eleventhCircuitJurisdictionID =
        "federal-united-states-court-of-appeals-for-the-eleventh-circuit"
    private let fifthCircuitJurisdictionID =
        "federal-united-states-court-of-appeals-for-the-fifth-circuit"
    private let floridaJurisdictionID = "state-florida-courts"

    func testExactSouthernDistrictSelectionMapsToEleventhCircuitJurisdiction() throws {
        let selectedCourt = try XCTUnwrap(catalog.option(id: southernDistrictCourtID))
        let eleventhCircuit = try XCTUnwrap(
            catalog.option(id: eleventhCircuitJurisdictionID)
        )
        let fifthCircuit = try XCTUnwrap(catalog.option(id: fifthCircuitJurisdictionID))

        let jurisdiction: JurisdictionOption = try XCTUnwrap(
            catalog.canonicalJurisdictionOption(
                forSelectedOptionID: selectedCourt.id
            )
        )

        XCTAssertEqual(jurisdiction.id, eleventhCircuit.id)
        XCTAssertEqual(
            jurisdiction.displayName,
            "United States Court of Appeals for the Eleventh Circuit"
        )
        XCTAssertEqual(jurisdiction.level, .federalAppellate)

        // Scoped forbidden-default proof: the selected FLSD result itself must
        // carry no Fifth Circuit identity, while the forbidden option is proven
        // to be a real catalog member rather than an absent fixture.
        XCTAssertNotEqual(jurisdiction.id, fifthCircuit.id)
        XCTAssertNotEqual(
            jurisdiction.displayName,
            "United States Court of Appeals for the Fifth Circuit"
        )
    }

    func testJurisdictionOnlySelectionMapsToItself() throws {
        let selectedJurisdiction = try XCTUnwrap(
            catalog.option(id: floridaJurisdictionID)
        )

        let jurisdiction: JurisdictionOption = try XCTUnwrap(
            catalog.canonicalJurisdictionOption(
                forSelectedOptionID: selectedJurisdiction.id
            )
        )

        XCTAssertEqual(selectedJurisdiction.level, .jurisdiction)
        XCTAssertEqual(jurisdiction, selectedJurisdiction)
        XCTAssertEqual(jurisdiction.id, floridaJurisdictionID)
        XCTAssertNotEqual(jurisdiction.id, southernDistrictCourtID)
    }

    func testNamesAliasesAndFuzzyTextCannotEstablishSelectedIdentity() throws {
        let selectedCourt = try XCTUnwrap(catalog.option(id: southernDistrictCourtID))

        // Each value can succeed through a different non-authoritative path for
        // this boundary: exact display-name lookup, the persisted legacy alias,
        // or fuzzy search. None is an exact interactive selection ID.
        for forbiddenNonID in [
            selectedCourt.displayName,
            "S.D. Fla.",
            "Southern District of Florida",
        ] {
            XCTAssertNil(
                catalog.canonicalJurisdictionOption(
                    forSelectedOptionID: forbiddenNonID
                ),
                "Non-ID input must not establish canonical selection identity: \(forbiddenNonID)"
            )
        }
    }
}
