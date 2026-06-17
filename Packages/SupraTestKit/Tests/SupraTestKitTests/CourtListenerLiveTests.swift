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
/// Each probe is one matter's verified lead authority (confirmed live on
/// CourtListener 2026-06-17), so a healthy connection returns it as a hit.
final class CourtListenerLiveTests: XCTestCase {

    /// In-memory key store so the live test never touches the real Keychain.
    private struct StaticTokenStore: APIKeyStoreProtocol {
        let token: String
        func saveCourtListenerToken(_ token: String) throws {}
        func loadCourtListenerToken() throws -> String? { token }
        func deleteCourtListenerToken() throws {}
        func hasCourtListenerToken() throws -> Bool { !token.isEmpty }
    }

    /// One verified authority per seeded matter.
    private struct AuthorityProbe {
        let matter: String
        let query: String
        let expectedCaseSubstring: String
    }

    private static let probes: [AuthorityProbe] = [
        AuthorityProbe(matter: "construction-lien",
                       query: "Deen v. Tampa Port Authority",
                       expectedCaseSubstring: "Tampa Port Authority"),
        AuthorityProbe(matter: "purchase-sale",
                       query: "Microdecisions v. Skinner",
                       expectedCaseSubstring: "Microdecisions"),
        AuthorityProbe(matter: "insurance-claim",
                       query: "Dowd v. Monroe County",
                       expectedCaseSubstring: "Dowd")
    ]

    func testLiveCourtListenerSurfacesEachMatterLeadAuthority() async throws {
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
        let client = CourtListenerClient(
            httpClient: AuthorizedHTTPClient(
                keyStore: StaticTokenStore(token: token),
                policy: NetworkPolicyService(),
                logger: NetworkRequestLogger(repository: store.networkRequests)
            )
        )

        for (index, probe) in Self.probes.enumerated() {
            // Space requests so the burst stays comfortably under the 5/min limit.
            if index > 0 { try await Task.sleep(nanoseconds: 1_200_000_000) }

            let response = try await client.searchOpinions(CourtListenerSearchRequest(query: probe.query))
            XCTAssertGreaterThan(response.count, 0, "\(probe.matter): CourtListener returned no results for \(probe.query)")
            XCTAssertTrue(
                response.results.contains { ($0.caseName ?? "").localizedCaseInsensitiveContains(probe.expectedCaseSubstring) },
                "\(probe.matter): expected '\(probe.expectedCaseSubstring)' for query '\(probe.query)'; got: \(response.results.prefix(5).map { $0.caseName ?? "?" })"
            )
        }

        // Every request flowed through the app's audited, allowlisted client.
        let audited = try store.networkRequests.fetchRecent(limit: 20)
        let approved2xx = audited.filter {
            $0.domain.contains("courtlistener.com") && $0.approved && ($0.statusCode ?? 0) / 100 == 2
        }
        XCTAssertEqual(
            approved2xx.count, Self.probes.count,
            "expected \(Self.probes.count) approved 2xx CourtListener requests in the audit log; got: \(audited.map { "\($0.domain) \($0.statusCode ?? -1)" })"
        )
    }
}
