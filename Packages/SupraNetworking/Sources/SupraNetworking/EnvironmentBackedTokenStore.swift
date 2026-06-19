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
}
