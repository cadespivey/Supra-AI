import Foundation
import SupraNetworking
import SupraResearch
import XCTest

/// Covers the key'd legal-data sources (govinfo, OpenStates, LegiScan, Regulations.gov): result
/// mapping via stub clients, and the missing-key degradation path (no key → empty + a note).
final class KeyedSourceTests: XCTestCase {

    // MARK: - Regulations.gov (developments, regulatory)

    func testRegulationsGovMapsDocumentToRegulatoryDevelopment() async throws {
        let json = """
        {"data":[{"id":"EPA-HQ-2026-0001-0001","type":"documents","attributes":{"title":"Hazardous Waste Rule","documentType":"Proposed Rule","postedDate":"2026-06-01","docketId":"EPA-HQ-2026-0001","frDocNum":"2026-12993","agencyId":"EPA"}}]}
        """
        let response = try JSONDecoder().decode(RegulationsGovResponse.self, from: Data(json.utf8))
        let source = RegulationsGovSource(client: StubRegulationsGovClient(result: .success(response)))
        let result = await source.lookup(LegalDevelopmentQuery(terms: "hazardous waste", jurisdiction: "Federal"))
        let development = try XCTUnwrap(result.developments.first)
        XCTAssertEqual(development.kind, .regulatory)
        XCTAssertTrue(development.identifier.contains("2026-12993"))
        XCTAssertTrue(development.status?.contains("Proposed Rule") ?? false)
        XCTAssertEqual(development.date, "2026-06-01")
    }

    func testRegulationsGovDocketIDDetection() {
        XCTAssertEqual(RegulationsGovSource.docketID(in: "status of EPA-HQ-OW-2021-0602 rulemaking"), "EPA-HQ-OW-2021-0602")
        XCTAssertEqual(RegulationsGovSource.docketID(in: "what's new in fda-2023-n-1234?"), "FDA-2023-N-1234")
        XCTAssertNil(RegulationsGovSource.docketID(in: "hazardous waste manifests"))
        // Ordinary hyphenated word-year-number phrases must NOT read as dockets.
        XCTAssertNil(RegulationsGovSource.docketID(in: "the Order-2021-05-14 deadline"))
        XCTAssertNil(RegulationsGovSource.docketID(in: "under contract-2022-100 terms"))
        XCTAssertNil(RegulationsGovSource.docketID(in: "case No-2019-045 was continued"))
    }

    func testRegulationsGovDocketQueryReturnsDocketTimeline() async throws {
        let documentsJSON = """
        {"data":[{"id":"EPA-HQ-OW-2021-0602-0501","type":"documents","attributes":{"title":"Final Rule","documentType":"Rule","postedDate":"2026-05-01","docketId":"EPA-HQ-OW-2021-0602","frDocNum":"2026-09999","agencyId":"EPA"}}]}
        """
        let documents = try JSONDecoder().decode(RegulationsGovResponse.self, from: Data(documentsJSON.utf8))
        let docket = RegulationsGovDocket(
            id: "EPA-HQ-OW-2021-0602",
            attributes: .init(title: "Clean Water Act Rulemaking", docketType: "Rulemaking", agencyId: "EPA", modifyDate: "2026-05-02")
        )
        let source = RegulationsGovSource(client: StubRegulationsGovClient(
            result: .failure(.invalidResponse),   // keyword search must NOT be hit
            docket: docket,
            docketDocuments: documents
        ))
        let result = await source.lookup(LegalDevelopmentQuery(terms: "status of EPA-HQ-OW-2021-0602", jurisdiction: "Federal"))
        XCTAssertEqual(result.developments.count, 2)
        XCTAssertEqual(result.developments.first?.identifier, "Docket EPA-HQ-OW-2021-0602")
        XCTAssertTrue(result.developments.first?.url?.contains("/docket/") ?? false)
        XCTAssertTrue(result.developments[1].identifier.contains("2026-09999"))
    }

