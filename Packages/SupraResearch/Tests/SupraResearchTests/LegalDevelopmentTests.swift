import Foundation
import SupraResearch
import XCTest

final class LegalDevelopmentTests: XCTestCase {

    // MARK: - Federal Register source

    func testFederalRegisterMapsToRegulatoryDevelopment() async throws {
        let json = """
        {"count":1,"results":[{"document_number":"2026-12993","title":"Hazardous Waste Listing Rule","type":"Proposed Rule","abstract":"EPA proposes new criteria.","html_url":"https://www.federalregister.gov/d/2026-12993","publication_date":"2026-06-29","agencies":[{"name":"Environmental Protection Agency"}]}]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(FederalRegisterResponse.self, from: Data(json.utf8))
        let source = FederalRegisterSource(client: StubFRClient(result: .success(response)))

        let result = await source.lookup(LegalDevelopmentQuery(terms: "hazardous waste", jurisdiction: "Federal"))
        XCTAssertEqual(result.developments.count, 1)
        let development = try XCTUnwrap(result.developments.first)
        XCTAssertEqual(development.kind, .regulatory)
        XCTAssertEqual(development.jurisdiction, "Federal")
        XCTAssertEqual(development.date, "2026-06-29")
        XCTAssertTrue(development.status?.contains("Proposed Rule") ?? false)
        XCTAssertTrue(development.status?.contains("Environmental Protection Agency") ?? false)
        XCTAssertTrue(development.identifier.contains("2026-12993"))
    }

    func testFederalRegisterSkipsStateSpecificQueries() async {
        let source = FederalRegisterSource(client: StubFRClient(result: .failure(.invalidResponse)))
        let result = await source.lookup(LegalDevelopmentQuery(terms: "x", jurisdiction: "Florida"))
        XCTAssertTrue(result.developments.isEmpty)
        XCTAssertNil(result.note)
    }

    func testFederalRegisterDegradesOnError() async {
        let source = FederalRegisterSource(client: StubFRClient(result: .failure(.serverError(statusCode: 503))))
        let result = await source.lookup(LegalDevelopmentQuery(terms: "x", jurisdiction: "Federal"))
        XCTAssertTrue(result.developments.isEmpty)
        XCTAssertNotNil(result.note)
    }

    // MARK: - Orchestrator

    func testOrchestratorDedupsAndSortsByDateDescending() async {
        let older = development(id: "a", date: "2026-01-01")
        let newer = development(id: "b", date: "2026-06-01")
        let duplicate = development(id: "b", date: "2026-06-01")
        let (merged, _) = await LegalDevelopmentOrchestrator(sources: [
            StubDevSource(developments: [older, newer]),
            StubDevSource(developments: [duplicate])
        ]).lookup(LegalDevelopmentQuery(terms: "x"))

        XCTAssertEqual(merged.count, 2, "the duplicate is removed")
        XCTAssertEqual(merged.first?.identifier, "b", "most recent first")
    }

    // MARK: - Formatter (non-citable section)

    func testFormatterProducesLabeledNonCitableSection() throws {
        let section = try XCTUnwrap(LegalDevelopmentFormatter.section(developments: [development(id: "x", date: "2026-06-01")]))
        XCTAssertTrue(section.contains("not authority"), "the section is explicitly marked non-citable")
        XCTAssertTrue(section.contains("Rulemaking"))
        XCTAssertTrue(section.contains("https://x/x"))
    }

    func testFormatterReturnsNilForEmpty() {
        XCTAssertNil(LegalDevelopmentFormatter.section(developments: []))
    }

    // MARK: - Helpers

    private func development(id: String, date: String) -> LegalDevelopment {
        LegalDevelopment(sourceID: "fr", sourceName: "FR", kind: .regulatory, identifier: id,
                         title: "Title \(id)", jurisdiction: "Federal", status: "Proposed Rule",
                         date: date, url: "https://x/\(id)")
    }
}

private struct StubFRClient: FederalRegisterClientProtocol {
    let result: Result<FederalRegisterResponse, FederalRegisterError>
    func search(query: String, limit: Int) async throws -> FederalRegisterResponse { try result.get() }
}

private struct StubDevSource: LegalDevelopmentSource {
    let id = "stub"
    let displayName = "Stub"
    let kind: LegalDevelopmentKind = .regulatory
    let developments: [LegalDevelopment]
    func lookup(_ query: LegalDevelopmentQuery) async -> LegalDevelopmentLookupResult {
        LegalDevelopmentLookupResult(developments: developments)
    }
}
