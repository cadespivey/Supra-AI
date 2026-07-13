import Foundation

public protocol NetworkPolicyServiceProtocol: Sendable {
    func isAllowed(_ url: URL) -> Bool
    func validate(_ url: URL) throws
    func redirectPolicy(for initialURL: URL, credentialOwner: String?) throws -> RedirectPolicy
}

public extension NetworkPolicyServiceProtocol {
    /// The default is exact-origin only. The initial URL has already passed this policy's
    /// validation, which permits tightly scoped loopback policies in integration tests without
    /// exposing an HTTPS bypass on `RedirectPolicy`'s public initializer.
    func redirectPolicy(for initialURL: URL, credentialOwner: String?) throws -> RedirectPolicy {
        try validate(initialURL)
        return try RedirectPolicy(
            trustedInitialURL: initialURL,
            service: initialURL.host?.lowercased() ?? "unknown-service",
            credentialOwner: credentialOwner
        )
    }
}

public final class NetworkPolicyService: NetworkPolicyServiceProtocol, @unchecked Sendable {
    private let allowedHosts: Set<String>
    private let allowedPortsByHost: [String: Set<Int>]

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
        ],
        allowedPortsByHost: [String: Set<Int>] = [:]
    ) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.allowedPortsByHost = Dictionary(uniqueKeysWithValues: allowedPortsByHost.map {
            ($0.key.lowercased(), $0.value)
        })
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
        if let port = components.port,
           !(allowedPortsByHost[host]?.contains(port) ?? false) {
            throw NetworkPolicyError.portNotAllowed(host: host, port: port)
        }
    }

    public func redirectPolicy(for initialURL: URL, credentialOwner: String?) throws -> RedirectPolicy {
        try validate(initialURL)
        guard let host = initialURL.host?.lowercased() else {
            throw NetworkPolicyError.missingHost
        }

        switch host {
        case "www.courtlistener.com", "courtlistener.com":
            return try pairedPolicy(
                initialURL: initialURL,
                service: "courtlistener-api",
                hosts: ("www.courtlistener.com", "courtlistener.com"),
                credentialOwner: credentialOwner
            )
        case "www.openlegalcodes.org", "openlegalcodes.org":
            return try pairedPolicy(
                initialURL: initialURL,
                service: "open-legal-codes",
                hosts: ("www.openlegalcodes.org", "openlegalcodes.org"),
                credentialOwner: credentialOwner
            )
        case "www.ecfr.gov", "ecfr.gov":
            return try pairedPolicy(
                initialURL: initialURL,
                service: "ecfr",
                hosts: ("www.ecfr.gov", "ecfr.gov"),
                credentialOwner: credentialOwner
            )
        case "www.federalregister.gov", "federalregister.gov":
            return try pairedPolicy(
                initialURL: initialURL,
                service: "federal-register",
                hosts: ("www.federalregister.gov", "federalregister.gov"),
                credentialOwner: credentialOwner
            )
        default:
            return try RedirectPolicy(
                initialURL: initialURL,
                service: host,
                credentialOwner: credentialOwner
            )
        }
    }

    private func pairedPolicy(
        initialURL: URL,
        service: String,
        hosts: (String, String),
        credentialOwner: String?
    ) throws -> RedirectPolicy {
        let first = URL(string: "https://\(hosts.0)")!
        let second = URL(string: "https://\(hosts.1)")!
        return try RedirectPolicy(
            initialURL: initialURL,
            service: service,
            credentialOwner: credentialOwner,
            additionalOrigins: [
                try .init(url: first, service: service, credentialOwner: credentialOwner),
                try .init(url: second, service: service, credentialOwner: credentialOwner)
            ],
            crossOriginRules: [
                try .init(
                    from: first,
                    to: second,
                    service: service
                ),
                try .init(
                    from: second,
                    to: first,
                    service: service
                )
            ]
        )
    }
}
