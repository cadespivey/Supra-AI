import Foundation
import SupraCore
import SupraDocuments
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

    /// Structure-aware, deterministic relation proposals for version families.
    /// The pass deliberately stops at `proposed`: confidence is evidence for a
    /// reviewer, never permission to select an operative document.
    @discardableResult
    public func proposeVersionRelations(
        matterID: String
    ) throws -> [DocumentRelationRecord] {
        let documents = try store.documentLibrary.fetchDocuments(matterID: matterID)
            .sorted { $0.id < $1.id }
            .map(analyze)
        let canonicalDocuments = Dictionary(grouping: documents, by: { $0.record.blobID })
            .values
            .compactMap { group in group.sorted(by: Self.canonicalInstanceOrder).first }
            .sorted { $0.record.id < $1.record.id }
        var proposals: [DocumentRelationRecord] = []

        for (lhs, rhs) in Self.pairs(canonicalDocuments) {
            let comparison = Self.compare(lhs, rhs)
            guard comparison.sameFamily || comparison.combinedSimilarity >= 0.55 else { continue }

            if comparison.combinedSimilarity >= 0.55,
               lhs.text != rhs.text {
                proposals.append(try propose(
                    matterID: matterID,
                    from: lhs,
                    to: rhs,
                    kind: .nearDuplicate,
                    roleSignal: "similar_content",
                    comparison: comparison,
                    confidence: comparison.combinedSimilarity
                ))
            }

            if lhs.role == .draft, rhs.role == .executed {
                proposals.append(try propose(
                    matterID: matterID,
                    from: lhs,
                    to: rhs,
                    kind: .draftOf,
                    roleSignal: "draft_to_executed",
                    comparison: comparison,
                    confidence: Self.directionalConfidence(comparison, ambiguityPenalty: false)
                ))
            } else if rhs.role == .draft, lhs.role == .executed {
                proposals.append(try propose(
                    matterID: matterID,
                    from: rhs,
                    to: lhs,
                    kind: .draftOf,
                    roleSignal: "draft_to_executed",
                    comparison: comparison,
                    confidence: Self.directionalConfidence(comparison, ambiguityPenalty: false)
                ))
            }

            if lhs.role == .redline, rhs.role == .executed {
                proposals.append(try propose(
                    matterID: matterID,
                    from: lhs,
                    to: rhs,
                    kind: .redlineOf,
                    roleSignal: "redline_to_executed",
                    comparison: comparison,
                    confidence: Self.directionalConfidence(comparison, ambiguityPenalty: false)
                ))
            } else if rhs.role == .redline, lhs.role == .executed {
                proposals.append(try propose(
                    matterID: matterID,
                    from: rhs,
                    to: lhs,
                    kind: .redlineOf,
                    roleSignal: "redline_to_executed",
                    comparison: comparison,
                    confidence: Self.directionalConfidence(comparison, ambiguityPenalty: false)
                ))
            }

            if lhs.role == .executed, rhs.role == .superseded {
                proposals.append(try propose(
                    matterID: matterID,
                    from: lhs,
                    to: rhs,
                    kind: .supersedes,
                    roleSignal: "executed_supersedes_prior",
                    comparison: comparison,
                    confidence: Self.directionalConfidence(comparison, ambiguityPenalty: false)
                ))
            } else if rhs.role == .executed, lhs.role == .superseded {
                proposals.append(try propose(
                    matterID: matterID,
                    from: rhs,
                    to: lhs,
                    kind: .supersedes,
                    roleSignal: "executed_supersedes_prior",
                    comparison: comparison,
                    confidence: Self.directionalConfidence(comparison, ambiguityPenalty: false)
                ))
            }
        }

        let families = Dictionary(grouping: canonicalDocuments.compactMap { document in
            document.familyKey.map { ($0, document) }
        }, by: \.0)
        for familyKey in families.keys.sorted() {
            let family = families[familyKey, default: []].map(\.1)
            let bases = family.filter { $0.role == .executed }.sorted(by: Self.versionOrder)
            guard var predecessor = bases.last else { continue }
            let amendments = family.filter { $0.role == .amendment }
                .sorted(by: Self.amendmentOrder)
            for amendment in amendments {
                let comparison = Self.compare(amendment, predecessor)
                let ambiguous = amendment.metadataDate == nil || predecessor.metadataDate == nil
                proposals.append(try propose(
                    matterID: matterID,
                    from: amendment,
                    to: predecessor,
                    kind: .amendmentOf,
                    roleSignal: "amendment_chain",
                    comparison: comparison,
                    confidence: Self.directionalConfidence(comparison, ambiguityPenalty: ambiguous)
                ))
                predecessor = amendment
            }
        }

        return proposals.sorted {
            ($0.relationKey, $0.kind, $0.id) < ($1.relationKey, $1.kind, $1.id)
        }
    }

    private func analyze(_ document: MatterDocumentRecord) throws -> AnalyzedDocument {
        let chunks = try store.documentIndex.fetchChunks(documentID: document.id)
        let text = chunks.sorted { lhs, rhs in
            lhs.chunkIndex < rhs.chunkIndex
                || (lhs.chunkIndex == rhs.chunkIndex && lhs.id < rhs.id)
        }.map(\.normalizedText).joined(separator: "\n\n")
        let records = try store.documentStructure.fetchNodes(documentID: document.id)
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var revisionTextByID: [String: String] = [:]
        for revisionID in Set(records.map(\.revisionID)) {
            guard let revision = try store.documentRevisions.fetchRevision(id: revisionID) else {
                throw StructureRepositoryError.revisionScopeMismatch(revisionID)
            }
            revisionTextByID[revisionID] = revision.text
        }
        let nodes = try records.compactMap { record -> StructuralDiffNode? in
            guard let kind = DocumentStructureNodeKind(rawValue: record.kind) else { return nil }
            let text = try Self.resolvedText(
                record,
                revisionText: revisionTextByID[record.revisionID, default: ""]
            )
            return StructuralDiffNode(
                nodeID: record.id,
                nodeKey: record.nodeKey,
                parentNodeKey: record.parentNodeID.flatMap { recordsByID[$0]?.nodeKey },
                ordinal: record.ordinal,
                kind: kind,
                text: text
            )
        }
        let role = Self.role(displayName: document.displayName, text: text)
        return AnalyzedDocument(
            record: document,
            text: text,
            nodes: nodes,
            familyKey: Self.familyKey(text: text),
            role: role.kind,
            amendmentOrdinal: role.amendmentOrdinal,
            metadataDate: document.metadataModifiedAt ?? document.metadataCreatedAt
        )
    }

    private func propose(
        matterID: String,
        from: AnalyzedDocument,
        to: AnalyzedDocument,
        kind: DocumentRelationKind,
        roleSignal: String,
        comparison _: RelationComparison,
        confidence: Double
    ) throws -> DocumentRelationRecord {
        let comparison = Self.compare(from, to)
        var evidence: [String: Any] = [
            "algorithm": "structural_relation_v1",
            "changed_units": comparison.diff.changed.count,
            "combined_similarity": comparison.combinedSimilarity,
            "date_order": Self.dateOrder(from.metadataDate, to.metadataDate),
            "deleted_units": comparison.diff.deleted.count,
            "from_role": from.role.rawValue,
            "inserted_units": comparison.diff.inserted.count,
            "relation_kind": kind.rawValue,
            "role_signal": roleSignal,
            "schema_version": 1,
            "structure_similarity": comparison.structureSimilarity,
            "text_shingle_size": 3,
            "text_similarity": comparison.textSimilarity,
            "to_role": to.role.rawValue,
        ]
        if let familyKey = comparison.familyKey { evidence["family_key"] = familyKey }
        if let date = from.metadataDate { evidence["from_metadata_date"] = Self.timestamp(date) }
        if let date = to.metadataDate { evidence["to_metadata_date"] = Self.timestamp(date) }
        return try store.documentRelations.propose(
            matterID: matterID,
            fromDocumentID: from.record.id,
            toDocumentID: to.record.id,
            kind: kind,
            evidenceJSON: try Self.canonicalEvidence(evidence),
            confidence: confidence,
            proposedBy: .system
        )
    }

    private enum VersionRole: String {
        case neutral
        case draft
        case executed
        case amendment
        case redline
        case superseded
    }

    private struct AnalyzedDocument {
        var record: MatterDocumentRecord
        var text: String
        var nodes: [StructuralDiffNode]
        var familyKey: String?
        var role: VersionRole
        var amendmentOrdinal: Int?
        var metadataDate: Date?
    }

    private struct RelationComparison {
        var textSimilarity: Double
        var structureSimilarity: Double
        var combinedSimilarity: Double
        var diff: StructuralDiffResult
        var sameFamily: Bool
        var familyKey: String?
    }

    private static func compare(
        _ lhs: AnalyzedDocument,
        _ rhs: AnalyzedDocument
    ) -> RelationComparison {
        let textSimilarity = jaccard(shingles(normalizedTokens(lhs.text), size: 3),
                                     shingles(normalizedTokens(rhs.text), size: 3))
        let diff = StructuralDiff.compare(before: lhs.nodes, after: rhs.nodes)
        let unitCount = max(
            lhs.nodes.filter { $0.kind != .document }.count,
            rhs.nodes.filter { $0.kind != .document }.count
        )
        let structureSimilarity = unitCount == 0
            ? 0
            : max(0, 1 - Double(diff.changes.count) / Double(unitCount))
        let combined = round6((textSimilarity * 0.75) + (structureSimilarity * 0.25))
        let familyKey = lhs.familyKey == rhs.familyKey ? lhs.familyKey : nil
        return RelationComparison(
            textSimilarity: round6(textSimilarity),
            structureSimilarity: round6(structureSimilarity),
            combinedSimilarity: combined,
            diff: diff,
            sameFamily: familyKey != nil,
            familyKey: familyKey
        )
    }

    private static func resolvedText(
        _ node: DocumentStructureNodeRecord,
        revisionText: String
    ) throws -> String? {
        guard (node.charStart == nil) == (node.charEnd == nil) else {
            throw StructureRepositoryError.invalidRange(node.id)
        }
        var rangedText: String?
        if let start = node.charStart, let end = node.charEnd {
            guard start >= 0, start < end, end <= revisionText.count else {
                throw StructureRepositoryError.invalidRange(node.id)
            }
            let lower = revisionText.index(revisionText.startIndex, offsetBy: start)
            let upper = revisionText.index(revisionText.startIndex, offsetBy: end)
            rangedText = String(revisionText[lower..<upper])
        }
        let explicitText = node.textContent.flatMap { $0.isEmpty ? nil : $0 }
        if node.textContent != nil, explicitText == nil {
            throw StructureRepositoryError.invalidTextContract(node.id)
        }
        if let rangedText, let explicitText, rangedText != explicitText {
            throw StructureRepositoryError.invalidTextContract(node.id)
        }
        return rangedText ?? explicitText
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        text.lowercased().split { character in
            !character.isLetter && !character.isNumber
        }.map(String.init)
    }

    private static func shingles(_ tokens: [String], size: Int) -> Set<String> {
        guard !tokens.isEmpty else { return [] }
        guard tokens.count >= size else { return [tokens.joined(separator: " ")] }
        return Set((0...(tokens.count - size)).map { index in
            tokens[index..<(index + size)].joined(separator: " ")
        })
    }

    private static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }

    private static func role(
        displayName: String,
        text: String
    ) -> (kind: VersionRole, amendmentOrdinal: Int?) {
        let filename = displayName.lowercased()
        if let role = explicitRole(in: filename) { return role }
        return explicitRole(in: String(text.prefix(400)).lowercased()) ?? (.neutral, nil)
    }

    private static func explicitRole(
        in probe: String
    ) -> (kind: VersionRole, amendmentOrdinal: Int?)? {
        if probe.contains("amendment") {
            return (.amendment, firstInteger(after: "amendment", in: probe))
        }
        if probe.contains("redline") { return (.redline, nil) }
        if probe.contains("draft") { return (.draft, nil) }
        if probe.contains("superseded") { return (.superseded, nil) }
        if probe.contains("executed") || probe.contains("signed") { return (.executed, nil) }
        return nil
    }

    private static func firstInteger(after marker: String, in text: String) -> Int? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let suffix = text[markerRange.upperBound...]
            .drop { !$0.isNumber }
            .prefix { $0.isNumber }
        return Int(suffix)
    }

    private static func familyKey(text: String) -> String? {
        let pattern = #"(?i)control\s+no\.?\s*[:#-]?\s*([a-z0-9-]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        var value = String(text[range]).lowercased()
        for suffixPattern in [#"-draft$"#, #"-redline$"#, #"-a[0-9]+$"#, #"-s[0-9]+$"#] {
            value = value.replacingOccurrences(
                of: suffixPattern,
                with: "",
                options: .regularExpression
            )
        }
        return value
    }

    private static func dateOrder(_ lhs: Date?, _ rhs: Date?) -> String {
        guard let lhs, let rhs else { return "ambiguous_missing_date" }
        if lhs < rhs { return "from_before_to" }
        if lhs > rhs { return "from_after_to" }
        return "same_date"
    }

    private static func directionalConfidence(
        _ comparison: RelationComparison,
        ambiguityPenalty: Bool
    ) -> Double {
        if ambiguityPenalty {
            return round6(min(0.69, 0.45 + comparison.combinedSimilarity * 0.25))
        }
        return round6(min(0.95, 0.55 + comparison.combinedSimilarity * 0.4))
    }

    private static func versionOrder(_ lhs: AnalyzedDocument, _ rhs: AnalyzedDocument) -> Bool {
        switch (lhs.metadataDate, rhs.metadataDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.record.id < rhs.record.id
        }
    }

    private static func amendmentOrder(_ lhs: AnalyzedDocument, _ rhs: AnalyzedDocument) -> Bool {
        switch (lhs.metadataDate, rhs.metadataDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        switch (lhs.amendmentOrdinal, rhs.amendmentOrdinal) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.record.id < rhs.record.id
        }
    }

    private static func canonicalInstanceOrder(
        _ lhs: AnalyzedDocument,
        _ rhs: AnalyzedDocument
    ) -> Bool {
        let lhsCopy = lhs.record.displayName.lowercased().contains("copy")
        let rhsCopy = rhs.record.displayName.lowercased().contains("copy")
        if lhsCopy != rhsCopy { return !lhsCopy }
        if lhs.record.displayName.count != rhs.record.displayName.count {
            return lhs.record.displayName.count < rhs.record.displayName.count
        }
        return (lhs.record.displayName, lhs.record.id) < (rhs.record.displayName, rhs.record.id)
    }

    private static func round6(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
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