    func testRegulationsGovSkipsStateQueries() async {
        let source = RegulationsGovSource(client: StubRegulationsGovClient(result: .failure(.invalidResponse)))
        let result = await source.lookup(LegalDevelopmentQuery(terms: "x", jurisdiction: "Florida"))
        XCTAssertTrue(result.developments.isEmpty)
        XCTAssertNil(result.note)
    }

    func testRegulationsGovMissingKeyYieldsActionableNote() async {
        let source = RegulationsGovSource(httpClient: ThrowingHTTPClient(), tokenStore: NoKeyStore())
        let result = await source.lookup(LegalDevelopmentQuery(terms: "x", jurisdiction: "Federal"))
        XCTAssertTrue(result.developments.isEmpty)
        XCTAssertTrue(result.note?.contains("Settings") ?? false)
    }

    // MARK: - OpenStates (developments, legislative)

    func testOpenStatesMapsBillToLegislativeDevelopment() async throws {
        let json = """
        {"results":[{"id":"ocd-bill/1","identifier":"HB 123","title":"An Act relating to sales","session":"2026","jurisdiction":{"name":"Florida"},"latest_action_date":"2026-03-04","latest_action_description":"Passed House","openstates_url":"https://openstates.org/fl/bills/2026/HB123/"}]}
        """
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(OpenStatesResponse.self, from: Data(json.utf8))
        let source = OpenStatesSource(client: StubOpenStatesClient(result: .success(response)))
        let result = await source.lookup(LegalDevelopmentQuery(terms: "sales", jurisdiction: "Florida"))
        let development = try XCTUnwrap(result.developments.first)
        XCTAssertEqual(development.kind, .legislative)
        XCTAssertEqual(development.jurisdiction, "Florida")
        XCTAssertTrue(development.identifier.contains("HB 123"))
        XCTAssertEqual(development.status, "Passed House")
    }

    // MARK: - LegiScan (developments, legislative; quirky numeric-keyed response)

    func testLegiScanDecodesNumericKeyedResultsSkippingSummary() async throws {
        let json = """
        {"status":"OK","searchresult":{"summary":{"count":1,"page":"1"},"0":{"bill_id":12345,"bill_number":"HB123","state":"FL","title":"Sales Act","last_action":"Passed House","last_action_date":"2026-03-04","url":"https://legiscan.com/FL/bill/HB123"}}}
        """
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(LegiScanResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.results.count, 1, "the 'summary' entry is skipped, the bill is kept")
        let source = LegiScanSource(client: StubLegiScanClient(result: .success(response)))
        let lookup = await source.lookup(LegalDevelopmentQuery(terms: "sales", jurisdiction: "Florida"))
        let development = try XCTUnwrap(lookup.developments.first)
        XCTAssertEqual(development.kind, .legislative)
        XCTAssertTrue(development.identifier.contains("HB123"))
        XCTAssertEqual(development.date, "2026-03-04")
    }

    func testBillReferenceDetection() {
        XCTAssertEqual(BillReference.billNumber(in: "what is the status of HB 123 in Florida"), "HB 123")
        XCTAssertEqual(BillReference.billNumber(in: "track h.r. 40 reparations"), "HR 40")
        XCTAssertEqual(BillReference.billNumber(in: "sb-456 amendments"), "SB 456")
        XCTAssertNil(BillReference.billNumber(in: "new privacy legislation this session"))
    }

    func testLegiScanNamedBillIsEnrichedWithDetail() async throws {
        let json = """
        {"status":"OK","searchresult":{"summary":{"count":1},"0":{"bill_id":12345,"bill_number":"HB123","state":"FL","title":"Sales Act","last_action":"Passed House","last_action_date":"2026-03-04","url":"https://legiscan.com/FL/bill/HB123"}}}
        """
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(LegiScanResponse.self, from: Data(json.utf8))
        let detail = LegiScanBillDetail(
            description: "Revises Florida's sales-tax remittance schedule for small sellers.",
            statusDate: "2026-03-05",
            sponsors: [.init(name: "Rep. Smith"), .init(name: "Rep. Jones")],
            texts: [.init(stateLink: "https://flsenate.gov/HB123/text", url: nil)]
        )
        let source = LegiScanSource(client: StubLegiScanClient(result: .success(response), billDetail: detail))
        let lookup = await source.lookup(LegalDevelopmentQuery(terms: "status of HB 123", jurisdiction: "Florida"))
        let development = try XCTUnwrap(lookup.developments.first)
        XCTAssertTrue(development.summary?.contains("sales-tax remittance") ?? false)
        XCTAssertTrue(development.summary?.contains("Rep. Smith") ?? false)
        XCTAssertEqual(development.date, "2026-03-05")
        XCTAssertEqual(development.url, "https://flsenate.gov/HB123/text")
    }

