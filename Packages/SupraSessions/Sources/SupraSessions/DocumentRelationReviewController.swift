import Combine
import Foundation
import SupraCore
import SupraStore

public struct DocumentRelationReviewItem: Identifiable, Sendable, Equatable {
    public var id: String { relation.id }
    public var relation: DocumentRelationRecord
    public var fromDocumentName: String
    public var toDocumentName: String
    public var evidenceSummary: String
    public var diffSummary: String

    public var kind: DocumentRelationKind? { DocumentRelationKind(rawValue: relation.kind) }
    public var reviewState: DocumentRelationReviewState? {
        DocumentRelationReviewState(rawValue: relation.reviewState)
    }
}

/// View-facing relation review workflow. Repository methods remain the authority
/// for immutable identity/evidence, one-way state transitions, audit events, and
/// output invalidation; this controller only coordinates explicit user actions.
@MainActor
public final class DocumentRelationReviewController: ObservableObject {
    @Published public private(set) var items: [DocumentRelationReviewItem] = []
    @Published public private(set) var auditConfirmation: String?
    @Published public private(set) var errorMessage: String?

    public let matterID: String
    private let store: SupraStore

    public init(matterID: String, store: SupraStore) {
        self.matterID = matterID
        self.store = store
        reload()
    }

    public var pendingReviewCount: Int {
        items.count { $0.reviewState == .proposed }
    }

