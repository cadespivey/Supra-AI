import Foundation

public enum CourtListenerEndpoint {
    public static let baseURL = URL(string: "https://www.courtlistener.com")!
    public static let searchURL = URL(string: "https://www.courtlistener.com/api/rest/v4/search/")!

    static func searchURL(for request: CourtListenerSearchRequest) throws -> URL {
        if let cursorURL = request.cursorURL {
            guard cursorURL.scheme?.lowercased() == "https",
                  cursorURL.host?.lowercased() == "www.courtlistener.com" else {
                throw CourtListenerError.invalidCursorHost
            }
            return cursorURL
        }

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
        components.queryItems = queryItems
        guard let url = components.url else {
            throw CourtListenerError.invalidResponse
        }
        return url
    }
}
