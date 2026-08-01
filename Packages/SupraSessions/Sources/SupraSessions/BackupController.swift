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

/// Restore's durable, display-safe state machine. Staging is intentionally the
/// final live-process state: activation is permitted only at the next cold start.
public enum RestoreControllerState: String, Codable, Equatable, Sendable {
    case idle
    case inspecting
    case ready
    case incompatible
    case staging
    case stagedRestartRequired
    case succeeded
    case failed
    case failedAndRolledBack
    case recoveryRequired
    case needsDestinationRepick
}

/// Content-free restore status persisted in `app_settings`. It deliberately
/// contains no filesystem URL, matter/document name, or user-provided content.
public struct RestoreStatusRecord: Codable, Equatable, Sendable {
    public let state: RestoreControllerState
    public let message: String
    public let operationID: String?
    public let snapshotIdentifier: String?
    public let updatedAt: Date

    public init(
        state: RestoreControllerState,
        message: String,
        operationID: String? = nil,
        snapshotIdentifier: String? = nil,
        updatedAt: Date
    ) {
        self.state = state
        self.message = message
        self.operationID = operationID
        self.snapshotIdentifier = snapshotIdentifier
        self.updatedAt = updatedAt
    }
}

/// One inspected snapshot as exposed to Settings. Source URLs and hashes stay
/// private to the controller so accessibility and logs cannot leak paths.
public struct RestoreSnapshotListItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date?
    public let appVersion: String?
    public let appBuild: String?
    public let databaseBytes: Int?
    public let referencedBlobCount: Int?
    public let incompatibility: RestoreIncompatibility?

    public var isRestorable: Bool { incompatibility == nil }
    public var blockedReason: String? { incompatibility?.localizedDescription }
}

/// The facts shown immediately before the destructive confirmation. This is a
/// display model only; an internal hash/manifest identity is frozen separately.
public struct RestoreConfirmation: Equatable, Sendable {
    public let snapshotIdentifier: String
    public let createdAt: Date
    public let appVersion: String
    public let appBuild: String
    public let databaseBytes: Int
    public let referencedBlobCount: Int
}

/// Minimal result returned across the controller's injectable staging boundary.
/// Core staging URLs remain private to `RestoreService`.
public struct RestoreStageSummary: Equatable, Sendable {
    public let operationID: String
    public let snapshotIdentifier: String
    public let stagedAt: Date

    public init(operationID: String, snapshotIdentifier: String, stagedAt: Date) {
        self.operationID = operationID
        self.snapshotIdentifier = snapshotIdentifier
        self.stagedAt = stagedAt
    }
}

/// P2 app-facing backup orchestration: persisted destination, manual runs,
/// on-launch-if-stale scheduling, and user-facing health state. The package layer
/// owns no panel or UI; Settings only mints the bookmark and renders this state.
@MainActor
public final class BackupController: ObservableObject {
    public typealias BackupRunner = @MainActor (URL) async throws -> BackupRunSummary
    public typealias DestinationFactory = @MainActor (Data) -> any BackupDestination
    public typealias SourceSizeProvider = @MainActor () async -> Int64
    public typealias RestoreInspector = @MainActor (URL) async throws -> [RestoreSnapshotCandidate]
    public typealias RestoreRunner = @MainActor (
        RestoreSnapshotCandidate,
        RestoreLiveLayout,
        UUID
    ) async throws -> RestoreStageSummary
    public typealias RestoreOperationIDProvider = @MainActor () -> UUID
    public typealias ProcessExitRequester = @MainActor () -> Void
    public typealias RestoreEvidenceAcknowledger = @MainActor () throws -> Void

    public static let storageKey = "backup.configuration.v1"
    public static let restoreStatusStorageKey = "restore.status.v1"
    public static let staleInterval: TimeInterval = 24 * 60 * 60
    public static let firstBackupWarningBytes: Int64 = 5 * 1_024 * 1_024 * 1_024

