import Foundation
import SupraNetworking
import SupraResearch
import XCTest

final class LegalDataKeyVerifierTests: XCTestCase {

    func testAcceptedKeyIsValid() async {
        let verifier = LegalDataKeyVerifier(httpClient: StubHTTP(status: 200), tokenStore: KeyStore(key: "k"))
        let result = await verifier.verify(.openStates)
        XCTAssertEqual(result, .valid)
    }

    func testRejectedKeyIsInvalid() async {
        let verifier = LegalDataKeyVerifier(httpClient: StubHTTP(status: 403), tokenStore: KeyStore(key: "bad"))
        guard case .invalid = await verifier.verify(.regulationsGov) else { return XCTFail("expected invalid") }
    }

    func testServerErrorIsUnreachable() async {
        let verifier = LegalDataKeyVerifier(httpClient: StubHTTP(status: 503), tokenStore: KeyStore(key: "k"))
        guard case .unreachable = await verifier.verify(.govInfo) else { return XCTFail("expected unreachable") }
    }

    func testGovInfoVerificationUsesProductionSearchRequest() async throws {
        let http = RecordingHTTP(status: 200)
        let verifier = LegalDataKeyVerifier(httpClient: http, tokenStore: KeyStore(key: "k"))

        let result = await verifier.verify(.govInfo)
        XCTAssertEqual(result, .valid)

        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.govinfo.gov/search")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "k")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["query"] as? String, "collection:USCODE")
        XCTAssertEqual(body["pageSize"] as? Int, 1)
        XCTAssertEqual(body["offsetMark"] as? String, "*")
    }

    func testMissingKeyShortCircuits() async {
        let verifier = LegalDataKeyVerifier(httpClient: StubHTTP(status: 500), tokenStore: KeyStore(key: nil))
        let result = await verifier.verify(.openStates)
        XCTAssertEqual(result, .missingKey)
    }



    func testKeylessSourceReachableIsValid() async {
        let verifier = LegalDataKeyVerifier(httpClient: StubHTTP(status: 200), tokenStore: KeyStore())
        let result = await verifier.verifyReachable(.eCFR)
        XCTAssertEqual(result, .valid, "a responding key-less source verifies as reachable")
    }

    func testKeylessSourceUnreachable() async {
        let verifier = LegalDataKeyVerifier(httpClient: StubHTTP(status: 503), tokenStore: KeyStore())
        guard case .unreachable = await verifier.verifyReachable(.federalRegister) else {
            return XCTFail("a 5xx key-less source should read as unreachable")
        }
    }

    func testCourtListenerValidAndInvalidAndMissing() async {
        let validResult = await LegalDataKeyVerifier(httpClient: StubHTTP(status: 200), tokenStore: KeyStore(clToken: "t")).verifyCourtListener()
        XCTAssertEqual(validResult, .valid)

        let invalidResult = await LegalDataKeyVerifier(httpClient: StubHTTP(status: 401), tokenStore: KeyStore(clToken: "t")).verifyCourtListener()
        guard case .invalid = invalidResult else { return XCTFail("expected invalid") }

        let missingResult = await LegalDataKeyVerifier(httpClient: StubHTTP(status: 200), tokenStore: KeyStore(clToken: nil)).verifyCourtListener()
        XCTAssertEqual(missingResult, .missingKey)
    }
}

private struct StubHTTP: AuthorizedHTTPClientProtocol {
    let status: Int
    var body: String = "{}"

    func send(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
        respond(request)
    }
    func sendUnauthenticated(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
        respond(request)
    }
    private func respond(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class RecordingHTTP: AuthorizedHTTPClientProtocol, @unchecked Sendable {
    let status: Int
    var body: String = "{}"
    private(set) var lastRequest: URLRequest?

    init(status: Int) {
        self.status = status
    }

    func send(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
        respond(request)
    }

    func sendUnauthenticated(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
        respond(request)
    }

    private func respond(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        lastRequest = request
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private struct KeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    var key: String? = nil
    var clToken: String? = nil
    func saveCourtListenerToken(_ token: String) throws {}
    func loadCourtListenerToken() throws -> String? { clToken }
    func deleteCourtListenerToken() throws {}
    func hasCourtListenerToken() throws -> Bool { clToken != nil }
    func loadAPIKey(for service: APIKeyService) throws -> String? { key }
    func hasAPIKey(for service: APIKeyService) throws -> Bool { key != nil }
}
