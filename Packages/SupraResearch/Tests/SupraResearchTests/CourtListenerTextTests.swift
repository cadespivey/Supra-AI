import XCTest
@testable import SupraResearch

final class CourtListenerTextTests: XCTestCase {
    func testCleanStripsHighlightMarkupAndDecodesEntities() {
        XCTAssertEqual(
            CourtListenerText.clean("12 <mark>Fla</mark>. L. Weekly Fed. S 216"),
            "12 Fla. L. Weekly Fed. S 216"
        )
        XCTAssertEqual(
            CourtListenerText.clean("Smith &amp; Co. v. &quot;Jones&quot;"),
            "Smith & Co. v. \"Jones\""
        )
        XCTAssertEqual(CourtListenerText.clean("§&#167; <b>x</b>"), "§§ x")
        XCTAssertNil(CourtListenerText.clean("   "))
        XCTAssertNil(CourtListenerText.clean(nil))
        XCTAssertEqual(CourtListenerText.cleanList(["<mark>A</mark>", "   ", "B"]), ["A", "B"])
    }

    func testPreferredCitationPrefersOfficialReporterAndStripsMarkup() {
        let dto = CourtListenerSearchResultDTO(
            caseName: "Bank of America v. 203 North LaSalle",
            citation: ["12 <mark>Fla</mark>. L. Weekly Fed. S 216", "526 U.S. 434", "119 S. Ct. 1411"]
        )
        XCTAssertEqual(CourtListenerMapper.preferredCitation(for: dto), "526 U.S. 434")
    }

    func testPreferredCitationFallsBackWhenOnlySpecialtyAvailable() {
        let dto = CourtListenerSearchResultDTO(citation: ["12 <mark>Fla</mark>. L. Weekly Fed. S 216"])
        XCTAssertEqual(CourtListenerMapper.preferredCitation(for: dto), "12 Fla. L. Weekly Fed. S 216")
        XCTAssertNil(CourtListenerMapper.preferredCitation(for: CourtListenerSearchResultDTO()))
    }

    func testReporterRankOrdersOfficialAheadOfSpecialty() {
        let specialty = CourtListenerMapper.reporterRank("12 Fla. L. Weekly Fed. S 216")
        XCTAssertLessThan(CourtListenerMapper.reporterRank("526 U.S. 434"), specialty)
        XCTAssertLessThan(CourtListenerMapper.reporterRank("923 F.3d 1234"), specialty)
        XCTAssertLessThan(CourtListenerMapper.reporterRank("526 U.S. 434"), CourtListenerMapper.reporterRank("923 F.3d 1234"))
    }

    func testNormalizeSanitizesCaseNameAndCitations() {
        let dto = CourtListenerSearchResultDTO(
            caseName: "<mark>United</mark> States v. Winstar Corp.",
            citation: ["10 <mark>Fla</mark>. L. Weekly Fed. S 166", "518 U.S. 839"]
        )
        let authority = LegalAuthorityNormalizer.normalize(dto)
        XCTAssertEqual(authority.caseName, "United States v. Winstar Corp.")
        XCTAssertEqual(authority.citation, "518 U.S. 839")
        XCTAssertFalse(authority.citations.contains { $0.contains("<mark>") })
    }
}
