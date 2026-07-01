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
            // A named rulemaking (docket ID in the query, e.g. EPA-HQ-OW-2021-0602) gets the
            // docket's own timeline — its metadata plus its documents, newest first — instead
            // of a keyword search across all of Regulations.gov.
            if let docketID = Self.docketID(in: query.terms),
               let timeline = try? await docketTimeline(docketID: docketID, limit: query.limit),
               !timeline.isEmpty {
                return LegalDevelopmentLookupResult(developments: timeline)
            }
            let response = try await client.searchDocuments(term: query.terms, limit: query.limit)
            return LegalDevelopmentLookupResult(developments: response.data.prefix(query.limit).compactMap(Self.development(from:)))
        } catch RegulationsGovError.missingKey {
            return LegalDevelopmentLookupResult(note: "Add a Regulations.gov API key in Settings to track federal rulemaking.")
        } catch {
            return LegalDevelopmentLookupResult(note: "Regulations.gov lookup was unavailable for this query.")
        }
    }

    /// The named docket (as a development) followed by its documents, newest first.
    private func docketTimeline(docketID: String, limit: Int) async throws -> [LegalDevelopment] {
        var developments: [LegalDevelopment] = []
        if let docket = try? await client.fetchDocket(id: docketID) {
            developments.append(Self.development(fromDocket: docket))
        }
        let documents = try await client.documentsForDocket(id: docketID, limit: limit)
        developments += documents.data.prefix(limit).compactMap(Self.development(from:))
        return developments
    }

    /// A Regulations.gov docket ID in free text (e.g. `EPA-HQ-OW-2021-0602`,
    /// `FDA-2023-N-1234`): agency prefix, optional program segments, a year, and a
    /// trailing number. Nil when the text names no specific rulemaking.
    public static func docketID(in text: String) -> String? {
        let pattern = #"(?i)\b[A-Z]{2,10}(?:-[A-Z0-9]{1,10}){0,4}-(?:19|20)\d{2}(?:-[A-Z]{1,3})?-\d{2,6}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange]).uppercased()
    }

    static func development(fromDocket docket: RegulationsGovDocket) -> LegalDevelopment {
        let attributes = docket.attributes
        let status = [attributes.docketType, attributes.agencyId.map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        return LegalDevelopment(
            sourceID: "regulations-gov",
            sourceName: "Regulations.gov",
            kind: .regulatory,
            identifier: "Docket \(docket.id)",
            title: attributes.title ?? docket.id,
            jurisdiction: "Federal",
            status: status.isEmpty ? nil : status,
            date: attributes.modifyDate,
            summary: "Rulemaking docket — the documents below are its most recent filings.",
            url: "https://www.regulations.gov/docket/\(docket.id)"
        )
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

    /// Fetches one rulemaking docket's metadata (`/v4/dockets/{id}`).
    func fetchDocket(id: String) async throws -> RegulationsGovDocket

    /// Fetches a docket's documents, newest first (`/v4/documents?filter[docketId]=`).
    func documentsForDocket(id: String, limit: Int) async throws -> RegulationsGovResponse
}

public extension RegulationsGovClientProtocol {
    /// Defaults so stubs/conformers that don't browse dockets still compile.
    func fetchDocket(id: String) async throws -> RegulationsGovDocket {
        throw RegulationsGovError.invalidResponse
    }

    func documentsForDocket(id: String, limit: Int) async throws -> RegulationsGovResponse {
        throw RegulationsGovError.invalidResponse
    }
}

public struct RegulationsGovResponse: Decodable, Sendable, Equatable {
    public let data: [RegulationsGovDocument]
}

public struct RegulationsGovDocketResponse: Decodable, Sendable, Equatable {
    public let data: RegulationsGovDocket
}

public struct RegulationsGovDocket: Decodable, Sendable, Equatable {
    public let id: String
    public let attributes: Attributes
    public struct Attributes: Decodable, Sendable, Equatable {
        public let title: String?
        public let docketType: String?
        public let agencyId: String?
        public let modifyDate: String?

        public init(title: String?, docketType: String?, agencyId: String?, modifyDate: String?) {
            self.title = title
            self.docketType = docketType
            self.agencyId = agencyId
            self.modifyDate = modifyDate
        }
    }

    public init(id: String, attributes: Attributes) {
        self.id = id
        self.attributes = attributes
    }
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

    public func fetchDocket(id: String) async throws -> RegulationsGovDocket {
        guard let key = (try? tokenStore.loadAPIKey(for: .regulationsGov)) ?? nil, !key.isEmpty else {
            throw RegulationsGovError.missingKey
        }
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.regulations.gov/v4/dockets/\(encoded)") else {
            throw RegulationsGovError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")

        let (data, response) = try await Self.send(httpClient, request)
        switch response.statusCode {
        case 200..<300:
            do { return try JSONDecoder().decode(RegulationsGovDocketResponse.self, from: data).data }
            catch { throw RegulationsGovError.decodingFailed }
        case 500...599: throw RegulationsGovError.serverError(statusCode: response.statusCode)
        default: throw RegulationsGovError.invalidResponse
        }
    }

    public func documentsForDocket(id: String, limit: Int) async throws -> RegulationsGovResponse {
        guard let key = (try? tokenStore.loadAPIKey(for: .regulationsGov)) ?? nil, !key.isEmpty else {
            throw RegulationsGovError.missingKey
        }
        var components = URLComponents(string: "https://api.regulations.gov/v4/documents")!
        components.queryItems = [
            URLQueryItem(name: "filter[docketId]", value: id),
            URLQueryItem(name: "sort", value: "-postedDate"),
            URLQueryItem(name: "page[size]", value: String(max(5, min(limit, 250))))
        ]
        guard let url = components.url else { throw RegulationsGovError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")

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
