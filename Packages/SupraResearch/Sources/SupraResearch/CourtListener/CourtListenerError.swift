import Foundation

public enum CourtListenerError: Error, Equatable, Sendable {
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
}
