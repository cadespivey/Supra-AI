import Foundation
import GRDB

public enum StructureRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case documentNotFound(String)
    case revisionScopeMismatch(String)
    case nodeScopeMismatch(String)
    case duplicateNodeIdentity(String)
    case invalidRootCount(Int)
    case invalidParent(nodeID: String, parentID: String)
    case cyclicParentage(String)
    case invalidOrdinal(String)
    case invalidTextContract(String)
    case invalidRange(String)
    case edgeEndpointMissing(String)
    case edgeMatterMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .documentNotFound(let id):
            "Structure document \(id) does not exist."
        case .revisionScopeMismatch(let id):
            "Structure revision \(id) does not belong to the document."
        case .nodeScopeMismatch(let id):
            "Structure node \(id) does not belong to the replacement scope."
        case .duplicateNodeIdentity(let key):
            "Structure node identity \(key) is duplicated."
        case .invalidRootCount(let count):
            "A structure tree requires exactly one root; received \(count)."
        case .invalidParent(let nodeID, let parentID):
            "Structure node \(nodeID) has missing parent \(parentID)."
        case .cyclicParentage(let id):
            "Structure node \(id) participates in a parent cycle."
        case .invalidOrdinal(let id):
            "Structure node \(id) has a negative ordinal."
        case .invalidTextContract(let id):
            "Structure node \(id) violates the range/out-of-flow text contract."
        case .invalidRange(let id):
            "Structure node \(id) has an invalid revision character range."
        case .edgeEndpointMissing(let id):
            "Structure edge \(id) references a missing node."
        case .edgeMatterMismatch(let id):
            "Structure edge \(id) crosses matter boundaries."
        }
    }
}

