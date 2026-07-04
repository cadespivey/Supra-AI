import XCTest
@testable import SupraResearch

/// Lawyers type courts by number ("11th Circuit", "2d Cir", "5 DCA") while the
/// catalog spells ordinals out — search must match both directions.
final class JurisdictionOrdinalSearchTests: XCTestCase {
    private let catalog = JurisdictionCatalog.shared

    func testNumericOrdinalFindsSpelledCircuit() {
        let results = catalog.search("11th circuit")
        XCTAssertTrue(
            results.contains { $0.displayName.localizedCaseInsensitiveContains("Eleventh Circuit") },
            "got: \(results.prefix(5).map(\.displayName))"
        )
    }

    func testBareNumberFindsSpelledCircuit() {
        let results = catalog.search("11 circuit")
        XCTAssertTrue(results.contains { $0.displayName.localizedCaseInsensitiveContains("Eleventh Circuit") })
    }

    func testBluebookAbbreviatedOrdinalMatches() {
        // "2d" and "3d" are the Bluebook forms.
        let second = catalog.search("2d circuit")
        XCTAssertTrue(second.contains { $0.displayName.localizedCaseInsensitiveContains("Second Circuit") })
        let third = catalog.search("3d circuit")
        XCTAssertTrue(third.contains { $0.displayName.localizedCaseInsensitiveContains("Third Circuit") })
    }

    func testSpelledQueriesStillMatch() {
        let results = catalog.search("eleventh circuit")
        XCTAssertTrue(results.contains { $0.displayName.localizedCaseInsensitiveContains("Eleventh Circuit") })
    }

    func testNonOrdinalQueriesAreUntouched() {
        // Plain word queries must not be mangled by the ordinal pass.
        let results = catalog.search("Middle District of Florida")
        XCTAssertTrue(results.contains { $0.displayName.localizedCaseInsensitiveContains("Middle District of Florida") })
    }
}
