#if DEBUG
import Foundation
import SupraCore

/// Test-only acknowledgements for deterministic hosted-XPC lifecycle probes.
/// This wire surface is excluded from non-Debug builds.
public struct RuntimeLifecycleDebugStatus: Codable, Sendable {
    public let reservationPausedGenerationID: GenerationID?
    public let reservationTerminationHandlerEnteredGenerationID: GenerationID?
    public let reservationAdmissionReleasedGenerationID: GenerationID?
    public let reservationCancellationAttemptedGenerationID: GenerationID?
    public let reservationCancellationStatus: CancelGenerationStatus?
    public let staleTerminationCapturedGenerationID: GenerationID?
    public let staleSuccessorAdmittedGenerationID: GenerationID?
    public let staleCancellationAttemptedGenerationID: GenerationID?
    public let staleCancellationStatus: CancelGenerationStatus?

    public init(
        reservationPausedGenerationID: GenerationID? = nil,
        reservationTerminationHandlerEnteredGenerationID: GenerationID? = nil,
        reservationAdmissionReleasedGenerationID: GenerationID? = nil,
        reservationCancellationAttemptedGenerationID: GenerationID? = nil,
        reservationCancellationStatus: CancelGenerationStatus? = nil,
        staleTerminationCapturedGenerationID: GenerationID? = nil,
        staleSuccessorAdmittedGenerationID: GenerationID? = nil,
        staleCancellationAttemptedGenerationID: GenerationID? = nil,
        staleCancellationStatus: CancelGenerationStatus? = nil
    ) {
        self.reservationPausedGenerationID = reservationPausedGenerationID
        self.reservationTerminationHandlerEnteredGenerationID = reservationTerminationHandlerEnteredGenerationID
        self.reservationAdmissionReleasedGenerationID = reservationAdmissionReleasedGenerationID
        self.reservationCancellationAttemptedGenerationID = reservationCancellationAttemptedGenerationID
        self.reservationCancellationStatus = reservationCancellationStatus
        self.staleTerminationCapturedGenerationID = staleTerminationCapturedGenerationID
        self.staleSuccessorAdmittedGenerationID = staleSuccessorAdmittedGenerationID
        self.staleCancellationAttemptedGenerationID = staleCancellationAttemptedGenerationID
        self.staleCancellationStatus = staleCancellationStatus
    }
}
#endif
