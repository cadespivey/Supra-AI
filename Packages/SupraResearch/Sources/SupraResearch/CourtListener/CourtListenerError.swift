import Foundation

public enum CourtListenerError: Error, Equatable, Sendable, LocalizedError {
    case missingToken
    case blockedByNetworkPolicy
    case localRateLimitExceeded
    case invalidCursorHost
    case invalidResponse
    case authenticationFailed
    case throttled
    case serverError(statusCode: Int)
    case decodingFailed
    case transportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "No CourtListener API token. Add one in Settings to run research."
        case .blockedByNetworkPolicy:
            "Network request blocked by Supra AI network policy."
        case .localRateLimitExceeded:
            "CourtListener request limit reached for the current window. Try again later or increase your CourtListener API limits."
        case .invalidCursorHost:
            "The pagination link pointed outside CourtListener and was not followed."
        case .invalidResponse:
            "CourtListener returned an unexpected response."
        case .authenticationFailed:
            "CourtListener rejected the API token (check it in Settings)."
        case .throttled:
            "CourtListener throttled the request (HTTP 429). Try again shortly."
        case let .serverError(statusCode):
            "CourtListener server error (HTTP \(statusCode))."
        case .decodingFailed:
            "CourtListener's response could not be decoded."
        case let .transportFailed(message):
            "Network error contacting CourtListener: \(message)"
        }
    }
}
