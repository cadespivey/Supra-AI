import Foundation

public actor RateLimitTracker {
    public struct Limits: Equatable, Sendable {
        public let perMinute: Int
        public let perHour: Int
        public let perDay: Int

        public init(perMinute: Int = 5, perHour: Int = 50, perDay: Int = 125) {
            self.perMinute = perMinute
            self.perHour = perHour
            self.perDay = perDay
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let requestsLastMinute: Int
        public let requestsLastHour: Int
        public let requestsLastDay: Int
        public let limits: Limits

        public init(
            requestsLastMinute: Int,
            requestsLastHour: Int,
            requestsLastDay: Int,
            limits: Limits
        ) {
            self.requestsLastMinute = requestsLastMinute
            self.requestsLastHour = requestsLastHour
            self.requestsLastDay = requestsLastDay
            self.limits = limits
        }
    }

    private let limits: Limits
    private var requestDates: [Date] = []

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    @discardableResult
    public func reserveSlot(now: Date = Date()) throws -> Snapshot {
        prune(now: now)
        let current = snapshot(now: now)
        guard current.requestsLastMinute < limits.perMinute,
              current.requestsLastHour < limits.perHour,
              current.requestsLastDay < limits.perDay else {
            throw NetworkPolicyError.localRateLimitExceeded(current)
        }

        requestDates.append(now)
        return snapshot(now: now)
    }

    private func snapshot(now: Date) -> Snapshot {
        Snapshot(
            requestsLastMinute: countRequests(since: now.addingTimeInterval(-60)),
            requestsLastHour: countRequests(since: now.addingTimeInterval(-3_600)),
            requestsLastDay: countRequests(since: now.addingTimeInterval(-86_400)),
            limits: limits
        )
    }

    private func prune(now: Date) {
        let earliest = now.addingTimeInterval(-86_400)
        requestDates.removeAll { $0 < earliest }
    }

    private func countRequests(since date: Date) -> Int {
        requestDates.filter { $0 >= date }.count
    }
}
