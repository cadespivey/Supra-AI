import Foundation
import SupraRuntimeInterface

/// Exact identity of the locally authorized model artifact used by a durable
/// corpus-analysis request. Repository and revision identify the release;
/// `artifactFingerprintSHA256` records the declared expected artifact fingerprint.
public struct CorpusAnalysisPinnedModel: Codable, Equatable, Sendable {
    public var modelRepository: String
    public var modelRevision: String
    public var contentBindingAlgorithm: String
    public var contentBindingSchemaVersion: Int
    public var artifactFingerprintSHA256: String

    public init(
        modelRepository: String,
        modelRevision: String,
        contentBindingAlgorithm: String,
        contentBindingSchemaVersion: Int,
        artifactFingerprintSHA256: String
    ) {
        self.modelRepository = modelRepository
        self.modelRevision = modelRevision
        self.contentBindingAlgorithm = contentBindingAlgorithm
        self.contentBindingSchemaVersion = contentBindingSchemaVersion
        self.artifactFingerprintSHA256 = artifactFingerprintSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case modelRepository = "model_repository"
        case modelRevision = "model_revision"
        case contentBindingAlgorithm = "content_binding_algorithm"
        case contentBindingSchemaVersion = "content_binding_schema_version"
        case artifactFingerprintSHA256 = "artifact_fingerprint_sha256"
    }

    static func decode(json: String?) -> Self? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func validate() throws {
        guard !modelRepository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CorpusAnalysisPreparationError.invalidPinnedModel("model repository")
        }
        guard Self.isLowercaseHex(modelRevision, count: 40) else {
            throw CorpusAnalysisPreparationError.invalidPinnedModel("model revision")
        }
        guard contentBindingAlgorithm == RuntimeModelContentBinding.fingerprintAlgorithm else {
            throw CorpusAnalysisPreparationError.invalidPinnedModel("content-binding algorithm")
        }
        guard contentBindingSchemaVersion == RuntimeModelContentBinding.supportedManifestSchemaVersion else {
            throw CorpusAnalysisPreparationError.invalidPinnedModel("content-binding schema")
        }
        guard Self.isLowercaseHex(artifactFingerprintSHA256, count: 64) else {
            throw CorpusAnalysisPreparationError.invalidPinnedModel("artifact fingerprint")
        }
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count
            && value.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
            }
    }
}

/// Reconstructible, production-safe exhaustive-list request. Evaluation-only
/// answer keys deliberately remain on `ExhaustiveListRequest` and never cross
/// this persistence boundary.
public struct ExhaustiveListQueuedRequest: Codable, Equatable, Sendable {
    public var taskSchemaVersion: Int
    public var promptBuilderVersion: String
    public var runKey: String
    public var matterID: String
    public var title: String
    public var query: String
    public var scope: CorpusAnalysisScope
    public var characterBudget: Int
    public var maximumRetryCount: Int

    public init(
        taskSchemaVersion: Int,
        promptBuilderVersion: String,
        runKey: String,
        matterID: String,
        title: String,
        query: String,
        scope: CorpusAnalysisScope = .wholeMatter,
        characterBudget: Int = 24_000,
        maximumRetryCount: Int = 2
    ) {
        self.taskSchemaVersion = taskSchemaVersion
        self.promptBuilderVersion = promptBuilderVersion
        self.runKey = runKey
        self.matterID = matterID
        self.title = title
        self.query = query
        self.scope = scope
        self.characterBudget = max(1, characterBudget)
        self.maximumRetryCount = max(0, maximumRetryCount)
    }

    private enum CodingKeys: String, CodingKey {
        case taskSchemaVersion = "task_schema_version"
        case promptBuilderVersion = "prompt_builder_version"
        case runKey = "run_key"
        case matterID = "matter_id"
        case title
        case query
        case scope
        case characterBudget = "character_budget"
        case maximumRetryCount = "maximum_retry_count"
    }
}

public enum CorpusAnalysisQueuedTask: Codable, Equatable, Sendable {
    case legacy
    case exhaustiveList(ExhaustiveListQueuedRequest)

    private enum CodingKeys: String, CodingKey {
        case kind
        case request
    }

    private enum Kind: String, Codable {
        case exhaustiveList = "exhaustive_list"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .exhaustiveList:
            self = .exhaustiveList(
                try container.decode(ExhaustiveListQueuedRequest.self, forKey: .request)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .legacy:
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "A legacy corpus task has no v2 task encoding."
                )
            )
        case .exhaustiveList(let request):
            try container.encode(Kind.exhaustiveList, forKey: .kind)
            try container.encode(request, forKey: .request)
        }
    }
}

public struct CorpusAnalysisJobPayload: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var runID: String
    public var requestDigest: String
    public var task: CorpusAnalysisQueuedTask
    public var pinnedModel: CorpusAnalysisPinnedModel

    public init(
        schemaVersion: Int = 2,
        runID: String,
        requestDigest: String,
        task: CorpusAnalysisQueuedTask,
        pinnedModel: CorpusAnalysisPinnedModel
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.requestDigest = requestDigest
        self.task = task
        self.pinnedModel = pinnedModel
    }

    /// Historical run-ID-only representation. It remains decodable so the
    /// durable queue can identify and fail legacy work explicitly; it is never
    /// promoted into a reconstructible v2 request.
    public init(runID: String) {
        schemaVersion = 1
        self.runID = runID
        requestDigest = ""
        task = .legacy
        pinnedModel = CorpusAnalysisPinnedModel(
            modelRepository: "",
            modelRevision: "",
            contentBindingAlgorithm: "",
            contentBindingSchemaVersion: 0,
            artifactFingerprintSHA256: ""
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case requestDigest = "request_digest"
        case task
        case pinnedModel = "pinned_model"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let runID = try container.decode(String.self, forKey: .runID)
        guard container.contains(.schemaVersion) else {
            self.init(runID: runID)
            return
        }
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            runID: runID,
            requestDigest: try container.decode(String.self, forKey: .requestDigest),
            task: try container.decode(CorpusAnalysisQueuedTask.self, forKey: .task),
            pinnedModel: try container.decode(CorpusAnalysisPinnedModel.self, forKey: .pinnedModel)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID, forKey: .runID)
        guard schemaVersion != 1 else { return }
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(requestDigest, forKey: .requestDigest)
        try container.encode(task, forKey: .task)
        try container.encode(pinnedModel, forKey: .pinnedModel)
    }
}
