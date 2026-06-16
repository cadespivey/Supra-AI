public struct AppVersion: Codable, Hashable, Sendable {
    public let marketingVersion: String
    public let buildNumber: String

    public init(marketingVersion: String, buildNumber: String) {
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
    }

    public static let unknown = AppVersion(marketingVersion: "0.0.0", buildNumber: "0")
}
