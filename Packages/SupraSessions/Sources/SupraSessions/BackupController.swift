import Combine
import Foundation
import SupraStore

/// A persisted user-selected backup folder. The operation body is the only place
/// callers receive its URL, which makes security-scoped access structural rather
/// than a convention that can be accidentally bypassed.
@MainActor
public protocol BackupDestination {
    func withAccess<T: Sendable>(_ operation: (URL) async throws -> T) async throws -> T
}

public enum BackupDestinationError: Error, Equatable, LocalizedError {
    case invalidBookmark
    case staleBookmark
    case accessDenied

    public var errorDescription: String? {
        switch self {
        case .invalidBookmark:
            "The saved backup folder can no longer be found. Choose the folder again."
        case .staleBookmark:
            "The backup folder moved or changed. Choose the folder again to renew access."
        case .accessDenied:
            "Supra AI no longer has permission to use the backup folder. Choose it again."
        }
    }
}

/// Resolves one app-scoped bookmark and holds its sandbox extension for the full
/// asynchronous backup. Stale bookmarks fail closed so Settings can request a
/// deliberate re-pick instead of silently skipping the launch backup.
@MainActor
public struct SecurityScopedBackupDestination: BackupDestination {
    private let bookmarkData: Data

    public init(bookmarkData: Data) {
        self.bookmarkData = bookmarkData
    }

    public func withAccess<T: Sendable>(_ operation: (URL) async throws -> T) async throws -> T {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw BackupDestinationError.invalidBookmark
        }
        guard !isStale else { throw BackupDestinationError.staleBookmark }
        guard url.startAccessingSecurityScopedResource() else {
            throw BackupDestinationError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try await operation(url)
    }
}

/// The durable P2 state stored in `app_settings`. The bookmark and status travel
/// together so replacing a folder cannot accidentally display an old folder's
/// successful run as protection for the new destination.
public struct BackupConfiguration: Codable, Equatable, Sendable {
    public var bookmarkData: Data
    public var destinationPath: String
    public var isICloudDrive: Bool
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var lastSnapshotBytes: Int?
    public var lastCopiedBlobCount: Int?
    public var lastReferencedBlobCount: Int?
    public var lastErrorDescription: String?
    public var requiresDestinationRepick: Bool

    public init(
        bookmarkData: Data,
        destinationPath: String,
        isICloudDrive: Bool,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        lastSnapshotBytes: Int? = nil,
        lastCopiedBlobCount: Int? = nil,
        lastReferencedBlobCount: Int? = nil,
        lastErrorDescription: String? = nil,
        requiresDestinationRepick: Bool = false
    ) {
        self.bookmarkData = bookmarkData
        self.destinationPath = destinationPath
        self.isICloudDrive = isICloudDrive
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.lastSnapshotBytes = lastSnapshotBytes
        self.lastCopiedBlobCount = lastCopiedBlobCount
        self.lastReferencedBlobCount = lastReferencedBlobCount
        self.lastErrorDescription = lastErrorDescription
        self.requiresDestinationRepick = requiresDestinationRepick
    }
}

public struct BackupRunSummary: Equatable, Sendable {
    public var snapshotBytes: Int
    public var copiedBlobCount: Int
    public var referencedBlobCount: Int

    public init(snapshotBytes: Int, copiedBlobCount: Int, referencedBlobCount: Int) {
        self.snapshotBytes = snapshotBytes
        self.copiedBlobCount = copiedBlobCount
        self.referencedBlobCount = referencedBlobCount
    }
}

public enum BackupControllerState: Equatable, Sendable {
    case unconfigured
    case ready
    case backingUp
    case succeeded
    case failed
    case needsDestinationRepick
}

public enum LaunchBackupOutcome: Equatable, Sendable {
    case notConfigured
    case needsDestinationRepick
    case notDue
    case completed
    case failed
}

