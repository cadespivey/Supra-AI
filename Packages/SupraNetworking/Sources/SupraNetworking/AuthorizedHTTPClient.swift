import Foundation

public protocol AuthorizedHTTPClientProtocol: Sendable {
    func send(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse)

    /// Sends an allow-listed, rate-limited, logged request WITHOUT attaching the
    /// CourtListener token — for public resources (e.g. opinion PDFs on the
    /// CourtListener storage CDN) where the token must not be sent off the API host.
    func sendUnauthenticated(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse)
}

public extension AuthorizedHTTPClientProtocol {
    /// Default so conformers that don't fetch public resources still compile.
    func sendUnauthenticated(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse) {
        throw AuthorizedHTTPClientError.invalidResponse
    }
}

public final class AuthorizedHTTPClient: AuthorizedHTTPClientProtocol, @unchecked Sendable {
    public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Hosts the CourtListener API token may be sent to. The network allow-list also
    /// permits the token-free storage CDN (storage.courtlistener.com) for opinion PDFs,
    /// so the token is gated to the API hosts only — it must never reach the CDN.
    static let tokenAllowedHosts: Set<String> = ["www.courtlistener.com", "courtlistener.com"]

    private let keyStore: any APIKeyStoreProtocol
    private let policy: any NetworkPolicyServiceProtocol
    private let logger: NetworkRequestLogger
    private let rateLimitTracker: RateLimitTracker
    private let policyTransport: PolicyEnforcingURLSessionTransport
    private let injectedTestTransport: HTTPTransport?
    private let redactsQueryValues: Bool

    public init(
        keyStore: any APIKeyStoreProtocol,
        policy: any NetworkPolicyServiceProtocol,
        logger: NetworkRequestLogger,
        rateLimitTracker: RateLimitTracker = RateLimitTracker(),
        redactsQueryValues: Bool = true,
        policyTransport: PolicyEnforcingURLSessionTransport = PolicyEnforcingURLSessionTransport()
    ) {
        self.keyStore = keyStore
        self.policy = policy
        self.logger = logger
        self.rateLimitTracker = rateLimitTracker
        self.redactsQueryValues = redactsQueryValues
        self.policyTransport = policyTransport
        self.injectedTestTransport = nil
    }

    /// Closure injection is internal and available to `@testable` package tests only. A public
    /// arbitrary closure could hide a redirecting `URLSession` and recreate SA-ACR-005.
    init(
        keyStore: any APIKeyStoreProtocol,
        policy: any NetworkPolicyServiceProtocol,
        logger: NetworkRequestLogger,
        rateLimitTracker: RateLimitTracker = RateLimitTracker(),
        redactsQueryValues: Bool = true,
        transport: @escaping HTTPTransport
    ) {
        self.keyStore = keyStore
        self.policy = policy
        self.logger = logger
        self.rateLimitTracker = rateLimitTracker
        self.redactsQueryValues = redactsQueryValues
        self.policyTransport = PolicyEnforcingURLSessionTransport()
        self.injectedTestTransport = transport
    }

    public func send(
        _ request: URLRequest,
        relatedResearchSessionID: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try await perform(request, authenticated: true, relatedResearchSessionID: relatedResearchSessionID)
    }

    public func sendUnauthenticated(
        _ request: URLRequest,
        relatedResearchSessionID: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try await perform(request, authenticated: false, relatedResearchSessionID: relatedResearchSessionID)
    }

    /// Shared request path: policy check → rate-limit → (optional) token → log →
    /// transport → log. `authenticated == false` skips token injection entirely so
    /// the `Authorization` header is never sent (used for the public storage CDN).
    private func perform(
        _ request: URLRequest,
        authenticated: Bool,
        relatedResearchSessionID: String?
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw NetworkPolicyError.invalidURL
        }
        let method = request.httpMethod ?? "GET"

        do {
            try policy.validate(url)
        } catch {
            _ = try? await logger.recordBlockedRequest(
                url: url,
                method: method,
                blockedReason: String(describing: error),
                relatedResearchSessionID: relatedResearchSessionID,
                requestMetadataJSON: requestMetadataJSON(for: request)
            )
            throw error
        }

