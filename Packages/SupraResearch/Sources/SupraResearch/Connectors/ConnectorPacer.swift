import Foundation

/// Per-connector request pacing: enforces a minimum delay between OUTBOUND
/// attempts (including retries). This is client-side courtesy pacing on top of
/// `AuthorizedHTTPClient`'s rolling per-minute/hour budget — the pacer smooths
/// the short term, the tracker caps the long term.
public actor ConnectorPacer {
    private let minimumDelay: TimeInterval
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let now: @Sendable () -> Date
    private var lastAttempt: Date?

    public init(
        requestsPerSecond: Double,
        now: @escaping @Sendable () -> Date = Date.init,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.minimumDelay = requestsPerSecond > 0 ? 1.0 / requestsPerSecond : 0
        self.now = now
        self.sleeper = sleeper
    }

    /// Reserves the next slot BEFORE suspending, then waits it out. Reserving
    /// first is what keeps the contract under actor reentrancy: while one
    /// caller is suspended in `sleeper`, the actor is free to admit another —
    /// each claims the next sequential slot instead of re-reading a stale
    /// `lastAttempt` and firing simultaneously.
    public func pace() async {
        let currentTime = now()
        let slot: Date
        if let lastAttempt {
            slot = max(currentTime, lastAttempt.addingTimeInterval(minimumDelay))
        } else {
            slot = currentTime
        }
        lastAttempt = slot
        let remaining = slot.timeIntervalSince(currentTime)
        if remaining > 0 {
            await sleeper(remaining)
        }
    }
}
