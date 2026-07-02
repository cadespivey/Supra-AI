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
            var provisions: [StatutoryProvision] = []
            var fetchedText = 0
            for result in response.results.prefix(query.limit) {
                // Section-level (granule) hits: fetch the official section text so the
                // provision is real, citable primary law — capped to bound latency.
                if let packageId = result.packageId, let granuleId = result.granuleId,
                   fetchedText < Self.maxSectionTextFetches,
                   let text = try? await client.fetchGranuleText(packageId: packageId, granuleId: granuleId),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fetchedText += 1
                    provisions.append(Self.sectionProvision(from: result, packageId: packageId, granuleId: granuleId, text: text))
                } else if let provision = Self.provision(from: result) {
                    provisions.append(provision)
                }
            }
            let note = (provisions.isEmpty || fetchedText > 0)
                ? nil
                : "govinfo returned official U.S. Code package-level locators only; section text was not retrieved, so those locators were not used as citable primary law."
            return StatutoryLookupResult(provisions: provisions, note: note)
        } catch GovInfoError.missingKey {
            return StatutoryLookupResult(note: "Add a govinfo API key in Settings for official U.S. Code lookups.")
        } catch {
            return StatutoryLookupResult(note: "govinfo lookup was unavailable for this query.")
        }
    }

    /// The most section-text fetches per lookup — bounds latency AND keeps a lookup
    /// (search + fetches) comfortably inside the client's local per-minute rate budget.
    static let maxSectionTextFetches = 2
    /// Cap stored section text (some sections run very long).
    static let maxSectionTextLength = 8_000

    /// A citable provision from a granule-level (section) hit with fetched text.
    static func sectionProvision(from result: GovInfoResult, packageId: String, granuleId: String, text: String) -> StatutoryProvision {
        let cleaned = ECFRStatutorySource.stripHTML(text)
        let capped = cleaned.count > maxSectionTextLength
            ? String(cleaned.prefix(maxSectionTextLength)) + "…"
            : cleaned
        let citation = Self.uscCitation(packageId: packageId, granuleId: granuleId) ?? result.title ?? granuleId
        return StatutoryProvision(
            sourceID: "govinfo",
            sourceName: "govinfo",
            weightTier: .currencyVerifiable,
            jurisdictionID: packageId,
            jurisdictionName: "United States Code",
            citation: citation,
            heading: result.title,
            snippet: String(capped.prefix(280)),
            text: capped,
            url: "https://www.govinfo.gov/app/details/\(packageId)/\(granuleId)",
            locatorPath: "\(packageId)/\(granuleId)",
            effectiveDate: result.dateIssued,
            currencyCaveat: nil,
            isCitableAuthority: true   // real official section text retrieved
        )
    }

    /// Derives a "11 U.S.C. § 701"-style citation from USCODE package/granule ids
    /// (`USCODE-2023-title11` / `…-sec701`). Nil when the ids don't carry both parts.
    public static func uscCitation(packageId: String, granuleId: String) -> String? {
        guard let titleRange = packageId.range(of: #"title(\d+[A-Za-z]?)"#, options: .regularExpression),
              let secRange = granuleId.range(of: #"sec[0-9][0-9A-Za-z\-–.]*$"#, options: .regularExpression) else {
            return nil
        }
        let title = packageId[titleRange].dropFirst("title".count)
        let section = granuleId[secRange].dropFirst("sec".count)
        return "\(title) U.S.C. § \(section)"
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

    /// Fetches a granule's (U.S. Code section's) rendered text. Throwing conformers
    /// degrade to locator-only results.
    func fetchGranuleText(packageId: String, granuleId: String) async throws -> String
}

public extension GovInfoClientProtocol {
    /// Default so stubs/conformers that don't fetch section text still compile.
    func fetchGranuleText(packageId: String, granuleId: String) async throws -> String {
        throw GovInfoError.invalidResponse
    }
}

public struct GovInfoSearchResponse: Decodable, Sendable, Equatable {
    public let results: [GovInfoResult]
}

public struct GovInfoResult: Decodable, Sendable, Equatable {
    public let title: String?
    public let packageId: String?
    /// Present on granule-level (section-level) hits, e.g.
    /// `USCODE-2023-title11-chap7-subchapI-sec701`; nil on package-level hits.
    public let granuleId: String?
    public let dateIssued: String?
    public let collectionCode: String?

    public init(title: String?, packageId: String?, granuleId: String? = nil, dateIssued: String?, collectionCode: String?) {
        self.title = title
        self.packageId = packageId
        self.granuleId = granuleId
        self.dateIssued = dateIssued
        self.collectionCode = collectionCode
    }
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

    public func fetchGranuleText(packageId: String, granuleId: String) async throws -> String {
        guard let key = (try? tokenStore.loadAPIKey(for: .govInfo)) ?? nil, !key.isEmpty else {
            throw GovInfoError.missingKey
        }
        // Rendered HTML of the section from the official content endpoint.
        guard let encodedPackage = packageId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedGranule = granuleId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.govinfo.gov/packages/\(encodedPackage)/granules/\(encodedGranule)/htm") else {
            throw GovInfoError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")

        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await httpClient.sendUnauthenticated(request, relatedResearchSessionID: nil) }
        catch { throw GovInfoError.transportFailed(error.localizedDescription) }

        switch response.statusCode {
        case 200..<300:
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                throw GovInfoError.decodingFailed
            }
            return text
        case 500...599: throw GovInfoError.serverError(statusCode: response.statusCode)
        default: throw GovInfoError.invalidResponse
        }
    }
}
