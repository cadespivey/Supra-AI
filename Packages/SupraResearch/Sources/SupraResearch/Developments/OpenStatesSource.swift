import Foundation
import SupraNetworking

/// `LegalDevelopmentSource` backed by OpenStates v3 — state & federal **bills** (legislative
/// developments). Key'd (`X-API-Key` header, read from the token store). Best-effort.
public struct OpenStatesSource: LegalDevelopmentSource {
    public let id = "openstates"
    public let displayName = "OpenStates"
    public let kind: LegalDevelopmentKind = .legislative

    private let client: any OpenStatesClientProtocol

    public init(client: any OpenStatesClientProtocol) { self.client = client }

    public init(httpClient: any AuthorizedHTTPClientProtocol, tokenStore: any APIKeyStoreProtocol) {
        self.client = OpenStatesClient(httpClient: httpClient, tokenStore: tokenStore)
    }

    public func lookup(_ query: LegalDevelopmentQuery) async -> LegalDevelopmentLookupResult {
        do {
            let response = try await client.searchBills(term: query.terms, jurisdiction: query.jurisdiction, limit: query.limit)
            return LegalDevelopmentLookupResult(developments: response.results.prefix(query.limit).compactMap(Self.development(from:)))
        } catch OpenStatesError.missingKey {
            return LegalDevelopmentLookupResult(note: "Add an OpenStates API key in Settings to track bills.")
        } catch {
            return LegalDevelopmentLookupResult(note: "OpenStates lookup was unavailable for this query.")
        }
    }

    static func development(from bill: OpenStatesBill) -> LegalDevelopment? {
        let jurisdiction = bill.jurisdiction?.name ?? "Unknown"
        guard let title = bill.title else { return nil }
        return LegalDevelopment(
            sourceID: "openstates",
            sourceName: "OpenStates",
            kind: .legislative,
            identifier: "\(jurisdiction): \(bill.identifier ?? bill.id)",
            title: title,
            jurisdiction: jurisdiction,
            status: bill.latestActionDescription,
            date: bill.latestActionDate,
            summary: bill.session.map { "Session \($0)" },
            url: bill.openstatesUrl
        )
    }
}

public enum OpenStatesError: Error, Equatable, Sendable {
    case missingKey, invalidResponse, decodingFailed, serverError(statusCode: Int), transportFailed(String)
}

public protocol OpenStatesClientProtocol: Sendable {
    func searchBills(term: String, jurisdiction: String?, limit: Int) async throws -> OpenStatesResponse
}

public struct OpenStatesResponse: Decodable, Sendable, Equatable {
    public let results: [OpenStatesBill]
}

public struct OpenStatesBill: Decodable, Sendable, Equatable {
    public let id: String
    public let identifier: String?
    public let title: String?
    public let session: String?
    public let jurisdiction: Jurisdiction?
    public let latestActionDate: String?
    public let latestActionDescription: String?
    public let openstatesUrl: String?

    public struct Jurisdiction: Decodable, Sendable, Equatable { public let name: String? }
}

public final class OpenStatesClient: OpenStatesClientProtocol, @unchecked Sendable {
    private let httpClient: any AuthorizedHTTPClientProtocol
    private let tokenStore: any APIKeyStoreProtocol

    public init(httpClient: any AuthorizedHTTPClientProtocol, tokenStore: any APIKeyStoreProtocol) {
        self.httpClient = httpClient
        self.tokenStore = tokenStore
    }

    public func searchBills(term: String, jurisdiction: String?, limit: Int) async throws -> OpenStatesResponse {
        guard let key = (try? tokenStore.loadAPIKey(for: .openStates)) ?? nil, !key.isEmpty else {
            throw OpenStatesError.missingKey
        }
        var components = URLComponents(string: "https://v3.openstates.org/bills")!
        var items = [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "sort", value: "latest_action_desc"),
            URLQueryItem(name: "per_page", value: String(max(1, min(limit, 20))))
        ]
        if let jurisdiction, !jurisdiction.isEmpty {
            items.append(URLQueryItem(name: "jurisdiction", value: jurisdiction))
        }
        components.queryItems = items
        guard let url = components.url else { throw OpenStatesError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "X-API-Key")

        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await httpClient.sendUnauthenticated(request, relatedResearchSessionID: nil) }
        catch { throw OpenStatesError.transportFailed(error.localizedDescription) }

        switch response.statusCode {
        case 200..<300:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            do { return try decoder.decode(OpenStatesResponse.self, from: data) }
            catch { throw OpenStatesError.decodingFailed }
        case 500...599: throw OpenStatesError.serverError(statusCode: response.statusCode)
        default: throw OpenStatesError.invalidResponse
        }
    }
}
