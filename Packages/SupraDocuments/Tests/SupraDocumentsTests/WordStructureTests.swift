import Foundation
@testable import SupraDocuments
import XCTest
import ZIPFoundation

final class WordStructureTests: XCTestCase {
    private let service = ExtractionService()
    private var tempDirectory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordStructureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testTSTR04NumberingProducesListHierarchyAndStableNumberingPayload() async throws {
        // T-STR-04 expected RED: DOCX currently receives only the universal
        // document/paragraph wrapper; numbering.xml and numPr are not represented.
        let document = wordDocument("""
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="42"/></w:numPr></w:pPr><w:r><w:t>ARTICLE-ALPHA</w:t></w:r></w:p>
        <w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="42"/></w:numPr></w:pPr><w:r><w:t>SUBPART-BETA</w:t></w:r></w:p>
        """)
        let numbering = xml("""
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:abstractNum w:abstractNumId="7">
            <w:lvl w:ilvl="0"><w:start w:val="3"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>
            <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%1.%2)"/></w:lvl>
          </w:abstractNum>
          <w:num w:numId="42"><w:abstractNumId w:val="7"/></w:num>
        </w:numbering>
        """)
        let result = try await extractDOCX(entries: [
            "word/document.xml": document,
            "word/numbering.xml": numbering,
        ])

        XCTAssertEqual(result.combinedText, "ARTICLE-ALPHA\nSUBPART-BETA")
        let list = try node(kind: .list, in: result)
        let items = result.structure.nodes.filter { $0.kind == .listItem }
        XCTAssertEqual(items.count, 2)
        let top = try XCTUnwrap(items.first { resolvedText($0, in: result) == "ARTICLE-ALPHA" })
        let nested = try XCTUnwrap(items.first { resolvedText($0, in: result) == "SUBPART-BETA" })
        XCTAssertEqual(top.parentNodeKey, list.nodeKey)
        XCTAssertEqual(nested.parentNodeKey, top.nodeKey, "level 1 must nest under the preceding level 0 item")
        XCTAssertEqual(payload(top)["numId"] as? String, "42")
        XCTAssertEqual(payload(top)["level"] as? Int, 0)
        XCTAssertEqual(payload(top)["start"] as? Int, 3)
        XCTAssertEqual(payload(top)["format"] as? String, "decimal")
        XCTAssertEqual(payload(nested)["level"] as? Int, 1)
        XCTAssertEqual(payload(nested)["levelText"] as? String, "%1.%2)")
    }

    func testTSTR05TableCellsRetainGridAndHeaderEdges() async throws {
        // T-STR-05 expected RED: Word tables are flattened into paragraph text;
        // row/cell nodes and header_for edges are absent.
        let document = wordDocument("""
        <w:tbl>
          <w:tr><w:trPr><w:tblHeader/></w:trPr>
            <w:tc><w:p><w:r><w:t>HEADER-A</w:t></w:r></w:p></w:tc>
            <w:tc><w:p><w:r><w:t>HEADER-B</w:t></w:r></w:p></w:tc>
          </w:tr>
          <w:tr>
            <w:tc><w:p><w:r><w:t>VALUE-A-742</w:t></w:r></w:p></w:tc>
            <w:tc><w:p><w:r><w:t>VALUE-B-913</w:t></w:r></w:p></w:tc>
          </w:tr>
        </w:tbl>
        """)
        let result = try await extractDOCX(entries: ["word/document.xml": document])

        XCTAssertEqual(result.combinedText, "HEADER-A\nHEADER-B\nVALUE-A-742\nVALUE-B-913")
        XCTAssertEqual(result.structure.nodes.filter { $0.kind == .table }.count, 1)
        XCTAssertEqual(result.structure.nodes.filter { $0.kind == .tableRow }.count, 2)
        let cells = result.structure.nodes.filter { $0.kind == .tableCell }
        XCTAssertEqual(cells.count, 4)
        let headerA = try XCTUnwrap(cells.first { resolvedText($0, in: result) == "HEADER-A" })
        let headerB = try XCTUnwrap(cells.first { resolvedText($0, in: result) == "HEADER-B" })
        let valueA = try XCTUnwrap(cells.first { resolvedText($0, in: result) == "VALUE-A-742" })
        let valueB = try XCTUnwrap(cells.first { resolvedText($0, in: result) == "VALUE-B-913" })
        XCTAssertEqual(payload(headerA)["header"] as? Bool, true)
        XCTAssertEqual(payload(valueB)["column"] as? Int, 1)
        XCTAssertEqual(
            Set(result.structure.edges.filter { $0.kind == .headerFor }.map { "\($0.fromNodeKey)->\($0.toNodeKey)" }),
            Set(["\(valueA.nodeKey)->\(headerA.nodeKey)", "\(valueB.nodeKey)->\(headerB.nodeKey)"])
        )
    }

