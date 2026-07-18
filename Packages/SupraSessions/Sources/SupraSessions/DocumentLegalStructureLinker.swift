import Foundation
import SupraDocuments
import SupraStore

/// Connects numbered discovery responses to uniquely matching requests after
/// documents have been imported. Pairing is matter-local and deterministic;
/// ambiguous duplicate request numbers are left unlinked for review.
public final class DocumentLegalStructureLinker: @unchecked Sendable {
    private static let edgeIDPrefix = "legal-pair-edge-"
    private let store: SupraStore

    public init(store: SupraStore) {
        self.store = store
    }

    @discardableResult
    public func relink(matterID: String) throws -> Int {
        var requests: [LegalNode] = []
        var responses: [LegalNode] = []
        for document in try store.documentLibrary.fetchDocuments(matterID: matterID) {
            for node in try store.documentStructure.fetchNodes(documentID: document.id) {
                guard node.kind == "discovery_request" || node.kind == "discovery_response",
                      let payload = node.payloadJSON,
                      let decoded = try? JSONDecoder().decode(
                          DiscoveryPayload.self,
                          from: Data(payload.utf8)
                      ) else { continue }
                let legalNode = LegalNode(
                    nodeID: node.id,
                    documentID: document.id,
                    identity: "\(decoded.family.lowercased())|\(decoded.number.uppercased())"
                )
                if node.kind == "discovery_request" {
                    requests.append(legalNode)
                } else {
                    responses.append(legalNode)
                }
            }
        }

        let groupedRequests = Dictionary(grouping: requests, by: \.identity)
        let uniqueRequestByIdentity: [String: LegalNode] = Dictionary(
            uniqueKeysWithValues: groupedRequests.compactMap { identity, matches in
                guard matches.count == 1, let request = matches.first else { return nil }
                return (identity, request)
            }
        )
        var records: [DocumentStructureEdgeRecord] = []
        for response in responses.sorted(by: { $0.nodeID < $1.nodeID }) {
            guard let request = uniqueRequestByIdentity[response.identity],
                  request.documentID != response.documentID else { continue }
            let identity = "\(response.nodeID)|\(request.nodeID)|responds_to"
            records.append(DocumentStructureEdgeRecord(
                id: "\(Self.edgeIDPrefix)\(DocumentStorage.sha256Hex(of: Data(identity.utf8)))",
                matterID: matterID,
                fromNodeID: response.nodeID,
                toNodeID: request.nodeID,
                kind: "responds_to"
            ))
        }

        try store.documentStructure.replaceMatterEdges(
            matterID: matterID,
            kinds: ["responds_to"],
            idPrefix: Self.edgeIDPrefix,
            edges: records
        )
        return records.count
    }

    private struct DiscoveryPayload: Decodable {
        var family: String
        var number: String
    }

    private struct LegalNode {
        var nodeID: String
        var documentID: String
        var identity: String
    }
}
