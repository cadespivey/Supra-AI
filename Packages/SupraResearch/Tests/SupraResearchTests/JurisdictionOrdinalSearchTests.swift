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

    func testHigherStateCircuitsMatchByNumber() {
        // Florida's judicial circuits run to the 20th — a FL litigator searches
        // "16th circuit" (Monroe) and "20th circuit" (Collier/Lee) by number.
        for (number, spelled) in [("16", "Sixteenth"), ("17", "Seventeenth"), ("18", "Eighteenth"), ("19", "Nineteenth"), ("20", "Twentieth")] {
            let results = catalog.search("\(number)th judicial circuit")
            XCTAssertTrue(
                results.contains { $0.displayName.localizedCaseInsensitiveContains("\(spelled) Judicial Circuit") },
                "\(number)th judicial circuit should match \(spelled): \(results.prefix(3).map(\.displayName))"
            )
        }
    }

    func testNonOrdinalQueriesAreUntouched() {
        // Plain word queries must not be mangled by the ordinal pass.
        let results = catalog.search("Middle District of Florida")
        XCTAssertTrue(results.contains { $0.displayName.localizedCaseInsensitiveContains("Middle District of Florida") })
    }
}