        do {
            _ = try await rateLimitTracker.reserveSlot()
        } catch {
            // Best-effort logging: a logging failure must not mask the rate-limit
            // error the caller needs to see (matches the policy-block path above).
            _ = try? await logger.recordBlockedRequest(
                url: url,
                method: method,
                blockedReason: String(describing: error),
                relatedResearchSessionID: relatedResearchSessionID,
                requestMetadataJSON: requestMetadataJSON(for: request)
            )
            throw error
        }

        var outgoing = request
        if authenticated {
            // Defense-in-depth for the "token never reaches the CDN" invariant: the
            // allow-list also permits the token-free storage CDN, so gate token
            // injection on the host here rather than relying only on caller discipline
            // (sendUnauthenticated). An authenticated request to any non-API host fails
            // loudly instead of leaking the Authorization header.
            guard Self.tokenAllowedHosts.contains(url.host?.lowercased() ?? "") else {
                throw AuthorizedHTTPClientError.tokenHostNotAllowed
            }
            guard let token = try keyStore.loadCourtListenerToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else {
                throw AuthorizedHTTPClientError.missingToken
            }
            outgoing.setValue("application/json", forHTTPHeaderField: "Accept")
            outgoing.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }

        let credentialOwner: String?
        if authenticated {
            credentialOwner = "courtlistener-api"
        } else if RedirectPolicy.containsCredentialHeaders(outgoing) {
            credentialOwner = "request-credential:\(url.host?.lowercased() ?? "unknown")"
        } else {
            credentialOwner = nil
        }
        let redirectPolicy = try policy.redirectPolicy(
            for: url,
            credentialOwner: credentialOwner
        )

        let logID = try await logger.recordApprovedRequest(
            url: url,
            method: method,
            relatedResearchSessionID: relatedResearchSessionID,
            requestMetadataJSON: requestMetadataJSON(for: outgoing)
        )

