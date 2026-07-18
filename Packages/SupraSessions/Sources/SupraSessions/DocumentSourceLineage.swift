import CryptoKit
import Foundation
import SupraCore
import SupraDocuments
import SupraStore

/// The exact retrieval/packing knobs used to form a source set. Fields that do
/// not apply to a deterministic chronology or exhaustive task remain nil rather
/// than being assigned a fabricated retrieval value.
struct DocumentRetrievalConfiguration: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var mode: String
    var depth: String?
    var candidateLimit: Int?
    var packedLimit: Int?
    var maxPerDocument: Int?
    var semanticFloor: Double?
    var rrfK: Double?
    var characterBudget: Int?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case mode
        case depth
        case candidateLimit = "candidate_limit"
        case packedLimit = "packed_limit"
        case maxPerDocument = "max_per_document"
        case semanticFloor = "semantic_floor"
        case rrfK = "rrf_k"
        case characterBudget = "character_budget"
    }
}

struct DocumentSourceLineage: Sendable, Equatable {
    var packingReportJSON: String
    var embeddingModelID: String
    var embeddingModelRevision: String
    var chunkerVersion: Int
    var retrievalConfigJSON: String
    var corpusSnapshotHash: String
}

enum DocumentSourceLineageBuilder {
    struct Candidate: Sendable {
        var sourceID: String
        var label: String
        var rank: Int
        var originalText: String
        var packedText: String
    }

    private struct SnapshotMember: Codable {
        var documentID: String
        var revisionIDs: [String]
        var indexStatus: String

        private enum CodingKeys: String, CodingKey {
            case documentID = "document_id"
            case revisionIDs = "revision_ids"
            case indexStatus = "index_status"
        }
    }

    static func report(
        summary: TokenPackingReport?,
        candidates: [Candidate]
    ) -> DocumentPackingReport {
        let cumulativeCounts = summary?.cumulativeInputTokenCounts ?? []
        var previousCumulativeCount = 0
        let rows = candidates.enumerated().map { index, candidate in
            let fallbackOriginal = TokenBudgeter.fallbackTokenCount(candidate.originalText)
            let fallbackPacked = TokenBudgeter.fallbackTokenCount(candidate.packedText)
            let cumulativeContribution: Int? = if cumulativeCounts.indices.contains(index) {
                max(0, cumulativeCounts[index] - previousCumulativeCount)
            } else {
                nil
            }
            if cumulativeCounts.indices.contains(index) {
                previousCumulativeCount = cumulativeCounts[index]
            }

            let isPacked = index < (summary?.packedItemCount ?? candidates.count)
            let wasTruncated = candidate.originalText != candidate.packedText
            let disposition: DocumentPackingDisposition
            let reason: String
            if isPacked, wasTruncated {
                disposition = .truncated
                reason = "per_source_character_limit"
            } else if isPacked {
                disposition = .packed
                reason = "within_context_budget"
            } else if summary?.overflowRetryCount ?? 0 > 0,
                      index == summary?.packedItemCount {
                disposition = .deferred
                reason = "context_overflow_retry"
            } else {
                disposition = .omitted
                reason = summary?.omissionReason ?? "not_selected_for_packet"
            }
            return DocumentPackingCandidate(
                sourceID: candidate.sourceID,
                label: candidate.label,
                rank: candidate.rank,
                disposition: disposition,
                reason: reason,
                originalTokenCount: max(fallbackOriginal, cumulativeContribution ?? 0),
                packedTokenCount: isPacked ? max(fallbackPacked, cumulativeContribution ?? 0) : 0
            )
        }
        return DocumentPackingReport(
            countMethod: summary?.countMethod ?? .conservativeFallback,
            availableInputTokens: summary?.availableInputTokens
                ?? rows.reduce(0) { $0 + $1.packedTokenCount },
            selectedInputTokens: summary?.selectedInputTokens
                ?? rows.reduce(0) { $0 + $1.packedTokenCount },
            overflowRetryCount: summary?.overflowRetryCount ?? 0,
            candidates: rows
        )
    }

    static func make(
        store: SupraStore,
        matterID: String,
        scope: RetrievalScope,
        configuration: DocumentRetrievalConfiguration,
        packingReport: DocumentPackingReport
    ) throws -> DocumentSourceLineage {
        let settings = try store.documentSettings.loadSettings()
        let embedding = try store.documentSettings.fetchSelectedEmbeddingModel()
        let modelID = embedding?.repoID ?? "none"
        let modelRevision = embedding?.revision ?? (embedding == nil ? "not_applicable" : "unresolved")
        let documentIDs = try store.documentLibrary.resolveScopeDocumentIDs(
            matterID: matterID,
            folderIDs: scope.folderIDs,
            documentIDs: scope.documentIDs,
            tagIDs: scope.tagIDs,
            dateStart: scope.dateStart,
            dateEnd: scope.dateEnd
        ).sorted()
        let documents = Dictionary(
            uniqueKeysWithValues: try store.documentLibrary.fetchDocuments(matterID: matterID)
                .map { ($0.id, $0) }
        )
        let members = try documentIDs.map { documentID in
            let revisions = Set(
                try store.documentIndex.fetchChunks(documentID: documentID).compactMap(\.revisionID)
            ).sorted()
            return SnapshotMember(
                documentID: documentID,
                revisionIDs: revisions,
                indexStatus: documents[documentID]?.indexStatus ?? "missing"
            )
        }
        let snapshotData = try canonicalData(members)
        let snapshotHash = SHA256.hash(data: snapshotData).map { String(format: "%02x", $0) }.joined()
        return DocumentSourceLineage(
            packingReportJSON: try packingReport.canonicalJSON(),
            embeddingModelID: modelID,
            embeddingModelRevision: modelRevision,
            chunkerVersion: settings.chunkerVersion,
            retrievalConfigJSON: String(decoding: try canonicalData(configuration), as: UTF8.self),
            corpusSnapshotHash: snapshotHash
        )
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