/// P2 app-facing backup orchestration: persisted destination, manual runs,
/// on-launch-if-stale scheduling, and user-facing health state. The package layer
/// owns no panel or UI; Settings only mints the bookmark and renders this state.
@MainActor
public final class BackupController: ObservableObject {
    public typealias BackupRunner = @MainActor (URL) async throws -> BackupRunSummary
    public typealias DestinationFactory = @MainActor (Data) -> any BackupDestination
    public typealias SourceSizeProvider = @MainActor () async -> Int64

    public static let storageKey = "backup.configuration.v1"
    public static let staleInterval: TimeInterval = 24 * 60 * 60
    public static let firstBackupWarningBytes: Int64 = 5 * 1_024 * 1_024 * 1_024

    @Published public private(set) var configuration: BackupConfiguration?
    @Published public private(set) var state: BackupControllerState
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var estimatedSourceBytes: Int64 = 0

    private let store: SupraStore
    private let destinationFactory: DestinationFactory
    private let backupRunner: BackupRunner
    private let sourceSizeProvider: SourceSizeProvider
    private let now: @MainActor () -> Date

    public init(
        store: SupraStore,
        blobsDirectory: URL,
        appVersion: String,
        appBuild: String,
        destinationFactory: DestinationFactory? = nil,
        backupRunner: BackupRunner? = nil,
        sourceSizeProvider: SourceSizeProvider? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.store = store
        self.destinationFactory = destinationFactory ?? { bookmarkData in
            SecurityScopedBackupDestination(bookmarkData: bookmarkData)
        }
        self.backupRunner = backupRunner ?? { destination in
            try await Task.detached(priority: .utility) {
                let result = try BackupService.runBackup(
                    writer: store.database.writer,
                    blobsDirectory: blobsDirectory,
                    destination: destination,
                    appVersion: appVersion,
                    appBuild: appBuild
                )
                let manifest = try BackupManifest.decode(Data(contentsOf: result.manifestURL))
                return BackupRunSummary(
                    snapshotBytes: manifest.sourceDbBytes,
                    copiedBlobCount: result.copiedBlobCount,
                    referencedBlobCount: result.referencedBlobCount
                )
            }.value
        }
        self.sourceSizeProvider = sourceSizeProvider ?? {
            await Task.detached(priority: .utility) {
                Self.directoryByteCount(at: blobsDirectory)
            }.value
        }
        self.now = now

        let stored = try? store.appSettings.getSetting(Self.storageKey, as: BackupConfiguration.self)
        self.configuration = stored
        if stored?.requiresDestinationRepick == true {
            self.state = .needsDestinationRepick
            self.statusMessage = stored?.lastErrorDescription
        } else if let error = stored?.lastErrorDescription {
            self.state = .failed
            self.statusMessage = error
        } else if stored != nil {
            self.state = .ready
            self.statusMessage = nil
        } else {
            self.state = .unconfigured
            self.statusMessage = "Choose a backup folder to get started."
        }
    }

    public var hasDestination: Bool { configuration != nil }
    public var isBackingUp: Bool { state == .backingUp }
    public var destinationPath: String? { configuration?.destinationPath }
    public var destinationIsICloudDrive: Bool { configuration?.isICloudDrive == true }
    public var lastSuccessAt: Date? { configuration?.lastSuccessAt }
    public var lastSnapshotBytes: Int? { configuration?.lastSnapshotBytes }
    public var lastCopiedBlobCount: Int? { configuration?.lastCopiedBlobCount }
    public var lastReferencedBlobCount: Int? { configuration?.lastReferencedBlobCount }

    public var shouldWarnAboutLargeFirstBackup: Bool {
        configuration?.lastSuccessAt == nil
            && estimatedSourceBytes >= Self.firstBackupWarningBytes
    }

    public var isLastBackupStale: Bool {
        guard let lastSuccessAt else { return hasDestination }
        return now().timeIntervalSince(lastSuccessAt) >= Self.staleInterval
    }

