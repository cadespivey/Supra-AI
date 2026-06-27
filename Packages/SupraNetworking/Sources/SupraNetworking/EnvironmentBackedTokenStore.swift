import Foundation

public final class EnvironmentBackedTokenStore: APIKeyStoreProtocol, @unchecked Sendable {
    private let primary: any APIKeyStoreProtocol
    private let environment: [String: String]
    private let courtListenerKey: String

    public init(
        primary: any APIKeyStoreProtocol = KeychainTokenStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        courtListenerKey: String = "SUPRA_COURTLISTENER_API_KEY"
    ) {
        self.primary = primary
        self.environment = environment
        self.courtListenerKey = courtListenerKey
    }

    public func saveCourtListenerToken(_ token: String) throws {
        try primary.saveCourtListenerToken(token)
    }

    public func loadCourtListenerToken() throws -> String? {
        if let token = environment[courtListenerKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }
        return try primary.loadCourtListenerToken()
    }

    public func deleteCourtListenerToken() throws {
        try primary.deleteCourtListenerToken()
    }

    public func hasCourtListenerToken() throws -> Bool {
        if hasEnvironmentCourtListenerToken {
            return true
        }
        return try primary.hasCourtListenerToken()
    }

    public var hasEnvironmentCourtListenerToken: Bool {
        guard let token = environment[courtListenerKey]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !token.isEmpty
    }

    // MARK: - Generic keyed API (env fallback → primary Keychain)

    public func saveAPIKey(_ key: String, for service: APIKeyService) throws {
        try primary.saveAPIKey(key, for: service)
    }

    public func loadAPIKey(for service: APIKeyService) throws -> String? {
        if let value = environmentValue(for: service) { return value }
        return try primary.loadAPIKey(for: service)
    }

    public func deleteAPIKey(for service: APIKeyService) throws {
        try primary.deleteAPIKey(for: service)
    }

    public func hasAPIKey(for service: APIKeyService) throws -> Bool {
        if environmentValue(for: service) != nil { return true }
        return try primary.hasAPIKey(for: service)
    }

    /// Whether a key for `service` comes from the environment (vs the Keychain).
    public func hasEnvironmentAPIKey(for service: APIKeyService) -> Bool {
        environmentValue(for: service) != nil
    }

    private func environmentValue(for service: APIKeyService) -> String? {
        guard let value = environment[service.environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
