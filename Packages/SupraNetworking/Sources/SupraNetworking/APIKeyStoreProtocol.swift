import Foundation

public protocol APIKeyStoreProtocol: Sendable {
    func saveCourtListenerToken(_ token: String) throws
    func loadCourtListenerToken() throws -> String?
    func deleteCourtListenerToken() throws
    func hasCourtListenerToken() throws -> Bool
}