    func testOpenStatesAbstractBecomesSummary() async throws {
        let json = """
        {"results":[{"id":"ocd-bill/1","identifier":"HB 123","title":"An Act relating to sales","session":"2026","jurisdiction":{"name":"Florida"},"latest_action_date":"2026-03-04","latest_action_description":"Passed House","openstates_url":"https://openstates.org/fl/bills/2026/HB123/","abstracts":[{"abstract":"Revises the sales-tax remittance schedule for small sellers."}]}]}
        """
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(OpenStatesResponse.self, from: Data(json.utf8))
        let source = OpenStatesSource(client: StubOpenStatesClient(result: .success(response)))
        let result = await source.lookup(LegalDevelopmentQuery(terms: "sales", jurisdiction: "Florida"))
        let development = try XCTUnwrap(result.developments.first)
        XCTAssertTrue(development.summary?.contains("remittance schedule") ?? false, "abstract outranks the bare session note")
    }

    // MARK: - govinfo (statutory, currency-verifiable)

    func testGovInfoMapsUSCodeResultToCurrencyVerifiableProvision() async throws {
        let json = """
        {"results":[{"title":"United States Code, 2023 Edition, Title 11 - BANKRUPTCY","packageId":"USCODE-2023-title11","dateIssued":"2024-01-03","collectionCode":"USCODE"}]}
        """
        let response = try JSONDecoder().decode(GovInfoSearchResponse.self, from: Data(json.utf8))
        let source = GovInfoStatutorySource(client: StubGovInfoClient(result: .success(response)))
        let result = await source.lookup(StatutoryQuery(terms: "bankruptcy", jurisdiction: "Federal"))
        let provision = try XCTUnwrap(result.provisions.first)
        XCTAssertEqual(provision.weightTier, .currencyVerifiable)
        XCTAssertEqual(provision.effectiveDate, "2024-01-03")
        XCTAssertNil(provision.currencyCaveat)
        XCTAssertTrue(provision.url?.contains("USCODE-2023-title11") ?? false)
        XCTAssertFalse(provision.isCitableAuthority, "govinfo search hits are package locators until exact section text is fetched")
        XCTAssertTrue(result.note?.contains("package-level") ?? false)
    }

    func testGovInfoMissingKeyYieldsActionableNote() async {
        let source = GovInfoStatutorySource(httpClient: ThrowingHTTPClient(), tokenStore: NoKeyStore())
        let result = await source.lookup(StatutoryQuery(terms: "bankruptcy", jurisdiction: "Federal"))
        XCTAssertTrue(result.provisions.isEmpty)
        XCTAssertTrue(result.note?.contains("Settings") ?? false)
    }

    func testGovInfoGranuleHitFetchesSectionTextAndBecomesCitable() async throws {
        let json = """
        {"results":[{"title":"11 U.S.C. Sec. 701 - Interim trustee","packageId":"USCODE-2023-title11","granuleId":"USCODE-2023-title11-chap7-subchapI-sec701","dateIssued":"2024-01-03","collectionCode":"USCODE"}]}
        """
        let response = try JSONDecoder().decode(GovInfoSearchResponse.self, from: Data(json.utf8))
        let source = GovInfoStatutorySource(client: StubGovInfoClient(
            result: .success(response),
            granuleText: "<html><body><p>§ 701. Interim trustee. (a) Promptly after the order for relief…</p></body></html>"
        ))
        let result = await source.lookup(StatutoryQuery(terms: "interim trustee", jurisdiction: "Federal"))
        let provision = try XCTUnwrap(result.provisions.first)
        XCTAssertTrue(provision.isCitableAuthority, "fetched official section text is citable primary law")
        XCTAssertEqual(provision.citation, "11 U.S.C. § 701")
        XCTAssertTrue(provision.text.contains("Interim trustee"))
        XCTAssertFalse(provision.text.contains("<p>"), "HTML is stripped")
        XCTAssertNil(result.note, "no locator-only caveat when real section text was retrieved")
    }

