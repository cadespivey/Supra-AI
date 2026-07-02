import Foundation

/// Additional keyed API-credential services (beyond the CourtListener token, which keeps its own
/// dedicated methods for backwards compatibility). Each maps to a distinct Keychain account and an
/// optional environment-variable fallback, mirroring the CourtListener token.
public enum APIKeyService: String, Sendable, CaseIterable, Codable {
    case openStates
    case regulationsGov
    case govInfo

    /// Keychain account this service's key is stored under (within the store's Keychain service).
    public var keychainAccount: String { "supra.apikey.\(rawValue)" }

    /// Environment-variable fallback (CI / power users), like `SUPRA_COURTLISTENER_API_KEY`.
    public var environmentVariable: String {
        switch self {
        case .openStates: return "SUPRA_OPENSTATES_API_KEY"
        case .regulationsGov: return "SUPRA_REGULATIONS_GOV_API_KEY"
        case .govInfo: return "SUPRA_GOVINFO_API_KEY"
        }
    }
}

public protocol APIKeyStoreProtocol: Sendable {
    func saveCourtListenerToken(_ token: String) throws
    func loadCourtListenerToken() throws -> String?
    func deleteCourtListenerToken() throws
    func hasCourtListenerToken() throws -> Bool

    // Generic keyed API for the additional services above.
    func saveAPIKey(_ key: String, for service: APIKeyService) throws
    func loadAPIKey(for service: APIKeyService) throws -> String?
    func deleteAPIKey(for service: APIKeyService) throws
    func hasAPIKey(for service: APIKeyService) throws -> Bool
}

public extension APIKeyStoreProtocol {
    // Defaults so conformers that only handle the CourtListener token (e.g. test stubs) still compile.
    func saveAPIKey(_ key: String, for service: APIKeyService) throws {}
    func loadAPIKey(for service: APIKeyService) throws -> String? { nil }
    func deleteAPIKey(for service: APIKeyService) throws {}
    func hasAPIKey(for service: APIKeyService) throws -> Bool { false }
}
