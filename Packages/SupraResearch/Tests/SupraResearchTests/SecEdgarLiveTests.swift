import Foundation
import SupraNetworking
import XCTest
@testable import SupraResearch

/// OPT-IN live probes against real SEC EDGAR. Skipped unless
/// `SUPRA_LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS=true` AND
/// `SUPRA_SEC_EDGAR_USER_AGENT` is set — CI and normal runs never touch the
/// public service.
final class SecEdgarLiveTests: XCTestCase {
    func testLiveAppleSubmissionsProbe() async throws {
        let configuration = LegalDataConnectorConfiguration.fromEnvironment()
        try XCTSkipUnless(configuration.liveTestsEnabled, "live tests are opt-in")
        try XCTSkipUnless(configuration.secEdgarUserAgent != nil, "SUPRA_SEC_EDGAR_USER_AGENT required")

        let client = LivePolicyHTTPClient()
        let connector = SecEdgarConnector(
            httpClient: client,
            configuration: configuration,
            cache: NoopConnectorCache()
        )
        let submissions = try await connector.getCompanySubmissions("0000320193")
        XCTAssertEqual(submissions.company.cik, "0000320193")
        XCTAssertFalse(submissions.recentFilings.isEmpty)
    }
}

/// Minimal live client: policy-validated URLSession, no token, no logger —
/// live tests are store-free and these sources are public.
struct LivePolicyHTTPClient: AuthorizedHTTPClientProtocol {
    private let policy = NetworkPolicyService()

    func send(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
        throw LegalDataConnectorError(
            kind: .config, connectorName: "live-test", operation: "send",
            message: "connectors must not use the authenticated send path"
        )
    }

    func sendUnauthenticated(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        try policy.validate(url)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
