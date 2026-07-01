import Foundation
import SupraNetworking

public protocol CourtListenerClientProtocol: Sendable {
    func searchOpinions(
        _ request: CourtListenerSearchRequest,
        relatedResearchSessionID: String?
    ) async throws -> CourtListenerSearchResponse

    /// Fetches a single opinion's full text + HTML from the allow-listed
    /// opinion-detail endpoint.
    func fetchOpinion(id: Int) async throws -> CourtListenerOpinionDetailDTO

    /// Downloads an opinion PDF from CourtListener's storage CDN (no token sent).
    func downloadOpinionPDF(from url: URL) async throws -> Data
}

public extension CourtListenerClientProtocol {
    /// Convenience for callers that don't link the request to a session.
    func searchOpinions(_ request: CourtListenerSearchRequest) async throws -> CourtListenerSearchResponse {
        try await searchOpinions(request, relatedResearchSessionID: nil)
    }

    /// Searches RECAP dockets (PACER case filings) instead of published opinions — for
    /// "who has sued X / litigation involving X" questions. Forces the RECAP corpus and
    /// reuses the same request/decode path; each result populates the docket fields
    /// (caseName, court, dateFiled, docketNumber, docketID, suitNature). These are
    /// factual filings, NOT citable legal authority.
    func searchDockets(
        _ request: CourtListenerSearchRequest,
        relatedResearchSessionID: String? = nil
    ) async throws -> CourtListenerSearchResponse {
        try await searchOpinions(request.withSearchType(.recap), relatedResearchSessionID: relatedResearchSessionID)
    }

    /// Default so stubs/conformers that don't fetch opinion detail still compile.
    func fetchOpinion(id: Int) async throws -> CourtListenerOpinionDetailDTO {
        throw CourtListenerError.invalidResponse
    }

    /// Default so conformers that don't download PDFs still compile.
    func downloadOpinionPDF(from url: URL) async throws -> Data {
        throw CourtListenerError.invalidResponse
    }
}

public final class CourtListenerClient: CourtListenerClientProtocol, @unchecked Sendable {
    private let httpClient: any AuthorizedHTTPClientProtocol
    private let baseURLOverride: String?

    public init(httpClient: any AuthorizedHTTPClientProtocol, baseURLOverride: String? = nil) {
        self.httpClient = httpClient
        self.baseURLOverride = baseURLOverride
    }

    public func searchOpinions(
        _ request: CourtListenerSearchRequest,
        relatedResearchSessionID: String?
    ) async throws -> CourtListenerSearchResponse {
        let url = try CourtListenerEndpoint.searchURL(for: request, baseURLOverride: baseURLOverride)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"

        do {
            let (data, response) = try await httpClient.send(urlRequest, relatedResearchSessionID: relatedResearchSessionID)
            switch response.statusCode {
            case 200..<300:
                do {
                    return try CourtListenerSearchResponse.decodePreservingRawResults(from: data)
                } catch {
                    throw CourtListenerError.decodingFailed
                }
            case 401, 403:
                throw CourtListenerError.authenticationFailed
            case 429:
                throw CourtListenerError.throttled(retryAfter: Self.retryAfterSeconds(from: response))
            case 500...599:
                throw CourtListenerError.serverError(statusCode: response.statusCode)
            default:
                throw CourtListenerError.invalidResponse
            }
        } catch let error as CourtListenerError {
            throw error
        } catch let error as NetworkPolicyError {
            switch error {
            case .localRateLimitExceeded:
                throw CourtListenerError.localRateLimitExceeded
            default:
                throw CourtListenerError.blockedByNetworkPolicy
            }
        } catch let error as AuthorizedHTTPClientError {
            switch error {
            case .missingToken:
                throw CourtListenerError.missingToken
            case .invalidResponse:
                throw CourtListenerError.invalidResponse
            case .tokenHostNotAllowed:
                // An authenticated request was aimed at a non-API host — a programming
                // error, surfaced as a network-policy block rather than leaking a token.
                throw CourtListenerError.blockedByNetworkPolicy
            }
        } catch {
            throw CourtListenerError.transportFailed(error.localizedDescription)
        }
    }

    public func fetchOpinion(id: Int) async throws -> CourtListenerOpinionDetailDTO {
        let url = CourtListenerEndpoint.opinionURL(id: id, baseURLOverride: baseURLOverride)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"

        do {
            let (data, response) = try await httpClient.send(urlRequest, relatedResearchSessionID: nil)
            switch response.statusCode {
            case 200..<300:
                do {
                    return try JSONDecoder().decode(CourtListenerOpinionDetailDTO.self, from: data)
                } catch {
                    throw CourtListenerError.decodingFailed
                }
            case 401, 403:
                throw CourtListenerError.authenticationFailed
            case 429:
                throw CourtListenerError.throttled(retryAfter: Self.retryAfterSeconds(from: response))
            case 500...599:
                throw CourtListenerError.serverError(statusCode: response.statusCode)
            default:
                throw CourtListenerError.invalidResponse
            }
        } catch let error as CourtListenerError {
            throw error
        } catch let error as NetworkPolicyError {
            switch error {
            case .localRateLimitExceeded:
                throw CourtListenerError.localRateLimitExceeded
            default:
                throw CourtListenerError.blockedByNetworkPolicy
            }
        } catch let error as AuthorizedHTTPClientError {
            switch error {
            case .missingToken:
                throw CourtListenerError.missingToken
            case .invalidResponse:
                throw CourtListenerError.invalidResponse
            case .tokenHostNotAllowed:
                // An authenticated request was aimed at a non-API host — a programming
                // error, surfaced as a network-policy block rather than leaking a token.
                throw CourtListenerError.blockedByNetworkPolicy
            }
        } catch {
            throw CourtListenerError.transportFailed(error.localizedDescription)
        }
    }

    public func downloadOpinionPDF(from url: URL) async throws -> Data {
        // Defense in depth: only the CourtListener storage CDN, never the original
        // court `download_url` (arbitrary host) or the API host (which would attach
        // the token). The network policy also enforces the allow-list.
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "storage.courtlistener.com" else {
            throw CourtListenerError.invalidResponse
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"

        do {
            let (data, response) = try await httpClient.sendUnauthenticated(urlRequest, relatedResearchSessionID: nil)
            switch response.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                throw CourtListenerError.authenticationFailed
            case 429:
                throw CourtListenerError.throttled(retryAfter: Self.retryAfterSeconds(from: response))
            case 500...599:
                throw CourtListenerError.serverError(statusCode: response.statusCode)
            default:
                throw CourtListenerError.invalidResponse
            }
        } catch let error as CourtListenerError {
            throw error
        } catch let error as NetworkPolicyError {
            switch error {
            case .localRateLimitExceeded:
                throw CourtListenerError.localRateLimitExceeded
            default:
                throw CourtListenerError.blockedByNetworkPolicy
            }
        } catch {
            throw CourtListenerError.transportFailed(error.localizedDescription)
        }
    }

    /// Parses a `Retry-After` header (delta-seconds or HTTP-date) into a
    /// non-negative back-off in seconds, or `nil` when absent/unparseable.
    private static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) {
            return max(0, seconds)
        }
        // Accept all three RFC 7231 HTTP-date forms: IMF-fixdate, RFC 850, asctime.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        // Collapse whitespace runs so asctime's double-space before single-digit
        // days parses with a single 'd'.
        let normalized = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) {
                return max(0, date.timeIntervalSinceNow)
            }
        }
        return nil
    }
}
