import Foundation
import SupraDocuments
import SupraStore

/// Rebuilds RFC reply/thread relationships from persisted email-message nodes.
/// Message IDs are resolved only inside the supplied matter; duplicate IDs are
/// treated as ambiguous and never linked automatically.
public final class DocumentEmailThreadLinker: @unchecked Sendable {
    private let store: SupraStore

    public init(store: SupraStore) {
        self.store = store
    }

    @discardableResult
    public func relink(matterID: String) throws -> Int {
        var messages: [MessageNode] = []
        for document in try store.documentLibrary.fetchDocuments(matterID: matterID) {
            for node in try store.documentStructure.fetchNodes(documentID: document.id)
                where node.kind == "email_message" {
                guard let payload = node.payloadJSON,
                      let decoded = try? JSONDecoder().decode(
                          MessagePayload.self,
                          from: Data(payload.utf8)
                      ) else { continue }
                messages.append(MessageNode(
                    nodeID: node.id,
                    documentID: document.id,
                    messageID: Self.normalized(decoded.messageID),
                    inReplyTo: Self.normalized(decoded.inReplyTo),
                    references: decoded.references.compactMap(Self.normalized)
                ))
            }
        }
        messages.sort {
            $0.documentID == $1.documentID ? $0.nodeID < $1.nodeID : $0.documentID < $1.documentID
        }

        let grouped = Dictionary(grouping: messages.compactMap { message in
            message.messageID.map { ($0, message) }
        }, by: \.0)
        let uniqueByMessageID: [String: MessageNode] = Dictionary(
            uniqueKeysWithValues: grouped.compactMap { identifier, entries in
                guard entries.count == 1, let message = entries.first?.1 else { return nil }
                return (identifier, message)
            }
        )

        var records: [DocumentStructureEdgeRecord] = []
        var identities = Set<String>()
        for message in messages {
            guard let directIdentifier = message.inReplyTo,
                  let parent = uniqueByMessageID[directIdentifier],
                  parent.nodeID != message.nodeID else { continue }
            appendEdge(
                from: message.nodeID,
                to: parent.nodeID,
                kind: "in_reply_to",
                matterID: matterID,
                identities: &identities,
                records: &records
            )

            let root = threadRoot(
                for: message,
                directParent: parent,
                uniqueByMessageID: uniqueByMessageID
            )
            if root.nodeID != message.nodeID {
                appendEdge(
                    from: message.nodeID,
                    to: root.nodeID,
                    kind: "thread_member",
                    matterID: matterID,
                    identities: &identities,
                    records: &records
                )
            }
        }

        try store.documentStructure.replaceMatterEdges(
            matterID: matterID,
            kinds: ["in_reply_to", "thread_member"],
            edges: records
        )
        return records.count
    }

    private func threadRoot(
        for message: MessageNode,
        directParent: MessageNode,
        uniqueByMessageID: [String: MessageNode]
    ) -> MessageNode {
        for identifier in message.references {
            if let referenced = uniqueByMessageID[identifier] { return referenced }
        }

        var root = directParent
        var visited = Set([message.nodeID])
        while visited.insert(root.nodeID).inserted,
              let parentID = root.inReplyTo,
              let parent = uniqueByMessageID[parentID] {
            root = parent
        }
        return root
    }

    private func appendEdge(
        from: String,
        to: String,
        kind: String,
        matterID: String,
        identities: inout Set<String>,
        records: inout [DocumentStructureEdgeRecord]
    ) {
        let identity = "\(from)|\(to)|\(kind)"
        guard identities.insert(identity).inserted else { return }
        records.append(DocumentStructureEdgeRecord(
            id: "structure-edge-\(DocumentStorage.sha256Hex(of: Data(identity.utf8)))",
            matterID: matterID,
            fromNodeID: from,
            toNodeID: to,
            kind: kind
        ))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private struct MessagePayload: Decodable {
        var messageID: String?
        var inReplyTo: String?
        var references: [String] = []

        private enum CodingKeys: String, CodingKey {
            case messageID
            case inReplyTo
            case references
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
            inReplyTo = try container.decodeIfPresent(String.self, forKey: .inReplyTo)
            references = try container.decodeIfPresent([String].self, forKey: .references) ?? []
        }
    }

    private struct MessageNode {
        var nodeID: String
        var documentID: String
        var messageID: String?
        var inReplyTo: String?
        var references: [String]
    }
}
