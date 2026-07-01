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
            var developments = response.results.prefix(query.limit).compactMap(Self.development(from:))
            // When the query names a specific bill ("HB 123"), enrich the top hit with
            // getBill detail — description, sponsors, status date, and the bill-text link.
            if BillReference.billNumber(in: query.terms) != nil,
               let first = response.results.first, let billId = first.billId,
               let detail = try? await client.getBill(id: billId),
               let enriched = Self.development(from: first, detail: detail) {
                developments = [enriched] + developments.dropFirst()
            }
            return LegalDevelopmentLookupResult(developments: developments)
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

    /// A named bill's development enriched with getBill detail: the description and
    /// sponsors as the summary, the status date, and the official bill-text link.
    static func development(from bill: LegiScanBill, detail: LegiScanBillDetail) -> LegalDevelopment? {
        guard var development = development(from: bill) else { return nil }
        var summaryParts: [String] = []
        if let description = detail.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            summaryParts.append(description.count > 400 ? String(description.prefix(400)) + "…" : description)
        }
        let sponsorNames = detail.sponsors.compactMap(\.name).prefix(5)
        if !sponsorNames.isEmpty {
            summaryParts.append("Sponsors: \(sponsorNames.joined(separator: ", "))\(detail.sponsors.count > 5 ? ", …" : "")")
        }
        if !summaryParts.isEmpty {
            development.summary = summaryParts.joined(separator: "\n")
        }
        if let statusDate = detail.statusDate, !statusDate.isEmpty {
            development.date = statusDate
        }
        if let textLink = detail.texts.last?.stateLink ?? detail.texts.last?.url {
            development.url = textLink
        }
        return development
    }
}

public enum LegiScanError: Error, Equatable, Sendable {
    case missingKey, invalidResponse, decodingFailed, serverError(statusCode: Int), transportFailed(String)
}

public protocol LegiScanClientProtocol: Sendable {
    func search(term: String, state: String, limit: Int) async throws -> LegiScanResponse

    /// Fetches one bill's detail (`op=getBill`): description, status, sponsors, texts.
    func getBill(id: Int) async throws -> LegiScanBillDetail
}

public extension LegiScanClientProtocol {
    /// Default so stubs/conformers that don't fetch bill detail still compile.
    func getBill(id: Int) async throws -> LegiScanBillDetail {
        throw LegiScanError.invalidResponse
    }
}

/// The subset of LegiScan's `getBill` payload the app uses to enrich a named bill.
public struct LegiScanBillDetail: Decodable, Sendable, Equatable {
    public let description: String?
    public let statusDate: String?
    public let sponsors: [Sponsor]
    public let texts: [Text]

    public struct Sponsor: Decodable, Sendable, Equatable {
        public let name: String?
        public init(name: String?) { self.name = name }
    }

    public struct Text: Decodable, Sendable, Equatable {
        public let stateLink: String?
        public let url: String?
        public init(stateLink: String?, url: String?) {
            self.stateLink = stateLink
            self.url = url
        }
    }

    public init(description: String?, statusDate: String?, sponsors: [Sponsor] = [], texts: [Text] = []) {
        self.description = description
        self.statusDate = statusDate
        self.sponsors = sponsors
        self.texts = texts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.statusDate = try container.decodeIfPresent(String.self, forKey: .statusDate)
        self.sponsors = (try? container.decodeIfPresent([Sponsor].self, forKey: .sponsors)) ?? []
        self.texts = (try? container.decodeIfPresent([Text].self, forKey: .texts)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case description, statusDate, sponsors, texts
    }
}

/// `op=getBill` wraps the bill under a `bill` key.
public struct LegiScanBillDetailResponse: Decodable, Sendable, Equatable {
    public let bill: LegiScanBillDetail
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

    public func getBill(id: Int) async throws -> LegiScanBillDetail {
        guard let key = (try? tokenStore.loadAPIKey(for: .legiScan)) ?? nil, !key.isEmpty else {
            throw LegiScanError.missingKey
        }
        var components = URLComponents(string: "https://api.legiscan.com/")!
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "op", value: "getBill"),
            URLQueryItem(name: "id", value: String(id))
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
            do { return try decoder.decode(LegiScanBillDetailResponse.self, from: data).bill }
            catch { throw LegiScanError.decodingFailed }
        case 500...599: throw LegiScanError.serverError(statusCode: response.statusCode)
        default: throw LegiScanError.invalidResponse
        }
    }
}
