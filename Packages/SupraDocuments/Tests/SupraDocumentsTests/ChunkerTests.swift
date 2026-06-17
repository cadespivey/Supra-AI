import Foundation
import SupraCore
@testable import SupraDocuments
import XCTest

final class ChunkerTests: XCTestCase {
    func testShortPartProducesSingleChunkPreservingLocator() {
        let chunker = DocumentChunker(maxChars: 1200, overlapChars: 200)
        let parts = [ChunkPart(partID: "p1", sourceKind: .pdfPage, text: "Short page text.", pageIndex: 2, pageLabel: "3")]
        let chunks = chunker.chunk(parts: parts)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].pageIndex, 2)
        XCTAssertEqual(chunks[0].pageLabel, "3")
        XCTAssertEqual(chunks[0].partID, "p1")
        XCTAssertEqual(chunks[0].charStart, 0)
        XCTAssertEqual(chunks[0].text, "Short page text.")
    }

    func testLongTextSplitsWithOverlapDeterministically() {
        let chunker = DocumentChunker(maxChars: 300, overlapChars: 50)
        let sentence = "The indemnification clause survives termination of the agreement. "
        let text = String(repeating: sentence, count: 30)
        let parts = [ChunkPart(partID: "p1", sourceKind: .text, text: text)]
        let first = chunker.chunk(parts: parts)
        let second = chunker.chunk(parts: parts)

        XCTAssertGreaterThan(first.count, 1)
        XCTAssertEqual(first.map(\.text), second.map(\.text), "chunking must be deterministic")
        // Sequential, non-decreasing chunk indices.
        XCTAssertEqual(first.map(\.chunkIndex), Array(0..<first.count))
        // Overlap: each chunk after the first starts before the previous end.
        for i in 1..<first.count {
            XCTAssertLessThanOrEqual(first[i].charStart, first[i - 1].charEnd)
        }
        // No chunk exceeds the bound by much.
        for chunk in first {
            XCTAssertLessThanOrEqual(chunk.text.count, 320)
        }
    }

    func testEmptyPartsSkipped() {
        let chunker = DocumentChunker()
        let parts = [
            ChunkPart(sourceKind: .image, text: "   \n  "),
            ChunkPart(sourceKind: .text, text: "Real content here.")
        ]
        let chunks = chunker.chunk(parts: parts)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].text, "Real content here.")
    }
}
