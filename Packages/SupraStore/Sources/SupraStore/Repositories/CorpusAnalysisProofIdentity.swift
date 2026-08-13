import CryptoKit
import Foundation
import GRDB
import SupraCore

/// Store-owned reconstruction of the corpus-only proof identity used by exact
/// execution. Keeping this derivation at the persistence boundary prevents a
/// caller from binding an otherwise valid run to a foreign source set.
enum CorpusAnalysisProofIdentity {
    static func frozenCorpusLineageHash(
        db: Database,
        runID: String
    ) throws -> String? {
        guard let run = try CorpusAnalysisRunRecord.fetchOne(db, key: runID),
              let snapshot = try? JSONDecoder().decode(
                  CorpusAnalysisSnapshot.self,
                  from: Data(run.corpusSnapshotJSON.utf8)
              ) else {
            return nil
        }
        let partitions = try CorpusAnalysisPartitionRecord.fetchAll(
            db,
            sql: "SELECT * FROM corpus_analysis_partitions WHERE run_id = ?",
            arguments: [runID]
        )
        let partitionPairs = partitions.map { ($0.id, $0.partitionKey) }
        guard Set(partitionPairs.map(\.0)).count == partitionPairs.count else {
            return nil
        }
        let partitionKeyByID = Dictionary(uniqueKeysWithValues: partitionPairs)
        let records = try CorpusAnalysisPartitionSliceRecord.fetchAll(
            db,
            sql: "SELECT * FROM corpus_analysis_partition_slices WHERE run_id = ?",
            arguments: [runID]
        )
        var slices: [FrozenSlice] = []
        slices.reserveCapacity(records.count)
        for record in records {
            guard let partitionKey = partitionKeyByID[record.partitionID],
                  let locator = decodeLocator(record.locatorJSON) else {
                return nil
            }
            slices.append(FrozenSlice(
                partitionKey: partitionKey,
                ordinal: record.ordinal,
                memberKey: record.memberKey,
                documentID: record.documentID,
                partIndex: record.partIndex,
                revisionID: record.revisionID,
                charStart: record.charStart,
                charEnd: record.charEnd,
                revisionCharCount: record.revisionCharCount,
                textSHA256: record.textSHA256,
                locator: locator
            ))
        }
        let envelope = FrozenCorpusLineageEnvelope(
            snapshot: CorpusAnalysisSnapshot(
                schemaVersion: snapshot.schemaVersion,
                members: snapshot.members.sorted { $0.memberKey < $1.memberKey }
            ),
            slices: slices.sorted(by: FrozenSlice.lessThan)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sourceSetMatchesFrozenCorpus(
        _ sourceSet: DocumentSourceSetRecord,
        run: CorpusAnalysisRunRecord,
        db: Database
    ) throws -> Bool {
        guard let expected = try frozenCorpusLineageHash(db: db, runID: run.id) else {
            return false
        }
        return sourceSet.matterID == run.matterID
            && sourceSet.mode == DocumentSourceSetMode.exhaustive.rawValue
            && sourceSet.corpusSnapshotHash == expected
    }

    static func attachedSourceSetMatchesFrozenCorpus(
        versionID: String,
        run: CorpusAnalysisRunRecord,
        db: Database
    ) throws -> Bool {
        let sourceSets = try DocumentSourceSetRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM document_source_sets
                WHERE structured_output_version_id = ?
                ORDER BY id
                """,
            arguments: [versionID]
        )
        guard sourceSets.count == 1 else { return false }
        return try sourceSetMatchesFrozenCorpus(sourceSets[0], run: run, db: db)
    }

    private static func decodeLocator(_ json: String) -> FrozenLocator? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let locator = object as? [String: Any] else {
            return nil
        }
        let hasCamel = locator["sourceKind"] != nil
        let hasSnake = locator["source_kind"] != nil
        guard hasCamel != hasSnake else { return nil }
        let key: (String, String) -> String = { camel, snake in hasCamel ? camel : snake }
        guard let sourceKindRaw = locator[key("sourceKind", "source_kind")] as? String,
              let sourceKind = DocumentSourceKind(rawValue: sourceKindRaw) else {
            return nil
        }
        return FrozenLocator(
            sourceKind: sourceKind,
            pageIndex: locator[key("pageIndex", "page_index")] as? Int,
            pageLabel: locator[key("pageLabel", "page_label")] as? String,
            sheetName: locator[key("sheetName", "sheet_name")] as? String,
            cellRange: locator[key("cellRange", "cell_range")] as? String,
            emailPartPath: locator[key("emailPartPath", "email_part_path")] as? String,
            charStart: locator[key("charStart", "char_start")] as? Int,
            charEnd: locator[key("charEnd", "char_end")] as? Int,
            boundingBoxesJSON: locator[key("boundingBoxesJSON", "bounding_boxes_json")] as? String
        )
    }
}

private struct FrozenLocator: Codable, Sendable {
    var sourceKind: DocumentSourceKind
    var pageIndex: Int?
    var pageLabel: String?
    var sheetName: String?
    var cellRange: String?
    var emailPartPath: String?
    var charStart: Int?
    var charEnd: Int?
    var boundingBoxesJSON: String?
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
    var locator: FrozenLocator

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