    func testGovInfoUSCCitationDerivation() {
        XCTAssertEqual(
            GovInfoStatutorySource.uscCitation(packageId: "USCODE-2023-title11", granuleId: "USCODE-2023-title11-chap7-subchapI-sec701"),
            "11 U.S.C. § 701"
        )
        XCTAssertEqual(
            GovInfoStatutorySource.uscCitation(packageId: "USCODE-2011-title15", granuleId: "USCODE-2011-title15-chap2B-sec78j-1"),
            "15 U.S.C. § 78j-1"
        )
        XCTAssertNil(GovInfoStatutorySource.uscCitation(packageId: "USCODE-2023-title11", granuleId: "USCODE-2023-title11-chap7"))
        // An alphabetic granule suffix must not fold into the citation.
        XCTAssertEqual(
            GovInfoStatutorySource.uscCitation(packageId: "USCODE-2011-title15", granuleId: "USCODE-2011-title15-chap2B-sec78j-1-note"),
            "15 U.S.C. \u{00A7} 78j-1"
        )
    }
}

// MARK: - Stubs

private struct StubRegulationsGovClient: RegulationsGovClientProtocol {
    let result: Result<RegulationsGovResponse, RegulationsGovError>
    var docket: RegulationsGovDocket?
    var docketDocuments: RegulationsGovResponse?
    func searchDocuments(term: String, limit: Int) async throws -> RegulationsGovResponse { try result.get() }
    func fetchDocket(id: String) async throws -> RegulationsGovDocket {
        guard let docket else { throw RegulationsGovError.invalidResponse }
        return docket
    }
    func documentsForDocket(id: String, limit: Int) async throws -> RegulationsGovResponse {
        guard let docketDocuments else { throw RegulationsGovError.invalidResponse }
        return docketDocuments
    }
}
private struct StubOpenStatesClient: OpenStatesClientProtocol {
    let result: Result<OpenStatesResponse, OpenStatesError>
    func searchBills(term: String, jurisdiction: String?, limit: Int) async throws -> OpenStatesResponse { try result.get() }
}
private struct StubLegiScanClient: LegiScanClientProtocol {
    let result: Result<LegiScanResponse, LegiScanError>
    var billDetail: LegiScanBillDetail?
    func search(term: String, state: String, limit: Int) async throws -> LegiScanResponse { try result.get() }
    func getBill(id: Int) async throws -> LegiScanBillDetail {
        guard let billDetail else { throw LegiScanError.invalidResponse }
        return billDetail
    }
}
private struct StubGovInfoClient: GovInfoClientProtocol {
    let result: Result<GovInfoSearchResponse, GovInfoError>
    var granuleText: String?
    func searchUSCode(term: String, limit: Int) async throws -> GovInfoSearchResponse { try result.get() }
    func fetchGranuleText(packageId: String, granuleId: String) async throws -> String {
        guard let granuleText else { throw GovInfoError.invalidResponse }
        return granuleText
    }
}

private struct NoKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    func saveCourtListenerToken(_ token: String) throws {}
    func loadCourtListenerToken() throws -> String? { nil }
    func deleteCourtListenerToken() throws {}
    func hasCourtListenerToken() throws -> Bool { false }
    func loadAPIKey(for service: APIKeyService) throws -> String? { nil }
    func hasAPIKey(for service: APIKeyService) throws -> Bool { false }
}

private struct ThrowingHTTPClient: AuthorizedHTTPClientProtocol {
    func send(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
        throw AuthorizedHTTPClientError.invalidResponse
    }
    func sendUnauthenticated(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
        throw AuthorizedHTTPClientError.invalidResponse
    }
}
