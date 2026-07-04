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

    /// Waits out the remainder of the pacing window, then records the attempt.
    public func pace() async {
        if let lastAttempt {
            let elapsed = now().timeIntervalSince(lastAttempt)
            let remaining = minimumDelay - elapsed
            if remaining > 0 {
                await sleeper(remaining)
            }
        }
        lastAttempt = now()
    }
}
