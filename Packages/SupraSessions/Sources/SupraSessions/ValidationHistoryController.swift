import Combine
import Foundation
import SupraCore
import SupraStore

/// A view-facing snapshot of a persisted validation run.
public struct ValidationRunSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let modelName: String
    public let suiteID: String
    public let suiteVersion: Int
    public let status: ValidationRunStatus
    public let startedAt: Date
    public let completedAt: Date?
    public let summary: String?
    public let warningCount: Int
    public let errorCount: Int

    /// `true` when the run row was never finalized (no terminal status written).
    public var isUnfinished: Bool {
        completedAt == nil
    }
}

/// A view-facing snapshot of a single test within a validation run.
public struct ValidationTestSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let status: ValidationTestStatus
    public let outputExcerpt: String
}

/// Read-side controller that surfaces persisted validation runs for Diagnostics.
@MainActor
public final class ValidationHistoryController: ObservableObject {
    @Published public private(set) var runs: [ValidationRunSummary] = []

    private let store: SupraStore

    public init(store: SupraStore) {
        self.store = store
    }

    public func refresh() {
        let records = (try? store.validation.fetchValidationRuns()) ?? []
        runs = records.map { record in
            ValidationRunSummary(
                id: record.id,
                modelName: (try? store.models.fetchModel(id: record.modelID))?.displayName ?? "Unknown model",
                suiteID: record.suiteID,
                suiteVersion: record.suiteVersion,
                status: ValidationRunStatus(rawValue: record.status) ?? .partial,
                startedAt: record.startedAt,
                completedAt: record.completedAt,
                summary: record.summary,
                warningCount: decodeCount(record.warningsJSON),
                errorCount: decodeCount(record.errorsJSON)
            )
        }
    }

    public func tests(forRun runID: String) -> [ValidationTestSummary] {
        let records = (try? store.validation.fetchValidationTests(runID: runID)) ?? []
        return records.map { record in
            ValidationTestSummary(
                id: record.id,
                name: record.name,
                status: ValidationTestStatus(rawValue: record.status) ?? .skipped,
                outputExcerpt: record.outputExcerpt
            )
        }
    }

    private func decodeCount(_ json: String) -> Int {
        guard
            let data = json.data(using: .utf8),
            let values = try? JSONDecoder().decode([String].self, from: data)
        else {
            return 0
        }
        return values.count
    }
}
