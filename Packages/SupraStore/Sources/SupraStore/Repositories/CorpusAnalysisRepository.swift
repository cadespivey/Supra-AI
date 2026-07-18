import Foundation
import GRDB
import SupraCore

public enum CorpusAnalysisRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case runKeyCollision(String)
    case runScopeMismatch(String)
    case partitionScopeMismatch(String)
    case partitionIdentityCollision(String)
    case terminalDispositionConflict(String)
    case invalidSnapshot
    case invalidStatusTransition(String)
    case corpusCompleteRequiresAllSucceeded
    case corpusCompleteRequiresDisclosedExclusions

    public var errorDescription: String? {
        switch self {
        case .runKeyCollision(let key): "Corpus run key \(key) was reused for different immutable inputs."
        case .runScopeMismatch(let id): "Corpus run \(id) does not belong to the selected matter."
        case .partitionScopeMismatch(let id): "Corpus partition \(id) does not belong to the selected run."
        case .partitionIdentityCollision(let key): "Corpus partition key \(key) was reused for different revisions."
        case .terminalDispositionConflict(let id): "Corpus partition \(id) already has a different terminal disposition."
        case .invalidSnapshot: "The corpus snapshot could not be decoded."
        case .invalidStatusTransition(let transition): "Invalid corpus run transition: \(transition)."
        case .corpusCompleteRequiresAllSucceeded: "Corpus-complete requires a balanced ledger with every partition succeeded."
        case .corpusCompleteRequiresDisclosedExclusions: "Corpus-complete requires every excluded snapshot member to be disclosed."
        }
    }
}

