import SupraNetworking
import SupraResearch
import XCTest

final class SupraResearchTests: XCTestCase {
    func testModuleExposesCourtListenerTokenService() {
        XCTAssertEqual(SupraResearchModule.courtListenerTokenService, "com.supraai.courtlistener")
    }

    func testJurisdictionCatalogResolvesDuvalCountyFloridaScope() throws {
        let option = try XCTUnwrap(
            JurisdictionCatalog.shared.bestMatch(
                jurisdiction: "Florida",
                court: "Circuit Court of the Fourth Judicial Circuit in and for Duval County"
            )
        )

        XCTAssertEqual(option.state, "Florida")
        XCTAssertEqual(option.county, "Duval County")
        let scope = JurisdictionCatalog.shared.authorityScope(for: option)
        XCTAssertTrue(scope.mandatoryAuthorities.contains("Fifth District Court of Appeal of Florida"))
        XCTAssertTrue(scope.mandatoryAuthorities.contains("Supreme Court of Florida"))
        XCTAssertTrue(scope.mandatoryAuthorities.contains("Supreme Court of the United States for federal questions"))
        XCTAssertTrue(scope.courtListenerIDs.contains("fla"))
        XCTAssertTrue(scope.courtListenerIDs.contains("fladistctapp"))
        XCTAssertTrue(scope.courtListenerIDs.contains("scotus"))
    }

    func testJurisdictionCatalogResolvesFederalDistrictScope() throws {
        let option = try XCTUnwrap(
            JurisdictionCatalog.shared.bestMatch(
                jurisdiction: "Eleventh Circuit",
                court: "United States District Court for the Middle District of Florida"
            )
        )

        let scope = JurisdictionCatalog.shared.authorityScope(for: option)
        XCTAssertTrue(scope.mandatoryAuthorities.contains("United States Court of Appeals for the Eleventh Circuit"))
        XCTAssertTrue(scope.mandatoryAuthorities.contains("Supreme Court of the United States"))
        XCTAssertTrue(scope.courtListenerIDs.contains("flmd"))
        XCTAssertTrue(scope.courtListenerIDs.contains("ca11"))
        XCTAssertTrue(scope.courtListenerIDs.contains("scotus"))
    }

    func testCourtListenerSearchBuildsOpinionQueryAndPreservesRawResultJSON() async throws {
        let httpClient = StubHTTPClient(
            statusCode: 200,
            data: Data(Self.searchResponseJSON.utf8)
        )
        let client = CourtListenerClient(httpClient: httpClient)

        let response = try await client.searchOpinions(
            CourtListenerSearchRequest(query: "contract breach", orderBy: "score desc")
        )

        let lastURL = await httpClient.lastURL()
        let requestURL = try XCTUnwrap(lastURL)
        let queryItems = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(requestURL.scheme, "https")
        XCTAssertEqual(requestURL.host, "www.courtlistener.com")
        XCTAssertEqual(requestURL.path, "/api/rest/v4/search")
        XCTAssertEqual(query["q"], "contract breach")
        XCTAssertEqual(query["type"], "o")
        XCTAssertEqual(query["highlight"], "on")
        XCTAssertEqual(query["order_by"], "score desc")
        XCTAssertEqual(response.count, 1)
        XCTAssertEqual(response.results.single?.caseName, "Specter v. Hardman")
        XCTAssertEqual(response.results.single?.citation, ["101 Haw. 235", "65 P.3d 182"])
        XCTAssertEqual(response.results.single?.opinions.single?.id, 6489975)
        XCTAssertTrue(response.results.single?.rawResultJSON.contains("extra_unknown") ?? false)
        XCTAssertEqual(
            CourtListenerMapper.displayURL(for: try XCTUnwrap(response.results.single))?.absoluteString,
            "https://www.courtlistener.com/opinion/6613686/specter-v-hardman/"
        )
    }

    func testCourtListenerSearchAddsSupportedResearchFilters() async throws {
        let httpClient = StubHTTPClient(
            statusCode: 200,
            data: Data(Self.searchResponseJSON.utf8)
        )
        let client = CourtListenerClient(httpClient: httpClient)

        _ = try await client.searchOpinions(
            CourtListenerSearchRequest(
                query: "non-compete",
                courtIDs: ["ca9"],
                dateFiledAfter: "2020-01-01",
                dateFiledBefore: "2024-12-31",
                citation: "410 U.S. 113"
            )
        )

        let lastURL = await httpClient.lastURL()
        let requestURL = try XCTUnwrap(lastURL)
        let queryItems = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(query["court"], "ca9")
        XCTAssertEqual(query["filed_after"], "2020-01-01")
        XCTAssertEqual(query["filed_before"], "2024-12-31")
        XCTAssertEqual(query["citation"], "410 U.S. 113")
    }

