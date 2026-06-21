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
            "storage.courtlistener.com"
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
