import AppKit
import Combine
import Sparkle
import SwiftUI

/// Drives in-app updates via Sparkle. Automatic checks plus silent background
/// downloads mean updates arrive seamlessly: Sparkle downloads the new version in
/// the background and shows a single "Install and Relaunch" prompt — no browser, no
/// DMG drag, no Finder, no macOS "replace data" dialog. The Settings button forces an
/// explicit check; an already-downloaded update installs straight from that prompt.
@MainActor
final class SparkleUpdaterController: NSObject, ObservableObject {
    /// Mirrors `SPUUpdater.canCheckForUpdates` so the Settings button can disable
    /// itself while a check/install session is in progress.
    @Published private(set) var canCheckForUpdates = false
    /// Bound to the "Check for updates automatically" toggle.
    @Published var automaticallyChecksForUpdates = true {
        didSet {
            guard isStarted, updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    /// Last user-facing line from a manual check (e.g. "You're on the latest version.").
    @Published private(set) var statusMessage: String?

    private var controller: SPUStandardUpdaterController!
    private var cancellables: Set<AnyCancellable> = []
    private var isStarted = false

    private var updater: SPUUpdater { controller.updater }

    override init() {
        super.init()
        // Defer starting so the delegates are wired before the first scheduled check.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        // `canCheckForUpdates` is KVO-compliant (Sparkle uses it to validate the
        // standard menu item); mirror it into a published value for SwiftUI.
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
            .store(in: &cancellables)
    }

    /// Starts Sparkle. Called from `AppEnvironment.bootstrap()` after the store and
    /// runtime are up, so the first scheduled check has the delegates in place.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        controller.startUpdater()
        // Silent background download → single "Install and Relaunch" prompt.
        updater.automaticallyDownloadsUpdates = true
        updater.updateCheckInterval = 86_400
    }

    /// Explicit "Check for Updates" action. If a background check already downloaded
    /// an update, Sparkle presents the install prompt directly.
    func checkForUpdates() {
        guard isStarted, updater.canCheckForUpdates else { return }
        statusMessage = nil
        updater.checkForUpdates()
    }
}

// MARK: - SPUUpdaterDelegate

extension SparkleUpdaterController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.statusMessage = "Version \(item.displayVersionString) is available — downloading in the background…"
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.statusMessage = "You're on the latest version." }
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Task { @MainActor in self.statusMessage = "Update download failed: \(error.localizedDescription)" }
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension SparkleUpdaterController: SPUStandardUserDriverDelegate {
    // Use Sparkle's standard "Install and Relaunch" prompt as the single
    // interruption for scheduled, auto-downloaded updates (no gentle-reminder
    // deferral, so the ready-to-install prompt surfaces directly).
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { false }
}
