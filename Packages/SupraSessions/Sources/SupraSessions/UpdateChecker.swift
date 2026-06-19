import Combine
import Foundation
import SupraStore

/// A GitHub release, as returned by `/releases/latest`.
public struct GitHubRelease: Decodable, Sendable, Equatable {
    public let tagName: String
    public let name: String?
    public let htmlURL: URL
    public let prerelease: Bool
    public let assets: [Asset]

    public struct Asset: Decodable, Sendable, Equatable {
        public let name: String
        public let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case prerelease
        case assets
    }
}

/// A newer release than the running app, surfaced to the user.
public struct AvailableUpdate: Sendable, Equatable {
    public let version: String
    public let releaseURL: URL
    /// A downloadable `.zip`/`.dmg` asset attached to the release, if any.
    public let downloadURL: URL?
}

/// Pure version/release logic for the GitHub-releases update check.
public enum ReleaseUpdateChecker {
    public static let repository = "cadespivey/Supra-AI"

    public static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// True when `candidate` is a strictly higher dotted-numeric version than
    /// `current` (a leading "v" is ignored; versions are padded to three parts so
    /// "1.1" == "1.1.0").
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        components(current).lexicographicallyPrecedes(components(candidate))
    }

    /// Returns an update only when the release is newer than the running version
    /// and isn't a prerelease.
    public static func evaluate(release: GitHubRelease, currentVersion: String) -> AvailableUpdate? {
        let latest = release.tagName.trimmingCharacters(in: Self.versionPrefix)
        guard !release.prerelease, isNewer(latest, than: currentVersion) else { return nil }
        let asset = release.assets.first { $0.name.hasSuffix(".zip") || $0.name.hasSuffix(".dmg") }
        return AvailableUpdate(version: latest, releaseURL: release.htmlURL, downloadURL: asset?.browserDownloadURL)
    }

    private static let versionPrefix = CharacterSet(charactersIn: "vV ")

    private static func components(_ version: String) -> [Int] {
        let parts = version
            .trimmingCharacters(in: versionPrefix)
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        return parts + Array(repeating: 0, count: max(0, 3 - parts.count))
    }
}

/// Checks GitHub for a newer release of the app. Opt-in: nothing reaches the
/// network unless the user enables it (the app is otherwise CourtListener-only).
@MainActor
public final class UpdateController: ObservableObject {
    @Published public private(set) var available: AvailableUpdate?
    @Published public private(set) var isChecking = false
    @Published public private(set) var statusMessage: String?
    @Published public var autoCheckEnabled: Bool {
        didSet {
            guard autoCheckEnabled != oldValue else { return }
            try? store.appSettings.setSetting(Self.autoCheckKey, value: autoCheckEnabled)
            if autoCheckEnabled { Task { await checkNow() } }
        }
    }

    public static let autoCheckKey = "updates.autoCheck"

    private let store: SupraStore
    private let currentVersion: String
    private let fetch: @Sendable (URL) async throws -> Data

    public init(
        store: SupraStore,
        currentVersion: String,
        fetch: @escaping @Sendable (URL) async throws -> Data = UpdateController.defaultFetch
    ) {
        self.store = store
        self.currentVersion = currentVersion
        self.fetch = fetch
        self.autoCheckEnabled = (try? store.appSettings.getSetting(Self.autoCheckKey, as: Bool.self)) ?? false
    }

    /// Runs an automatic check on launch, only when the user has opted in.
    public func checkOnLaunchIfEnabled() {
        guard autoCheckEnabled else { return }
        Task { await checkNow() }
    }

    public func checkNow() async {
        isChecking = true
        statusMessage = nil
        defer { isChecking = false }
        do {
            let data = try await fetch(ReleaseUpdateChecker.latestReleaseURL)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let update = ReleaseUpdateChecker.evaluate(release: release, currentVersion: currentVersion)
            available = update
            statusMessage = update == nil ? "You're on the latest version (\(currentVersion))." : nil
        } catch {
            available = nil
            statusMessage = "Couldn't check for updates: \(error.localizedDescription)"
        }
    }

    public static let defaultFetch: @Sendable (URL) async throws -> Data = { url in
        var request = URLRequest(url: url)
        request.setValue("Supra-AI", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return try await URLSession.shared.data(for: request).0
    }
}
