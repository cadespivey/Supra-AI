import CryptoKit
import Foundation
import Security

public protocol QueryFingerprinting: Sendable {
    /// Returns a complete, versioned marker (for example `#h1:…`). Returning nil
    /// means the caller must fully redact the value.
    func marker(for value: String) -> String?
}

public protocol QueryFingerprintKeyStore: Sendable {
    func loadOrCreateKey() throws -> Data
}

public enum QueryFingerprinterError: Error, Equatable, Sendable {
    case invalidKeyLength(Int)
    case randomGenerationFailed(OSStatus)
    case keychainFailure(OSStatus)
    case invalidStoredKey
}

/// HMAC-SHA256 pseudonyms scoped to a caller-supplied installation key.
public struct HMACQueryFingerprinter: QueryFingerprinting, Sendable {
    private let key: SymmetricKey

    public init(key: Data) throws {
        guard key.count == 32 else {
            throw QueryFingerprinterError.invalidKeyLength(key.count)
        }
        self.key = SymmetricKey(data: key)
    }

    public func marker(for value: String) -> String? {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(value.utf8),
            using: key
        )
        // 128 retained bits are sufficient for local audit grouping while keeping
        // the marker compact. The version prefix makes future rotation explicit.
        let truncated = authenticationCode.prefix(16)
        let hex = truncated.map { String(format: "%02x", $0) }.joined()
        return "#h1:\(hex)"
    }
}

/// Lazily resolves the per-install key. Any Keychain or decoding failure is
/// sticky for this instance and produces full redaction, never an unkeyed hash.
public final class KeychainBackedQueryFingerprinter: QueryFingerprinting, @unchecked Sendable {
    private enum State {
        case unresolved
        case ready(HMACQueryFingerprinter)
        case unavailable
    }

    private let keyStore: any QueryFingerprintKeyStore
    private let lock = NSLock()
    private var state: State = .unresolved

    public init(keyStore: any QueryFingerprintKeyStore = KeychainQueryFingerprintKeyStore()) {
        self.keyStore = keyStore
    }

    public func marker(for value: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .ready(let fingerprinter):
            return fingerprinter.marker(for: value)
        case .unavailable:
            return nil
        case .unresolved:
            do {
                let fingerprinter = try HMACQueryFingerprinter(key: keyStore.loadOrCreateKey())
                state = .ready(fingerprinter)
                return fingerprinter.marker(for: value)
            } catch {
                state = .unavailable
                return nil
            }
        }
    }
}

public final class KeychainQueryFingerprintKeyStore: QueryFingerprintKeyStore, @unchecked Sendable {
    public static let defaultService = "com.supraai.network-audit"
    public static let defaultAccount = "query-fingerprint-hmac-v1"

    private let service: String
    private let account: String

    public init(
        service: String = KeychainQueryFingerprintKeyStore.defaultService,
        account: String = KeychainQueryFingerprintKeyStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    public func loadOrCreateKey() throws -> Data {
        if let existing = try load() {
            guard existing.count == 32 else { throw QueryFingerprinterError.invalidStoredKey }
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw QueryFingerprinterError.randomGenerationFailed(randomStatus)
        }
        let key = Data(bytes)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem, let raced = try load(), raced.count == 32 {
            return raced
        }
        guard addStatus == errSecSuccess else {
            throw QueryFingerprinterError.keychainFailure(addStatus)
        }
        return key
    }

    private func load() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw QueryFingerprinterError.keychainFailure(status)
        }
        guard let data = result as? Data else {
            throw QueryFingerprinterError.invalidStoredKey
        }
        return data
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