/// Owns revision-bound structural trees and their matter-scoped relationships.
/// Replacement validates the complete candidate before deleting the prior tree,
/// and GRDB keeps validation/deletion/insertion in one transaction.
public final class StructureRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    private static let structuralKinds: Set<String> = [
        "document", "section", "list", "table", "table_row", "table_cell", "page",
        "sheet", "email_message",
    ]

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Replaces one revision's tree. This is the stable adapter retry boundary.
    public func replaceStructure(
        documentID: String,
        revisionID: String,
        nodes: [DocumentStructureNodeRecord],
        edges: [DocumentStructureEdgeRecord]
    ) throws {
        try writer.write { db in
            try replaceStructure(
                documentID: documentID,
                revisionID: revisionID,
                nodes: nodes,
                edges: edges,
                db: db
            )
        }
    }

    /// Replaces the complete document tree. It permits nodes bound to different
    /// selected part revisions while retaining one document root.
    public func replaceStructure(
        documentID: String,
        nodes: [DocumentStructureNodeRecord],
        edges: [DocumentStructureEdgeRecord]
    ) throws {
        try writer.write { db in
            try replaceStructure(
                documentID: documentID,
                revisionID: nil,
                nodes: nodes,
                edges: edges,
                db: db
            )
        }
    }

    public func fetchNodes(documentID: String) throws -> [DocumentStructureNodeRecord] {
        try writer.read { db in
            try DocumentStructureNodeRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM document_structure_nodes
                WHERE document_id = ?
                ORDER BY CASE WHEN parent_node_id IS NULL THEN 0 ELSE 1 END,
                         ordinal ASC, node_key ASC
                """,
                arguments: [documentID]
            )
        }
    }

    public func fetchEdges(documentID: String) throws -> [DocumentStructureEdgeRecord] {
        try writer.read { db in
            try DocumentStructureEdgeRecord.fetchAll(
                db,
                sql: """
                SELECT DISTINCT e.*
                FROM document_structure_edges e
                JOIN document_structure_nodes f ON f.id = e.from_node_id
                JOIN document_structure_nodes t ON t.id = e.to_node_id
                WHERE f.document_id = ? OR t.document_id = ?
                ORDER BY e.created_at ASC, e.rowid ASC
                """,
                arguments: [documentID, documentID]
            )
        }
    }

    /// Atomically replaces a matter-scoped family of cross-document edges.
    /// The email thread linker uses this after import/reprocess; validating every
    /// endpoint before deletion keeps a failed relink from erasing the last good graph.
    public func replaceMatterEdges(
        matterID: String,
        kinds: Set<String>,
        edges: [DocumentStructureEdgeRecord]
    ) throws {
        guard !kinds.isEmpty else { return }
        try writer.write { db in
            guard try String.fetchOne(
                db,
                sql: "SELECT id FROM matters WHERE id = ?",
                arguments: [matterID]
            ) != nil else {
                throw StructureRepositoryError.edgeMatterMismatch(matterID)
            }
            guard edges.allSatisfy({ $0.matterID == matterID && kinds.contains($0.kind) }) else {
                throw StructureRepositoryError.edgeMatterMismatch(matterID)
            }
            guard Set(edges.map(\.id)).count == edges.count else {
                throw StructureRepositoryError.duplicateNodeIdentity("edge_id")
            }
            for edge in edges {
                for endpointID in [edge.fromNodeID, edge.toNodeID] {
                    let endpointMatterID = try String.fetchOne(
                        db,
                        sql: """
                        SELECT d.matter_id
                        FROM document_structure_nodes n
                        JOIN matter_documents d ON d.id = n.document_id
                        WHERE n.id = ?
                        """,
                        arguments: [endpointID]
                    )
                    guard endpointMatterID == matterID else {
                        throw StructureRepositoryError.edgeMatterMismatch(edge.id)
                    }
                }
            }

            let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ",")
            var arguments: [DatabaseValueConvertible] = [matterID]
            arguments.append(contentsOf: kinds.sorted())
            try db.execute(
                sql: "DELETE FROM document_structure_edges WHERE matter_id = ? AND kind IN (\(placeholders))",
                arguments: StatementArguments(arguments)
            )
            for edge in edges.sorted(by: { $0.id < $1.id }) {
                try edge.insert(db)
            }
        }
    }

    public func resolveText(nodeID: String) throws -> String? {
        try writer.read { db in
            guard let node = try DocumentStructureNodeRecord.fetchOne(db, key: nodeID),
                  let revision = try DocumentPartRevisionRecord.fetchOne(db, key: node.revisionID) else {
                return nil
            }
            return try resolvedText(node: node, revisionText: revision.text)
        }
    }

    private func replaceStructure(
        documentID: String,
        revisionID: String?,
        nodes: [DocumentStructureNodeRecord],
        edges: [DocumentStructureEdgeRecord],
        db: Database
    ) throws {
        guard let document = try MatterDocumentRecord.fetchOne(db, key: documentID) else {
            throw StructureRepositoryError.documentNotFound(documentID)
        }
        guard !nodes.isEmpty else {
            throw StructureRepositoryError.invalidRootCount(0)
        }
        guard nodes.allSatisfy({ $0.documentID == documentID }) else {
            throw StructureRepositoryError.nodeScopeMismatch(documentID)
        }
        if let revisionID,
           !nodes.allSatisfy({ $0.revisionID == revisionID }) {
            throw StructureRepositoryError.revisionScopeMismatch(revisionID)
        }

        let ids = nodes.map(\.id)
        guard Set(ids).count == ids.count else {
            throw StructureRepositoryError.duplicateNodeIdentity("id")
        }
        let scopedKeys = nodes.map { "\($0.revisionID)|\($0.nodeKey)" }
        guard Set(scopedKeys).count == scopedKeys.count else {
            throw StructureRepositoryError.duplicateNodeIdentity("node_key")
        }
        let roots = nodes.filter { $0.parentNodeID == nil }
        guard roots.count == 1, roots.first?.kind == "document" else {
            throw StructureRepositoryError.invalidRootCount(roots.count)
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for node in nodes {
            guard node.ordinal >= 0 else {
                throw StructureRepositoryError.invalidOrdinal(node.id)
            }
            if let parentID = node.parentNodeID, nodesByID[parentID] == nil {
                throw StructureRepositoryError.invalidParent(nodeID: node.id, parentID: parentID)
            }
            var visited = Set<String>()
            var cursor: DocumentStructureNodeRecord? = node
            while let current = cursor, let parentID = current.parentNodeID {
                guard visited.insert(current.id).inserted else {
                    throw StructureRepositoryError.cyclicParentage(node.id)
                }
                cursor = nodesByID[parentID]
            }
        }

        var revisionTextByID: [String: String] = [:]
        for revisionID in Set(nodes.map(\.revisionID)) {
            guard let revision = try DocumentPartRevisionRecord.fetchOne(db, key: revisionID),
                  revision.documentID == documentID else {
                throw StructureRepositoryError.revisionScopeMismatch(revisionID)
            }
            revisionTextByID[revisionID] = revision.text
        }
        for node in nodes {
            guard !node.nodeKey.isEmpty, !node.kind.isEmpty else {
                throw StructureRepositoryError.invalidTextContract(node.id)
            }
            _ = try resolvedText(
                node: node,
                revisionText: revisionTextByID[node.revisionID] ?? ""
            )
        }

        let newNodeIDs = Set(nodes.map(\.id))
        for edge in edges {
            guard edge.matterID == document.matterID else {
                throw StructureRepositoryError.edgeMatterMismatch(edge.id)
            }
            guard !edge.kind.isEmpty else {
                throw StructureRepositoryError.edgeEndpointMissing(edge.id)
            }
            guard try endpointExists(
                edge.fromNodeID,
                replacementNodeIDs: newNodeIDs,
                documentID: documentID,
                revisionID: revisionID,
                db: db
            ), try endpointExists(
                edge.toNodeID,
                replacementNodeIDs: newNodeIDs,
                documentID: documentID,
                revisionID: revisionID,
                db: db
            ) else {
                throw StructureRepositoryError.edgeEndpointMissing(edge.id)
            }
            for endpointID in [edge.fromNodeID, edge.toNodeID] where !newNodeIDs.contains(endpointID) {
                guard let endpointMatterID = try String.fetchOne(
                    db,
                    sql: """
                    SELECT d.matter_id
                    FROM document_structure_nodes n
                    JOIN matter_documents d ON d.id = n.document_id
                    WHERE n.id = ?
                    """,
                    arguments: [endpointID]
                ), endpointMatterID == document.matterID else {
                    throw StructureRepositoryError.edgeMatterMismatch(edge.id)
                }
            }
        }

        if let revisionID {
            try db.execute(
                sql: "DELETE FROM document_structure_nodes WHERE document_id = ? AND revision_id = ?",
                arguments: [documentID, revisionID]
            )
        } else {
            try db.execute(
                sql: "DELETE FROM document_structure_nodes WHERE document_id = ?",
                arguments: [documentID]
            )
        }

        for node in nodes.sorted(by: { depth(of: $0, nodesByID: nodesByID) < depth(of: $1, nodesByID: nodesByID) }) {
            try node.insert(db)
        }
        for edge in edges {
            try edge.insert(db)
        }
    }

    private func endpointExists(
        _ nodeID: String,
        replacementNodeIDs: Set<String>,
        documentID: String,
        revisionID: String?,
        db: Database
    ) throws -> Bool {
        if replacementNodeIDs.contains(nodeID) { return true }
        guard let existing = try DocumentStructureNodeRecord.fetchOne(db, key: nodeID) else {
            return false
        }
        if existing.documentID != documentID { return true }
        if let revisionID { return existing.revisionID != revisionID }
        return false
    }

    private func resolvedText(
        node: DocumentStructureNodeRecord,
        revisionText: String
    ) throws -> String? {
        let hasStart = node.charStart != nil
        let hasEnd = node.charEnd != nil
        guard hasStart == hasEnd else {
            throw StructureRepositoryError.invalidRange(node.id)
        }

        let rangedText: String?
        if let start = node.charStart, let end = node.charEnd {
            guard start >= 0, start < end, end <= revisionText.count else {
                throw StructureRepositoryError.invalidRange(node.id)
            }
            let lower = revisionText.index(revisionText.startIndex, offsetBy: start)
            let upper = revisionText.index(revisionText.startIndex, offsetBy: end)
            rangedText = String(revisionText[lower..<upper])
        } else {
            rangedText = nil
        }

        let explicitText = node.textContent.flatMap { $0.isEmpty ? nil : $0 }
        if node.textContent != nil, explicitText == nil {
            throw StructureRepositoryError.invalidTextContract(node.id)
        }
        if let rangedText, let explicitText, rangedText != explicitText {
            throw StructureRepositoryError.invalidTextContract(node.id)
        }
        if rangedText == nil, explicitText == nil,
           !Self.structuralKinds.contains(node.kind) {
            throw StructureRepositoryError.invalidTextContract(node.id)
        }
        return rangedText ?? explicitText
    }

    private func depth(
        of node: DocumentStructureNodeRecord,
        nodesByID: [String: DocumentStructureNodeRecord]
    ) -> Int {
        var result = 0
        var cursor = node
        while let parentID = cursor.parentNodeID, let parent = nodesByID[parentID] {
            result += 1
            cursor = parent
        }
        return result
    }
}