    public func reload() {
        do {
            let relations = try store.documentRelations.fetchAll(matterID: matterID)
            let documents = try store.documentLibrary.fetchDocuments(matterID: matterID)
            let names = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.displayName) })
            items = relations.map { relation in
                let evidence = Self.evidenceObject(relation.evidenceJSON)
                return DocumentRelationReviewItem(
                    relation: relation,
                    fromDocumentName: names[relation.fromDocumentID] ?? "Document",
                    toDocumentName: names[relation.toDocumentID] ?? "Document",
                    evidenceSummary: Self.evidenceSummary(relation: relation, evidence: evidence),
                    diffSummary: Self.diffSummary(evidence)
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func confirm(
        relationID: String,
        actor: String = "Local user"
    ) throws -> DocumentRelationRecord {
        try review(relationID: relationID, decision: .confirmed, actor: actor)
    }

    @discardableResult
    public func reject(
        relationID: String,
        actor: String = "Local user"
    ) throws -> DocumentRelationRecord {
        try review(relationID: relationID, decision: .rejected, actor: actor)
    }

    /// Replaces a rejected proposal with a distinct user-authored row and then
    /// confirms that row through the same audited review transition. When invoked
    /// directly from the UI on a proposed row, the original rejection is explicit
    /// in the audit trail before the override is created.
    @discardableResult
    public func createAndConfirmOverride(
        replacingRelationID: String,
        fromDocumentID: String,
        toDocumentID: String,
        kind: DocumentRelationKind,
        evidenceJSON: String,
        actor: String = "Local user"
    ) throws -> DocumentRelationRecord {
        do {
            guard let existing = try store.documentRelations.fetch(
                matterID: matterID,
                id: replacingRelationID
            ) else {
                throw DocumentRelationRepositoryError.relationNotFound(replacingRelationID)
            }
            if existing.reviewState == DocumentRelationReviewState.proposed.rawValue {
                _ = try store.documentRelations.review(
                    matterID: matterID,
                    id: replacingRelationID,
                    decision: .rejected,
                    reviewedBy: actor
                )
            }
            let override = try store.documentRelations.proposeUserOverride(
                matterID: matterID,
                replacingRelationID: replacingRelationID,
                fromDocumentID: fromDocumentID,
                toDocumentID: toDocumentID,
                kind: kind,
                evidenceJSON: evidenceJSON,
                actor: actor
            )
            let confirmed = try store.documentRelations.review(
                matterID: matterID,
                id: override.id,
                decision: .confirmed,
                reviewedBy: actor
            )
            auditConfirmation = "Override confirmed and recorded for \(actor)."
            errorMessage = nil
            reload()
            return confirmed
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    private func review(
        relationID: String,
        decision: DocumentRelationReviewState,
        actor: String
    ) throws -> DocumentRelationRecord {
        do {
            let reviewed = try store.documentRelations.review(
                matterID: matterID,
                id: relationID,
                decision: decision,
                reviewedBy: actor
            )
            auditConfirmation = "\(decision == .confirmed ? "Confirmation" : "Rejection") recorded for \(actor)."
            errorMessage = nil
            reload()
            return reviewed
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private static func evidenceObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func evidenceSummary(
        relation: DocumentRelationRecord,
        evidence: [String: Any]
    ) -> String {
        var parts: [String] = []
        if let signal = evidence["role_signal"] as? String ?? evidence["basis"] as? String {
            parts.append(signal.replacingOccurrences(of: "_", with: " "))
        }
        if let similarity = evidence["combined_similarity"] as? Double {
            parts.append("\(Int((similarity * 100).rounded()))% combined similarity")
        } else if let confidence = relation.confidence {
            parts.append("\(Int((confidence * 100).rounded()))% confidence")
        }
        return parts.isEmpty ? "Recorded relation evidence" : parts.joined(separator: " · ")
    }

    private static func diffSummary(_ evidence: [String: Any]) -> String {
        let changed = evidence["changed_units"] as? Int ?? 0
        let inserted = evidence["inserted_units"] as? Int ?? 0
        let deleted = evidence["deleted_units"] as? Int ?? 0
        if changed == 0, inserted == 0, deleted == 0 {
            return "No structural unit changes recorded"
        }
        return "\(changed) changed · \(inserted) inserted · \(deleted) deleted units"
    }
}

/// Shared pure policy used by retrieval, corpus assurance, and the deterministic
/// benchmark so all three surfaces agree about confirmed operative flags and
/// proposed-relation blockers.
public enum DocumentRelationDownstreamPolicy {
    public static func unreviewedReasons(
        relations: [DocumentRelationRecord],
        documents: [MatterDocumentRecord],
        inScopeDocumentIDs: Set<String>
    ) -> [String] {
        let names = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.displayName) })
        return relations
            .filter { relation in
                relation.reviewState == DocumentRelationReviewState.proposed.rawValue
                    && inScopeDocumentIDs.contains(relation.fromDocumentID)
                    && inScopeDocumentIDs.contains(relation.toDocumentID)
            }
            .map { relation in
                let from = names[relation.fromDocumentID] ?? relation.fromDocumentID
                let to = names[relation.toDocumentID] ?? relation.toDocumentID
                return "An unreviewed relation \(relation.id) (\(relation.kind)) between \(from) and \(to) blocks a clean version-sensitive result."
            }
            .sorted()
    }

    public static func confirmedMetadataByDocumentID(
        relations: [DocumentRelationRecord]
    ) -> [String: String] {
        var values: [String: Set<String>] = [:]
        for relation in relations where relation.reviewState == DocumentRelationReviewState.confirmed.rawValue {
            guard let kind = DocumentRelationKind(rawValue: relation.kind) else { continue }
            switch kind {
            case .draftOf:
                values[relation.fromDocumentID, default: []].insert("Version state: draft (confirmed)")
                values[relation.toDocumentID, default: []].insert("Version state: operative (confirmed)")
            case .executedCopyOf:
                values[relation.fromDocumentID, default: []].insert("Version state: operative (confirmed)")
                values[relation.toDocumentID, default: []].insert("Version state: operative (confirmed)")
            case .redlineOf:
                values[relation.fromDocumentID, default: []].insert("Version state: redline (confirmed)")
                values[relation.toDocumentID, default: []].insert("Version state: comparison baseline (confirmed)")
            case .supersedes:
                values[relation.fromDocumentID, default: []].insert("Version state: operative (confirmed)")
                values[relation.toDocumentID, default: []].insert("Version state: superseded (confirmed)")
            case .amendmentOf:
                values[relation.fromDocumentID, default: []].insert("Version state: operative amendment (confirmed)")
                values[relation.toDocumentID, default: []].insert("Version state: operative base (confirmed)")
            case .exactDuplicate, .normalizedDuplicate, .renderVariant, .nearDuplicate,
                 .exhibitOf, .attachmentOf:
                break
            }
        }
        return values.mapValues { $0.sorted().joined(separator: " · ") }
    }

    public static func requiresReviewedRelations(for taskKind: CorpusAnalysisTaskKind) -> Bool {
        taskKind == .comparison || taskKind == .negativeCheck
    }
}
