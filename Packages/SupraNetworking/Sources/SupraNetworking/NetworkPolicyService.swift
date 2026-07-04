import Foundation

public protocol NetworkPolicyServiceProtocol: Sendable {
    func isAllowed(_ url: URL) -> Bool
    func validate(_ url: URL) throws
}

public final class NetworkPolicyService: NetworkPolicyServiceProtocol, @unchecked Sendable {
    private let allowedHosts: Set<String>

    public init(
        allowedHosts: Set<String> = [
            "www.courtlistener.com",
            "courtlistener.com",
            // CourtListener's own public asset CDN — used only for user-initiated,
            // token-free opinion PDF downloads (see SECURITY.md).
            "storage.courtlistener.com",
            // Open Legal Codes — free, key-less statutory lookups. Always token-free
            // (the CourtListener token is gated to the courtlistener hosts above).
            "openlegalcodes.org",
            "www.openlegalcodes.org",
            // eCFR — official Code of Federal Regulations, free + key-less. Token-free.
            "www.ecfr.gov",
            "ecfr.gov",
            // Federal Register — official daily publication (regulatory developments), key-less.
            "www.federalregister.gov",
            "federalregister.gov",
            // Key'd legal-data sources (the key is read from the Keychain, not the URL where avoidable).
            "api.govinfo.gov",        // official U.S. Code (USCODE)
            // govinfo's KEYLESS citation link service + official section HTML it
            // redirects to (exact-cite U.S.C. resolution — search can't find a
            // section because a section's text never cites itself). Token-free.
            "www.govinfo.gov",
            "v3.openstates.org",      // state/federal bills
            "api.regulations.gov",    // federal rulemaking dockets
            // Government-records connectors — public, key-less, token-free.
            // Only hosts the client actually FETCHES are listed; filing URLs
            // built for the user's browser (www.sec.gov archives) are not.
            "data.sec.gov",           // SEC EDGAR submissions + XBRL APIs
            "www.consumerfinance.gov", // CFPB consumer-complaint database API
            "www.nlrb.gov"            // NLRB official CSV exports
        ]
    ) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
    }

    public func isAllowed(_ url: URL) -> Bool {
        (try? validate(url)) != nil
    }

    public func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw NetworkPolicyError.insecureScheme(url.scheme)
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw NetworkPolicyError.missingHost
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw NetworkPolicyError.invalidURL
        }
        if components.user != nil || components.password != nil {
            throw NetworkPolicyError.embeddedCredentials
        }
        guard allowedHosts.contains(host) else {
            throw NetworkPolicyError.hostNotAllowed(host)
        }
    }
}
