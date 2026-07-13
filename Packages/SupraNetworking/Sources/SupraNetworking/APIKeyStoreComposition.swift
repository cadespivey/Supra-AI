import Foundation

/// The single composition boundary for API credentials.
///
/// Shipping code is Keychain-only. Environment-backed credentials exist solely
/// in DEBUG builds and require explicit composition or the DEBUG `live()` path.
public enum APIKeyStoreComposition {
    public static func production(
        primary: any APIKeyStoreProtocol = KeychainTokenStore()
    ) -> any APIKeyStoreProtocol {
        primary
    }

    #if DEBUG
    public static func development(
        primary: any APIKeyStoreProtocol = KeychainTokenStore(),
        environment: [String: String]
    ) -> any APIKeyStoreProtocol {
        EnvironmentBackedTokenStore(primary: primary, environment: environment)
    }
    #endif

    public static func live(
        primary: any APIKeyStoreProtocol = KeychainTokenStore()
    ) -> any APIKeyStoreProtocol {
        #if DEBUG
        development(primary: primary, environment: ProcessInfo.processInfo.environment)
        #else
        production(primary: primary)
        #endif
    }
}
