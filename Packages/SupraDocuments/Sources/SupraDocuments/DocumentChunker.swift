import Foundation
import SupraCore

/// Input to chunking: one extracted part plus its locator (plan §7.1).
public struct ChunkPart: Sendable {
    public var partID: String?
    public var sourceKind: DocumentSourceKind
    public var pageIndex: Int?
    public var pageLabel: String?
    public var sheetName: String?
    public var cellRange: String?
    public var emailPartPath: String?
    public var ocrConfidence: Double?
    public var boundingBoxesJSON: String?
    public var text: String

    public init(
        partID: String? = nil,
        sourceKind: DocumentSourceKind,
        text: String,
        pageIndex: Int? = nil,
        pageLabel: String? = nil,
        sheetName: String? = nil,
        cellRange: String? = nil,
        emailPartPath: String? = nil,
        ocrConfidence: Double? = nil,
        boundingBoxesJSON: String? = nil
    ) {
        self.partID = partID
        self.sourceKind = sourceKind
        self.text = text
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.sheetName = sheetName
        self.cellRange = cellRange
        self.emailPartPath = emailPartPath
        self.ocrConfidence = ocrConfidence
        self.boundingBoxesJSON = boundingBoxesJSON
    }
}

/// A retrieval chunk with a stable locator and char range within its part.
public struct DocumentChunk: Sendable, Equatable {
    public var chunkIndex: Int
    public var partID: String?
    public var sourceKind: DocumentSourceKind
    public var pageIndex: Int?
    public var pageLabel: String?
    public var sheetName: String?
    public var cellRange: String?
    public var emailPartPath: String?
    public var charStart: Int
    public var charEnd: Int
    public var text: String
    public var displayExcerpt: String
    public var tokenCount: Int
    public var ocrConfidence: Double?
    public var boundingBoxesJSON: String?
    /// Primary structure node represented by this chunk. Nil for legacy v1.
    public var nodeID: String?
    /// Structural unit kind of `nodeID`. Nil for legacy v1.
    public var unitKind: String?
    /// Related nodes whose text or relationship supplies retrieval context.
    /// This graph projection is recomputed from persisted structure edges.
    public var relatedNodeIDs: [String]
    public var chunkerVersion: Int
}

/// Revision-bound structure projected into the pure chunking package. The
/// indexing layer resolves persisted node revisions to compatible part ids.
public struct ChunkStructureNode: Sendable, Equatable {
    public var nodeID: String
    public var parentNodeID: String?
    public var partID: String
    public var revisionID: String
    public var ordinal: Int
    public var kind: DocumentStructureNodeKind
    public var charStart: Int?
    public var charEnd: Int?
    public var textContent: String?

    public init(
        nodeID: String,
        parentNodeID: String? = nil,
        partID: String,
        revisionID: String,
        ordinal: Int,
        kind: DocumentStructureNodeKind,
        charStart: Int? = nil,
        charEnd: Int? = nil,
        textContent: String? = nil
    ) {
        self.nodeID = nodeID
        self.parentNodeID = parentNodeID
        self.partID = partID
        self.revisionID = revisionID
        self.ordinal = ordinal
        self.kind = kind
        self.charStart = charStart
        self.charEnd = charEnd
        self.textContent = textContent
    }
}

public struct ChunkStructureEdge: Sendable, Equatable {
    public var fromNodeID: String
    public var toNodeID: String
    public var kind: DocumentStructureEdgeKind

    public init(fromNodeID: String, toNodeID: String, kind: DocumentStructureEdgeKind) {
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.kind = kind
    }
}

/// Deterministic chunker: chunks by natural part boundaries first, then splits
/// long text into character-bounded chunks with overlap, preferring to break at
/// paragraph/sentence boundaries. Locators are preserved so citations resolve
/// back to the right page/sheet/part (plan §7.1).
public struct DocumentChunker: Sendable {
    public let version: Int
    public let maxChars: Int
    public let overlapChars: Int

