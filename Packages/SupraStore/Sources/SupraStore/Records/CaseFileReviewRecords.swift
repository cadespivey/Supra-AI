import Foundation
import GRDB

public struct CaseFileReviewProjectRecord: Codable, FetchableRecord, PersistableRecord,
    Sendable, Identifiable, Equatable
{
    public static let databaseTableName = "case_file_review_projects"

    public var id: String
    public var matterID: String
    public var title: String
    public var status: String
    public var staleReason: String?
    public var sourceRunID: String
    public var sourceOutputID: String
    public var sourceOutputVersionID: String
    public var sourceRequestDigest: String
    public var frozenScopeJSON: String
    public var frozenCorpusSnapshotJSON: String
    public var frozenReconciliationJSON: String
    public var activeTableID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        title: String,
        status: String = "active",
        staleReason: String? = nil,
        sourceRunID: String,
        sourceOutputID: String,
        sourceOutputVersionID: String,
        sourceRequestDigest: String,
        frozenScopeJSON: String,
        frozenCorpusSnapshotJSON: String,
        frozenReconciliationJSON: String,
        activeTableID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.matterID = matterID
        self.title = title
        self.status = status
        self.staleReason = staleReason
        self.sourceRunID = sourceRunID
        self.sourceOutputID = sourceOutputID
        self.sourceOutputVersionID = sourceOutputVersionID
        self.sourceRequestDigest = sourceRequestDigest
        self.frozenScopeJSON = frozenScopeJSON
        self.frozenCorpusSnapshotJSON = frozenCorpusSnapshotJSON
        self.frozenReconciliationJSON = frozenReconciliationJSON
        self.activeTableID = activeTableID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case title, status
        case staleReason = "stale_reason"
        case sourceRunID = "source_run_id"
        case sourceOutputID = "source_output_id"
        case sourceOutputVersionID = "source_output_version_id"
        case sourceRequestDigest = "source_request_digest"
        case frozenScopeJSON = "frozen_scope_json"
        case frozenCorpusSnapshotJSON = "frozen_corpus_snapshot_json"
        case frozenReconciliationJSON = "frozen_reconciliation_json"
        case activeTableID = "active_table_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct CaseFileReviewTableRecord: Codable, FetchableRecord, PersistableRecord,
    Sendable, Identifiable, Equatable
{
    public static let databaseTableName = "case_file_review_tables"
    public var id: String
    public var projectID: String
    public var title: String
    public var versionIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        projectID: String,
        title: String,
        versionIndex: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.versionIndex = versionIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case title
        case versionIndex = "version_index"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct CaseFileReviewColumnRecord: Codable, FetchableRecord, PersistableRecord,
    Sendable, Identifiable, Equatable
{
    public static let databaseTableName = "case_file_review_columns"
    public var id: String
    public var tableID: String
    public var columnKey: String
    public var title: String
    public var ordinal: Int
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        tableID: String,
        columnKey: String,
        title: String,
        ordinal: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.tableID = tableID
        self.columnKey = columnKey
        self.title = title
        self.ordinal = ordinal
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case tableID = "table_id"
        case columnKey = "column_key"
        case title, ordinal
        case createdAt = "created_at"
    }
}

public struct CaseFileReviewRowRecord: Codable, FetchableRecord, PersistableRecord,
    Sendable, Identifiable, Equatable
{
    public static let databaseTableName = "case_file_review_rows"
    public var id: String
    public var tableID: String
    public var rowKey: String
    public var ordinal: Int
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        tableID: String,
        rowKey: String,
        ordinal: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.tableID = tableID
        self.rowKey = rowKey
        self.ordinal = ordinal
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case tableID = "table_id"
        case rowKey = "row_key"
        case ordinal
        case createdAt = "created_at"
    }
}

public struct CaseFileReviewCellRecord: Codable, FetchableRecord, PersistableRecord,
    Sendable, Identifiable, Equatable
{
    public static let databaseTableName = "case_file_review_cells"
    public var id: String
    public var tableID: String
    public var rowID: String
    public var columnID: String
    public var currentGenerationID: String?
    public var attorneyValue: String?
    public var reviewState: String
    public var valueState: String
    public var supportState: String
    public var reviewedBy: String?
    public var reviewedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        tableID: String,
        rowID: String,
        columnID: String,
        currentGenerationID: String? = nil,
        attorneyValue: String? = nil,
        reviewState: String = "needs_review",
        valueState: String = "generated",
        supportState: String,
        reviewedBy: String? = nil,
        reviewedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.tableID = tableID
        self.rowID = rowID
        self.columnID = columnID
        self.currentGenerationID = currentGenerationID
        self.attorneyValue = attorneyValue
        self.reviewState = reviewState
        self.valueState = valueState
        self.supportState = supportState
        self.reviewedBy = reviewedBy
        self.reviewedAt = reviewedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case tableID = "table_id"
        case rowID = "row_id"
        case columnID = "column_id"
        case currentGenerationID = "current_generation_id"
        case attorneyValue = "attorney_value"
        case reviewState = "review_state"
        case valueState = "value_state"
        case supportState = "support_state"
        case reviewedBy = "reviewed_by"
        case reviewedAt = "reviewed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct CaseFileReviewCellGenerationRecord: Codable, FetchableRecord, PersistableRecord,
    Sendable, Identifiable, Equatable
{
    public static let databaseTableName = "case_file_review_cell_generations"
    public var id: String
    public var cellID: String
    public var generationIndex: Int
    public var sourceRunID: String
    public var generatedValuesJSON: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        cellID: String,
        generationIndex: Int = 1,
        sourceRunID: String,
        generatedValuesJSON: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.cellID = cellID
        self.generationIndex = generationIndex
        self.sourceRunID = sourceRunID
        self.generatedValuesJSON = generatedValuesJSON
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case cellID = "cell_id"
        case generationIndex = "generation_index"
        case sourceRunID = "source_run_id"
        case generatedValuesJSON = "generated_values_json"
        case createdAt = "created_at"
    }
}

