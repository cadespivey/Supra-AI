import Combine
import Foundation
import SupraDraftingCore
import SupraStore

/// Owns the firm's `FirmStyleProfile` (Track A structural style): loads it at launch, autosaves
/// every edit, and surfaces a message only if a write fails. Mirrors `AssistantProfileController`
/// (SPEC §4.4). In the app it feeds its `.profile` into `MatterDraftingController`'s
/// `firmStyleProfile` injection point, so a firm's letterhead/caption/signature choices flow
/// deterministically into every draft.
@MainActor
public final class FirmStyleProfileController: ObservableObject {
    /// Every edit autosaves immediately (didSet → persist), so a firm can never lose its style by
    /// forgetting to press a button. didSet does not fire for the initial assignment in `init`, so
    /// loading the stored profile doesn't loop.
    @Published public var profile: FirmStyleProfile { didSet { persist() } }
    @Published public var message: String?

    /// The persistence operation. Defaults to a write into `store.appSettings`; the internal init
    /// swaps in a custom closure so the failure path is unit-testable (there is no store protocol
    /// to stub).
    private let write: (FirmStyleProfile) throws -> Void

    public init(store: SupraStore) {
        self.write = { try store.appSettings.setSetting(FirmStyleProfile.profileKey, value: $0) }
        self.profile = (try? store.appSettings.getSetting(FirmStyleProfile.profileKey, as: FirmStyleProfile.self))
            ?? FirmStyleProfile()
    }

    /// Testing seam: an explicit initial profile + injectable persistence (no store).
    init(initialProfile: FirmStyleProfile, write: @escaping (FirmStyleProfile) throws -> Void) {
        self.write = write
        self.profile = initialProfile
    }

    /// The effective sheet the renderers would consume for this firm — for a Settings preview.
    public var effectiveStyle: HouseStyleSheet {
        profile.resolved(over: .defaultFL).clampedToFloor()
    }

    /// Clears any transient status message.
    public func clearMessage() { message = nil }

    /// Autosaves the profile. Silent on success (no per-keystroke status), but surfaces a message
    /// if the write fails so the firm is never silently losing its style configuration.
    private func persist() {
        do {
            try write(profile)
        } catch {
            message = "Couldn't save your firm style. \(error.localizedDescription)"
        }
    }
}