    func testCourtListenerClientRejectsInvalidCursorHostBeforeSending() async throws {
        let httpClient = StubHTTPClient(statusCode: 200, data: Data(Self.searchResponseJSON.utf8))
        let client = CourtListenerClient(httpClient: httpClient)
        let cursor = try XCTUnwrap(URL(string: "https://example.com/api/rest/v4/search/?cursor=abc"))

        do {
            _ = try await client.searchOpinions(CourtListenerSearchRequest(query: "", cursorURL: cursor))
            XCTFail("Expected invalid cursor host to throw.")
        } catch CourtListenerError.invalidCursorHost {
            let count = await httpClient.requestCount()
            XCTAssertEqual(count, 0)
        }
    }

    func testCourtListenerClientMapsHTTPStatuses() async throws {
        let cases: [(Int, CourtListenerError)] = [
            (401, .authenticationFailed),
            (403, .authenticationFailed),
            (429, .throttled(retryAfter: nil)),
            (503, .serverError(statusCode: 503)),
            (302, .invalidResponse)
        ]

        for (statusCode, expectedError) in cases {
            let httpClient = StubHTTPClient(statusCode: statusCode, data: Data())
            let client = CourtListenerClient(httpClient: httpClient)

            do {
                _ = try await client.searchOpinions(CourtListenerSearchRequest(query: "contract"))
                XCTFail("Expected status \(statusCode) to throw.")
            } catch let error as CourtListenerError {
                XCTAssertEqual(error, expectedError)
            }
        }
    }

    func testCourtListenerClientMapsNetworkingErrors() async throws {
        let cases: [(Error, CourtListenerError)] = [
            (AuthorizedHTTPClientError.missingToken, .missingToken),
            (AuthorizedHTTPClientError.invalidResponse, .invalidResponse),
            (NetworkPolicyError.hostNotAllowed("example.com"), .blockedByNetworkPolicy),
            (
                NetworkPolicyError.localRateLimitExceeded(
                    .init(
                        requestsLastMinute: 5,
                        requestsLastHour: 5,
                        requestsLastDay: 5,
                        limits: .init()
                    )
                ),
                .localRateLimitExceeded
            )
        ]

        for (thrownError, expectedError) in cases {
            let httpClient = StubHTTPClient(statusCode: 200, data: Data(), thrownError: thrownError)
            let client = CourtListenerClient(httpClient: httpClient)

            do {
                _ = try await client.searchOpinions(CourtListenerSearchRequest(query: "contract"))
                XCTFail("Expected networking error to throw.")
            } catch let error as CourtListenerError {
                XCTAssertEqual(error, expectedError)
            }
        }
    }

    private static let searchResponseJSON = """
    {
      "count": 1,
      "next": "https://www.courtlistener.com/api/rest/v4/search/?cursor=abc&q=contract",
      "previous": null,
      "results": [
        {
          "absolute_url": "/opinion/6613686/specter-v-hardman/",
          "caseName": "Specter v. Hardman",
          "caseNameFull": "Specter v. Hardman",
          "citation": ["101 Haw. 235", "65 P.3d 182"],
          "citeCount": 0,
          "cluster_id": 6613686,
          "court": "Hawaii Intermediate Court of Appeals",
          "court_citation_string": "Haw. App.",
          "court_id": "hawapp",
          "dateFiled": "2003-01-10",
          "docketNumber": "24158",
          "docket_id": 63544014,
          "judge": "",
          "lexisCite": "",
          "neutralCite": "",
          "opinions": [
            {
              "author_id": null,
              "download_url": null,
              "id": 6489975,
              "local_path": null,
              "per_curiam": false,
              "sha1": "",
              "snippet": "Affirmed",
              "type": "lead-opinion"
            }
          ],
          "posture": "",
          "procedural_history": "",
          "source": "U",
          "status": "Published",
          "suitNature": "",
          "syllabus": "",
          "meta": { "score": { "bm25": 2.13 } },
          "extra_unknown": "preserve me"
        }
      ]
    }
    """
}

private actor StubHTTPClient: AuthorizedHTTPClientProtocol {
    private let statusCode: Int
    private let data: Data
    private let thrownError: Error?
    private var requests: [URLRequest] = []

    init(statusCode: Int, data: Data, thrownError: Error? = nil) {
        self.statusCode = statusCode
        self.data = data
        self.thrownError = thrownError
    }

    func send(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let thrownError {
            throw thrownError
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    func lastURL() -> URL? {
        requests.last?.url
    }

    func requestCount() -> Int {
        requests.count
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