    func testTSTR06FootnoteEndnoteAndCommentAnchorToExactBodyNodes() async throws {
        // T-STR-06 expected RED: note/comment parts and their body anchors are
        // ignored, so no out-of-flow nodes or anchor_of edges exist.
        let document = wordDocument("""
        <w:p><w:r><w:t>REPEATED-ANCHOR</w:t></w:r><w:r><w:footnoteReference w:id="2"/></w:r></w:p>
        <w:p><w:commentRangeStart w:id="5"/><w:r><w:t>REPEATED-ANCHOR</w:t></w:r><w:commentRangeEnd w:id="5"/><w:r><w:endnoteReference w:id="3"/></w:r></w:p>
        """)
        let footnotes = xml("""
        <w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:footnote w:id="2"><w:p><w:r><w:t>FOOTNOTE-NONDEFAULT</w:t></w:r></w:p></w:footnote>
        </w:footnotes>
        """)
        let endnotes = xml("""
        <w:endnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:endnote w:id="3"><w:p><w:r><w:t>ENDNOTE-NONDEFAULT</w:t></w:r></w:p></w:endnote>
        </w:endnotes>
        """)
        let comments = xml("""
        <w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:comment w:id="5"><w:p><w:r><w:t>COMMENT-NONDEFAULT</w:t></w:r></w:p></w:comment>
        </w:comments>
        """)
        let result = try await extractDOCX(entries: [
            "word/document.xml": document,
            "word/footnotes.xml": footnotes,
            "word/endnotes.xml": endnotes,
            "word/comments.xml": comments,
        ])

        XCTAssertEqual(result.combinedText, "REPEATED-ANCHOR\nREPEATED-ANCHOR")
        let paragraphs = result.structure.nodes.filter { $0.kind == .paragraph }
        XCTAssertEqual(paragraphs.count, 2)
        let footnote = try node(kind: .footnote, in: result)
        let endnote = try node(kind: .endnote, in: result)
        let comment = try node(kind: .comment, in: result)
        XCTAssertEqual(footnote.textContent, "FOOTNOTE-NONDEFAULT")
        XCTAssertEqual(endnote.textContent, "ENDNOTE-NONDEFAULT")
        XCTAssertEqual(comment.textContent, "COMMENT-NONDEFAULT")

        let anchors = Dictionary(uniqueKeysWithValues: result.structure.edges
            .filter { $0.kind == .anchorOf }
            .map { ($0.fromNodeKey, $0.toNodeKey) })
        XCTAssertEqual(anchors[footnote.nodeKey], paragraphs[0].nodeKey)
        XCTAssertEqual(anchors[comment.nodeKey], paragraphs[1].nodeKey)
        XCTAssertEqual(anchors[endnote.nodeKey], paragraphs[1].nodeKey)
        XCTAssertNotEqual(anchors[footnote.nodeKey], anchors[comment.nodeKey], "repeated body text must not collapse anchors")
    }

    func testTSTR07TrackedDeletionIsRepresentedButExcludedFromSelectedText() async throws {
        // T-STR-07 expected RED: w:delText is silently dropped and no tracked
        // insertion/deletion structure or warning survives extraction.
        let document = wordDocument("""
        <w:p>
          <w:r><w:t>BEFORE</w:t></w:r>
          <w:del w:id="8" w:author="Synthetic"><w:r><w:delText> DELETED-NONDEFAULT</w:delText></w:r></w:del>
          <w:ins w:id="9" w:author="Synthetic"><w:r><w:t> INSERTED-NONDEFAULT</w:t></w:r></w:ins>
          <w:r><w:t> AFTER</w:t></w:r>
        </w:p>
        """)
        let result = try await extractDOCX(entries: ["word/document.xml": document])

        XCTAssertTrue(result.combinedText.contains("INSERTED-NONDEFAULT"))
        XCTAssertFalse(result.combinedText.contains("DELETED-NONDEFAULT"))
        let deletion = try node(kind: .trackedDeletion, in: result)
        let insertion = try node(kind: .trackedInsertion, in: result)
        XCTAssertEqual(deletion.textContent, " DELETED-NONDEFAULT")
        XCTAssertEqual(resolvedText(insertion, in: result), " INSERTED-NONDEFAULT")
        XCTAssertTrue(result.warnings.contains { $0.localizedCaseInsensitiveContains("tracked changes") })
    }