        do {
            let data: Data
            let response: URLResponse
            let redirects: [RedirectAuditHop]
            if let injectedTestTransport {
                (data, response) = try await injectedTestTransport(outgoing)
                redirects = []
            } else {
                let result = try await policyTransport.data(for: outgoing, policy: redirectPolicy)
                data = result.data
                response = result.response
                redirects = result.redirects
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                try await logger.finishRequest(
                    id: logID,
                    statusCode: nil,
                    errorMessage: AuthorizedHTTPClientError.invalidResponse.localizedDescription
                )
                throw AuthorizedHTTPClientError.invalidResponse
            }
            await recordAllowedRedirects(
                redirects,
                finalStatusCode: httpResponse.statusCode,
                relatedResearchSessionID: relatedResearchSessionID
            )
            // Best-effort: a logging failure must not discard a successful response
            // (the catch below would otherwise re-log this success as a failure).
            try? await logger.finishRequest(
                id: logID,
                statusCode: redirects.first?.statusCode ?? httpResponse.statusCode
            )
            return (data, httpResponse)
        } catch NetworkPolicyError.redirectRejected(let rejection) {
            await recordAllowedRedirects(
                rejection.allowedHops,
                finalStatusCode: rejection.statusCode,
                relatedResearchSessionID: relatedResearchSessionID,
                terminalError: "redirectRejected"
            )
            let blockedURL = rejection.destinationURL ?? url
            var blockedRequest = URLRequest(url: blockedURL)
            blockedRequest.httpMethod = method
            _ = try? await logger.recordBlockedRequest(
                url: blockedURL,
                method: method,
                blockedReason: "redirectRejected:\(String(describing: rejection.reason))",
                relatedResearchSessionID: relatedResearchSessionID,
                requestMetadataJSON: requestMetadataJSON(for: blockedRequest)
            )
            try? await logger.finishRequest(
                id: logID,
                statusCode: rejection.allowedHops.first?.statusCode,
                errorMessage: "redirectRejected"
            )
            throw NetworkPolicyError.redirectRejected(rejection)
        } catch {
            try? await logger.finishRequest(id: logID, statusCode: nil, errorMessage: error.localizedDescription)
            throw error
        }
    }

    private func recordAllowedRedirects(
        _ redirects: [RedirectAuditHop],
        finalStatusCode: Int,
        relatedResearchSessionID: String?,
        terminalError: String? = nil
    ) async {
        for (index, hop) in redirects.enumerated() {
            var request = URLRequest(url: hop.destinationURL)
            request.httpMethod = hop.method
            guard let id = try? await logger.recordApprovedRequest(
                url: hop.destinationURL,
                method: hop.method,
                relatedResearchSessionID: relatedResearchSessionID,
                requestMetadataJSON: requestMetadataJSON(for: request)
            ) else {
                continue
            }
            let statusCode = redirects.indices.contains(index + 1)
                ? redirects[index + 1].statusCode
                : finalStatusCode
            try? await logger.finishRequest(
                id: id,
                statusCode: statusCode,
                errorMessage: index == redirects.count - 1 ? terminalError : nil
            )
        }
    }

    private func requestMetadataJSON(for request: URLRequest) -> String? {
        guard let url = request.url else { return nil }
        let sanitizedHeaders = Self.sanitizedHeaders(request.allHTTPHeaderFields ?? [:])
        // The query string can carry privileged search terms and, for some APIs,
        // credentials. Sensitive parameter names are always masked; other values
        // are fingerprinted unless query-term logging is explicitly enabled.
        let query = url.query.map { Self.sanitizedQuery($0, redactsValues: redactsQueryValues) }
        let metadata = NetworkRequestAuditMetadata(
            query: query,
            headers: sanitizedHeaders.isEmpty ? nil : sanitizedHeaders
        )
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func sanitizedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, item in
            let normalized = item.key.lowercased()
            if normalized == "authorization" {
                return
            }
            if sensitiveHeaderNames.contains(normalized) {
                result[item.key] = "#redacted"
            } else {
                result[item.key] = item.value
            }
        }
    }

    private static let sensitiveHeaderNames: Set<String> = [
        "x-api-key",
        "api-key",
        "apikey",
        "x-auth-token",
        "x-access-token",
        "ocp-apim-subscription-key"
    ]

    private static let sensitiveQueryParameterNames: Set<String> = [
        "key",
        "x-api-key",
        "x_api_key",
        "api_key",
        "apikey",
        "api-key",
        "access_token",
        "auth_token",
        "token",
        "client_secret",
        "subscription_key",
        "subscription-key",
        "ocp-apim-subscription-key"
    ]

    /// Replaces each query parameter's value with a stable fingerprint, preserving
    /// the parameter names so the *shape* of the request remains auditable.
    static func redactedQuery(_ query: String) -> String {
        sanitizedQuery(query, redactsValues: true)
    }

    static func sanitizedQuery(_ query: String, redactsValues: Bool) -> String {
        query.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return String(pair) }
            let name = String(parts[0])
            let value = String(parts[1])
            let normalizedName = name
                .removingPercentEncoding?
                .lowercased() ?? name.lowercased()
            let marker: String
            if value.isEmpty {
                marker = ""
            } else if sensitiveQueryParameterNames.contains(normalizedName) {
                marker = "#redacted"
            } else if redactsValues {
                marker = "#\(fingerprint(value))"
            } else {
                marker = value
            }
            return "\(name)=\(marker)"
        }.joined(separator: "&")
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return String(hash, radix: 16)
    }
}

private struct NetworkRequestAuditMetadata: Encodable {
    let query: String?
    let headers: [String: String]?
}

public enum AuthorizedHTTPClientError: Error, Equatable, Sendable {
    case missingToken
    case invalidResponse
    /// An authenticated request targeted a host that is not a CourtListener API host
    /// (e.g. the public storage CDN). The API token must never leave the API hosts.
    case tokenHostNotAllowed
}
