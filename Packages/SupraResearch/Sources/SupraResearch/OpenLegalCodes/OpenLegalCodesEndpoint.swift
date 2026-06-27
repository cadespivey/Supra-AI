import Foundation

/// Builds Open Legal Codes REST URLs (`https://openlegalcodes.org/api/v1`). The base URL
/// is overridable via `SUPRA_OPENLEGALCODES_BASE_URL` (or an explicit override) but is
/// pinned to the OLC host so a bad override can't redirect requests off-host.
public enum OpenLegalCodesEndpoint {
    static let host = "openlegalcodes.org"

    static func apiBaseURL(_ override: String? = nil) -> URL {
        let fallback = URL(string: "https://openlegalcodes.org/api/v1")!
        let raw = override ?? ProcessInfo.processInfo.environment["SUPRA_OPENLEGALCODES_BASE_URL"]
        guard
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
            let url = URL(string: trimmed),
            url.scheme?.lowercased() == "https",
            ["openlegalcodes.org", "www.openlegalcodes.org"].contains(url.host?.lowercased() ?? "")
        else {
            return fallback
        }
        return url
    }

    /// Full-text search within a single code, e.g. `fl-statutes` or `us-usc-title-11`.
    static func searchWithinURL(jurisdictionID: String, query: String, limit: Int?, baseURLOverride: String? = nil) throws -> URL {
        let path = apiBaseURL(baseURLOverride)
            .appendingPathComponent("jurisdictions")
            .appendingPathComponent(jurisdictionID)
            .appendingPathComponent("search")
        guard var components = URLComponents(url: path, resolvingAgainstBaseURL: false) else {
            throw OpenLegalCodesError.invalidResponse
        }
        components.queryItems = queryItems(q: query, state: nil, limit: limit)
        guard let url = components.url else { throw OpenLegalCodesError.invalidResponse }
        return url
    }

    /// Cross-jurisdiction search (optionally filtered by state). Note: this surface tends to
    /// return municipal ordinances, not state statutes — prefer `searchWithinURL` for statutes.
    static func searchAcrossURL(query: String, state: String?, limit: Int?, baseURLOverride: String? = nil) throws -> URL {
        let base = apiBaseURL(baseURLOverride).appendingPathComponent("search")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw OpenLegalCodesError.invalidResponse
        }
        components.queryItems = queryItems(q: query, state: state, limit: limit)
        guard let url = components.url else { throw OpenLegalCodesError.invalidResponse }
        return url
    }

    /// One section's full text. `path` is the slash-separated locator OLC returns in search
    /// hits (e.g. `chapter-i/subchapter-a/part-1/section-1.1`); each segment is appended as a
    /// real path component.
    static func sectionURL(jurisdictionID: String, path: String, baseURLOverride: String? = nil) -> URL {
        var url = apiBaseURL(baseURLOverride)
            .appendingPathComponent("jurisdictions")
            .appendingPathComponent(jurisdictionID)
            .appendingPathComponent("code")
        for segment in path.split(separator: "/") where !segment.isEmpty {
            url.appendPathComponent(String(segment))
        }
        return url
    }

    static func jurisdictionURL(id: String, baseURLOverride: String? = nil) -> URL {
        apiBaseURL(baseURLOverride)
            .appendingPathComponent("jurisdictions")
            .appendingPathComponent(id)
    }

    private static func queryItems(q: String, state: String?, limit: Int?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "q", value: q)]
        if let state = state?.trimmingCharacters(in: .whitespacesAndNewlines), !state.isEmpty {
            items.append(URLQueryItem(name: "state", value: state))
        }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        return items
    }
}
