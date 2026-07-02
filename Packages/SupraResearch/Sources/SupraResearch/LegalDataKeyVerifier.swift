import Foundation
import SupraNetworking

/// Outcome of a live "does this key work?" round-trip.
public enum KeyVerificationResult: Sendable, Equatable {
    case valid
    case invalid(String)      // the service rejected the key (e.g. HTTP 401/403)
    case unreachable(String)  // a network / unexpected error — the key may still be fine
    case missingKey
}

/// Performs a minimal, real request against each legal-data API to confirm the saved key is
/// accepted. Goes through the shared `AuthorizedHTTPClient` (allow-listed, logged, rate-limited);
/// keys ride in a header where the API allows, so they stay out of request logs.
public struct LegalDataKeyVerifier: Sendable {
    private let httpClient: any AuthorizedHTTPClientProtocol
    private let tokenStore: any APIKeyStoreProtocol

    public init(httpClient: any AuthorizedHTTPClientProtocol, tokenStore: any APIKeyStoreProtocol) {
        self.httpClient = httpClient
        self.tokenStore = tokenStore
    }

    public func verify(_ service: APIKeyService) async -> KeyVerificationResult {
        guard let key = (try? tokenStore.loadAPIKey(for: service)) ?? nil, !key.isEmpty else { return .missingKey }
        guard let request = Self.request(for: service, key: key) else { return .unreachable("Could not build a verification request.") }
        do {
            let (data, response) = try await httpClient.sendUnauthenticated(request, relatedResearchSessionID: nil)
            return Self.interpret(service: service, status: response.statusCode, data: data)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// CourtListener uses a different (token-header) auth path, handled by `AuthorizedHTTPClient.send`.
    public func verifyCourtListener() async -> KeyVerificationResult {
        guard let token = (try? tokenStore.loadCourtListenerToken()) ?? nil, !token.isEmpty else { return .missingKey }
        guard var components = URLComponents(string: "https://www.courtlistener.com/api/rest/v4/search/") else {
            return .unreachable("Could not build a verification request.")
        }
        components.queryItems = [URLQueryItem(name: "q", value: "test"), URLQueryItem(name: "type", value: "o")]
        guard let url = components.url else { return .unreachable("Could not build a verification request.") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await httpClient.send(request, relatedResearchSessionID: nil)
            return Self.interpretStatus(response.statusCode)
        } catch let error as AuthorizedHTTPClientError {
            if case .missingToken = error { return .missingKey }
            return .unreachable(error.localizedDescription)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// The free, key-less legal-data sources. They have no key to validate, so
    /// "verification" is a reachability probe rather than an auth check.
    public enum KeylessLegalSource: String, Sendable, CaseIterable {
        case eCFR = "ecfr"
        case federalRegister = "federal-register"
        case openLegalCodes = "open-legal-codes"
    }

    /// Confirms a key-less source is reachable: a minimal unauthenticated request that
    /// returns `.valid` when the host answers, `.unreachable` otherwise. There is no
    /// `.invalid`/`.missingKey` — these sources require no key.
    public func verifyReachable(_ source: KeylessLegalSource) async -> KeyVerificationResult {
        guard let request = Self.reachabilityRequest(for: source) else {
            return .unreachable("Could not build a verification request.")
        }
        do {
            let (_, response) = try await httpClient.sendUnauthenticated(request, relatedResearchSessionID: nil)
            return Self.interpretReachability(response.statusCode)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    static func reachabilityRequest(for source: KeylessLegalSource) -> URLRequest? {
        let urlString: String
        switch source {
        case .eCFR: urlString = "https://www.ecfr.gov/api/versioner/v1/titles.json"
        case .federalRegister: urlString = "https://www.federalregister.gov/api/v1/documents.json?per_page=1"
        case .openLegalCodes: urlString = "https://openlegalcodes.org/api/v1/jurisdictions"
        }
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return request
    }

    static func interpretReachability(_ status: Int) -> KeyVerificationResult {
        // Any 2xx/3xx (or a 429 throttle) means the host answered — the source is live.
        switch status {
        case 200..<400, 429: return .valid
        default: return .unreachable("The source responded with HTTP \(status).")
        }
    }

    // MARK: - Per-service minimal requests

    static func request(for service: APIKeyService, key: String) -> URLRequest? {
        switch service {
        case .govInfo:
            guard let url = URL(string: "https://api.govinfo.gov/search") else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let body: [String: Any] = [
                "query": "collection:USCODE",
                "pageSize": 1,
                "offsetMark": "*"
            ]
            guard JSONSerialization.isValidJSONObject(body),
                  let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            request.httpBody = data
            return request
        case .openStates:
            return headerKeyedRequest("https://v3.openstates.org/jurisdictions", query: [("per_page", "1")], header: "X-API-Key", key: key)
        case .regulationsGov:
            return headerKeyedRequest("https://api.regulations.gov/v4/documents", query: [("page[size]", "5")], header: "X-Api-Key", key: key)
        }
    }

    private static func headerKeyedRequest(_ base: String, query: [(String, String)], header: String, key: String) -> URLRequest? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: header)
        return request
    }

    // MARK: - Interpretation

    static func interpret(service: APIKeyService, status: Int, data: Data) -> KeyVerificationResult {
        switch status {
        case 401, 403:
            return .invalid("The key was rejected (HTTP \(status)).")
        case 200..<300, 429:   // 429 = accepted but throttled → the key is valid
            return .valid
        default:
            return .unreachable("Unexpected response (HTTP \(status)).")
        }
    }

    static func interpretStatus(_ status: Int) -> KeyVerificationResult {
        switch status {
        case 401, 403: return .invalid("The token was rejected (HTTP \(status)).")
        case 200..<300, 429: return .valid
        default: return .unreachable("Unexpected response (HTTP \(status)).")
        }
    }
}
