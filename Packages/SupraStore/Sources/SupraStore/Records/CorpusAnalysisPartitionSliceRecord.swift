import Foundation
import GRDB

/// One immutable, exact Character range presented to a corpus mapper. Document
/// and revision identities are frozen provenance rather than live foreign keys;
/// repository preparation validates them before this row is persisted.
public struct CorpusAnalysisPartitionSliceRecord: Codable, FetchableRecord, PersistableRecord,
    Sendable, Identifiable, Equatable
{
    public static let databaseTableName = "corpus_analysis_partition_slices"

    public var id: String
    public var runID: String
    public var partitionID: String
    public var ordinal: Int
    public var memberKey: String
    public var documentID: String
    public var partIndex: Int
    public var revisionID: String
    public var charStart: Int
    public var charEnd: Int
    public var revisionCharCount: Int
    public var textSHA256: String
    public var locatorJSON: String

    public init(
        id: String = UUID().uuidString,
        runID: String,
        partitionID: String,
        ordinal: Int,
        memberKey: String,
        documentID: String,
        partIndex: Int,
        revisionID: String,
        charStart: Int,
        charEnd: Int,
        revisionCharCount: Int,
        textSHA256: String,
        locatorJSON: String
    ) {
        self.id = id
        self.runID = runID
        self.partitionID = partitionID
        self.ordinal = ordinal
        self.memberKey = memberKey
        self.documentID = documentID
        self.partIndex = partIndex
        self.revisionID = revisionID
        self.charStart = charStart
        self.charEnd = charEnd
        self.revisionCharCount = revisionCharCount
        self.textSHA256 = textSHA256
        self.locatorJSON = locatorJSON
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case runID = "run_id"
        case partitionID = "partition_id"
        case ordinal
        case memberKey = "member_key"
        case documentID = "document_id"
        case partIndex = "part_index"
        case revisionID = "revision_id"
        case charStart = "char_start"
        case charEnd = "char_end"
        case revisionCharCount = "revision_char_count"
        case textSHA256 = "text_sha256"
        case locatorJSON = "locator_json"
    }
}
