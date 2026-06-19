import Foundation

public enum CourtListenerEndpoint {
    public static var baseURL: URL {
        var components = URLComponents(url: apiBaseURL(), resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        return components?.url ?? URL(string: "https://www.courtlistener.com")!
    }

    public static var searchURL: URL {
        apiBaseURL().appendingPathComponent("search")
    }

    private static func apiBaseURL(_ override: String? = nil) -> URL {
        let fallback = URL(string: "https://www.courtlistener.com/api/rest/v4")!
        let rawBaseURL = override ?? ProcessInfo.processInfo.environment["SUPRA_COURTLISTENER_BASE_URL"]
        guard
            let raw = rawBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let url = URL(string: raw),
            url.scheme?.lowercased() == "https",
            ["www.courtlistener.com", "courtlistener.com"].contains(url.host?.lowercased() ?? "")
        else {
            return fallback
        }
        return url
    }

    static func searchURL(for request: CourtListenerSearchRequest, baseURLOverride: String? = nil) throws -> URL {
        if let cursorURL = request.cursorURL {
            guard cursorURL.scheme?.lowercased() == "https",
                  cursorURL.host?.lowercased() == "www.courtlistener.com" else {
                throw CourtListenerError.invalidCursorHost
            }
            return cursorURL
        }

        let searchURL = apiBaseURL(baseURLOverride).appendingPathComponent("search")
        guard var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false) else {
            throw CourtListenerError.invalidResponse
        }
        var queryItems = [
            URLQueryItem(name: "q", value: request.query),
            URLQueryItem(name: "type", value: "o")
        ]
        if let orderBy = request.orderBy {
            queryItems.append(URLQueryItem(name: "order_by", value: orderBy))
        }
        if request.highlight {
            queryItems.append(URLQueryItem(name: "highlight", value: "on"))
        }
        for courtID in request.courtIDs where !courtID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "court", value: courtID))
        }
        if let dateFiledAfter = request.dateFiledAfter?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dateFiledAfter.isEmpty {
            queryItems.append(URLQueryItem(name: "filed_after", value: dateFiledAfter))
        }
        if let dateFiledBefore = request.dateFiledBefore?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dateFiledBefore.isEmpty {
            queryItems.append(URLQueryItem(name: "filed_before", value: dateFiledBefore))
        }
        if let citation = request.citation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !citation.isEmpty {
            queryItems.append(URLQueryItem(name: "citation", value: citation))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw CourtListenerError.invalidResponse
        }
        return url
    }
}