    @Published public private(set) var configuration: BackupConfiguration?
    @Published public private(set) var state: BackupControllerState
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var estimatedSourceBytes: Int64 = 0
    @Published public private(set) var restoreSnapshots: [RestoreSnapshotListItem] = []
    @Published public private(set) var selectedRestoreSnapshotID: String?
    @Published public private(set) var restoreConfirmation: RestoreConfirmation?
    @Published public private(set) var restoreState: RestoreControllerState = .idle
    @Published public private(set) var restoreStatusMessage: String?
    /// Once true, the live controller/store graph must never be used for work
    /// again. The application replaces its shell and exits after staging returns.
    @Published public private(set) var restoreProcessIsTerminal = false

    private let store: SupraStore
    private let destinationFactory: DestinationFactory
    private let backupRunner: BackupRunner
    private let sourceSizeProvider: SourceSizeProvider
    private let restoreLiveLayout: RestoreLiveLayout?
    private let restoreInspector: RestoreInspector
    private let restoreRunner: RestoreRunner
    private let restoreOperationIDProvider: RestoreOperationIDProvider
    private let requestProcessExit: ProcessExitRequester
    private let now: @MainActor () -> Date
    private var restoreCandidates: [String: RestoreSnapshotCandidate] = [:]
    private var confirmedRestoreIdentity: RestoreSnapshotIdentity?
    private var activeOperation: ActiveOperation?

    public init(
        store: SupraStore,
        blobsDirectory: URL,
        appVersion: String,
        appBuild: String,
        destinationFactory: DestinationFactory? = nil,
        backupRunner: BackupRunner? = nil,
        sourceSizeProvider: SourceSizeProvider? = nil,
        restoreLiveLayout: RestoreLiveLayout? = nil,
        restoreInspector: RestoreInspector? = nil,
        restoreRunner: RestoreRunner? = nil,
        restoreOperationIDProvider: @escaping RestoreOperationIDProvider = { UUID() },
        requestProcessExit: @escaping ProcessExitRequester = {},
        launchRestoreResult: RestoreActivationResult? = nil,
        launchRestoreOutcome: RestoreOutcomeRecord? = nil,
        launchStagingFailure: RestoreStagingFailureRecord? = nil,
        acknowledgeRestoreOutcome: RestoreEvidenceAcknowledger = {},
        acknowledgeStagingFailure: RestoreEvidenceAcknowledger = {},
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
        self.restoreLiveLayout = restoreLiveLayout
        self.restoreInspector = restoreInspector ?? { destination in
            try await Task.detached(priority: .utility) {
                try RestoreSnapshotInspector.discover(in: destination)
            }.value
        }
        self.restoreRunner = restoreRunner ?? { candidate, layout, operationID in
            try await Task.detached(priority: .utility) {
                do {
                    let staged = try RestoreService.stageQuiescedRestore(
                        candidate: candidate,
                        liveDatabase: store.database,
                        liveLayout: layout,
                        operationID: operationID
                    )
                    return RestoreStageSummary(
                        operationID: staged.intent.operationID,
                        snapshotIdentifier: staged.intent.selectedSnapshotIdentifier,
                        stagedAt: staged.intent.createdAt
                    )
                } catch {
                    _ = try? RestoreSidecarStore.recordStagingFailure(
                        operationID: operationID,
                        reason: Self.stagingFailureReason(for: error),
                        stagingRootDirectory: layout.stagingRootDirectory
                    )
                    throw error
                }
            }.value
        }
        self.restoreOperationIDProvider = restoreOperationIDProvider
        self.requestProcessExit = requestProcessExit
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

        let storedStatus = try? store.appSettings.getSetting(
            Self.restoreStatusStorageKey,
            as: RestoreStatusRecord.self
        )
        if let storedStatus {
            self.restoreState = storedStatus.state
            self.restoreStatusMessage = storedStatus.message
            self.selectedRestoreSnapshotID = storedStatus.snapshotIdentifier
        } else if stored?.requiresDestinationRepick == true {
            self.restoreState = .needsDestinationRepick
            self.restoreStatusMessage = stored?.lastErrorDescription
        }
        let appliedActivation = applyLaunchRestoreResult(launchRestoreResult)
        if appliedActivation,
           launchRestoreResult?.status != .recoveryRequired
        {
            try? acknowledgeRestoreOutcome()
        } else if !appliedActivation,
                  let launchRestoreOutcome,
                  applyLaunchRestoreOutcome(launchRestoreOutcome)
        {
            if launchRestoreOutcome.status != .recoveryRequired {
                try? acknowledgeRestoreOutcome()
            }
        } else if !appliedActivation,
                  let launchStagingFailure,
                  let storedStatus,
                  storedStatus.state == .staging,
                  storedStatus.operationID?.lowercased() == launchStagingFailure.operationID,
                  applyLaunchStagingFailure(launchStagingFailure, storedStatus: storedStatus)
        {
            try? acknowledgeStagingFailure()
        } else if restoreState == .staging,
                  let stranded = storedStatus
        {
            setRestoreStatus(
                .failed,
                "Restore staging was interrupted before activation. Inspect and schedule the backup again.",
                operationID: stranded.operationID,
                snapshotIdentifier: stranded.snapshotIdentifier
            )
        }
    }

