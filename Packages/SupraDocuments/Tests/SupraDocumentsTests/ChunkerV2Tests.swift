import Foundation
import SupraCore
@testable import SupraDocuments
import XCTest

final class ChunkerV2Tests: XCTestCase {
    func testClauseAndProvisoRemainOneSemanticUnit() {
        // T-CHK-01 expected RED: DocumentChunker has no structure-aligned v2 path.
        let clause = "The supplier shall preserve all source records "
            + String(repeating: "supporting the invoice and claimed adjustment, ", count: 4)
            + "provided, however, that privileged material may be logged instead of produced."
        let part = ChunkPart(partID: "part-1", sourceKind: .text, text: clause)
        let nodes = [node("clause", partID: "part-1", revisionID: "rev-1", kind: .paragraph, range: 0..<clause.count)]

        let chunks = DocumentChunker(version: 2, maxChars: 200, overlapChars: 50)
            .chunk(parts: [part], nodes: nodes, edges: [])

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].nodeID, "clause")
        XCTAssertTrue(chunks[0].text.contains("provided, however"), "the proviso must not become an orphan chunk")
        XCTAssertEqual(chunks[0].chunkerVersion, 2)
    }

    func testDefinitionCarriesOnlyItsFirstOperativeUseAsStableContext() {
        // T-CHK-02 expected RED: v2 chunks cannot express structure links or scoped context.
        let definition = #"“Records” means invoices, ledgers, and supporting materials."#
        let unrelated = "The hearing shall occur in Boston."
        let use = "Supplier shall preserve the Records for seven years."
        let text = [definition, unrelated, use].joined(separator: "\n\n")
        let definitionStart = 0
        let unrelatedStart = definition.count + 2
        let useStart = unrelatedStart + unrelated.count + 2
        let nodes = [
            node("definition", partID: "part-1", revisionID: "rev-1", kind: .paragraph, range: definitionStart..<(definitionStart + definition.count)),
            node("unrelated", partID: "part-1", revisionID: "rev-1", kind: .paragraph, range: unrelatedStart..<(unrelatedStart + unrelated.count)),
            node("first-use", partID: "part-1", revisionID: "rev-1", kind: .paragraph, range: useStart..<(useStart + use.count)),
        ]
        let edges = [ChunkStructureEdge(fromNodeID: "first-use", toNodeID: "definition", kind: .references)]

        let chunks = DocumentChunker(version: 2).chunk(
            parts: [ChunkPart(partID: "part-1", sourceKind: .text, text: text)],
            nodes: nodes,
            edges: edges
        )
        let definitionChunk = try! XCTUnwrap(chunks.first { $0.nodeID == "definition" })

        XCTAssertEqual(definitionChunk.relatedNodeIDs, ["first-use"])
        XCTAssertTrue(definitionChunk.text.contains(definition))
        XCTAssertTrue(definitionChunk.text.contains(use))
        XCTAssertFalse(definitionChunk.text.contains(unrelated), "unrelated intervening text must not leak into definition context")
    }

    func testTableCellIncludesAssociatedHeaderOnlyInV2() {
        // T-CHK-03 expected RED: v2 cannot consume header_for edges.
        let text = "Outstanding Balance\n742.19"
        let headerRange = 0..<19
        let valueRange = 20..<26
        let nodes = [
            node("header", partID: "sheet-1", revisionID: "rev-sheet", kind: .tableCell, range: headerRange),
            node("target", partID: "sheet-1", revisionID: "rev-sheet", kind: .tableCell, range: valueRange),
        ]
        let edges = [ChunkStructureEdge(fromNodeID: "target", toNodeID: "header", kind: .headerFor)]
        let part = ChunkPart(partID: "sheet-1", sourceKind: .spreadsheetSheet, text: text, sheetName: "Aging")

        let v1 = DocumentChunker(version: 1).chunk(parts: [part], nodes: nodes, edges: edges)
        let v2 = DocumentChunker(version: 2).chunk(parts: [part], nodes: nodes, edges: edges)
        let target = try! XCTUnwrap(v2.first { $0.nodeID == "target" })

        XCTAssertFalse(v1.first!.text.contains("Outstanding Balance\n742.19") && v1.first!.nodeID == "target")
        XCTAssertEqual(target.text, "Outstanding Balance\n742.19")
        XCTAssertEqual(target.relatedNodeIDs, ["header"])
        XCTAssertEqual(target.unitKind, DocumentStructureNodeKind.tableCell.rawValue)
    }

    func testLinkedLegalPairsStayTogetherOrSplitAtNodeBoundary() {
        // T-CHK-04 expected RED: v2 has no responds_to keep-together/split contract.
        let shortQuestion = "Q. Who approved the transfer?"
        let shortAnswer = "A. Jordan Lee approved it."
        let shortText = shortQuestion + "\n" + shortAnswer
        let shortNodes = [
            node("q-short", partID: "depo", revisionID: "rev-depo", kind: .depositionQuestion, range: 0..<shortQuestion.count),
            node("a-short", partID: "depo", revisionID: "rev-depo", kind: .depositionAnswer, range: (shortQuestion.count + 1)..<shortText.count),
        ]
        let shortEdges = [ChunkStructureEdge(fromNodeID: "a-short", toNodeID: "q-short", kind: .respondsTo)]
        let shortChunks = DocumentChunker(version: 2, maxChars: 300).chunk(
            parts: [ChunkPart(partID: "depo", sourceKind: .text, text: shortText)],
            nodes: shortNodes,
            edges: shortEdges
        )
        XCTAssertEqual(shortChunks.count, 1)
        XCTAssertEqual(shortChunks[0].nodeID, "q-short")
        XCTAssertEqual(shortChunks[0].relatedNodeIDs, ["a-short"])
        XCTAssertTrue(shortChunks[0].text.contains(shortQuestion))
        XCTAssertTrue(shortChunks[0].text.contains(shortAnswer))

        let request = "Request for Production No. 4: " + String(repeating: "Produce invoice records. ", count: 10)
        let response = "Response to Request No. 4: " + String(repeating: "Responsive records will be produced. ", count: 10)
        let longText = request + "\n" + response
        let longNodes = [
            node("request-4", partID: "discovery", revisionID: "rev-discovery", kind: .discoveryRequest, range: 0..<request.count),
            node("response-4", partID: "discovery", revisionID: "rev-discovery", kind: .discoveryResponse, range: (request.count + 1)..<longText.count),
        ]
        let longEdges = [ChunkStructureEdge(fromNodeID: "response-4", toNodeID: "request-4", kind: .respondsTo)]
        let longChunks = DocumentChunker(version: 2, maxChars: 300).chunk(
            parts: [ChunkPart(partID: "discovery", sourceKind: .text, text: longText)],
            nodes: longNodes,
            edges: longEdges
        )

        XCTAssertEqual(longChunks.map(\.nodeID), ["request-4", "response-4"], "oversize pairs split only at the declared node boundary")
        XCTAssertEqual(longChunks[0].relatedNodeIDs, ["response-4"])
        XCTAssertEqual(longChunks[1].relatedNodeIDs, ["request-4"])
        XCTAssertEqual(longChunks[0].text, request)
        XCTAssertEqual(longChunks[1].text, response)
    }

    func testV1FrozenParityRemainsByteExact() {
        // T-CHK-06 parity fixture: this passes before v2 and must remain unchanged.
        let longText = String(repeating: "A", count: 210)
        let parts = [
            ChunkPart(partID: "page", sourceKind: .pdfPage, text: longText, pageIndex: 4, pageLabel: "5"),
            ChunkPart(partID: "empty", sourceKind: .text, text: " \n "),
            ChunkPart(partID: "sheet", sourceKind: .spreadsheetSheet, text: "Outstanding Balance\t742.19", sheetName: "Aging", cellRange: "D8"),
        ]

        let chunks = DocumentChunker(version: 1, maxChars: 200, overlapChars: 50)
            .chunk(parts: parts, nodes: [], edges: [])

        XCTAssertEqual(chunks.map(\.chunkIndex), [0, 1, 2])
        XCTAssertEqual(chunks.map(\.partID), ["page", "page", "sheet"])
        XCTAssertEqual(chunks.map(\.charStart), [0, 150, 0])
        XCTAssertEqual(chunks.map(\.charEnd), [200, 210, 26])
        XCTAssertEqual(chunks.map(\.text), [String(repeating: "A", count: 200), String(repeating: "A", count: 60), "Outstanding Balance\t742.19"])
        XCTAssertEqual(chunks.map(\.tokenCount), [1, 1, 2])
        XCTAssertEqual(chunks.map(\.pageIndex), [4, 4, nil])
        XCTAssertEqual(chunks.map(\.sheetName), [nil, nil, "Aging"])
    }

    private func node(
        _ id: String,
        partID: String,
        revisionID: String,
        kind: DocumentStructureNodeKind,
        range: Range<Int>
    ) -> ChunkStructureNode {
        ChunkStructureNode(
            nodeID: id,
            partID: partID,
            revisionID: revisionID,
            ordinal: range.lowerBound,
            kind: kind,
            charStart: range.lowerBound,
            charEnd: range.upperBound
        )
    }
}
