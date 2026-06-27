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
    }

    func testGovInfoMissingKeyYieldsActionableNote() async {
        let source = GovInfoStatutorySource(httpClient: ThrowingHTTPClient(), tokenStore: NoKeyStore())
        let result = await source.lookup(StatutoryQuery(terms: "bankruptcy", jurisdiction: "Federal"))
        XCTAssertTrue(result.provisions.isEmpty)
        XCTAssertTrue(result.note?.contains("Settings") ?? false)
    }
}

// MARK: - Stubs

private struct StubRegulationsGovClient: RegulationsGovClientProtocol {
    let result: Result<RegulationsGovResponse, RegulationsGovError>
    func searchDocuments(term: String, limit: Int) async throws -> RegulationsGovResponse { try result.get() }
}
private struct StubOpenStatesClient: OpenStatesClientProtocol {
    let result: Result<OpenStatesResponse, OpenStatesError>
    func searchBills(term: String, jurisdiction: String?, limit: Int) async throws -> OpenStatesResponse { try result.get() }
}
private struct StubLegiScanClient: LegiScanClientProtocol {
    let result: Result<LegiScanResponse, LegiScanError>
    func search(term: String, state: String, limit: Int) async throws -> LegiScanResponse { try result.get() }
}
private struct StubGovInfoClient: GovInfoClientProtocol {
    let result: Result<GovInfoSearchResponse, GovInfoError>
    func searchUSCode(term: String, limit: Int) async throws -> GovInfoSearchResponse { try result.get() }
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
