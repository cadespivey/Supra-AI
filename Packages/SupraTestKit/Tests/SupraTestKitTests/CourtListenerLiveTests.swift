import Foundation
import SupraNetworking
import SupraResearch
import SupraStore
import XCTest

/// Live, opt-in integration test of the APP's CourtListener client against the
/// real courtlistener.com v4 API, exercised through the exact production stack:
/// `CourtListenerClient` → `AuthorizedHTTPClient` (host allowlist + rate limiter
/// + network-request audit log). It is SKIPPED unless `COURTLISTENER_API_TOKEN`
/// is set, so it never blocks normal test runs or CI.
///
///     COURTLISTENER_API_TOKEN=<your-token> \
///     DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
///       swift test --package-path Packages/SupraTestKit --filter CourtListenerLiveTests
///
/// The query targets a verified real Florida authority used by the construction-
/// lien matter (Deen v. Tampa Port Authority, 207 So. 2d 688 (Fla. 1967)), so a
/// healthy connection returns it.
final class CourtListenerLiveTests: XCTestCase {

    /// In-memory key store so the live test never touches the real Keychain.
    private struct StaticTokenStore: APIKeyStoreProtocol {
        let token: String
        func saveCourtListenerToken(_ token: String) throws {}
        func loadCourtListenerToken() throws -> String? { token }
        func deleteCourtListenerToken() throws {}
        func hasCourtListenerToken() throws -> Bool { !token.isEmpty }
    }

    func testLiveCourtListenerSearchReturnsKnownFloridaAuthority() async throws {
        let token = (ProcessInfo.processInfo.environment["COURTLISTENER_API_TOKEN"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipIf(token.isEmpty, "Set COURTLISTENER_API_TOKEN to run the live CourtListener test.")

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLLive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Production CourtListener stack: token store, host allowlist, rate limiter,
        // and the network-request audit log (backed by a throwaway store).
        let store = try SupraStore(url: base.appendingPathComponent("cl.sqlite"))
        let logger = NetworkRequestLogger(repository: store.networkRequests)
        let client = CourtListenerClient(
            httpClient: AuthorizedHTTPClient(
                keyStore: StaticTokenStore(token: token),
                policy: NetworkPolicyService(),
                logger: logger
            )
        )

        let response = try await client.searchOpinions(
            CourtListenerSearchRequest(query: "Deen v. Tampa Port Authority")
        )

        XCTAssertGreaterThan(response.count, 0, "CourtListener returned no results for a known Florida authority")
        XCTAssertTrue(
            response.results.contains { ($0.caseName ?? "").localizedCaseInsensitiveContains("Tampa Port Authority") },
            "Expected Deen v. Tampa Port Authority among the live results; got: \(response.results.prefix(5).map { $0.caseName ?? "?" })"
        )

        // The request flowed through the app's audited, allowlisted client.
        let audited = try store.networkRequests.fetchRecent(limit: 10)
        XCTAssertTrue(
            audited.contains { $0.domain.contains("courtlistener.com") && $0.approved && ($0.statusCode ?? 0) / 100 == 2 },
            "Expected an approved 2xx CourtListener request in the network audit log; got: \(audited.map { "\($0.domain) \($0.statusCode ?? -1)" })"
        )
    }
}
