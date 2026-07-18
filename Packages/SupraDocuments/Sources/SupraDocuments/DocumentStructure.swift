import Foundation

/// Shared structural vocabulary. Format adapters may attach their lossless,
/// format-specific details in `payloadJSON` without widening this enum.
public enum DocumentStructureNodeKind: String, CaseIterable, Sendable, Codable {
    case document
    case section
    case heading
    case paragraph
    case list
    case listItem = "list_item"
    case table
    case tableRow = "table_row"
    case tableCell = "table_cell"
    case footnote
    case endnote
    case comment
    case header
    case footer
    case trackedInsertion = "tracked_insertion"
    case trackedDeletion = "tracked_deletion"
    case page
    case region
    case sheet
    case cellRange = "cell_range"
    case emailMessage = "email_message"
    case emailBody = "email_body"
    case emailQuote = "email_quote"
    case attachmentRef = "attachment_ref"
    case discoveryRequest = "discovery_request"
    case discoveryResponse = "discovery_response"
    case objection
    case depositionQuestion = "deposition_question"
    case depositionAnswer = "deposition_answer"
    case exhibitRef = "exhibit_ref"
}

public enum DocumentStructureEdgeKind: String, CaseIterable, Sendable, Codable {
    case anchorOf = "anchor_of"
    case headerFor = "header_for"
    case respondsTo = "responds_to"
    case references
    case inReplyTo = "in_reply_to"
    case threadMember = "thread_member"
    case continues
}

/// Extraction-time node keyed to a natural part index. Persistence resolves
/// that index to the immutable revision selected for the part.
public struct ExtractedStructureNode: Sendable, Equatable {
    public var nodeKey: String
    public var parentNodeKey: String?
    public var partIndex: Int
    public var ordinal: Int
    public var kind: DocumentStructureNodeKind
    public var charStart: Int?
    public var charEnd: Int?
    public var textContent: String?
    public var payloadJSON: String?

    public init(
        nodeKey: String,
        parentNodeKey: String? = nil,
        partIndex: Int,
        ordinal: Int,
        kind: DocumentStructureNodeKind,
        charStart: Int? = nil,
        charEnd: Int? = nil,
        textContent: String? = nil,
        payloadJSON: String? = nil
    ) {
        self.nodeKey = nodeKey
        self.parentNodeKey = parentNodeKey
        self.partIndex = partIndex
        self.ordinal = ordinal
        self.kind = kind
        self.charStart = charStart
        self.charEnd = charEnd
        self.textContent = textContent
        self.payloadJSON = payloadJSON
    }
}

public struct ExtractedStructureEdge: Sendable, Equatable {
    public var fromNodeKey: String
    public var toNodeKey: String
    public var kind: DocumentStructureEdgeKind

    public init(
        fromNodeKey: String,
        toNodeKey: String,
        kind: DocumentStructureEdgeKind
    ) {
        self.fromNodeKey = fromNodeKey
        self.toNodeKey = toNodeKey
        self.kind = kind
    }
}

/// Structure emitted alongside flat text. The default wrapper guarantees a
/// non-empty tree for every successfully extracted document with at least one
/// part while specialized adapters are introduced incrementally.
public struct ExtractedDocumentStructure: Sendable, Equatable {
    public var nodes: [ExtractedStructureNode]
    public var edges: [ExtractedStructureEdge]

    public init(
        nodes: [ExtractedStructureNode],
        edges: [ExtractedStructureEdge] = []
    ) {
        self.nodes = nodes
        self.edges = edges
    }

    public static func wrapper(for parts: [ExtractedPart]) -> ExtractedDocumentStructure {
        guard !parts.isEmpty else { return ExtractedDocumentStructure(nodes: []) }
        var nodes = [ExtractedStructureNode(
            nodeKey: "document",
            partIndex: 0,
            ordinal: 0,
            kind: .document
        )]
        for (index, part) in parts.enumerated() {
            if part.text.isEmpty {
                nodes.append(ExtractedStructureNode(
                    nodeKey: "part/\(index)",
                    parentNodeKey: "document",
                    partIndex: index,
                    ordinal: index,
                    kind: .section,
                    payloadJSON: #"{"empty":true}"#
                ))
            } else {
                nodes.append(ExtractedStructureNode(
                    nodeKey: "part/\(index)",
                    parentNodeKey: "document",
                    partIndex: index,
                    ordinal: index,
                    kind: .paragraph,
                    charStart: 0,
                    charEnd: part.text.count
                ))
            }
        }
        return ExtractedDocumentStructure(nodes: nodes)
    }
}
