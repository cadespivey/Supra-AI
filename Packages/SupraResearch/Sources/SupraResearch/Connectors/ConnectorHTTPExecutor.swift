import Foundation
import SupraNetworking

/// Shared request path for the government-data connectors: cache check →
/// pacing → `sendUnauthenticated` → bounded retry (429/5xx/transport) → status
/// mapping → cache write. Internal on purpose — the public surface is the
/// connector types, not a general HTTP framework.
///
/// `send` is never used: it is CourtListener-token-specific and must stay that
/// way. These sources are all public, key-less endpoints.
struct ConnectorHTTPExecutor: @unchecked Sendable {
    struct Response: Sendable {
        var data: Data
        var httpStatus: Int
        var fromCache: Bool
    }

    let connectorName: String
    let httpClient: any AuthorizedHTTPClientProtocol
    let pacer: ConnectorPacer
    let cache: any LegalDataConnectorCache
    let now: @Sendable () -> Date
    /// Injectable so retry tests don't actually wait.
    var retrySleeper: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    private static let maxAttempts = 3

    func execute(
        operation: String,
        request: URLRequest,
        requestParams: JSONValue = .object([:]),
        cacheTTL: TimeInterval?
    ) async throws -> Response {
        guard let url = request.url else {
            throw LegalDataConnectorError(
                kind: .validation,
                connectorName: connectorName,
                operation: operation,
                message: "The request had no URL."
            )
        }
        let key = FileLegalDataConnectorCache.cacheKey(
            method: request.httpMethod ?? "GET",
            url: url,
            params: requestParams
        )
        if cacheTTL != nil,
           let hit = try? await cache.get(key: key, now: now()),
           let payload = hit.rawPayload {
            return Response(data: payload, httpStatus: hit.httpStatus, fromCache: true)
        }

        var attempt = 0
        var lastError: LegalDataConnectorError?
        while attempt < Self.maxAttempts {
            attempt += 1
            await pacer.pace()
            do {
                let (data, response) = try await httpClient.sendUnauthenticated(request, relatedResearchSessionID: nil)
                let status = response.statusCode
                if (200..<300).contains(status) {
                    if let cacheTTL {
                        let entry = LegalDataCacheEntry(
                            connectorName: connectorName,
                            operation: operation,
                            requestURL: url.absoluteString,
                            requestParams: requestParams,
                            retrievedAt: now(),
                            expiresAt: now().addingTimeInterval(cacheTTL),
                            httpStatus: status,
                            rawPayload: data
                        )
                        try? await cache.put(entry, key: key)
                    }
                    return Response(data: data, httpStatus: status, fromCache: false)
                }
                let error = LegalDataConnectorError.fromHTTPStatus(
                    status, connectorName: connectorName, operation: operation, sourceURL: url.absoluteString
                )
                // Defer to the taxonomy's own retryable flag — a single source
                // of truth — so every 5xx (not just 502/503/504) is retried, as
                // the error it hands the caller already promises.
                guard error.retryable, attempt < Self.maxAttempts else {
                    throw error
                }
                lastError = error
                await retrySleeper(retryDelay(response: response, attempt: attempt))
            } catch let error as LegalDataConnectorError {
                throw error
            } catch NetworkPolicyError.localRateLimitExceeded {
                // The app-side rolling budget, not the remote source — report
                // it as the retryable rate limit it is, not a policy block.
                throw LegalDataConnectorError(
                    kind: .rateLimit,
                    connectorName: connectorName,
                    operation: operation,
                    sourceURL: url.absoluteString,
                    retryable: true,
                    message: "The local rate budget for this source is exhausted; retry shortly."
                )
            } catch is NetworkPolicyError {
                throw LegalDataConnectorError(
                    kind: .sourceUnavailable,
                    connectorName: connectorName,
                    operation: operation,
                    sourceURL: url.absoluteString,
                    retryable: false,
                    message: "The request was blocked by the app's network policy."
                )
            } catch {
                let transport = LegalDataConnectorError(
                    kind: .transport,
                    connectorName: connectorName,
                    operation: operation,
                    sourceURL: url.absoluteString,
                    retryable: true,
                    message: "The network request failed."
                )
                guard attempt < Self.maxAttempts else { throw transport }
                lastError = transport
                await retrySleeper(retryDelay(response: nil, attempt: attempt))
            }
        }
        throw lastError ?? LegalDataConnectorError(
            kind: .transport,
            connectorName: connectorName,
            operation: operation,
            sourceURL: url.absoluteString,
            retryable: false,
            message: "The request failed after \(Self.maxAttempts) attempts."
        )
    }

    /// `Retry-After` when present, else 0.5s then 1.0s.
    private func retryDelay(response: HTTPURLResponse?, attempt: Int) -> TimeInterval {
        if let header = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)),
           seconds >= 0, seconds <= 120 {
            return seconds
        }
        return attempt == 1 ? 0.5 : 1.0
    }
}
