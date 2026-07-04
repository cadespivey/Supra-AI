import Foundation

/// Environment-driven configuration for the government-data connectors. All
/// variables carry the repo's `SUPRA_` prefix. No `.env` file is read — the
/// app relies on environment injection (dev) and, later, Keychain-backed
/// settings for anything secret. Nothing here is a secret: the SEC User-Agent
/// is a contact string SEC's fair-access policy requires, not a credential.
public struct LegalDataConnectorConfiguration: Sendable, Equatable {
    public var cacheDirectory: URL
    public var nlrbLocalDataDirectory: URL
    public var liveTestsEnabled: Bool
    public var secEdgarUserAgent: String?
    public var secEdgarRateLimitPerSecond: Double
    public var cfpbRateLimitPerSecond: Double
    public var nlrbRateLimitPerSecond: Double

    public init(
        cacheDirectory: URL,
        nlrbLocalDataDirectory: URL,
        liveTestsEnabled: Bool = false,
        secEdgarUserAgent: String? = nil,
        secEdgarRateLimitPerSecond: Double = 2,
        cfpbRateLimitPerSecond: Double = 2,
        nlrbRateLimitPerSecond: Double = 1
    ) {
        self.cacheDirectory = cacheDirectory
        self.nlrbLocalDataDirectory = nlrbLocalDataDirectory
        self.liveTestsEnabled = liveTestsEnabled
        self.secEdgarUserAgent = secEdgarUserAgent
        self.secEdgarRateLimitPerSecond = secEdgarRateLimitPerSecond
        self.cfpbRateLimitPerSecond = cfpbRateLimitPerSecond
        self.nlrbRateLimitPerSecond = nlrbRateLimitPerSecond
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LegalDataConnectorConfiguration {
        let cacheDirectory = environment["SUPRA_LEGAL_DATA_CACHE_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? defaultCacheDirectory()
        let nlrbDirectory = environment["SUPRA_NLRB_LOCAL_DATA_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? cacheDirectory.appendingPathComponent("NLRBData", isDirectory: true)
        let userAgent = environment["SUPRA_SEC_EDGAR_USER_AGENT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LegalDataConnectorConfiguration(
            cacheDirectory: cacheDirectory,
            nlrbLocalDataDirectory: nlrbDirectory,
            liveTestsEnabled: parseBool(environment["SUPRA_LEGAL_DATA_CONNECTORS_ENABLE_LIVE_TESTS"]) ?? false,
            secEdgarUserAgent: (userAgent?.isEmpty == false) ? userAgent : nil,
            secEdgarRateLimitPerSecond: rate(environment["SUPRA_SEC_EDGAR_RATE_LIMIT_PER_SECOND"], default: 2, range: 0.1...10),
            cfpbRateLimitPerSecond: rate(environment["SUPRA_CFPB_RATE_LIMIT_PER_SECOND"], default: 2, range: 0.1...10),
            nlrbRateLimitPerSecond: rate(environment["SUPRA_NLRB_RATE_LIMIT_PER_SECOND"], default: 1, range: 0.05...5)
        )
    }

    /// SEC requests must carry a declared User-Agent; fail fast BEFORE any
    /// network work when it's absent. The error never echoes the value.
    public func requireSecEdgarUserAgent(connectorName: String, operation: String) throws -> String {
        guard let secEdgarUserAgent, !secEdgarUserAgent.isEmpty else {
            throw LegalDataConnectorError(
                kind: .config,
                connectorName: connectorName,
                operation: operation,
                message: "Set SUPRA_SEC_EDGAR_USER_AGENT (SEC fair-access policy requires a contact User-Agent) before using SEC EDGAR."
            )
        }
        return secEdgarUserAgent
    }

    /// Strict boolean parsing: true/false/1/0/yes/no, case-insensitive.
    /// Anything else is nil so the caller falls back to its default.
    static func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    private static func rate(_ value: String?, default defaultValue: Double, range: ClosedRange<Double>) -> Double {
        guard let value, let parsed = Double(value.trimmingCharacters(in: .whitespaces)), parsed > 0 else {
            return defaultValue
        }
        return min(max(parsed, range.lowerBound), range.upperBound)
    }

    static func defaultCacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("SupraAI", isDirectory: true)
            .appendingPathComponent("LegalDataConnectors", isDirectory: true)
    }
}
