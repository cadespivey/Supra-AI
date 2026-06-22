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
    private let transport: HTTPTransport
    private let redactsQueryValues: Bool

    public init(
        keyStore: any APIKeyStoreProtocol,
        policy: any NetworkPolicyServiceProtocol,
        logger: NetworkRequestLogger,
        rateLimitTracker: RateLimitTracker = RateLimitTracker(),
        redactsQueryValues: Bool = true,
        transport: @escaping HTTPTransport = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.keyStore = keyStore
        self.policy = policy
        self.logger = logger
        self.rateLimitTracker = rateLimitTracker
        self.redactsQueryValues = redactsQueryValues
        self.transport = transport
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

        let logID = try await logger.recordApprovedRequest(
            url: url,
            method: method,
            relatedResearchSessionID: relatedResearchSessionID,
            requestMetadataJSON: requestMetadataJSON(for: outgoing)
        )

        do {
            let (data, response) = try await transport(outgoing)
            guard let httpResponse = response as? HTTPURLResponse else {
                try await logger.finishRequest(
                    id: logID,
                    statusCode: nil,
                    errorMessage: AuthorizedHTTPClientError.invalidResponse.localizedDescription
                )
                throw AuthorizedHTTPClientError.invalidResponse
            }
            // Best-effort: a logging failure must not discard a successful response
            // (the catch below would otherwise re-log this success as a failure).
            try? await logger.finishRequest(id: logID, statusCode: httpResponse.statusCode)
            return (data, httpResponse)
        } catch {
            try? await logger.finishRequest(id: logID, statusCode: nil, errorMessage: error.localizedDescription)
            throw error
        }
    }

    private func requestMetadataJSON(for request: URLRequest) -> String? {
        guard let url = request.url else { return nil }
        let sanitizedHeaders = (request.allHTTPHeaderFields ?? [:]).filter { key, _ in
            key.lowercased() != "authorization"
        }
        // The query string carries the user's privileged search terms (e.g. the
        // CourtListener `q=` parameter). Unless query-term logging is explicitly
        // enabled, redact parameter *values* to a stable fingerprint while keeping
        // the parameter names, matching the audit-event privacy guarantee.
        let query = url.query.map { redactsQueryValues ? Self.redactedQuery($0) : $0 }
        let metadata = NetworkRequestAuditMetadata(
            query: query,
            headers: sanitizedHeaders.isEmpty ? nil : sanitizedHeaders
        )
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces each query parameter's value with a stable fingerprint, preserving
    /// the parameter names so the *shape* of the request remains auditable.
    static func redactedQuery(_ query: String) -> String {
        query.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return String(pair) }
            let value = String(parts[1])
            let marker = value.isEmpty ? "" : "#\(fingerprint(value))"
            return "\(parts[0])=\(marker)"
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