    public var hasDestination: Bool { configuration != nil }
    public var isBackingUp: Bool { state == .backingUp }
    public var isRestoreBusy: Bool { restoreState == .inspecting || restoreState == .staging }
    public var isAnyBackupOperationBusy: Bool {
        activeOperation != nil || requiresRestartForRestore || restoreProcessIsTerminal
    }
    public var requiresRestartForRestore: Bool { restoreState == .stagedRestartRequired }
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
        guard !isAnyBackupOperationBusy else { return false }
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
            resetRestoreSelection()
            setRestoreStatus(.idle, "Inspect this folder to choose a completed backup.")
            return true
        } catch {
            state = .failed
            statusMessage = "The backup folder could not be saved. \(error.localizedDescription)"
            return false
        }
    }

    public func reportDestinationSelectionFailure(_ message: String) {
        guard !isAnyBackupOperationBusy else {
            statusMessage = message
            return
        }
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
        guard !isAnyBackupOperationBusy else { return false }
        activeOperation = .backup
        defer { activeOperation = nil }

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

    /// Inspects every manifest-backed snapshot while the destination's security
    /// scope is held. Invalid candidates remain visible with a typed reason.
    @discardableResult
    public func inspectRestoreSnapshots() async -> Bool {
        guard let current = configuration else {
            setRestoreStatus(.idle, "Choose a backup folder before inspecting snapshots.")
            return false
        }
        guard !requiresRestartForRestore else { return false }
        guard activeOperation == nil else {
            setRestoreStatus(.failed, "Wait for the current backup or restore operation to finish.")
            return false
        }
        activeOperation = .restoreInspection
        defer { activeOperation = nil }
        resetRestoreSelection()
        restoreState = .inspecting
        restoreStatusMessage = "Inspecting completed backup snapshots…"

        do {
            let destination = destinationFactory(current.bookmarkData)
            let candidates = try await destination.withAccess { url in
                try await restoreInspector(url)
            }
            restoreCandidates = Dictionary(
                uniqueKeysWithValues: candidates.map { ($0.identifier, $0) }
            )
            restoreSnapshots = candidates.map(Self.displayItem)
            if candidates.isEmpty {
                setRestoreStatus(.idle, "No completed backup snapshots were found in this folder.")
            } else if candidates.contains(where: \.isRestorable) {
                setRestoreStatus(.ready, "Select a verified snapshot to review the restore.")
            } else {
                setRestoreStatus(.incompatible, "No compatible backup snapshot is available.")
            }
            return true
        } catch {
            handleRestoreFailure(error, phase: .inspection)
            return false
        }
    }

    /// Invalid rows fail closed even if invoked outside SwiftUI's disabled state.
    @discardableResult
    public func selectRestoreSnapshot(id: String) -> Bool {
        guard !requiresRestartForRestore,
              activeOperation == nil,
              let candidate = restoreCandidates[id],
              candidate.isRestorable,
              candidate.summary != nil
        else { return false }
        selectedRestoreSnapshotID = id
        restoreConfirmation = nil
        confirmedRestoreIdentity = nil
        setRestoreStatus(.ready, "Selected backup \(id). Review the replacement before staging.")
        return true
    }

    /// Freezes both the visible facts and the exact inspected manifest/hash/blob
    /// identity. Staging independently re-inspects before trusting this choice.
    @discardableResult
    public func prepareRestoreConfirmation() -> Bool {
        guard !requiresRestartForRestore,
              activeOperation == nil,
              let id = selectedRestoreSnapshotID,
              let candidate = restoreCandidates[id],
              candidate.isRestorable,
              let summary = candidate.summary
        else { return false }
        restoreConfirmation = RestoreConfirmation(
            snapshotIdentifier: candidate.identifier,
            createdAt: summary.createdAt,
            appVersion: summary.appVersion,
            appBuild: summary.appBuild,
            databaseBytes: summary.databaseBytes,
            referencedBlobCount: summary.referencedBlobCount
        )
        confirmedRestoreIdentity = RestoreSnapshotIdentity(candidate)
        return true
    }

    public func cancelRestoreConfirmation() {
        restoreConfirmation = nil
        confirmedRestoreIdentity = nil
    }

    /// Persists a content-free schedule, then crosses the terminal staging
    /// boundary. The runner owns writer quiescence and this process always exits
    /// after that boundary is invoked, whether staging succeeds or fails.
    @discardableResult
    public func stageConfirmedRestore() async -> Bool {
        guard !requiresRestartForRestore else { return false }
        guard activeOperation == nil else {
            setRestoreStatus(.failed, "Wait for the current backup or restore operation to finish.")
            return false
        }
        guard let current = configuration,
              let layout = restoreLiveLayout,
              let confirmation = restoreConfirmation,
              let confirmedIdentity = confirmedRestoreIdentity
        else {
            setRestoreStatus(.failed, "Review and confirm a compatible snapshot before staging restore.")
            return false
        }
        activeOperation = .restoreStaging
        var runnerWasInvoked = false
        var scheduledOperationID: UUID?
        defer {
            activeOperation = nil
            if runnerWasInvoked { requestProcessExit() }
        }
        restoreState = .staging
        restoreStatusMessage = "Creating a safety copy and staging the selected backup…"

        do {
            let destination = destinationFactory(current.bookmarkData)
            let summary = try await destination.withAccess { url in
                let refreshed = try await restoreInspector(url)
                guard let candidate = refreshed.first(where: {
                    $0.identifier == confirmation.snapshotIdentifier
                }), candidate.isRestorable,
                    RestoreSnapshotIdentity(candidate) == confirmedIdentity
                else { throw RestoreControllerError.snapshotChanged }

                let operationID = restoreOperationIDProvider()
                scheduledOperationID = operationID
                let operationIDString = operationID.uuidString
                let scheduleMessage = "Restore scheduled. Supra AI is finishing safely and will quit automatically."
                try persistRestoreStatus(
                    .staging,
                    scheduleMessage,
                    operationID: operationIDString,
                    snapshotIdentifier: candidate.identifier
                )
                try recordRestoreAuditOrThrow(
                    eventType: "restore_scheduled",
                    summary: "Restore scheduled for quiesced cold-start activation.",
                    operationID: operationIDString,
                    snapshotIdentifier: candidate.identifier,
                    state: .staging
                )
                restoreConfirmation = nil
                confirmedRestoreIdentity = nil
                restoreProcessIsTerminal = true
                runnerWasInvoked = true
                return try await restoreRunner(candidate, layout, operationID)
            }
            guard summary.snapshotIdentifier == confirmation.snapshotIdentifier,
                  UUID(uuidString: summary.operationID) == scheduledOperationID
            else { throw RestoreControllerError.invalidStageResult }

            setRestorePresentation(
                .stagedRestartRequired,
                "Restore staged. Supra AI is quitting now and will activate it on the next launch."
            )
            return true
        } catch {
            restoreConfirmation = nil
            confirmedRestoreIdentity = nil
            if runnerWasInvoked {
                setRestorePresentation(
                    .failed,
                    "Restore staging did not finish. Supra AI will quit; the live data was not replaced."
                )
            } else {
                handleRestoreFailure(error, phase: .staging)
            }
            return false
        }
    }

    private func persistBestEffort(_ configuration: BackupConfiguration) {
        do {
            try store.appSettings.setSetting(Self.storageKey, value: configuration)
        } catch {
            statusMessage = "Backup status could not be saved. \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func applyLaunchRestoreResult(_ result: RestoreActivationResult?) -> Bool {
        guard let result, result.status != .noPendingRestore else { return false }
        return applyLaunchRestoreEvidence(
            status: result.status,
            operationID: result.operationID,
            snapshotIdentifier: result.snapshotIdentifier,
            activationFailure: result.activationFailure,
            rollbackFailure: result.rollbackFailure
        )
    }

    @discardableResult
    private func applyLaunchRestoreOutcome(_ outcome: RestoreOutcomeRecord) -> Bool {
        applyLaunchRestoreEvidence(
            status: outcome.status,
            operationID: outcome.operationID,
            snapshotIdentifier: outcome.snapshotIdentifier,
            activationFailure: outcome.activationFailure,
            rollbackFailure: outcome.rollbackFailure
        )
    }

    @discardableResult
    private func applyLaunchRestoreEvidence(
        status: RestoreActivationStatus,
        operationID: String?,
        snapshotIdentifier: String?,
        activationFailure: RestoreActivationFailure?,
        rollbackFailure: RestoreActivationFailure?
    ) -> Bool {
        let state: RestoreControllerState
        let message: String
        let eventType: String
        switch status {
        case .activated:
            state = .succeeded
            message = "Restore complete. The selected backup is now active."
            eventType = "restore_activated"
        case .failedAndRolledBack:
            state = .failedAndRolledBack
            message = "Restore failed, and Supra AI returned to the verified pre-restore data."
            eventType = "restore_failed_rolled_back"
        case .recoveryRequired:
            state = .recoveryRequired
            message = "Restore recovery is required before normal work can continue."
            eventType = "restore_recovery_required"
        case .noPendingRestore:
            return false
        }
        do {
            try persistRestoreStatus(
                state,
                message,
                operationID: operationID,
                snapshotIdentifier: snapshotIdentifier
            )
            if status != .recoveryRequired {
                try recordRestoreAuditOrThrow(
                    eventType: eventType,
                    summary: message,
                    operationID: operationID,
                    snapshotIdentifier: snapshotIdentifier,
                    state: state,
                    activationFailure: activationFailure,
                    rollbackFailure: rollbackFailure
                )
            }
            return true
        } catch {
            setRestorePresentation(state, message)
            return false
        }
    }

    @discardableResult
    private func applyLaunchStagingFailure(
        _ failure: RestoreStagingFailureRecord,
        storedStatus: RestoreStatusRecord
    ) -> Bool {
        let message: String
        switch failure.reason {
        case .liveDatabasePathMismatch:
            message = "Restore staging stopped because the active database did not match the live restore location. The live data was not replaced."
        case .liveDatabaseCloseFailed:
            message = "Restore staging stopped because the live database could not close safely. The live data was not replaced."
        case .selectedSnapshotUnavailable, .selectedSnapshotChanged, .selectedSnapshotIncompatible:
            message = "Restore staging stopped because the selected backup was no longer the verified snapshot. Inspect and schedule it again."
        case .liveStateInvalid:
            message = "Restore staging stopped because the current data could not be verified for rollback. The live data was not replaced."
        case .stagingVolumeMismatch:
            message = "Restore staging stopped because its safety files were not on the live database disk. The live data was not replaced."
        case .copiedStateInvalid, .stagingIOFailed:
            message = "Restore staging did not finish safely. The live data was not replaced."
        }
        do {
            try persistRestoreStatus(
                .failed,
                message,
                operationID: failure.operationID,
                snapshotIdentifier: storedStatus.snapshotIdentifier,
                updatedAt: failure.failedAt
            )
            try recordRestoreAuditOrThrow(
                eventType: "restore_staging_failed",
                summary: message,
                operationID: failure.operationID,
                snapshotIdentifier: storedStatus.snapshotIdentifier,
                state: .failed,
                stagingFailure: failure.reason
            )
            return true
        } catch {
            setRestorePresentation(.failed, message)
            return false
        }
    }

    private func handleRestoreFailure(_ error: Error, phase: RestoreFailurePhase) {
        if let destinationError = error as? BackupDestinationError {
            markDestinationForRepick(destinationError)
            setRestoreStatus(.needsDestinationRepick, destinationError.localizedDescription)
            return
        }
        let message: String
        switch error {
        case RestoreControllerError.snapshotChanged,
             RestoreStageError.sourceSnapshotChanged,
             RestoreStageError.sourceSnapshotUnavailable:
            message = "The selected backup changed after inspection. Inspect and select it again."
        case let stageError as RestoreStageError:
            message = "Restore could not be staged. \(stageError.localizedDescription)"
        default:
            message = phase == .inspection
                ? "Backup snapshots could not be inspected. The saved folder and current data were not changed."
                : "Restore could not be staged. The current data was not changed."
        }
        setRestoreStatus(.failed, message)
    }

    private func markDestinationForRepick(_ error: BackupDestinationError) {
        guard var current = configuration else { return }
        current.requiresDestinationRepick = true
        current.lastErrorDescription = error.localizedDescription
        configuration = current
        state = .needsDestinationRepick
        statusMessage = current.lastErrorDescription
        persistBestEffort(current)
    }

    private func setRestoreStatus(
        _ newState: RestoreControllerState,
        _ message: String,
        operationID: String? = nil,
        snapshotIdentifier: String? = nil,
        updatedAt: Date? = nil
    ) {
        do {
            try persistRestoreStatus(
                newState,
                message,
                operationID: operationID,
                snapshotIdentifier: snapshotIdentifier,
                updatedAt: updatedAt
            )
        } catch {
            setRestorePresentation(newState, message)
        }
    }

    private func persistRestoreStatus(
        _ newState: RestoreControllerState,
        _ message: String,
        operationID: String? = nil,
        snapshotIdentifier: String? = nil,
        updatedAt: Date? = nil
    ) throws {
        let record = RestoreStatusRecord(
            state: newState,
            message: message,
            operationID: operationID,
            snapshotIdentifier: snapshotIdentifier,
            updatedAt: updatedAt ?? now()
        )
        try store.appSettings.setSetting(Self.restoreStatusStorageKey, value: record)
        setRestorePresentation(newState, message)
    }

    private func setRestorePresentation(
        _ newState: RestoreControllerState,
        _ message: String
    ) {
        restoreState = newState
        restoreStatusMessage = message
    }

    private func resetRestoreSelection() {
        restoreCandidates = [:]
        restoreSnapshots = []
        selectedRestoreSnapshotID = nil
        restoreConfirmation = nil
        confirmedRestoreIdentity = nil
    }

    private func recordRestoreAudit(
        eventType: String,
        summary: String,
        operationID: String?,
        snapshotIdentifier: String?,
        state: RestoreControllerState,
        activationFailure: RestoreActivationFailure? = nil,
        rollbackFailure: RestoreActivationFailure? = nil,
        stagingFailure: RestoreStagingFailureReason? = nil
    ) {
        try? recordRestoreAuditOrThrow(
            eventType: eventType,
            summary: summary,
            operationID: operationID,
            snapshotIdentifier: snapshotIdentifier,
            state: state,
            activationFailure: activationFailure,
            rollbackFailure: rollbackFailure,
            stagingFailure: stagingFailure
        )
    }

    private func recordRestoreAuditOrThrow(
        eventType: String,
        summary: String,
        operationID: String?,
        snapshotIdentifier: String?,
        state: RestoreControllerState,
        activationFailure: RestoreActivationFailure? = nil,
        rollbackFailure: RestoreActivationFailure? = nil,
        stagingFailure: RestoreStagingFailureReason? = nil
    ) throws {
        if let operationID,
           try store.auditEvents.fetchEvents(
               relatedTable: "backup_snapshots",
               relatedID: snapshotIdentifier ?? "unknown",
               eventType: eventType
           ).contains(where: {
               $0.metadataJSON?.lowercased().contains(operationID.lowercased()) == true
           })
        {
            return
        }
        let metadata = RestoreAuditMetadata(
            schemaVersion: 1,
            operationID: operationID,
            snapshotIdentifier: snapshotIdentifier,
            state: state.rawValue,
            activationFailure: activationFailure?.rawValue,
            rollbackFailure: rollbackFailure?.rawValue,
            stagingFailure: stagingFailure?.rawValue
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadataJSON = (try? encoder.encode(metadata)).map {
            String(decoding: $0, as: UTF8.self)
        }
        _ = try store.auditEvents.recordEvent(
            eventType: eventType,
            actor: "user",
            summary: summary,
            relatedTable: "backup_snapshots",
            relatedID: snapshotIdentifier ?? "unknown",
            metadataJSON: metadataJSON
        )
    }

    private static func displayItem(_ candidate: RestoreSnapshotCandidate) -> RestoreSnapshotListItem {
        RestoreSnapshotListItem(
            id: candidate.identifier,
            createdAt: candidate.summary?.createdAt,
            appVersion: candidate.summary?.appVersion,
            appBuild: candidate.summary?.appBuild,
            databaseBytes: candidate.summary?.databaseBytes,
            referencedBlobCount: candidate.summary?.referencedBlobCount,
            incompatibility: candidate.incompatibility
        )
    }

    private static func failureMessage(for error: Error) -> String {
        if let destinationError = error as? BackupDestinationError {
            return destinationError.localizedDescription
        }
        return "Backup failed. \(error.localizedDescription)"
    }

    nonisolated private static func stagingFailureReason(
        for error: Error
    ) -> RestoreStagingFailureReason {
        guard let error = error as? RestoreStageError else { return .stagingIOFailed }
        switch error {
        case .liveDatabasePathMismatch:
            return .liveDatabasePathMismatch
        case .liveDatabaseCloseFailed:
            return .liveDatabaseCloseFailed
        case .sourceSnapshotUnavailable:
            return .selectedSnapshotUnavailable
        case .sourceSnapshotChanged:
            return .selectedSnapshotChanged
        case .sourceSnapshotIncompatible:
            return .selectedSnapshotIncompatible
        case .liveDatabaseMissing, .liveStateIncompatible:
            return .liveStateInvalid
        case .stagingVolumeMismatch:
            return .stagingVolumeMismatch
        case .copiedSafetyStateMismatch, .copiedSelectedStateMismatch:
            return .copiedStateInvalid
        case .restoreAlreadyPending:
            return .stagingIOFailed
        }
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

private enum ActiveOperation {
    case backup
    case restoreInspection
    case restoreStaging
}

private enum RestoreFailurePhase {
    case inspection
    case staging
}

private enum RestoreControllerError: Error {
    case snapshotChanged
    case invalidStageResult
}

private struct RestoreSnapshotIdentity: Equatable {
    let identifier: String
    let manifest: BackupManifest?
    let databaseSHA256: String?
    let referencedBlobs: [RestoreBlobReference]

    init(_ candidate: RestoreSnapshotCandidate) {
        identifier = candidate.identifier
        manifest = candidate.manifest
        databaseSHA256 = candidate.databaseSHA256
        referencedBlobs = candidate.referencedBlobs
    }
}

private struct RestoreAuditMetadata: Codable {
    let schemaVersion: Int
    let operationID: String?
    let snapshotIdentifier: String?
    let state: String
    let activationFailure: String?
    let rollbackFailure: String?
    let stagingFailure: String?
}
