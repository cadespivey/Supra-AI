import Foundation
import GRDB

/// One immutable classifier attempt over an exact set of extracted revisions.
/// `matter_documents.classification_metadata_json` is only a compatible latest
/// projection; this row is the authoritative lineage and history record.
public struct DocumentClassificationRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "document_classifications"

    public var id: String
    public var matterID: String
    public var documentID: String
    public var classificationKey: String
    public var inputRevisionIDsJSON: String
    public var inputChecksum: String
    public var modelRepository: String
    public var modelRevision: String
    public var promptVersion: String
    public var samplingStrategy: String
    public var samplingVersion: Int
    public var primaryCategory: String?
    public var secondaryCategoriesJSON: String
    public var confidenceJSON: String
    public var calibrationVersion: String
    public var abstained: Bool
    public var abstentionReason: String?
    public var evidenceSpansJSON: String
    public var warningsJSON: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        matterID: String,
        documentID: String,
        classificationKey: String,
        inputRevisionIDsJSON: String,
        inputChecksum: String,
        modelRepository: String,
        modelRevision: String,
        promptVersion: String,
        samplingStrategy: String,
        samplingVersion: Int,
        primaryCategory: String?,
        secondaryCategoriesJSON: String,
        confidenceJSON: String,
        calibrationVersion: String,
        abstained: Bool,
        abstentionReason: String? = nil,
        evidenceSpansJSON: String,
        warningsJSON: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.matterID = matterID
        self.documentID = documentID
        self.classificationKey = classificationKey
        self.inputRevisionIDsJSON = inputRevisionIDsJSON
        self.inputChecksum = inputChecksum
        self.modelRepository = modelRepository
        self.modelRevision = modelRevision
        self.promptVersion = promptVersion
        self.samplingStrategy = samplingStrategy
        self.samplingVersion = samplingVersion
        self.primaryCategory = primaryCategory
        self.secondaryCategoriesJSON = secondaryCategoriesJSON
        self.confidenceJSON = confidenceJSON
        self.calibrationVersion = calibrationVersion
        self.abstained = abstained
        self.abstentionReason = abstentionReason
        self.evidenceSpansJSON = evidenceSpansJSON
        self.warningsJSON = warningsJSON
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matterID = "matter_id"
        case documentID = "document_id"
        case classificationKey = "classification_key"
        case inputRevisionIDsJSON = "input_revision_ids_json"
        case inputChecksum = "input_checksum"
        case modelRepository = "model_repository"
        case modelRevision = "model_revision"
        case promptVersion = "prompt_version"
        case samplingStrategy = "sampling_strategy"
        case samplingVersion = "sampling_version"
        case primaryCategory = "primary_category"
        case secondaryCategoriesJSON = "secondary_categories_json"
        case confidenceJSON = "confidence_json"
        case calibrationVersion = "calibration_version"
        case abstained
        case abstentionReason = "abstention_reason"
        case evidenceSpansJSON = "evidence_spans_json"
        case warningsJSON = "warnings_json"
        case createdAt = "created_at"
    }
}