    public init(version: Int = 1, maxChars: Int = 1200, overlapChars: Int = 200) {
        self.version = version == 2 ? 2 : 1
        self.maxChars = max(200, maxChars)
        self.overlapChars = max(0, min(overlapChars, maxChars / 2))
    }

    public func chunk(parts: [ChunkPart]) -> [DocumentChunk] {
        chunkV1(parts: parts)
    }

    /// Structure-aware entry point. Version 1 deliberately ignores both graph
    /// inputs and runs the frozen legacy implementation byte-for-byte.
    public func chunk(
        parts: [ChunkPart],
        nodes: [ChunkStructureNode],
        edges: [ChunkStructureEdge]
    ) -> [DocumentChunk] {
        guard version == 2 else { return chunkV1(parts: parts) }
        return chunkV2(parts: parts, nodes: nodes, edges: edges)
    }

    private func chunkV1(parts: [ChunkPart]) -> [DocumentChunk] {
        var chunks: [DocumentChunk] = []
        var index = 0
        for part in parts {
            let characters = Array(part.text)
            guard characters.contains(where: { !$0.isWhitespace }) else { continue }
            for (start, end) in ranges(characters) {
                let slice = String(characters[start..<end])
                let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                chunks.append(DocumentChunk(
                    chunkIndex: index,
                    partID: part.partID,
                    sourceKind: part.sourceKind,
                    pageIndex: part.pageIndex,
                    pageLabel: part.pageLabel,
                    sheetName: part.sheetName,
                    cellRange: part.cellRange,
                    emailPartPath: part.emailPartPath,
                    charStart: start,
                    charEnd: end,
                    text: slice,
                    displayExcerpt: Self.excerpt(slice),
                    tokenCount: Self.approxTokenCount(slice),
                    ocrConfidence: part.ocrConfidence,
                    boundingBoxesJSON: part.boundingBoxesJSON,
                    nodeID: nil,
                    unitKind: nil,
                    relatedNodeIDs: [],
                    chunkerVersion: 1
                ))
                index += 1
            }
        }
        return chunks
    }

