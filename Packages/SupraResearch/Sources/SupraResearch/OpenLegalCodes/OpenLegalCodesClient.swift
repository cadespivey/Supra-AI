import Foundation
import SupraNetworking

public protocol OpenLegalCodesClientProtocol: Sendable {
    /// Full-text search within a single code (e.g. `fl-statutes`, `us-usc-title-11`).
    func searchCode(jurisdictionID: String, query: String, limit: Int?, relatedResearchSessionID: String?) async throws -> OLCSearchResults

    /// Cross-jurisdiction search (optionally state-filtered). Tends to return municipal codes.
    func searchAcross(query: String, state: String?, limit: Int?, relatedResearchSessionID: String?) async throws -> OLCSearchResults

    /// One section's full text.
    func fetchSection(jurisdictionID: String, path: String, relatedResearchSessionID: String?) async throws -> OLCSection

    /// A jurisdiction's metadata (status, freshness stamps, publisher, source URL).
    func jurisdiction(id: String) async throws -> OLCJurisdiction
}

public extension OpenLegalCodesClientProtocol {
    func searchCode(jurisdictionID: String, query: String) async throws -> OLCSearchResults {
        try await searchCode(jurisdictionID: jurisdictionID, query: query, limit: nil, relatedResearchSessionID: nil)
    }
    func fetchSection(jurisdictionID: String, path: String) async throws -> OLCSection {
        try await fetchSection(jurisdictionID: jurisdictionID, path: path, relatedResearchSessionID: nil)
    }
}

/// A read-only REST client for Open Legal Codes — free, key-less, and unlimited. All calls go
/// out **unauthenticated** (no CourtListener token is ever attached) through the shared
/// `AuthorizedHTTPClient`, so they are still allow-listed, logged, and locally rate-limited.
///
/// OLC content is lazily crawled, so this client surfaces the crawl states (`202` warming /
/// `503 CRAWL_FAILED`) as typed, transient errors rather than generic failures — the research
/// layer treats OLC as a best-effort, un-verified statutory source and degrades gracefully.
public final class OpenLegalCodesClient: OpenLegalCodesClientProtocol, @unchecked Sendable {
    private let httpClient: any AuthorizedHTTPClientProtocol
    private let baseURLOverride: String?

    public init(httpClient: any AuthorizedHTTPClientProtocol, baseURLOverride: String? = nil) {
        self.httpClient = httpClient
        self.baseURLOverride = baseURLOverride
    }

    public func searchCode(jurisdictionID: String, query: String, limit: Int?, relatedResearchSessionID: String?) async throws -> OLCSearchResults {
        let url = try OpenLegalCodesEndpoint.searchWithinURL(jurisdictionID: jurisdictionID, query: query, limit: limit, baseURLOverride: baseURLOverride)
        return try await get(url, relatedResearchSessionID: relatedResearchSessionID) { data in
            try JSONDecoder().decode(OLCEnvelope<OLCSearchResults>.self, from: data).data
        }
    }

    public func searchAcross(query: String, state: String?, limit: Int?, relatedResearchSessionID: String?) async throws -> OLCSearchResults {
        let url = try OpenLegalCodesEndpoint.searchAcrossURL(query: query, state: state, limit: limit, baseURLOverride: baseURLOverride)
        return try await get(url, relatedResearchSessionID: relatedResearchSessionID) { data in
            try JSONDecoder().decode(OLCEnvelope<OLCSearchResults>.self, from: data).data
        }
    }

    public func fetchSection(jurisdictionID: String, path: String, relatedResearchSessionID: String?) async throws -> OLCSection {
        let url = OpenLegalCodesEndpoint.sectionURL(jurisdictionID: jurisdictionID, path: path, baseURLOverride: baseURLOverride)
        return try await get(url, relatedResearchSessionID: relatedResearchSessionID) { data in
            try JSONDecoder().decode(OLCEnvelope<OLCSection>.self, from: data).data
        }
    }

    public func jurisdiction(id: String) async throws -> OLCJurisdiction {
        let url = OpenLegalCodesEndpoint.jurisdictionURL(id: id, baseURLOverride: baseURLOverride)
        return try await get(url, relatedResearchSessionID: nil) { data in
            try JSONDecoder().decode(OLCEnvelope<OLCJurisdiction>.self, from: data).data
        }
    }

    // MARK: - Shared request path

    private func get<T: Sendable>(
        _ url: URL,
        relatedResearchSessionID: String?,
        _ decode: @Sendable (Data) throws -> T
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await httpClient.sendUnauthenticated(request, relatedResearchSessionID: relatedResearchSessionID)
            switch response.statusCode {
            case 202:
                // The code is being crawled on demand and isn't ready yet (202 is inside the
                // 2xx range, so this MUST precede the success case below).
                let status = try? JSONDecoder().decode(OLCCrawlStatus.self, from: data)
                throw OpenLegalCodesError.crawlInProgress(retryAfter: status?.retryAfter ?? Self.retryAfter(response))
            case 200..<300:
                do { return try decode(data) } catch { throw OpenLegalCodesError.decodingFailed }
            case 400:
                throw OpenLegalCodesError.badRequest(String(data: data, encoding: .utf8))
            case 503:
                if let status = try? JSONDecoder().decode(OLCCrawlStatus.self, from: data),
                   status.status.uppercased() == "CRAWL_FAILED" {
                    throw OpenLegalCodesError.crawlFailed(
                        reason: status.error ?? status.message ?? "crawl failed",
                        retryAfter: status.retryAfter ?? Self.retryAfter(response)
                    )
                }
                throw OpenLegalCodesError.serverError(statusCode: 503)
            case 500...599:
                throw OpenLegalCodesError.serverError(statusCode: response.statusCode)
            default:
                throw OpenLegalCodesError.invalidResponse
            }
        } catch let error as OpenLegalCodesError {
            throw error
        } catch let error as NetworkPolicyError {
            if case .localRateLimitExceeded = error { throw OpenLegalCodesError.localRateLimitExceeded }
            throw OpenLegalCodesError.blockedByNetworkPolicy
        } catch is AuthorizedHTTPClientError {
            // Unauthenticated path never needs a token; any client error here is a misuse.
            throw OpenLegalCodesError.invalidResponse
        } catch {
            throw OpenLegalCodesError.transportFailed(error.localizedDescription)
        }
    }

    /// Parses a `Retry-After` delta-seconds header into a non-negative back-off, or nil.
    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = TimeInterval(raw) else { return nil }
        return max(0, seconds)
    }
}
