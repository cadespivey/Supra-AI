import Foundation

public enum NetworkPolicyError: Error, Equatable, Sendable {
    case invalidURL
    case missingHost
    case insecureScheme(String?)
    case embeddedCredentials
    case hostNotAllowed(String)
    case portNotAllowed(host: String, port: Int)
    case redirectRejected(RedirectRejection)
    case localRateLimitExceeded(RateLimitTracker.Snapshot)
}
