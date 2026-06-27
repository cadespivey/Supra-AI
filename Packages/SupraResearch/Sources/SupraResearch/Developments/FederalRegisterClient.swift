import Foundation
import SupraNetworking

/// Minimal read-only client for the Federal Register API
/// (`https://www.federalregister.gov/api/v1/documents.json`) — the official daily publication of
/// federal rules, proposed rules, and notices. Free and key-less.
public enum FederalRegisterError: Error, Equatable, Sendable {
    case blockedByNetworkPolicy
    case invalidResponse
    case decodingFailed
    case serverError(statusCode: Int)
    case transportFailed(String)
}

public protocol FederalRegisterClientProtocol: Sendable {
    func search(query: String, limit: Int) async throws -> FederalRegisterResponse
}

public struct FederalRegisterResponse: Decodable, Sendable, Equatable {
    public let count: Int?
    public let results: [FederalRegisterDocument]
}

public struct FederalRegisterDocument: Decodable, Sendable, Equatable {
    public let documentNumber: String?     // document_number
    public let title: String?
    public let type: String?               // "Rule" | "Proposed Rule" | "Notice" | "Presidential Document"
    public let abstract: String?
    public let htmlUrl: String?            // html_url
    public let publicationDate: String?    // publication_date
    public let agencies: [Agency]?

    public struct Agency: Decodable, Sendable, Equatable {
        public let name: String?
    }
}

public final class FederalRegisterClient: FederalRegisterClientProtocol, @unchecked Sendable {
    private let httpClient: any AuthorizedHTTPClientProtocol
    private let baseURLOverride: String?

    public init(httpClient: any AuthorizedHTTPClientProtocol, baseURLOverride: String? = nil) {
        self.httpClient = httpClient
        self.baseURLOverride = baseURLOverride
    }

    public func search(query: String, limit: Int) async throws -> FederalRegisterResponse {
        let base = Self.apiBaseURL(baseURLOverride).appendingPathComponent("documents.json")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw FederalRegisterError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "conditions[term]", value: query),
            URLQueryItem(name: "per_page", value: String(limit)),
            URLQueryItem(name: "order", value: "newest")
        ]
        guard let url = components.url else { throw FederalRegisterError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await httpClient.sendUnauthenticated(request, relatedResearchSessionID: nil)
            switch response.statusCode {
            case 200..<300:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                do { return try decoder.decode(FederalRegisterResponse.self, from: data) }
                catch { throw FederalRegisterError.decodingFailed }
            case 500...599:
                throw FederalRegisterError.serverError(statusCode: response.statusCode)
            default:
                throw FederalRegisterError.invalidResponse
            }
        } catch let error as FederalRegisterError {
            throw error
        } catch let error as NetworkPolicyError {
            if case .localRateLimitExceeded = error { throw FederalRegisterError.transportFailed("rate limited") }
            throw FederalRegisterError.blockedByNetworkPolicy
        } catch is AuthorizedHTTPClientError {
            throw FederalRegisterError.invalidResponse
        } catch {
            throw FederalRegisterError.transportFailed(error.localizedDescription)
        }
    }

    static func apiBaseURL(_ override: String? = nil) -> URL {
        let fallback = URL(string: "https://www.federalregister.gov/api/v1")!
        let raw = override ?? ProcessInfo.processInfo.environment["SUPRA_FEDERALREGISTER_BASE_URL"]
        guard
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
            let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
            ["www.federalregister.gov", "federalregister.gov"].contains(url.host?.lowercased() ?? "")
        else { return fallback }
        return url
    }
}
