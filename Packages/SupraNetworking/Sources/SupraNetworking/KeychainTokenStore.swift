import Foundation
import Security

public final class KeychainTokenStore: APIKeyStoreProtocol, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = SupraNetworkingModule.courtListenerService,
        account: String = SupraNetworkingModule.courtListenerTokenAccount
    ) {
        self.service = service
        self.account = account
    }

    public func saveCourtListenerToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeychainTokenStoreError.emptyToken
        }
        let data = Data(trimmed.utf8)
        let query = baseQuery()
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainTokenStoreError.unhandledStatus(status)
        }
    }

    public func loadCourtListenerToken() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainTokenStoreError.unhandledStatus(status)
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func deleteCourtListenerToken() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStoreError.unhandledStatus(status)
        }
    }

    public func hasCourtListenerToken() throws -> Bool {
        try loadCourtListenerToken() != nil
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public enum KeychainTokenStoreError: Error, Equatable, Sendable {
    case emptyToken
    case unhandledStatus(OSStatus)
}
