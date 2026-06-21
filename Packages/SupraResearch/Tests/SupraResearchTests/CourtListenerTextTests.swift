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

    func testCleanDecodesSmartPunctuation() {
        XCTAssertEqual(CourtListenerText.clean("People&#8217;s &ldquo;Bank&rdquo;"), "People’s “Bank”")
        XCTAssertEqual(CourtListenerText.clean("Roe &ndash; Doe &mdash; 1999"), "Roe – Doe — 1999")
    }

    func testOpinionURLUsesTrailingSlashOnAllowedHost() {
        let url = CourtListenerEndpoint.opinionURL(id: 12345)
        XCTAssertEqual(url.host, "www.courtlistener.com")
        XCTAssertTrue(url.absoluteString.hasSuffix("/api/rest/v4/opinions/12345/"), url.absoluteString)
    }

    func testPassageReturnsShortBodyUnchanged() {
        XCTAssertEqual(CourtListenerText.passage(from: "A short opinion body."), "A short opinion body.")
        XCTAssertNil(CourtListenerText.passage(from: "   "))
        XCTAssertNil(CourtListenerText.passage(from: nil))
    }

    func testPassageWindowsAroundAnchorAndCapsLength() {
        let body = (1...300).map { "word\($0)" }.joined(separator: " ") + " the absolute priority rule applies here " + (301...600).map { "word\($0)" }.joined(separator: " ")
        let passage = try! XCTUnwrap(CourtListenerText.passage(from: body, around: "the absolute priority rule", targetWords: 60))
        XCTAssertTrue(passage.contains("absolute priority rule"))
        XCTAssertTrue(passage.hasPrefix("…"))
        XCTAssertLessThanOrEqual(passage.split(separator: " ").count, 62)
    }

    func testPassageStripsHtmlBodyWhenNoPlainText() {
        let dto = CourtListenerOpinionDetailDTO(html: "<p>Held: the <mark>statute</mark> bars the claim.</p>")
        XCTAssertEqual(dto.bodyText, "Held: the statute bars the claim.")
        XCTAssertEqual(dto.bestHTML, "<p>Held: the <mark>statute</mark> bars the claim.</p>")
    }

    func testBestHTMLPrefersCitationLinkedMarkup() {
        let dto = CourtListenerOpinionDetailDTO(html: "<p>plain</p>", htmlWithCitations: "<p>cited</p>")
        XCTAssertEqual(dto.bestHTML, "<p>cited</p>")
    }

    func testCourtListenerPDFURLOnlyForStoredPDF() {
        XCTAssertEqual(
            CourtListenerOpinionDetailDTO(localPath: "pdf/2009/04/file.pdf").courtListenerPDFURL?.absoluteString,
            "https://storage.courtlistener.com/pdf/2009/04/file.pdf"
        )
        XCTAssertEqual(
            CourtListenerOpinionDetailDTO(localPath: "/pdf/x.pdf").courtListenerPDFURL?.host,
            "storage.courtlistener.com"
        )
        XCTAssertNil(CourtListenerOpinionDetailDTO(localPath: "txt/2009/file.txt").courtListenerPDFURL)
        XCTAssertNil(CourtListenerOpinionDetailDTO(localPath: "").courtListenerPDFURL)
        XCTAssertNil(CourtListenerOpinionDetailDTO().courtListenerPDFURL)
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
