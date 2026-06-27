import Foundation

/// Errors from the Open Legal Codes statutory-lookup client.
///
/// OLC is free, key-less, and unlimited, but its content is lazily crawled: the first
/// request to an un-cached code triggers a server-side crawl (HTTP 202) and the crawl
/// can fail (HTTP 503 `CRAWL_FAILED`). Those states are modeled explicitly so the
/// research layer can treat OLC as a best-effort source and degrade gracefully — never
/// presenting it as authoritative or current (it exposes no freshness stamp).
public enum OpenLegalCodesError: Error, Equatable, Sendable, LocalizedError {
    case blockedByNetworkPolicy
    case localRateLimitExceeded
    case invalidResponse
    case decodingFailed
    /// HTTP 202: the code's text is being crawled on demand and isn't ready yet.
    case crawlInProgress(retryAfter: TimeInterval?)
    /// HTTP 503 with a `CRAWL_FAILED` body: the crawl failed on OLC's side.
    case crawlFailed(reason: String, retryAfter: TimeInterval?)
    case badRequest(String?)
    case serverError(statusCode: Int)
    case transportFailed(String)

    /// True when a later retry may succeed (warming or a transient OLC-side failure),
    /// so callers can fall back now and optionally retry later rather than surface a hard error.
    public var isTransient: Bool {
        switch self {
        case .crawlInProgress, .crawlFailed, .serverError, .transportFailed: return true
        case .blockedByNetworkPolicy, .localRateLimitExceeded, .invalidResponse, .decodingFailed, .badRequest:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .blockedByNetworkPolicy:
            "Network request blocked by Supra AI network policy."
        case .localRateLimitExceeded:
            "Local request limit reached for the current window. Try again shortly."
        case .invalidResponse:
            "Open Legal Codes returned an unexpected response."
        case .decodingFailed:
            "Open Legal Codes' response could not be decoded."
        case let .crawlInProgress(retryAfter):
            if let retryAfter, retryAfter > 0 {
                "Open Legal Codes is still fetching this code. Try again in about \(Int(retryAfter.rounded(.up))) second(s)."
            } else {
                "Open Legal Codes is still fetching this code. Try again shortly."
            }
        case let .crawlFailed(reason, _):
            "Open Legal Codes could not fetch this code (\(reason)). It may be temporary."
        case let .badRequest(detail):
            if let detail, !detail.isEmpty { "Open Legal Codes rejected the request: \(detail)" }
            else { "Open Legal Codes rejected the request." }
        case let .serverError(statusCode):
            "Open Legal Codes server error (HTTP \(statusCode))."
        case let .transportFailed(message):
            "Network error contacting Open Legal Codes: \(message)"
        }
    }
}
