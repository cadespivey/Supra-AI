import Foundation
import SupraResearch
import XCTest

final class ECFRStatutorySourceTests: XCTestCase {

    private func decode(_ json: String) throws -> ECFRSearchResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ECFRSearchResponse.self, from: Data(json.utf8))
    }

    func testMapsResultToCurrencyVerifiableProvisionWithEffectiveDate() async throws {
        let json = """
        {"results":[{"starts_on":"2023-08-09","ends_on":null,"type":"Section","hierarchy":{"title":"40","chapter":"I","part":"261","section":"261.11"},"headings":{"title":"Protection of Environment","part":"Identification and Listing of Hazardous Waste","section":"Criteria for listing <strong>hazardous</strong> waste."},"full_text_excerpt":"a solid <strong>waste</strong> is a hazardous waste if it meets the criteria..."}]}
        """
        let source = ECFRStatutorySource(client: StubECFRClient(result: .success(try decode(json))))
        let result = await source.lookup(StatutoryQuery(terms: "hazardous waste", jurisdiction: "Federal"))

        XCTAssertEqual(result.provisions.count, 1)
        let provision = try XCTUnwrap(result.provisions.first)
        XCTAssertEqual(provision.citation, "40 CFR § 261.11")
        XCTAssertEqual(provision.weightTier, .currencyVerifiable)
        XCTAssertEqual(provision.effectiveDate, "2023-08-09")
        XCTAssertNil(provision.currencyCaveat, "a currency-verifiable source carries no caveat")
        XCTAssertFalse(provision.text.contains("<strong>"), "HTML highlight tags are stripped")
        XCTAssertEqual(provision.heading, "Criteria for listing hazardous waste.")
    }

    func testSkipsStateSpecificQueriesWithoutHittingTheNetwork() async {
        // The stub would throw if queried — a state query must short-circuit before that.
        let source = ECFRStatutorySource(client: StubECFRClient(result: .failure(.invalidResponse)))
        let result = await source.lookup(StatutoryQuery(terms: "statute of frauds", jurisdiction: "Florida"))
        XCTAssertTrue(result.provisions.isEmpty)
        XCTAssertNil(result.note)
    }

    func testDegradesGracefullyOnError() async {
        let source = ECFRStatutorySource(client: StubECFRClient(result: .failure(.serverError(statusCode: 503))))
        let result = await source.lookup(StatutoryQuery(terms: "x", jurisdiction: "Federal"))
        XCTAssertTrue(result.provisions.isEmpty)
        XCTAssertNotNil(result.note)
    }

    func testEcfrOutranksOpenLegalCodesInTheOrchestrator() async throws {
        let ecfr = ECFRStatutorySource(client: StubECFRClient(result: .success(try decode(
            #"{"results":[{"starts_on":"2024-01-01","type":"Section","hierarchy":{"title":"29","section":"1604.11"},"headings":{"section":"Sexual harassment."},"full_text_excerpt":"Harassment on the basis of sex..."}]}"#
        ))))
        // OLC returns nothing federal here; eCFR provides the federal provision.
        let (merged, _) = await StatutorySourceOrchestrator(sources: [ecfr]).lookup(StatutoryQuery(terms: "sexual harassment", jurisdiction: "Federal"))
        XCTAssertEqual(merged.first?.weightTier, .currencyVerifiable)
        XCTAssertEqual(merged.first?.citation, "29 CFR § 1604.11")
    }

    // MARK: - Prompt rendering: verified date vs. unverified caveat

    func testSourcePacketShowsEffectiveDateForVerifiedAndCaveatForUnverified() {
        let verified = StatutoryProvision(
            sourceID: "ecfr", sourceName: "eCFR", weightTier: .currencyVerifiable,
            jurisdictionName: "CFR Title 40", citation: "40 CFR § 261.11", text: "regulatory text", effectiveDate: "2023-08-09"
        ).asLegalAuthority(jurisdictionLabel: "Federal")
        let unverified = StatutoryProvision(
            sourceID: "open-legal-codes", sourceName: "Open Legal Codes", weightTier: .convenience,
            jurisdictionName: "Florida Statutes", citation: "§ 672.201", text: "statute text",
            currencyCaveat: "Confirm against the official Florida Statutes."
        ).asLegalAuthority(jurisdictionLabel: "Florida")

        let packet = LegalResearchPromptBuilder.sourcePacket([verified, unverified])
        XCTAssertTrue(packet.contains("Effective date: 2023-08-09"), "verified regulation shows its effective date")
        XCTAssertTrue(packet.contains("no verified effective date"), "OLC statute shows the currency caveat")
    }
}

private struct StubECFRClient: ECFRClientProtocol {
    let result: Result<ECFRSearchResponse, ECFRError>
    func search(query: String, limit: Int) async throws -> ECFRSearchResponse { try result.get() }
}
