import CryptoKit
import Foundation
import SupraCore
import SupraDocuments
import SupraStore

enum CorpusAnalysisRequestDigest {
    static func exhaustiveList(
        request: ExhaustiveListQueuedRequest,
        snapshot: CorpusAnalysisSnapshot,
        partitions: [CorpusAnalysisPartitionRecord],
        slices: [CorpusAnalysisPartitionSliceRecord],
        pinnedModel: CorpusAnalysisPinnedModel
    ) throws -> String {
        let canonicalSnapshot = CorpusAnalysisSnapshot(
            schemaVersion: snapshot.schemaVersion,
            members: snapshot.members.sorted { $0.memberKey < $1.memberKey }
        )
        let envelope = FrozenExhaustiveRequestEnvelope(
            taskSchemaVersion: request.taskSchemaVersion,
            promptBuilderVersion: request.promptBuilderVersion,
            matterID: request.matterID,
            normalizedQuery: normalizeQuery(request.query),
            scope: FrozenScope(
                schemaVersion: request.scope.schemaVersion,
                mode: request.scope.documentIDs == nil ? "whole_matter" : "selected_documents",
                documentIDs: request.scope.documentIDs?.sorted()
            ),
            snapshot: canonicalSnapshot,
            slices: try frozenSlices(
                partitions: partitions,
                slices: slices
            ),
            characterBudget: request.characterBudget,
            maximumRetryCount: request.maximumRetryCount,
            modelArtifact: pinnedModel
        )
        return sha256(try canonicalData(envelope))
    }

    static func frozenCorpusLineage(
        snapshot: CorpusAnalysisSnapshot,
        partitions: [CorpusAnalysisPartitionRecord],
        slices: [CorpusAnalysisPartitionSliceRecord]
    ) throws -> String {
        let envelope = FrozenCorpusLineageEnvelope(
            snapshot: CorpusAnalysisSnapshot(
                schemaVersion: snapshot.schemaVersion,
                members: snapshot.members.sorted { $0.memberKey < $1.memberKey }
            ),
            slices: try frozenSlices(
                partitions: partitions,
                slices: slices
            )
        )
        return sha256(try canonicalData(envelope))
    }

    static func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try canonicalData(value), as: UTF8.self)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizeQuery(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func frozenSlices(
        partitions: [CorpusAnalysisPartitionRecord],
        slices: [CorpusAnalysisPartitionSliceRecord]
    ) throws -> [FrozenSlice] {
        let pairs = partitions.map { ($0.id, $0.partitionKey) }
        guard Set(pairs.map(\.0)).count == pairs.count else {
            throw CorpusAnalysisPreparationError.preparedRunMismatch("partition identity")
        }
        let partitionKeyByID = Dictionary(uniqueKeysWithValues: pairs)
        return try slices.map { slice in
            guard let partitionKey = partitionKeyByID[slice.partitionID] else {
                throw CorpusAnalysisPreparationError.preparedRunMismatch("slice partition")
            }
            return try FrozenSlice(slice, partitionKey: partitionKey)
        }.sorted(by: FrozenSlice.lessThan)
    }

    fileprivate static func decodeLocator(_ json: String) throws -> DocumentSourceLocator {
        let data = Data(json.utf8)
        if let locator = try? JSONDecoder().decode(DocumentSourceLocator.self, from: data) {
            return locator
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sourceKindValue = object["source_kind"] as? String,
              let sourceKind = DocumentSourceKind(rawValue: sourceKindValue) else {
            throw CorpusAnalysisPreparationError.preparedRunMismatch("slice locator")
        }
        return DocumentSourceLocator(
            sourceKind: sourceKind,
            pageIndex: object["page_index"] as? Int,
            pageLabel: object["page_label"] as? String,
            sheetName: object["sheet_name"] as? String,
            cellRange: object["cell_range"] as? String,
            emailPartPath: object["email_part_path"] as? String,
            charStart: object["char_start"] as? Int,
            charEnd: object["char_end"] as? Int,
            boundingBoxesJSON: object["bounding_boxes_json"] as? String
        )
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private struct FrozenScope: Codable, Sendable {
    var schemaVersion: Int
    var mode: String
    var documentIDs: [String]?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case mode
        case documentIDs = "document_ids"
    }
}

private struct FrozenSlice: Codable, Sendable {
    var partitionKey: String
    var ordinal: Int
    var memberKey: String
    var documentID: String
    var partIndex: Int
    var revisionID: String
    var charStart: Int
    var charEnd: Int
    var revisionCharCount: Int
    var textSHA256: String
    var locator: DocumentSourceLocator

    init(
        _ slice: CorpusAnalysisPartitionSliceRecord,
        partitionKey: String
    ) throws {
        self.partitionKey = partitionKey
        ordinal = slice.ordinal
        memberKey = slice.memberKey
        documentID = slice.documentID
        partIndex = slice.partIndex
        revisionID = slice.revisionID
        charStart = slice.charStart
        charEnd = slice.charEnd
        revisionCharCount = slice.revisionCharCount
        textSHA256 = slice.textSHA256
        locator = try CorpusAnalysisRequestDigest.decodeLocator(slice.locatorJSON)
    }

    static func lessThan(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.partitionKey != rhs.partitionKey { return lhs.partitionKey < rhs.partitionKey }
        if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
        if lhs.memberKey != rhs.memberKey { return lhs.memberKey < rhs.memberKey }
        if lhs.documentID != rhs.documentID { return lhs.documentID < rhs.documentID }
        if lhs.partIndex != rhs.partIndex { return lhs.partIndex < rhs.partIndex }
        if lhs.revisionID != rhs.revisionID { return lhs.revisionID < rhs.revisionID }
        if lhs.charStart != rhs.charStart { return lhs.charStart < rhs.charStart }
        if lhs.charEnd != rhs.charEnd { return lhs.charEnd < rhs.charEnd }
        return lhs.textSHA256 < rhs.textSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case partitionKey = "partition_key"
        case ordinal
        case memberKey = "member_key"
        case documentID = "document_id"
        case partIndex = "part_index"
        case revisionID = "revision_id"
        case charStart = "char_start"
        case charEnd = "char_end"
        case revisionCharCount = "revision_char_count"
        case textSHA256 = "text_sha256"
        case locator
    }
}

private struct FrozenExhaustiveRequestEnvelope: Codable, Sendable {
    var schemaVersion = 2
    var taskKind = CorpusAnalysisTaskKind.exhaustiveList.rawValue
    var taskSchemaVersion: Int
    var promptBuilderVersion: String
    var matterID: String
    var normalizedQuery: String
    var scope: FrozenScope
    var snapshot: CorpusAnalysisSnapshot
    var slices: [FrozenSlice]
    var characterBudget: Int
    var maximumRetryCount: Int
    var modelArtifact: CorpusAnalysisPinnedModel

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case taskKind = "task_kind"
        case taskSchemaVersion = "task_schema_version"
        case promptBuilderVersion = "prompt_builder_version"
        case matterID = "matter_id"
        case normalizedQuery = "normalized_query"
        case scope
        case snapshot
        case slices
        case characterBudget = "character_budget"
        case maximumRetryCount = "maximum_retry_count"
        case modelArtifact = "model_artifact"
    }
}

private struct FrozenCorpusLineageEnvelope: Codable, Sendable {
    var schemaVersion = 2
    var snapshot: CorpusAnalysisSnapshot
    var slices: [FrozenSlice]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case snapshot
        case slices
    }
}
