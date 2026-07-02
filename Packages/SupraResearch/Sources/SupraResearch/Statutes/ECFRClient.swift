import Foundation
import SupraNetworking

/// Minimal read-only client for the eCFR full-text search API
/// (`https://www.ecfr.gov/api/search/v1/results`). eCFR is the official, continuously-updated
/// Code of Federal Regulations — free, key-less, and (unlike Open Legal Codes) it stamps a real
/// effective date per section, so it backs the `.currencyVerifiable` statutory tier.
public enum ECFRError: Error, Equatable, Sendable {
    case blockedByNetworkPolicy
    case invalidResponse
    case decodingFailed
    case serverError(statusCode: Int)
    case transportFailed(String)
}

public protocol ECFRClientProtocol: Sendable {
    func search(query: String, limit: Int) async throws -> ECFRSearchResponse

    /// Fetches one CFR section's full text from the versioner API, as of `date`
    /// (the search hit's effective date). Throwing conformers degrade to the
    /// search excerpt.
    func fetchSectionText(title: String, part: String?, section: String, date: String) async throws -> String
}

public extension ECFRClientProtocol {
    /// Default so stubs/conformers that don't fetch section text still compile.
    func fetchSectionText(title: String, part: String?, section: String, date: String) async throws -> String {
        throw ECFRError.invalidResponse
    }
}

public struct ECFRSearchResponse: Decodable, Sendable, Equatable {
    public let results: [ECFRSearchResult]
}

public struct ECFRSearchResult: Decodable, Sendable, Equatable {
    public let startsOn: String?           // effective date of this version, e.g. "2023-08-09"
    public let endsOn: String?
    public let type: String?               // "Section"
    public let hierarchy: Hierarchy
    public let headings: Headings
    public let fullTextExcerpt: String?

    public struct Hierarchy: Decodable, Sendable, Equatable {
        public let title: String?
        public let chapter: String?
        public let part: String?
        public let section: String?
    }
    public struct Headings: Decodable, Sendable, Equatable {
        public let title: String?
        public let part: String?
        public let section: String?
    }
}

public final class ECFRClient: ECFRClientProtocol, @unchecked Sendable {
    private let httpClient: any AuthorizedHTTPClientProtocol
    private let baseURLOverride: String?

    public init(httpClient: any AuthorizedHTTPClientProtocol, baseURLOverride: String? = nil) {
        self.httpClient = httpClient
        self.baseURLOverride = baseURLOverride
    }

    public func search(query: String, limit: Int) async throws -> ECFRSearchResponse {
        let base = Self.apiBaseURL(baseURLOverride).appendingPathComponent("search/v1/results")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ECFRError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "per_page", value: String(limit))
        ]
        guard let url = components.url else { throw ECFRError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await httpClient.sendUnauthenticated(request, relatedResearchSessionID: nil)
            switch response.statusCode {
            case 200..<300:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                do { return try decoder.decode(ECFRSearchResponse.self, from: data) }
                catch { throw ECFRError.decodingFailed }
            case 500...599:
                throw ECFRError.serverError(statusCode: response.statusCode)
            default:
                throw ECFRError.invalidResponse
            }
        } catch let error as ECFRError {
            throw error
        } catch let error as NetworkPolicyError {
            if case .localRateLimitExceeded = error { throw ECFRError.transportFailed("rate limited") }
            throw ECFRError.blockedByNetworkPolicy
        } catch is AuthorizedHTTPClientError {
            throw ECFRError.invalidResponse
        } catch {
            throw ECFRError.transportFailed(error.localizedDescription)
        }
    }

    public func fetchSectionText(title: String, part: String?, section: String, date: String) async throws -> String {
        // The versioner returns just the requested section's XML when filtered.
        let base = Self.apiBaseURL(baseURLOverride)
            .appendingPathComponent("versioner/v1/full/\(date)/title-\(title).xml")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ECFRError.invalidResponse
        }
        var items = [URLQueryItem(name: "section", value: section)]
        if let part, !part.isEmpty {
            items.insert(URLQueryItem(name: "part", value: part), at: 0)
        }
        components.queryItems = items
        guard let url = components.url else { throw ECFRError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await httpClient.sendUnauthenticated(request, relatedResearchSessionID: nil)
            switch response.statusCode {
            case 200..<300:
                guard let xml = String(data: data, encoding: .utf8), !xml.isEmpty else {
                    throw ECFRError.decodingFailed
                }
                return xml
            case 500...599:
                throw ECFRError.serverError(statusCode: response.statusCode)
            default:
                throw ECFRError.invalidResponse
            }
        } catch let error as ECFRError {
            throw error
        } catch let error as NetworkPolicyError {
            if case .localRateLimitExceeded = error { throw ECFRError.transportFailed("rate limited") }
            throw ECFRError.blockedByNetworkPolicy
        } catch is AuthorizedHTTPClientError {
            throw ECFRError.invalidResponse
        } catch {
            throw ECFRError.transportFailed(error.localizedDescription)
        }
    }

    static func apiBaseURL(_ override: String? = nil) -> URL {
        let fallback = URL(string: "https://www.ecfr.gov/api")!
        let raw = override ?? ProcessInfo.processInfo.environment["SUPRA_ECFR_BASE_URL"]
        guard
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
            let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
            ["www.ecfr.gov", "ecfr.gov"].contains(url.host?.lowercased() ?? "")
        else { return fallback }
        return url
    }
}
