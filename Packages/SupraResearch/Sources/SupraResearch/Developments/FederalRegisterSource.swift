import Foundation

/// `LegalDevelopmentSource` backed by the Federal Register — federal regulatory developments
/// (rules, proposed rules, notices). Federal-only: it skips state-specific queries. Best-effort.
public struct FederalRegisterSource: LegalDevelopmentSource {
    public let id = "federal-register"
    public let displayName = "Federal Register"
    public let kind: LegalDevelopmentKind = .regulatory

    private let client: any FederalRegisterClientProtocol

    public init(client: any FederalRegisterClientProtocol) {
        self.client = client
    }

    public func lookup(_ query: LegalDevelopmentQuery) async -> LegalDevelopmentLookupResult {
        if let jurisdiction = query.jurisdiction,
           StatutoryJurisdictionMapper.postalCode(forJurisdiction: jurisdiction) != nil {
            return LegalDevelopmentLookupResult()   // a specific state → not the Federal Register's domain
        }
        do {
            let response = try await client.search(
                query: query.terms,
                limit: query.limit,
                publishedAfter: query.dateAfter,
                publishedBefore: query.dateBefore,
                documentType: Self.documentType(in: query.terms)
            )
            let developments = response.results.prefix(query.limit).compactMap(Self.development(from:))
            return LegalDevelopmentLookupResult(developments: Array(developments))
        } catch {
            return LegalDevelopmentLookupResult(note: "Federal Register lookup was unavailable for this query.")
        }
    }

    /// A Federal Register document-type filter implied by the query wording, or nil for
    /// an unfiltered search. ("proposed rule" → PRORULE must be checked before "rule".)
    public static func documentType(in terms: String) -> String? {
        let lower = terms.lowercased()
        if lower.contains("proposed rule") || lower.contains("nprm") { return "PRORULE" }
        if lower.contains("final rule") { return "RULE" }
        if lower.contains("executive order") || lower.contains("presidential") { return "PRESDOCU" }
        if lower.contains("notice") { return "NOTICE" }
        return nil
    }

    static func development(from document: FederalRegisterDocument) -> LegalDevelopment? {
        guard let title = document.title else { return nil }
        let agency = document.agencies?.first?.name
        let status = [document.type, agency.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        return LegalDevelopment(
            sourceID: "federal-register",
            sourceName: "Federal Register",
            kind: .regulatory,
            identifier: document.documentNumber.map { "FR Doc \($0)" } ?? title,
            title: title,
            jurisdiction: "Federal",
            status: status.isEmpty ? nil : status,
            date: document.publicationDate,
            summary: document.abstract,
            url: document.htmlUrl
        )
    }
}