public struct CaseFileReviewEvidenceEdgeRecord: Codable, FetchableRecord, PersistableRecord,
    Sendable, Identifiable, Equatable
{
    public static let databaseTableName = "case_file_review_evidence_edges"
    public var id: String
    public var generationID: String
    public var kind: String
    public var ordinal: Int
    public var frozenOutputSourceID: String
    public var frozenDocumentID: String
    public var frozenRevisionID: String
    public var frozenDocumentName: String
    public var citationLabel: String
    public var charStart: Int?
    public var charEnd: Int?
    public var locatorJSON: String
    public var excerpt: String
    public var excerptSHA256: String
    public var liveOutputSourceID: String?
    public var liveDocumentID: String?
    public var liveRevisionID: String?
    public var availability: String
    public var unavailableReason: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        generationID: String,
        kind: String,
        ordinal: Int,
        frozenOutputSourceID: String,
        frozenDocumentID: String,
        frozenRevisionID: String,
        frozenDocumentName: String,
        citationLabel: String,
        charStart: Int?,
        charEnd: Int?,
        locatorJSON: String,
        excerpt: String,
        excerptSHA256: String,
        liveOutputSourceID: String?,
        liveDocumentID: String?,
        liveRevisionID: String?,
        availability: String = "available",
        unavailableReason: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.generationID = generationID
        self.kind = kind
        self.ordinal = ordinal
        self.frozenOutputSourceID = frozenOutputSourceID
        self.frozenDocumentID = frozenDocumentID
        self.frozenRevisionID = frozenRevisionID
        self.frozenDocumentName = frozenDocumentName
        self.citationLabel = citationLabel
        self.charStart = charStart
        self.charEnd = charEnd
        self.locatorJSON = locatorJSON
        self.excerpt = excerpt
        self.excerptSHA256 = excerptSHA256
        self.liveOutputSourceID = liveOutputSourceID
        self.liveDocumentID = liveDocumentID
        self.liveRevisionID = liveRevisionID
        self.availability = availability
        self.unavailableReason = unavailableReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case generationID = "generation_id"
        case kind, ordinal
        case frozenOutputSourceID = "frozen_output_source_id"
        case frozenDocumentID = "frozen_document_id"
        case frozenRevisionID = "frozen_revision_id"
        case frozenDocumentName = "frozen_document_name"
        case citationLabel = "citation_label"
        case charStart = "char_start"
        case charEnd = "char_end"
        case locatorJSON = "locator_json"
        case excerpt
        case excerptSHA256 = "excerpt_sha256"
        case liveOutputSourceID = "live_output_source_id"
        case liveDocumentID = "live_document_id"
        case liveRevisionID = "live_revision_id"
        case availability
        case unavailableReason = "unavailable_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct CaseFileReviewProjectGraph: Sendable, Equatable {
    public var project: CaseFileReviewProjectRecord
    public var table: CaseFileReviewTableRecord
    public var columns: [CaseFileReviewColumnRecord]
    public var rows: [CaseFileReviewRowRecord]
    public var cells: [CaseFileReviewCellRecord]
    public var generations: [CaseFileReviewCellGenerationRecord]

    public init(
        project: CaseFileReviewProjectRecord,
        table: CaseFileReviewTableRecord,
        columns: [CaseFileReviewColumnRecord],
        rows: [CaseFileReviewRowRecord],
        cells: [CaseFileReviewCellRecord],
        generations: [CaseFileReviewCellGenerationRecord]
    ) {
        self.project = project
        self.table = table
        self.columns = columns
        self.rows = rows
        self.cells = cells
        self.generations = generations
    }
}

/// One current Review row captured with the exact immutable generation and
/// frozen evidence that support its mutable attorney-work state.
public struct CaseFileReviewSnapshotRow: Sendable, Equatable {
    public let row: CaseFileReviewRowRecord
    public let cell: CaseFileReviewCellRecord
    public let generation: CaseFileReviewCellGenerationRecord
    public let evidence: [CaseFileReviewEvidenceEdgeRecord]

    public init(
        row: CaseFileReviewRowRecord,
        cell: CaseFileReviewCellRecord,
        generation: CaseFileReviewCellGenerationRecord,
        evidence: [CaseFileReviewEvidenceEdgeRecord]
    ) {
        self.row = row
        self.cell = cell
        self.generation = generation
        self.evidence = evidence
    }
}

/// A format-neutral, point-in-time projection of every row in one active Review
/// Matrix. Store captures all members in one database transaction so CSV and
/// later spreadsheet renderers cannot mix project, cell, or evidence revisions.
public struct CaseFileReviewSnapshot: Sendable, Equatable {
    public let project: CaseFileReviewProjectRecord
    public let table: CaseFileReviewTableRecord
    public let columns: [CaseFileReviewColumnRecord]
    public let rows: [CaseFileReviewSnapshotRow]

    public init(
        project: CaseFileReviewProjectRecord,
        table: CaseFileReviewTableRecord,
        columns: [CaseFileReviewColumnRecord],
        rows: [CaseFileReviewSnapshotRow]
    ) {
        self.project = project
        self.table = table
        self.columns = columns
        self.rows = rows
    }
}
