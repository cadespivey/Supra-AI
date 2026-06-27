import Foundation
import SupraNetworking

/// `LegalDevelopmentSource` backed by Regulations.gov v4 — federal **rulemaking** dockets
/// (proposed/final rules, notices). Key'd (`X-Api-Key` header, an api.data.gov key read from the
/// token store). Federal-only; best-effort (a missing key or failure yields no developments + a note).
public struct RegulationsGovSource: LegalDevelopmentSource {
    public let id = "regulations-gov"
    public let displayName = "Regulations.gov"
    public let kind: LegalDevelopmentKind = .regulatory

    private let client: any RegulationsGovClientProtocol

    public init(client: any RegulationsGovClientProtocol) {
        self.client = client
    }

    public init(httpClient: any AuthorizedHTTPClientProtocol, tokenStore: any APIKeyStoreProtocol) {
        self.client = RegulationsGovClient(httpClient: httpClient, tokenStore: tokenStore)
    }

    public func lookup(_ query: LegalDevelopmentQuery) async -> LegalDevelopmentLookupResult {
        if let jurisdiction = query.jurisdiction,
           StatutoryJurisdictionMapper.postalCode(forJurisdiction: jurisdiction) != nil {
            return LegalDevelopmentLookupResult()   // a specific state — Regulations.gov is federal
        }
        do {
            let response = try await client.searchDocuments(term: query.terms, limit: query.limit)
            return LegalDevelopmentLookupResult(developments: response.data.prefix(query.limit).compactMap(Self.development(from:)))
        } catch RegulationsGovError.missingKey {
            return LegalDevelopmentLookupResult(note: "Add a Regulations.gov API key in Settings to track federal rulemaking.")
        } catch {
            return LegalDevelopmentLookupResult(note: "Regulations.gov lookup was unavailable for this query.")
        }
    }

    static func development(from item: RegulationsGovDocument) -> LegalDevelopment? {
        let attributes = item.attributes
        guard let title = attributes.title else { return nil }
        let status = [attributes.documentType, attributes.agencyId.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        return LegalDevelopment(
            sourceID: "regulations-gov",
            sourceName: "Regulations.gov",
            kind: .regulatory,
            identifier: attributes.frDocNum.map { "FR Doc \($0)" } ?? item.id,
            title: title,
            jurisdiction: "Federal",
            status: status.isEmpty ? nil : status,
            date: attributes.postedDate,
            summary: attributes.docketId.map { "Docket \($0)" },
            url: "https://www.regulations.gov/document/\(item.id)"
        )
    }
}

public enum RegulationsGovError: Error, Equatable, Sendable {
    case missingKey
    case invalidResponse
    case decodingFailed
    case serverError(statusCode: Int)
    case transportFailed(String)
}

public protocol RegulationsGovClientProtocol: Sendable {
    func searchDocuments(term: String, limit: Int) async throws -> RegulationsGovResponse
}

public struct RegulationsGovResponse: Decodable, Sendable, Equatable {
    public let data: [RegulationsGovDocument]
}

public struct RegulationsGovDocument: Decodable, Sendable, Equatable {
    public let id: String
    public let attributes: Attributes
    public struct Attributes: Decodable, Sendable, Equatable {
        public let title: String?
        public let documentType: String?
        public let postedDate: String?
        public let docketId: String?
        public let frDocNum: String?
        public let agencyId: String?
    }
}

public final class RegulationsGovClient: RegulationsGovClientProtocol, @unchecked Sendable {
    private let httpClient: any AuthorizedHTTPClientProtocol
    private let tokenStore: any APIKeyStoreProtocol

    public init(httpClient: any AuthorizedHTTPClientProtocol, tokenStore: any APIKeyStoreProtocol) {
        self.httpClient = httpClient
        self.tokenStore = tokenStore
    }

    public func searchDocuments(term: String, limit: Int) async throws -> RegulationsGovResponse {
        guard let key = (try? tokenStore.loadAPIKey(for: .regulationsGov)) ?? nil, !key.isEmpty else {
            throw RegulationsGovError.missingKey
        }
        var components = URLComponents(string: "https://api.regulations.gov/v4/documents")!
        components.queryItems = [
            URLQueryItem(name: "filter[searchTerm]", value: term),
            URLQueryItem(name: "sort", value: "-postedDate"),
            URLQueryItem(name: "page[size]", value: String(max(5, min(limit, 250))))
        ]
        guard let url = components.url else { throw RegulationsGovError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")   // header → kept out of request logs

        let (data, response) = try await Self.send(httpClient, request)
        switch response.statusCode {
        case 200..<300:
            do { return try JSONDecoder().decode(RegulationsGovResponse.self, from: data) }
            catch { throw RegulationsGovError.decodingFailed }
        case 500...599: throw RegulationsGovError.serverError(statusCode: response.statusCode)
        default: throw RegulationsGovError.invalidResponse
        }
    }

    static func send(_ httpClient: any AuthorizedHTTPClientProtocol, _ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await httpClient.sendUnauthenticated(request, relatedResearchSessionID: nil)
        } catch let error as NetworkPolicyError {
            throw RegulationsGovError.transportFailed(String(describing: error))
        } catch {
            throw RegulationsGovError.transportFailed(error.localizedDescription)
        }
    }
}
