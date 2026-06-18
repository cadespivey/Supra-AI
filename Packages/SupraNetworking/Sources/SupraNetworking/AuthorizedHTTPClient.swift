import Foundation

public protocol AuthorizedHTTPClientProtocol: Sendable {
    func send(_ request: URLRequest, relatedResearchSessionID: String?) async throws -> (Data, HTTPURLResponse)
}

public final class AuthorizedHTTPClient: AuthorizedHTTPClientProtocol, @unchecked Sendable {
    public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let keyStore: any APIKeyStoreProtocol
    private let policy: any NetworkPolicyServiceProtocol
    private let logger: NetworkRequestLogger
    private let rateLimitTracker: RateLimitTracker
    private let transport: HTTPTransport

    public init(
        keyStore: any APIKeyStoreProtocol,
        policy: any NetworkPolicyServiceProtocol,
        logger: NetworkRequestLogger,
        rateLimitTracker: RateLimitTracker = RateLimitTracker(),
        transport: @escaping HTTPTransport = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.keyStore = keyStore
        self.policy = policy
        self.logger = logger
        self.rateLimitTracker = rateLimitTracker
        self.transport = transport
    }

    public func send(
        _ request: URLRequest,
        relatedResearchSessionID: String? = nil
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
                requestMetadataJSON: Self.requestMetadataJSON(for: request)
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
                requestMetadataJSON: Self.requestMetadataJSON(for: request)
            )
            throw error
        }

        guard let token = try keyStore.loadCourtListenerToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw AuthorizedHTTPClientError.missingToken
        }

        var authorizedRequest = request
        authorizedRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        authorizedRequest.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

        let logID = try await logger.recordApprovedRequest(
            url: url,
            method: method,
            relatedResearchSessionID: relatedResearchSessionID,
            requestMetadataJSON: Self.requestMetadataJSON(for: authorizedRequest)
        )

        do {
            let (data, response) = try await transport(authorizedRequest)
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

    private static func requestMetadataJSON(for request: URLRequest) -> String? {
        guard let url = request.url else { return nil }
        let sanitizedHeaders = (request.allHTTPHeaderFields ?? [:]).filter { key, _ in
            key.lowercased() != "authorization"
        }
        let metadata = NetworkRequestAuditMetadata(
            query: url.query,
            headers: sanitizedHeaders.isEmpty ? nil : sanitizedHeaders
        )
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private struct NetworkRequestAuditMetadata: Encodable {
    let query: String?
    let headers: [String: String]?
}

public enum AuthorizedHTTPClientError: Error, Equatable, Sendable {
    case missingToken
    case invalidResponse
}