/// Owns the v064 frozen-run and partition ledger. Immutable planning inputs are
/// insert-only; lifecycle/result fields advance through scoped transactions.
public final class CorpusAnalysisRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func createOrFetchRun(_ proposed: CorpusAnalysisRunRecord) throws -> CorpusAnalysisRunRecord {
        try writer.write { db in
            if let existing = try CorpusAnalysisRunRecord.fetchOne(
                db,
                sql: "SELECT * FROM corpus_analysis_runs WHERE matter_id = ? AND run_key = ?",
                arguments: [proposed.matterID, proposed.runKey]
            ) {
                guard Self.sameImmutableRun(existing, proposed) else {
                    throw CorpusAnalysisRepositoryError.runKeyCollision(proposed.runKey)
                }
                return existing
            }
            try proposed.insert(db)
            return proposed
        }
    }

    public func fetchRun(matterID: String, id: String) throws -> CorpusAnalysisRunRecord? {
        try writer.read { db in
            try CorpusAnalysisRunRecord.fetchOne(
                db,
                sql: "SELECT * FROM corpus_analysis_runs WHERE id = ? AND matter_id = ?",
                arguments: [id, matterID]
            )
        }
    }

    public func fetchRun(matterID: String, runKey: String) throws -> CorpusAnalysisRunRecord? {
        try writer.read { db in
            try CorpusAnalysisRunRecord.fetchOne(
                db,
                sql: "SELECT * FROM corpus_analysis_runs WHERE matter_id = ? AND run_key = ?",
                arguments: [matterID, runKey]
            )
        }
    }

    public func createPartitions(
        matterID: String,
        runID: String,
        partitions: [CorpusAnalysisPartitionRecord]
    ) throws {
        try writer.write { db in
            let run = try scopedRun(db, matterID: matterID, runID: runID)
            guard run.status == CorpusAnalysisRunStatus.planning.rawValue else {
                throw CorpusAnalysisRepositoryError.invalidStatusTransition("\(run.status)->planning_write")
            }
            for partition in partitions {
                guard partition.runID == runID else {
                    throw CorpusAnalysisRepositoryError.partitionScopeMismatch(partition.id)
                }
                if let existing = try CorpusAnalysisPartitionRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM corpus_analysis_partitions WHERE run_id = ? AND partition_key = ?",
                    arguments: [runID, partition.partitionKey]
                ) {
                    guard existing.inputRevisionIDsJSON == partition.inputRevisionIDsJSON else {
                        throw CorpusAnalysisRepositoryError.partitionIdentityCollision(partition.partitionKey)
                    }
                    continue
                }
                try partition.insert(db)
            }
        }
    }

    public func fetchPartitions(matterID: String, runID: String) throws -> [CorpusAnalysisPartitionRecord] {
        try writer.read { db in
            _ = try scopedRun(db, matterID: matterID, runID: runID)
            return try CorpusAnalysisPartitionRecord.fetchAll(
                db,
                sql: "SELECT * FROM corpus_analysis_partitions WHERE run_id = ? ORDER BY partition_key ASC",
                arguments: [runID]
            )
        }
    }

    @discardableResult
    public func updateStatus(
        matterID: String,
        runID: String,
        to status: CorpusAnalysisRunStatus
    ) throws -> CorpusAnalysisRunRecord {
        try writer.write { db in
            var run = try scopedRun(db, matterID: matterID, runID: runID)
            guard Self.canTransition(from: run.status, to: status.rawValue) else {
                throw CorpusAnalysisRepositoryError.invalidStatusTransition("\(run.status)->\(status.rawValue)")
            }
            run.status = status.rawValue
            if status == .failed || status == .cancelled { run.completedAt = Date() }
            try run.update(db)
            return run
        }
    }

    public func setDisposition(
        matterID: String,
        runID: String,
        partitionID: String,
        disposition: CorpusAnalysisPartitionDisposition,
        dispositionReason: String? = nil,
        findingsJSON: String? = nil,
        errorSummary: String? = nil
    ) throws {
        try writer.write { db in
            _ = try scopedRun(db, matterID: matterID, runID: runID)
            guard var partition = try CorpusAnalysisPartitionRecord.fetchOne(db, key: partitionID),
                  partition.runID == runID else {
                throw CorpusAnalysisRepositoryError.partitionScopeMismatch(partitionID)
            }
            let current = CorpusAnalysisPartitionDisposition(rawValue: partition.disposition) ?? .pending
            if current.isTerminal {
                guard current == disposition,
                      partition.dispositionReason == dispositionReason,
                      partition.findingsJSON == findingsJSON,
                      partition.errorSummary == errorSummary else {
                    throw CorpusAnalysisRepositoryError.terminalDispositionConflict(partitionID)
                }
                return
            }
            partition.disposition = disposition.rawValue
            partition.dispositionReason = dispositionReason
            partition.findingsJSON = findingsJSON
            partition.errorSummary = errorSummary
            partition.startedAt = partition.startedAt ?? Date()
            partition.completedAt = disposition.isTerminal ? Date() : nil
            try partition.update(db)
        }
    }

    @discardableResult
    public func coverage(matterID: String, runID: String) throws -> CorpusAnalysisCoverage {
        try writer.write { db in
            var run = try scopedRun(db, matterID: matterID, runID: runID)
            let coverage = try calculateCoverage(db, run: run, exclusionsDisclosed: true)
            run.coverageJSON = try canonicalJSON(coverage)
            try run.update(db)
            return coverage
        }
    }

    @discardableResult
    public func saveReconciliation(
        matterID: String,
        runID: String,
        reconciliationJSON: String,
        validationResultsJSON: String? = nil
    ) throws -> CorpusAnalysisRunRecord {
        try writer.write { db in
            var run = try scopedRun(db, matterID: matterID, runID: runID)
            run.reconciliationJSON = reconciliationJSON
            run.validationResultsJSON = validationResultsJSON
            try run.update(db)
            return run
        }
    }

    @discardableResult
    public func finalizeRun(
        matterID: String,
        runID: String,
        assuranceState: OutputAssuranceState,
        assuranceReasons: [String],
        exclusionsDisclosed: Bool,
        structuredOutputVersionID: String? = nil
    ) throws -> CorpusAnalysisRunRecord {
        try writer.write { db in
            var run = try scopedRun(db, matterID: matterID, runID: runID)
            let coverage = try calculateCoverage(
                db,
                run: run,
                exclusionsDisclosed: exclusionsDisclosed
            )
            if assuranceState == .corpusComplete {
                guard coverage.pendingPartitionCount == 0,
                      coverage.failedPartitionCount == 0,
                      coverage.cancelledPartitionCount == 0,
                      coverage.excludedPartitionCount == 0,
                      coverage.succeededPartitionCount == coverage.partitionCount,
                      coverage.balanceErrorCount == 0 else {
                    throw CorpusAnalysisRepositoryError.corpusCompleteRequiresAllSucceeded
                }
                guard exclusionsDisclosed else {
                    throw CorpusAnalysisRepositoryError.corpusCompleteRequiresDisclosedExclusions
                }
            }
            run.status = CorpusAnalysisRunStatus.persisted.rawValue
            run.coverageJSON = try canonicalJSON(coverage)
            run.assuranceState = assuranceState.rawValue
            run.assuranceReasonsJSON = try canonicalJSON(assuranceReasons)
            run.structuredOutputVersionID = structuredOutputVersionID
            run.completedAt = Date()
            try run.update(db)
            return run
        }
    }

    private func calculateCoverage(
        _ db: Database,
        run: CorpusAnalysisRunRecord,
        exclusionsDisclosed: Bool
    ) throws -> CorpusAnalysisCoverage {
        guard let snapshotData = run.corpusSnapshotJSON.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(CorpusAnalysisSnapshot.self, from: snapshotData) else {
            throw CorpusAnalysisRepositoryError.invalidSnapshot
        }
        let partitions = try CorpusAnalysisPartitionRecord.fetchAll(
            db,
            sql: "SELECT * FROM corpus_analysis_partitions WHERE run_id = ?",
            arguments: [run.id]
        )
        let dispositionCounts = Dictionary(grouping: partitions, by: \.disposition).mapValues(\.count)
        let pending = dispositionCounts[CorpusAnalysisPartitionDisposition.pending.rawValue, default: 0]
        let succeeded = dispositionCounts[CorpusAnalysisPartitionDisposition.succeeded.rawValue, default: 0]
        let failed = dispositionCounts[CorpusAnalysisPartitionDisposition.failed.rawValue, default: 0]
        let cancelled = dispositionCounts[CorpusAnalysisPartitionDisposition.cancelled.rawValue, default: 0]
        let excluded = dispositionCounts[CorpusAnalysisPartitionDisposition.excluded.rawValue, default: 0]
        let terminal = succeeded + failed + cancelled + excluded

        let expectedRevisionIDs = snapshot.members
            .filter { $0.disposition == .eligible }
            .flatMap(\.revisionIDs)
        let actualRevisionIDs = try partitions.flatMap { partition -> [String] in
            guard let data = partition.inputRevisionIDsJSON.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else {
                throw CorpusAnalysisRepositoryError.invalidSnapshot
            }
            return ids
        }
        let expectedCounts = Dictionary(grouping: expectedRevisionIDs, by: { $0 }).mapValues(\.count)
        let actualCounts = Dictionary(grouping: actualRevisionIDs, by: { $0 }).mapValues(\.count)
        let revisionKeys = Set(expectedCounts.keys).union(actualCounts.keys)
        let revisionBalanceErrors = revisionKeys.reduce(0) {
            $0 + abs(expectedCounts[$1, default: 0] - actualCounts[$1, default: 0])
        }
        let bucketBalanceErrors = abs(partitions.count - pending - terminal)

        return CorpusAnalysisCoverage(
            snapshotMemberCount: snapshot.members.count,
            eligibleMemberCount: snapshot.members.filter { $0.disposition == .eligible }.count,
            excludedMemberCount: snapshot.members.filter { $0.disposition == .excluded }.count,
            excludedMembersDisclosed: exclusionsDisclosed,
            partitionCount: partitions.count,
            pendingPartitionCount: pending,
            succeededPartitionCount: succeeded,
            failedPartitionCount: failed,
            cancelledPartitionCount: cancelled,
            excludedPartitionCount: excluded,
            terminalPartitionCount: terminal,
            balanceErrorCount: revisionBalanceErrors + bucketBalanceErrors
        )
    }

    private func scopedRun(_ db: Database, matterID: String, runID: String) throws -> CorpusAnalysisRunRecord {
        guard let run = try CorpusAnalysisRunRecord.fetchOne(db, key: runID),
              run.matterID == matterID else {
            throw CorpusAnalysisRepositoryError.runScopeMismatch(runID)
        }
        return run
    }

    private static func sameImmutableRun(
        _ lhs: CorpusAnalysisRunRecord,
        _ rhs: CorpusAnalysisRunRecord
    ) -> Bool {
        lhs.taskKind == rhs.taskKind
            && lhs.scopeJSON == rhs.scopeJSON
            && lhs.corpusSnapshotJSON == rhs.corpusSnapshotJSON
            && lhs.partitionStrategy == rhs.partitionStrategy
            && lhs.partitionStrategyVersion == rhs.partitionStrategyVersion
            && lhs.modelLineageJSON == rhs.modelLineageJSON
    }

    private static func canTransition(from: String, to: String) -> Bool {
        if from == to { return true }
        return switch (CorpusAnalysisRunStatus(rawValue: from), CorpusAnalysisRunStatus(rawValue: to)) {
        case (.planning, .running), (.running, .reconciling), (.reconciling, .verifying),
             (.planning, .failed), (.running, .failed), (.reconciling, .failed), (.verifying, .failed),
             (.planning, .cancelled), (.running, .cancelled), (.reconciling, .cancelled), (.verifying, .cancelled):
            true
        default:
            false
        }
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