    /// Persists a newly minted app-scoped bookmark. Status fields intentionally
    /// reset because the new folder has not received any backup yet.
    @discardableResult
    public func configureDestination(bookmarkData: Data, url: URL) -> Bool {
        let candidate = BackupConfiguration(
            bookmarkData: bookmarkData,
            destinationPath: url.path,
            isICloudDrive: Self.isICloudDrive(url)
        )
        do {
            try store.appSettings.setSetting(Self.storageKey, value: candidate)
            configuration = candidate
            state = .ready
            statusMessage = nil
            return true
        } catch {
            state = .failed
            statusMessage = "The backup folder could not be saved. \(error.localizedDescription)"
            return false
        }
    }

    public func reportDestinationSelectionFailure(_ message: String) {
        state = configuration == nil ? .unconfigured : .failed
        statusMessage = message
    }

    /// Manual entry point used by Settings and by the 24-hour launch scheduler.
    /// Errors become visible, persisted status; callers never need to discard one.
    @discardableResult
    public func backUpNow() async -> Bool {
        guard var current = configuration else {
            state = .unconfigured
            statusMessage = "Choose a backup folder to get started."
            return false
        }
        guard state != .backingUp else { return false }

        let attemptDate = now()
        current.lastAttemptAt = attemptDate
        current.lastErrorDescription = nil
        current.requiresDestinationRepick = false
        configuration = current
        persistBestEffort(current)
        state = .backingUp
        statusMessage = "Backing up database and documents…"

        do {
            let destination = destinationFactory(current.bookmarkData)
            let summary = try await destination.withAccess { url in
                try await backupRunner(url)
            }
            current.lastSuccessAt = attemptDate
            current.lastSnapshotBytes = summary.snapshotBytes
            current.lastCopiedBlobCount = summary.copiedBlobCount
            current.lastReferencedBlobCount = summary.referencedBlobCount
            current.lastErrorDescription = nil
            current.requiresDestinationRepick = false
            try store.appSettings.setSetting(Self.storageKey, value: current)
            configuration = current
            state = .succeeded
            statusMessage = "Backup complete."
            return true
        } catch {
            let destinationError = error as? BackupDestinationError
            current.lastErrorDescription = Self.failureMessage(for: error)
            current.requiresDestinationRepick = destinationError != nil
            configuration = current
            persistBestEffort(current)
            state = destinationError == nil ? .failed : .needsDestinationRepick
            statusMessage = current.lastErrorDescription
            return false
        }
    }

    /// Launch trigger: no destination and stale permissions are explicit states;
    /// a successful run inside the last 24 hours is left untouched.
    @discardableResult
    public func backUpOnLaunchIfStale() async -> LaunchBackupOutcome {
        guard let configuration else {
            state = .unconfigured
            statusMessage = "Choose a backup folder to get started."
            return .notConfigured
        }
        guard !configuration.requiresDestinationRepick else {
            state = .needsDestinationRepick
            statusMessage = configuration.lastErrorDescription
                ?? "Choose the backup folder again to renew access."
            return .needsDestinationRepick
        }
        if let lastSuccessAt = configuration.lastSuccessAt,
           now().timeIntervalSince(lastSuccessAt) < Self.staleInterval
        {
            return .notDue
        }
        return await backUpNow() ? .completed : .failed
    }

    public func refreshEstimatedSourceSize() async {
        estimatedSourceBytes = max(0, await sourceSizeProvider())
    }

    private func persistBestEffort(_ configuration: BackupConfiguration) {
        do {
            try store.appSettings.setSetting(Self.storageKey, value: configuration)
        } catch {
            statusMessage = "Backup status could not be saved. \(error.localizedDescription)"
        }
    }

    private static func failureMessage(for error: Error) -> String {
        if let destinationError = error as? BackupDestinationError {
            return destinationError.localizedDescription
        }
        return "Backup failed. \(error.localizedDescription)"
    }

    private static func isICloudDrive(_ url: URL) -> Bool {
        if FileManager.default.isUbiquitousItem(at: url) { return true }
        let path = url.standardizedFileURL.path
        return path.contains("/Library/Mobile Documents/com~apple~CloudDocs/")
            || path.hasSuffix("/Library/Mobile Documents/com~apple~CloudDocs")
    }

    nonisolated private static func directoryByteCount(at directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
