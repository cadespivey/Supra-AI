import Foundation
import SupraCore

/// One exact, currently selected revision source admitted by the Store-owned
/// corpus-scope inspection policy. Sessions may partition these immutable record
/// values, while Store reuses the same policy inside atomic submission.
public struct CorpusAnalysisScopeSource: Sendable {
    public let memberKey: String
    public let documentID: String
    public let part: DocumentPagePartRecord
    public let revision: DocumentPartRevisionRecord
    public let orderDate: Date?

    public init(
        memberKey: String,
        documentID: String,
        part: DocumentPagePartRecord,
        revision: DocumentPartRevisionRecord,
        orderDate: Date?
    ) {
        self.memberKey = memberKey
        self.documentID = documentID
        self.part = part
        self.revision = revision
        self.orderDate = orderDate
    }
}

/// The exact current denominator and the eligible revision records from the
/// same database snapshot. Excluded members remain in `snapshot` but never
/// appear in `sources`.
public struct CorpusAnalysisScopeInspection: Sendable {
    public let snapshot: CorpusAnalysisSnapshot
    public let sources: [CorpusAnalysisScopeSource]

    public init(
        snapshot: CorpusAnalysisSnapshot,
        sources: [CorpusAnalysisScopeSource]
    ) {
        self.snapshot = snapshot
        self.sources = sources
    }
}
