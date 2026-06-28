import Foundation
import SupraNetworking

/// `StatutorySource` backed by govinfo — the official U.S. Code (USCODE collection). Key'd
/// (`X-Api-Key` header, an api.data.gov key read from the token store). `.currencyVerifiable`: each
/// USCODE package carries a `dateIssued`, so for the same provision it OUTRANKS Open Legal Codes.
///
/// Note: govinfo's search is package/title-level (e.g. "U.S. Code, Title 11 — Bankruptcy"), not
/// section-level, so these results are locator notes until a section-text fetcher is added.
/// Federal-only; best-effort (a missing key or failure yields no provisions + a note).
public struct GovInfoStatutorySource: StatutorySource {
    public let id = "govinfo"
    public let displayName = "govinfo"
    public let weightTier: SourceWeightTier = .currencyVerifiable
    public let providesCurrency = true

    private let client: any GovInfoClientProtocol

    public init(client: any GovInfoClientProtocol) { self.client = client }

    public init(httpClient: any AuthorizedHTTPClientProtocol, tokenStore: any APIKeyStoreProtocol) {
        self.client = GovInfoClient(httpClient: httpClient, tokenStore: tokenStore)
    }

    public func lookup(_ query: StatutoryQuery) async -> StatutoryLookupResult {
        if let jurisdiction = query.jurisdiction,
           StatutoryJurisdictionMapper.postalCode(forJurisdiction: jurisdiction) != nil {
            return StatutoryLookupResult()   // a specific state — govinfo USCODE is federal
        }
        do {
            let response = try await client.searchUSCode(term: query.terms, limit: query.limit)
            let provisions = response.results.prefix(query.limit).compactMap(Self.provision(from:))
            let note = provisions.isEmpty
                ? nil
                : "govinfo returned official U.S. Code package-level locators only; section text was not retrieved, so those locators were not used as citable primary law."
            return StatutoryLookupResult(provisions: provisions, note: note)
        } catch GovInfoError.missingKey {
            return StatutoryLookupResult(note: "Add a govinfo API key in Settings for official U.S. Code lookups.")
        } catch {
            return StatutoryLookupResult(note: "govinfo lookup was unavailable for this query.")
        }
    }

    static func provision(from result: GovInfoResult) -> StatutoryProvision? {
        guard let packageId = result.packageId, let title = result.title else { return nil }
        return StatutoryProvision(
            sourceID: "govinfo",
            sourceName: "govinfo",
            weightTier: .currencyVerifiable,
            jurisdictionID: packageId,
            jurisdictionName: "United States Code",
            citation: title,
            heading: title,
            snippet: title,
            text: "Locator only: \(title)\n\nOfficial full text: https://www.govinfo.gov/app/details/\(packageId)",
            url: "https://www.govinfo.gov/app/details/\(packageId)",
            locatorPath: packageId,
            effectiveDate: result.dateIssued,   // a real issue date → no currency caveat
            currencyCaveat: nil,
            isCitableAuthority: false
        )
    }
}

public enum GovInfoError: Error, Equatable, Sendable {
    case missingKey, invalidResponse, decodingFailed, serverError(statusCode: Int), transportFailed(String)
}

public protocol GovInfoClientProtocol: Sendable {
    func searchUSCode(term: String, limit: Int) async throws -> GovInfoSearchResponse
}

public struct GovInfoSearchResponse: Decodable, Sendable, Equatable {
    public let results: [GovInfoResult]
}

public struct GovInfoResult: Decodable, Sendable, Equatable {
    public let title: String?
    public let packageId: String?
    public let dateIssued: String?
    public let collectionCode: String?
}

public final class GovInfoClient: GovInfoClientProtocol, @unchecked Sendable {
    private let httpClient: any AuthorizedHTTPClientProtocol
    private let tokenStore: any APIKeyStoreProtocol

    public init(httpClient: any AuthorizedHTTPClientProtocol, tokenStore: any APIKeyStoreProtocol) {
        self.httpClient = httpClient
        self.tokenStore = tokenStore
    }

    private struct SearchBody: Encodable {
        let query: String
        let pageSize: Int
        let offsetMark: String
    }

    public func searchUSCode(term: String, limit: Int) async throws -> GovInfoSearchResponse {
        guard let key = (try? tokenStore.loadAPIKey(for: .govInfo)) ?? nil, !key.isEmpty else {
            throw GovInfoError.missingKey
        }
        guard let url = URL(string: "https://api.govinfo.gov/search") else { throw GovInfoError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(
            SearchBody(query: "\(term) collection:USCODE", pageSize: max(1, min(limit, 20)), offsetMark: "*")
        )

        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await httpClient.sendUnauthenticated(request, relatedResearchSessionID: nil) }
        catch { throw GovInfoError.transportFailed(error.localizedDescription) }

        switch response.statusCode {
        case 200..<300:
            do { return try JSONDecoder().decode(GovInfoSearchResponse.self, from: data) }
            catch { throw GovInfoError.decodingFailed }
        case 500...599: throw GovInfoError.serverError(statusCode: response.statusCode)
        default: throw GovInfoError.invalidResponse
        }
    }
}
