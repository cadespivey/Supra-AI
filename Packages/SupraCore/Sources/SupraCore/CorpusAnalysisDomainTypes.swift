import Foundation

/// Assurance is intentionally orthogonal to an output's lifecycle status.
/// These raw values are persisted on corpus-analysis runs beginning with v064.
public enum OutputAssuranceState: String, Codable, CaseIterable, Hashable, Sendable {
    case preliminary
    case supportNeedsReview = "support_needs_review"
    case propositionSupported = "proposition_supported"
    case corpusIncomplete = "corpus_incomplete"
    case corpusComplete = "corpus_complete"
    case negativeBlocked = "negative_blocked"
    case stale
}

public enum CorpusAnalysisTaskKind: String, Codable, CaseIterable, Hashable, Sendable {
    case exhaustiveList = "exhaustive_list"
    case chronology
    case comparison
    case negativeCheck = "negative_check"
    case customExtraction = "custom_extraction"
}

public enum CorpusAnalysisRunStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case planning
    case running
    case reconciling
    case verifying
    case persisted
    case failed
    case cancelled
}

public enum CorpusAnalysisPartitionDisposition: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case succeeded
    case failed
    case cancelled
    case excluded

    public var isTerminal: Bool { self != .pending }
}

public enum CorpusAnalysisSnapshotDisposition: String, Codable, CaseIterable, Hashable, Sendable {
    case eligible
    case excluded
}

/// One member of the frozen corpus denominator. Members without a document id
/// are persisted import-source exclusions that never became documents.
public struct CorpusAnalysisSnapshotMember: Codable, Equatable, Sendable {
    public var memberKey: String
    public var documentID: String?
    public var displayName: String
    public var revisionIDs: [String]
    public var indexState: String?
    public var disposition: CorpusAnalysisSnapshotDisposition
    public var reason: String?

    public init(
        memberKey: String,
        documentID: String? = nil,
        displayName: String,
        revisionIDs: [String] = [],
        indexState: String? = nil,
        disposition: CorpusAnalysisSnapshotDisposition,
        reason: String? = nil
    ) {
        self.memberKey = memberKey
        self.documentID = documentID
        self.displayName = displayName
        self.revisionIDs = revisionIDs
        self.indexState = indexState
        self.disposition = disposition
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case memberKey = "member_key"
        case documentID = "document_id"
        case displayName = "display_name"
        case revisionIDs = "revision_ids"
        case indexState = "index_state"
        case disposition
        case reason
    }
}

public struct CorpusAnalysisSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var members: [CorpusAnalysisSnapshotMember]

    public init(schemaVersion: Int = 1, members: [CorpusAnalysisSnapshotMember]) {
        self.schemaVersion = schemaVersion
        self.members = members
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case members
    }
}

/// Canonical denominator and terminal-bucket accounting persisted on each run.
public struct CorpusAnalysisCoverage: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var snapshotMemberCount: Int
    public var eligibleMemberCount: Int
    public var excludedMemberCount: Int
    public var excludedMembersDisclosed: Bool
    public var partitionCount: Int
    public var pendingPartitionCount: Int
    public var succeededPartitionCount: Int
    public var failedPartitionCount: Int
    public var cancelledPartitionCount: Int
    public var excludedPartitionCount: Int
    public var terminalPartitionCount: Int
    public var balanceErrorCount: Int

    public init(
        schemaVersion: Int = 1,
        snapshotMemberCount: Int,
        eligibleMemberCount: Int,
        excludedMemberCount: Int,
        excludedMembersDisclosed: Bool,
        partitionCount: Int,
        pendingPartitionCount: Int,
        succeededPartitionCount: Int,
        failedPartitionCount: Int,
        cancelledPartitionCount: Int,
        excludedPartitionCount: Int,
        terminalPartitionCount: Int,
        balanceErrorCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.snapshotMemberCount = snapshotMemberCount
        self.eligibleMemberCount = eligibleMemberCount
        self.excludedMemberCount = excludedMemberCount
        self.excludedMembersDisclosed = excludedMembersDisclosed
        self.partitionCount = partitionCount
        self.pendingPartitionCount = pendingPartitionCount
        self.succeededPartitionCount = succeededPartitionCount
        self.failedPartitionCount = failedPartitionCount
        self.cancelledPartitionCount = cancelledPartitionCount
        self.excludedPartitionCount = excludedPartitionCount
        self.terminalPartitionCount = terminalPartitionCount
        self.balanceErrorCount = balanceErrorCount
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case snapshotMemberCount = "snapshot_member_count"
        case eligibleMemberCount = "eligible_member_count"
        case excludedMemberCount = "excluded_member_count"
        case excludedMembersDisclosed = "excluded_members_disclosed"
        case partitionCount = "partition_count"
        case pendingPartitionCount = "pending_partition_count"
        case succeededPartitionCount = "succeeded_partition_count"
        case failedPartitionCount = "failed_partition_count"
        case cancelledPartitionCount = "cancelled_partition_count"
        case excludedPartitionCount = "excluded_partition_count"
        case terminalPartitionCount = "terminal_partition_count"
        case balanceErrorCount = "balance_error_count"
    }
}
