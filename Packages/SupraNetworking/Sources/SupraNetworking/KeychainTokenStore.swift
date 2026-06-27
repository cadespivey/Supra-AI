import Foundation
import LocalAuthentication
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
        // Bind the token to this device and keep it out of iCloud Keychain sync /
        // keychain migration; it is readable after first unlock so the background
        // runtime service can use it without an interactive unlock prompt.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

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
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        case errSecInteractionNotAllowed, errSecAuthFailed:
            // The item appears to require interactive authorization. Treat it as
            // present so callers can defer the prompt until they actually load it.
            return true
        default:
            throw KeychainTokenStoreError.unhandledStatus(status)
        }
    }

    // MARK: - Generic keyed API (additional services)

    public func saveAPIKey(_ key: String, for service: APIKeyService) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainTokenStoreError.emptyToken }
        let query = query(forAccount: service.keychainAccount)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainTokenStoreError.unhandledStatus(status) }
    }

    public func loadAPIKey(for service: APIKeyService) throws -> String? {
        var query = query(forAccount: service.keychainAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainTokenStoreError.unhandledStatus(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func deleteAPIKey(for service: APIKeyService) throws {
        let status = SecItemDelete(query(forAccount: service.keychainAccount) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStoreError.unhandledStatus(status)
        }
    }

    public func hasAPIKey(for service: APIKeyService) throws -> Bool {
        var query = query(forAccount: service.keychainAccount)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return true
        default:
            throw KeychainTokenStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        query(forAccount: account)
    }

    private func query(forAccount account: String) -> [String: Any] {
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
