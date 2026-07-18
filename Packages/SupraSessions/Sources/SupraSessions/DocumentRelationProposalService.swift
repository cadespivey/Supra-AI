import Foundation
import SupraCore
import SupraStore

/// Deterministic M7-W1 proposal pass. Exact bytes and complete normalized text
/// can create reviewable relations, but neither signal can confirm one.
public final class DocumentRelationProposalService: @unchecked Sendable {
    private let store: SupraStore

    public init(store: SupraStore) {
        self.store = store
    }

    @discardableResult
    public func proposeExactAndNormalizedDuplicates(
        matterID: String
    ) throws -> [DocumentRelationRecord] {
        let documents = try store.documentLibrary.fetchDocuments(matterID: matterID)
            .sorted { $0.id < $1.id }
        var proposals: [DocumentRelationRecord] = []

        let exactGroups = Dictionary(grouping: documents, by: \.blobID)
        for blobID in exactGroups.keys.sorted() {
            let group = exactGroups[blobID, default: []].sorted { $0.id < $1.id }
            let evidence = try Self.canonicalEvidence([
                "basis": "shared_blob",
                "blob_id": blobID,
                "schema_version": 1,
            ])
            for (from, to) in Self.pairs(group) {
                proposals.append(try store.documentRelations.propose(
                    matterID: matterID,
                    fromDocumentID: from.id,
                    toDocumentID: to.id,
                    kind: .exactDuplicate,
                    evidenceJSON: evidence,
                    confidence: 1,
                    proposedBy: .system
                ))
            }
        }

        var normalizedGroups: [String: [MatterDocumentRecord]] = [:]
        for document in documents {
            let chunks = try store.documentIndex.fetchChunks(documentID: document.id)
            let fullText = chunks.sorted { lhs, rhs in
                lhs.chunkIndex < rhs.chunkIndex
                    || (lhs.chunkIndex == rhs.chunkIndex && lhs.id < rhs.id)
            }.map(\.normalizedText).joined(separator: "\n\n")
            guard !fullText.isEmpty else { continue }
            normalizedGroups[DocumentStorageDigest.key(fullText), default: []].append(document)
        }
        for digest in normalizedGroups.keys.sorted() {
            let group = normalizedGroups[digest, default: []].sorted { $0.id < $1.id }
            let evidence = try Self.canonicalEvidence([
                "basis": "normalized_text_digest",
                "digest": digest,
                "schema_version": 1,
            ])
            for (from, to) in Self.pairs(group) where from.blobID != to.blobID {
                proposals.append(try store.documentRelations.propose(
                    matterID: matterID,
                    fromDocumentID: from.id,
                    toDocumentID: to.id,
                    kind: .normalizedDuplicate,
                    evidenceJSON: evidence,
                    confidence: 1,
                    proposedBy: .system
                ))
            }
        }

        return proposals.sorted {
            ($0.relationKey, $0.kind, $0.id) < ($1.relationKey, $1.kind, $1.id)
        }
    }

    private static func canonicalEvidence(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static func pairs<T>(_ values: [T]) -> [(T, T)] {
        guard values.count > 1 else { return [] }
        return values.indices.flatMap { firstIndex in
            values.indices.compactMap { secondIndex in
                guard secondIndex > firstIndex else { return nil }
                return (values[firstIndex], values[secondIndex])
            }
        }
    }
}
