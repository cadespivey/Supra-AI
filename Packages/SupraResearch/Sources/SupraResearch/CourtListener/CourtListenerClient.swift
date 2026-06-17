import Foundation
import SupraNetworking

public protocol CourtListenerClientProtocol: Sendable {
    func searchOpinions(_ request: CourtListenerSearchRequest) async throws -> CourtListenerSearchResponse
}

public final class CourtListenerClient: CourtListenerClientProtocol, @unchecked Sendable {
    private let httpClient: any AuthorizedHTTPClientProtocol

    public init(httpClient: any AuthorizedHTTPClientProtocol) {
        self.httpClient = httpClient
    }

    public func searchOpinions(
        _ request: CourtListenerSearchRequest
    ) async throws -> CourtListenerSearchResponse {
        let url = try CourtListenerEndpoint.searchURL(for: request)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"

        do {
            let (data, response) = try await httpClient.send(urlRequest, relatedResearchSessionID: nil)
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
                throw CourtListenerError.throttled
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
            }
        } catch {
            throw CourtListenerError.transportFailed(error.localizedDescription)
        }
    }
}
