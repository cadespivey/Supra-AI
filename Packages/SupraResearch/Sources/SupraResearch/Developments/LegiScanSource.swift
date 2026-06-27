import Foundation
import SupraNetworking

/// `LegalDevelopmentSource` backed by LegiScan — **bills** across all 50 states + Congress
/// (legislative developments). Key'd (`?key=` query param, read from the token store; the value is
/// redacted from request logs). Best-effort.
public struct LegiScanSource: LegalDevelopmentSource {
    public let id = "legiscan"
    public let displayName = "LegiScan"
    public let kind: LegalDevelopmentKind = .legislative

    private let client: any LegiScanClientProtocol

    public init(client: any LegiScanClientProtocol) { self.client = client }

    public init(httpClient: any AuthorizedHTTPClientProtocol, tokenStore: any APIKeyStoreProtocol) {
        self.client = LegiScanClient(httpClient: httpClient, tokenStore: tokenStore)
    }

    public func lookup(_ query: LegalDevelopmentQuery) async -> LegalDevelopmentLookupResult {
        // LegiScan wants a state filter: the state's postal code, else "ALL".
        let state = query.jurisdiction.flatMap(StatutoryJurisdictionMapper.postalCode(forJurisdiction:)) ?? "ALL"
        do {
            let response = try await client.search(term: query.terms, state: state, limit: query.limit)
            return LegalDevelopmentLookupResult(developments: response.results.prefix(query.limit).compactMap(Self.development(from:)))
        } catch LegiScanError.missingKey {
            return LegalDevelopmentLookupResult(note: "Add a LegiScan API key in Settings to track bills.")
        } catch {
            return LegalDevelopmentLookupResult(note: "LegiScan lookup was unavailable for this query.")
        }
    }

    static func development(from bill: LegiScanBill) -> LegalDevelopment? {
        guard let title = bill.title else { return nil }
        let jurisdiction = bill.state ?? "Unknown"
        return LegalDevelopment(
            sourceID: "legiscan",
            sourceName: "LegiScan",
            kind: .legislative,
            identifier: "\(jurisdiction) \(bill.billNumber ?? String(bill.billId ?? 0))",
            title: title,
            jurisdiction: jurisdiction,
            status: bill.lastAction,
            date: bill.lastActionDate,
            url: bill.url
        )
    }
}

public enum LegiScanError: Error, Equatable, Sendable {
    case missingKey, invalidResponse, decodingFailed, serverError(statusCode: Int), transportFailed(String)
}

public protocol LegiScanClientProtocol: Sendable {
    func search(term: String, state: String, limit: Int) async throws -> LegiScanResponse
}

public struct LegiScanBill: Decodable, Sendable, Equatable {
    public let billId: Int?
    public let billNumber: String?
    public let state: String?
    public let title: String?
    public let lastAction: String?
    public let lastActionDate: String?
    public let url: String?
}

/// LegiScan returns `searchresult` as a dictionary keyed by numeric strings ("0", "1", …) plus a
/// "summary" entry, so the bills are decoded by iterating dynamic keys and skipping "summary".
public struct LegiScanResponse: Decodable, Sendable, Equatable {
    public let status: String?
    public let results: [LegiScanBill]

    private enum CodingKeys: String, CodingKey { case status, searchresult }
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.intValue = intValue; self.stringValue = String(intValue) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        var bills: [LegiScanBill] = []
        if let nested = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: .searchresult) {
            for key in nested.allKeys where key.stringValue.lowercased() != "summary" {
                if let bill = try? nested.decode(LegiScanBill.self, forKey: key) {
                    bills.append(bill)
                }
            }
        }
        results = bills
    }
}

public final class LegiScanClient: LegiScanClientProtocol, @unchecked Sendable {
    private let httpClient: any AuthorizedHTTPClientProtocol
    private let tokenStore: any APIKeyStoreProtocol

    public init(httpClient: any AuthorizedHTTPClientProtocol, tokenStore: any APIKeyStoreProtocol) {
        self.httpClient = httpClient
        self.tokenStore = tokenStore
    }

    public func search(term: String, state: String, limit: Int) async throws -> LegiScanResponse {
        guard let key = (try? tokenStore.loadAPIKey(for: .legiScan)) ?? nil, !key.isEmpty else {
            throw LegiScanError.missingKey
        }
        var components = URLComponents(string: "https://api.legiscan.com/")!
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "op", value: "getSearch"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "query", value: term)
        ]
        guard let url = components.url else { throw LegiScanError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await httpClient.sendUnauthenticated(request, relatedResearchSessionID: nil) }
        catch { throw LegiScanError.transportFailed(error.localizedDescription) }

        switch response.statusCode {
        case 200..<300:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            do { return try decoder.decode(LegiScanResponse.self, from: data) }
            catch { throw LegiScanError.decodingFailed }
        case 500...599: throw LegiScanError.serverError(statusCode: response.statusCode)
        default: throw LegiScanError.invalidResponse
        }
    }
}