    private func chunkV2(
        parts: [ChunkPart],
        nodes: [ChunkStructureNode],
        edges: [ChunkStructureEdge]
    ) -> [DocumentChunk] {
        let partsByID = Dictionary(uniqueKeysWithValues: parts.compactMap { part in
            part.partID.map { ($0, part) }
        })
        let partOrder = Dictionary(uniqueKeysWithValues: parts.enumerated().compactMap { index, part in
            part.partID.map { ($0, index) }
        })
        let charactersByPartID = Dictionary(uniqueKeysWithValues: parts.compactMap { part in
            part.partID.map { ($0, Array(part.text)) }
        })
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.nodeID, $0) })
        let legalKinds: Set<DocumentStructureNodeKind> = [
            .discoveryRequest, .discoveryResponse, .objection,
            .depositionQuestion, .depositionAnswer,
        ]
        let genericKinds: Set<DocumentStructureNodeKind> = [.paragraph, .listItem, .region, .emailBody]
        let legalRangesByPart = Dictionary(grouping: nodes.filter {
            legalKinds.contains($0.kind) && $0.charStart != nil && $0.charEnd != nil
        }, by: \.partID)
        let candidates = nodes.filter { node in
            guard partsByID[node.partID] != nil else { return false }
            let hasRange = node.charStart != nil && node.charEnd != nil
            let hasText = !(node.textContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            guard hasRange || hasText else { return false }
            // Tracked changes are evidence metadata within the selected paragraph,
            // not duplicate retrieval units. Legal recognizer nodes supersede any
            // overlapping generic adapter paragraph/region/body projection.
            guard node.kind != .trackedInsertion && node.kind != .trackedDeletion else { return false }
            if genericKinds.contains(node.kind),
               let start = node.charStart,
               let end = node.charEnd,
               legalRangesByPart[node.partID]?.contains(where: {
                   guard let legalStart = $0.charStart, let legalEnd = $0.charEnd else { return false }
                   return start < legalEnd && legalStart < end
               }) == true {
                return false
            }
            return true
        }.sorted { lhs, rhs in
            let lhsPart = partOrder[lhs.partID] ?? .max
            let rhsPart = partOrder[rhs.partID] ?? .max
            if lhsPart != rhsPart { return lhsPart < rhsPart }
            if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
            if lhs.charStart != rhs.charStart { return (lhs.charStart ?? .max) < (rhs.charStart ?? .max) }
            return lhs.nodeID < rhs.nodeID
        }

        guard !candidates.isEmpty else {
            return chunkV1(parts: parts).map { legacy in
                var projected = legacy
                projected.chunkerVersion = 2
                return projected
            }
        }

        let usableEdges = edges.filter { edge in
            guard let from = nodesByID[edge.fromNodeID], let to = nodesByID[edge.toNodeID] else { return false }
            return from.partID == to.partID && from.revisionID == to.revisionID
        }
        let respondsByTarget = Dictionary(grouping: usableEdges.filter { $0.kind == .respondsTo }, by: \.toNodeID)
        let referencesByTarget = Dictionary(grouping: usableEdges.filter { $0.kind == .references }, by: \.toNodeID)
        let headersByCell = Dictionary(grouping: usableEdges.filter { $0.kind == .headerFor }, by: \.fromNodeID)

        var result: [DocumentChunk] = []
        var consumed = Set<String>()
        for node in candidates where !consumed.contains(node.nodeID) {
            guard let part = partsByID[node.partID],
                  let primaryText = text(for: node, characters: charactersByPartID[node.partID]) else { continue }

            if let responseEdge = respondsByTarget[node.nodeID]?.sorted(by: edgeOrder).first,
               let response = nodesByID[responseEdge.fromNodeID],
               let responseText = text(for: response, characters: charactersByPartID[response.partID]) {
                let combined = primaryText + "\n" + responseText
                if combined.count <= maxChars {
                    result.append(makeV2Chunk(
                        index: result.count,
                        node: node,
                        part: part,
                        text: combined,
                        relatedNodeIDs: [response.nodeID]
                    ))
                    consumed.formUnion([node.nodeID, response.nodeID])
                } else {
                    result.append(makeV2Chunk(
                        index: result.count,
                        node: node,
                        part: part,
                        text: primaryText,
                        relatedNodeIDs: [response.nodeID]
                    ))
                    result.append(makeV2Chunk(
                        index: result.count,
                        node: response,
                        part: part,
                        text: responseText,
                        relatedNodeIDs: [node.nodeID]
                    ))
                    consumed.formUnion([node.nodeID, response.nodeID])
                }
                continue
            }

            if let useEdge = referencesByTarget[node.nodeID]?.sorted(by: edgeOrder).first,
               let use = nodesByID[useEdge.fromNodeID],
               let useText = text(for: use, characters: charactersByPartID[use.partID]) {
                result.append(makeV2Chunk(
                    index: result.count,
                    node: node,
                    part: part,
                    text: primaryText + "\n" + useText,
                    relatedNodeIDs: [use.nodeID]
                ))
                consumed.insert(node.nodeID)
                continue
            }

            if let headerEdges = headersByCell[node.nodeID] {
                let headers = headerEdges.sorted(by: edgeOrder).compactMap { edge -> (String, String)? in
                    guard let header = nodesByID[edge.toNodeID],
                          let headerText = text(for: header, characters: charactersByPartID[header.partID]) else { return nil }
                    return (header.nodeID, headerText)
                }
                if !headers.isEmpty {
                    result.append(makeV2Chunk(
                        index: result.count,
                        node: node,
                        part: part,
                        text: headers.map(\.1).joined(separator: "\n") + "\n" + primaryText,
                        relatedNodeIDs: headers.map(\.0)
                    ))
                    consumed.insert(node.nodeID)
                    continue
                }
            }

            result.append(makeV2Chunk(
                index: result.count,
                node: node,
                part: part,
                text: primaryText,
                relatedNodeIDs: []
            ))
            consumed.insert(node.nodeID)
        }
        return result
    }

    private func text(
        for node: ChunkStructureNode,
        characters: [Character]?
    ) -> String? {
        if let start = node.charStart, let end = node.charEnd {
            guard let characters else { return nil }
            guard start >= 0, end > start, end <= characters.count else { return nil }
            let value = String(characters[start..<end])
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        guard let value = node.textContent,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func makeV2Chunk(
        index: Int,
        node: ChunkStructureNode,
        part: ChunkPart,
        text: String,
        relatedNodeIDs: [String]
    ) -> DocumentChunk {
        DocumentChunk(
            chunkIndex: index,
            partID: part.partID,
            sourceKind: part.sourceKind,
            pageIndex: part.pageIndex,
            pageLabel: part.pageLabel,
            sheetName: part.sheetName,
            cellRange: part.cellRange,
            emailPartPath: part.emailPartPath,
            charStart: node.charStart ?? 0,
            charEnd: node.charEnd ?? (node.textContent?.count ?? 0),
            text: text,
            displayExcerpt: Self.excerpt(text),
            tokenCount: Self.approxTokenCount(text),
            ocrConfidence: part.ocrConfidence,
            boundingBoxesJSON: part.boundingBoxesJSON,
            nodeID: node.nodeID,
            unitKind: node.kind.rawValue,
            relatedNodeIDs: relatedNodeIDs,
            chunkerVersion: 2
        )
    }

    private func edgeOrder(_ lhs: ChunkStructureEdge, _ rhs: ChunkStructureEdge) -> Bool {
        if lhs.fromNodeID != rhs.fromNodeID { return lhs.fromNodeID < rhs.fromNodeID }
        return lhs.toNodeID < rhs.toNodeID
    }

    /// Returns char ranges (start, end) over a character array, preferring breaks
    /// at paragraph/sentence/space boundaries within the tail window.
    private func ranges(_ characters: [Character]) -> [(Int, Int)] {
        let length = characters.count
        guard length > maxChars else { return [(0, length)] }
        var result: [(Int, Int)] = []
        var start = 0
        while start < length {
            let hardEnd = min(start + maxChars, length)
            var end = hardEnd
            if hardEnd < length {
                let windowStart = max(hardEnd - overlapChars - 1, start + 1)
                end = preferredBreak(in: characters, from: windowStart, to: hardEnd) ?? hardEnd
            }
            result.append((start, end))
            if end >= length { break }
            start = max(end - overlapChars, start + 1)
        }
        return result
    }

    /// Last paragraph break, else sentence break, else space within the window.
    private func preferredBreak(in characters: [Character], from lower: Int, to upper: Int) -> Int? {
        var lastParagraph: Int?
        var lastSpace: Int?
        var lastSentence: Int?
        var i = lower
        while i < upper {
            let ch = characters[i]
            if ch == "\n" {
                // Track the *last* paragraph break in the window (not the first) so the
                // chunk is as large as possible while still ending on a paragraph,
                // consistent with the sentence/space handling below.
                if i + 1 < upper && characters[i + 1] == "\n" { lastParagraph = i + 2 }
                lastSentence = i + 1
            } else if ch == "." || ch == "!" || ch == "?" {
                if i + 1 < upper && characters[i + 1] == " " { lastSentence = i + 1 }
            } else if ch == " " {
                lastSpace = i + 1
            }
            i += 1
        }
        return lastParagraph ?? lastSentence ?? lastSpace
    }

    public static func excerpt(_ text: String, limit: Int = 220) -> String {
        let collapsed = text.split(whereSeparator: { $0 == "\n" || $0 == "\t" }).joined(separator: " ")
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    static func approxTokenCount(_ text: String) -> Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }
}