    func testTSTR08HeadersAndFootersRemainOutOfBodyFlowWithRelationshipKinds() async throws {
        // T-STR-08 expected RED: header/footer parts and section relationships
        // are not read; only body text is available.
        let document = xml("""
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:body>
            <w:p><w:r><w:t>BODY-NONDEFAULT</w:t></w:r></w:p>
            <w:sectPr>
              <w:headerReference w:type="first" r:id="rIdH1"/>
              <w:headerReference w:type="even" r:id="rIdH2"/>
              <w:headerReference w:type="default" r:id="rIdH3"/>
              <w:footerReference w:type="default" r:id="rIdF1"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """)
        let relationships = xml("""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rIdH1" Type="header" Target="header1.xml"/>
          <Relationship Id="rIdH2" Type="header" Target="header2.xml"/>
          <Relationship Id="rIdH3" Type="header" Target="header3.xml"/>
          <Relationship Id="rIdF1" Type="footer" Target="footer1.xml"/>
        </Relationships>
        """)
        let result = try await extractDOCX(entries: [
            "word/document.xml": document,
            "word/_rels/document.xml.rels": relationships,
            "word/header1.xml": wordStory("w:hdr", text: "HEADER-FIRST"),
            "word/header2.xml": wordStory("w:hdr", text: "HEADER-EVEN"),
            "word/header3.xml": wordStory("w:hdr", text: "HEADER-DEFAULT"),
            "word/footer1.xml": wordStory("w:ftr", text: "FOOTER-DEFAULT"),
        ])

        XCTAssertEqual(result.combinedText, "BODY-NONDEFAULT")
        for sentinel in ["HEADER-FIRST", "HEADER-EVEN", "HEADER-DEFAULT", "FOOTER-DEFAULT"] {
            XCTAssertFalse(result.combinedText.contains(sentinel))
            XCTAssertTrue(result.structure.nodes.contains { $0.textContent == sentinel })
        }
        let headers = result.structure.nodes.filter { $0.kind == .header }
        XCTAssertEqual(Set(headers.compactMap { payload($0)["type"] as? String }), ["first", "even", "default"])
        let footer = try node(kind: .footer, in: result)
        XCTAssertEqual(payload(footer)["relationshipId"] as? String, "rIdF1")
        XCTAssertEqual(result.structure.nodes.filter { $0.kind == .section }.count, 1)
    }

    private func extractDOCX(entries: [String: String]) async throws -> ExtractionResult {
        let url = tempDirectory.appendingPathComponent("fixture-\(UUID().uuidString).docx")
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        for (path, contents) in entries.sorted(by: { $0.key < $1.key }) {
            let data = Data(contents.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<(start + size))
            }
        }
        return try await service.extract(fileURL: url)
    }

    private func node(
        kind: DocumentStructureNodeKind,
        in result: ExtractionResult
    ) throws -> ExtractedStructureNode {
        try XCTUnwrap(result.structure.nodes.first { $0.kind == kind })
    }

    private func resolvedText(
        _ node: ExtractedStructureNode,
        in result: ExtractionResult
    ) -> String? {
        if let text = node.textContent { return text }
        guard result.parts.indices.contains(node.partIndex),
              let start = node.charStart,
              let end = node.charEnd else { return nil }
        let text = result.parts[node.partIndex].text
        guard start >= 0, start <= end, end <= text.count else { return nil }
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(text.startIndex, offsetBy: end)
        return String(text[lower..<upper])
    }

    private func payload(_ node: ExtractedStructureNode) -> [String: Any] {
        guard let json = node.payloadJSON,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func wordDocument(_ body: String) -> String {
        xml("""
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:body>\(body)</w:body>
        </w:document>
        """)
    }

    private func wordStory(_ root: String, text: String) -> String {
        xml("""
        <\(root) xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:p><w:r><w:t>\(text)</w:t></w:r></w:p>
        </\(root)>
        """)
    }

    private func xml(_ value: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + value
    }
}
