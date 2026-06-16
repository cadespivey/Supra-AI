import Foundation
import SupraRuntimeInterface

struct RuntimeMetricsCollector {
    private let startedAt = Date()
    private var firstTokenAt: Date?
    private var generatedTokenCount = 0

    mutating func recordToken(at date: Date = Date()) {
        if firstTokenAt == nil {
            firstTokenAt = date
        }
        generatedTokenCount += 1
    }

    func completionMetrics(at date: Date = Date()) -> RuntimeMetrics {
        RuntimeMetrics(
            firstTokenLatencyMs: latency(from: startedAt, to: firstTokenAt),
            tokensPerSecond: tokensPerSecond(at: date),
            generatedTokenCount: generatedTokenCount
        )
    }

    func cancellationMetrics(at date: Date = Date()) -> RuntimeMetrics {
        RuntimeMetrics(
            firstTokenLatencyMs: latency(from: startedAt, to: firstTokenAt),
            tokensPerSecond: tokensPerSecond(at: date),
            cancellationLatencyMs: max(0, Int(date.timeIntervalSince(startedAt) * 1_000)),
            generatedTokenCount: generatedTokenCount
        )
    }

    private func latency(from start: Date, to end: Date?) -> Int? {
        guard let end else {
            return nil
        }
        return max(0, Int(end.timeIntervalSince(start) * 1_000))
    }

    private func tokensPerSecond(at date: Date) -> Double? {
        guard generatedTokenCount > 0 else {
            return nil
        }

        let elapsed = max(date.timeIntervalSince(startedAt), 0.001)
        return Double(generatedTokenCount) / elapsed
    }
}

