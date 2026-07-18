import Foundation
@testable import SupraDocuments
import XCTest
import ZIPFoundation

final class SpreadsheetStructureTests: XCTestCase {
    private var tempDirectory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpreadsheetStructureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testTSTR12HiddenSheetRowAndColumnCellsAreFlaggedAndExcludedFromVisibleProjection() async throws {
        // T-STR-12 expected RED: the current XLSX extractor includes hidden
        // content in flat text but emits only a generic wrapper, so provenance
        // cannot distinguish deliberately included hidden evidence.
        let result = try await extract(entries: [
            "xl/workbook.xml": workbook([
                ("Visible", "visible", "rIdVisible"),
                ("Hidden Evidence", "hidden", "rIdHidden"),
            ]),
            "xl/_rels/workbook.xml.rels": relationships([
                ("rIdVisible", "worksheets/sheet2.xml", "worksheet"),
                ("rIdHidden", "worksheets/sheet1.xml", "worksheet"),
            ]),
            "xl/worksheets/sheet2.xml": worksheet("""
              <cols><col min="3" max="3" hidden="1"/></cols>
              <sheetData>
                <row r="1"><c r="A1" t="inlineStr"><is><t>VISIBLE-CONTROL-913</t></is></c></row>
                <row r="2" hidden="1"><c r="B2" t="inlineStr"><is><t>HIDDEN-ROW-515</t></is></c></row>
                <row r="3"><c r="C3" t="inlineStr"><is><t>HIDDEN-COLUMN-626</t></is></c></row>
              </sheetData>
            """),
            "xl/worksheets/sheet1.xml": worksheet("""
              <sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>HIDDEN-SHEET-742</t></is></c></row></sheetData>
            """),
        ])

        for sentinel in ["VISIBLE-CONTROL-913", "HIDDEN-ROW-515", "HIDDEN-COLUMN-626", "HIDDEN-SHEET-742"] {
            XCTAssertTrue(result.combinedText.contains(sentinel), "full evidence projection must retain \(sentinel)")
        }
        let hiddenSheet = try cell("A1", sheet: "Hidden Evidence", in: result)
        let hiddenRow = try cell("B2", sheet: "Visible", in: result)
        let hiddenColumn = try cell("C3", sheet: "Visible", in: result)
        XCTAssertEqual(payload(hiddenSheet)["hidden"] as? Bool, true)
        XCTAssertEqual(payload(hiddenSheet)["hiddenSources"] as? [String], ["sheet"])
        XCTAssertEqual(payload(hiddenRow)["hiddenSources"] as? [String], ["row"])
        XCTAssertEqual(payload(hiddenColumn)["hiddenSources"] as? [String], ["column"])

        let visibleValues = visibleCellValues(in: result)
        XCTAssertTrue(visibleValues.contains("VISIBLE-CONTROL-913"))
        XCTAssertFalse(visibleValues.contains("HIDDEN-SHEET-742"))
        XCTAssertFalse(visibleValues.contains("HIDDEN-ROW-515"))
        XCTAssertFalse(visibleValues.contains("HIDDEN-COLUMN-626"))
    }

    func testTSTR13FormulaCachedValueTypesAndNumberFormatsRoundTripWithoutGridDrift() async throws {
        // T-STR-13 expected RED: cached values reach the rendered grid, but
        // formulas, cell types, style indexes, and number-format IDs are lost.
        let result = try await extract(entries: [
            "xl/workbook.xml": workbook([("Calculations", "visible", "rIdCalc")]),
            "xl/_rels/workbook.xml.rels": relationships([
                ("rIdCalc", "worksheets/sheet1.xml", "worksheet"),
            ]),
            "xl/styles.xml": """
              <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                <cellXfs count="3"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="10"/></cellXfs>
              </styleSheet>
            """,
            "xl/worksheets/sheet1.xml": worksheet("""
              <sheetData>
                <row r="1">
                  <c r="A1" t="inlineStr"><is><t>Date</t></is></c>
                  <c r="B1" t="inlineStr"><is><t>Total</t></is></c>
                  <c r="C1" t="inlineStr"><is><t>Rate</t></is></c>
                </row>
                <row r="2">
                  <c r="A2" s="1"><v>45292</v></c>
                  <c r="B2"><f>SUM(B3:B4)</f><v>42.5</v></c>
                  <c r="C2" s="2"><v>0.125</v></c>
                </row>
              </sheetData>
            """),
        ])

        XCTAssertEqual(
            result.combinedText,
            "fixture.xlsx > Calculations!A1:C2\nA1: Date\tB1: Total\tC1: Rate\nA2: 45292\tB2: 42.5\tC2: 0.125",
            "the selected revision text must retain the pre-adapter grid projection"
        )
        let formula = try cell("B2", sheet: "Calculations", in: result)
        XCTAssertEqual(payload(formula)["formula"] as? String, "=SUM(B3:B4)")
        XCTAssertEqual(payload(formula)["rawValue"] as? String, "42.5")
        XCTAssertEqual(payload(formula)["cachedValue"] as? String, "42.5")
        XCTAssertEqual(payload(formula)["cellType"] as? String, "formula")
        XCTAssertEqual(payload(formula)["numberFormatId"] as? Int, 0)
        XCTAssertEqual(resolvedText(formula, in: result), "42.5")

        let date = try cell("A2", sheet: "Calculations", in: result)
        XCTAssertEqual(payload(date)["cellType"] as? String, "date_serial")
        XCTAssertEqual(payload(date)["numberFormatId"] as? Int, 14)
        let percent = try cell("C2", sheet: "Calculations", in: result)
        XCTAssertEqual(payload(percent)["cellType"] as? String, "percentage")
        XCTAssertEqual(payload(percent)["numberFormatId"] as? Int, 10)
        let string = try cell("A1", sheet: "Calculations", in: result)
        XCTAssertEqual(payload(string)["cellType"] as? String, "string")
    }

    func testTSTR14MergeTableAndHeuristicHeadersResolveUnderRelationshipMappedSheets() async throws {
        // T-STR-14 expected RED: rendered cells have no merge/table nodes or
        // header_for graph, even though worksheet relationships map correctly.
        let result = try await extract(entries: [
            "xl/workbook.xml": workbook([
                ("Logical Data", "visible", "rIdData"),
                ("Heuristic", "visible", "rIdHeuristic"),
            ]),
            "xl/_rels/workbook.xml.rels": relationships([
                ("rIdData", "worksheets/sheet9.xml", "worksheet"),
                ("rIdHeuristic", "worksheets/sheet1.xml", "worksheet"),
            ]),
            "xl/worksheets/sheet9.xml": worksheet("""
              <sheetData>
                <row r="1"><c r="A1" t="inlineStr"><is><t>MERGED-REPORT-742</t></is></c></row>
                <row r="2">
                  <c r="A2" t="inlineStr"><is><t>Matter</t></is></c>
                  <c r="B2" t="inlineStr"><is><t>Amount</t></is></c>
                  <c r="C2" t="inlineStr"><is><t>Status</t></is></c>
                </row>
                <row r="3">
                  <c r="A3" t="inlineStr"><is><t>Alpha</t></is></c><c r="B3"><v>10</v></c><c r="C3" t="inlineStr"><is><t>Open</t></is></c>
                </row>
                <row r="4">
                  <c r="A4" t="inlineStr"><is><t>Beta</t></is></c><c r="B4"><v>20</v></c><c r="C4" t="inlineStr"><is><t>Closed</t></is></c>
                </row>
              </sheetData>
              <mergeCells count="1"><mergeCell ref="A1:C1"/></mergeCells>
              <tableParts count="1"><tablePart r:id="rIdTable"/></tableParts>
            """),
            "xl/worksheets/_rels/sheet9.xml.rels": relationships([
                ("rIdTable", "../tables/table1.xml", "table"),
            ]),
            "xl/tables/table1.xml": """
              <table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" id="1" name="MatterTable" displayName="MatterTable" ref="A2:C4" headerRowCount="1">
                <tableColumns count="3"><tableColumn id="1" name="Matter"/><tableColumn id="2" name="Amount"/><tableColumn id="3" name="Status"/></tableColumns>
              </table>
            """,
            "xl/worksheets/sheet1.xml": worksheet("""
              <sheetData>
                <row r="1"><c r="A1" t="inlineStr"><is><t>Code</t></is></c><c r="B1" t="inlineStr"><is><t>Description</t></is></c></row>
                <row r="2"><c r="A2" t="inlineStr"><is><t>X-913</t></is></c><c r="B2" t="inlineStr"><is><t>Heuristic Value</t></is></c></row>
              </sheetData>
            """),
        ])

        XCTAssertTrue(result.parts[0].text.contains("MERGED-REPORT-742"), "rIdData must map Logical Data to sheet9.xml")
        let merge = try XCTUnwrap(result.structure.nodes.first { node in
            node.kind == .cellRange && payload(node)["semanticKind"] as? String == "merge"
        })
        XCTAssertEqual(payload(merge)["range"] as? String, "A1:C1")
        let table = try XCTUnwrap(result.structure.nodes.first { $0.kind == .table })
        XCTAssertEqual(payload(table)["name"] as? String, "MatterTable")
        XCTAssertEqual(payload(table)["range"] as? String, "A2:C4")

        let amount = try cell("B3", sheet: "Logical Data", in: result)
        let columnHeader = try cell("B2", sheet: "Logical Data", in: result)
        let rowHeader = try cell("A3", sheet: "Logical Data", in: result)
        XCTAssertTrue(hasHeaderEdge(from: amount, to: columnHeader, in: result))
        XCTAssertTrue(hasHeaderEdge(from: amount, to: rowHeader, in: result))

        let heuristicValue = try cell("B2", sheet: "Heuristic", in: result)
        let heuristicHeader = try cell("B1", sheet: "Heuristic", in: result)
        XCTAssertTrue(hasHeaderEdge(from: heuristicValue, to: heuristicHeader, in: result))
    }

    private func extract(entries: [String: String]) async throws -> ExtractionResult {
        let url = tempDirectory.appendingPathComponent("fixture.xlsx")
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        var packageEntries = entries
        packageEntries["[Content_Types].xml"] = """
          <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          </Types>
        """
        for (path, contents) in packageEntries.sorted(by: { $0.key < $1.key }) {
            let data = Data(contents.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<(start + size))
            }
        }
        return try await SpreadsheetExtractor().extract(fileURL: url)
    }

    private func workbook(_ sheets: [(name: String, state: String, relationshipID: String)]) -> String {
        let sheetXML = sheets.enumerated().map { index, sheet in
            "<sheet name=\"\(sheet.name)\" sheetId=\"\(index + 1)\" state=\"\(sheet.state)\" r:id=\"\(sheet.relationshipID)\"/>"
        }.joined()
        return """
          <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheetXML)</sheets></workbook>
        """
    }

    private func relationships(_ values: [(id: String, target: String, type: String)]) -> String {
        let xml = values.map { value in
            "<Relationship Id=\"\(value.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(value.type)\" Target=\"\(value.target)\"/>"
        }.joined()
        return "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(xml)</Relationships>"
    }

    private func worksheet(_ body: String) -> String {
        "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\(body)</worksheet>"
    }

    private func cell(_ ref: String, sheet: String, in result: ExtractionResult) throws -> ExtractedStructureNode {
        try XCTUnwrap(result.structure.nodes.first { node in
            guard node.kind == .cellRange else { return false }
            let values = payload(node)
            return values["semanticKind"] as? String == "cell"
                && values["cellRef"] as? String == ref
                && values["sheetName"] as? String == sheet
        }, "missing cell node \(sheet)!\(ref)")
    }

    private func visibleCellValues(in result: ExtractionResult) -> [String] {
        result.structure.nodes.compactMap { node in
            guard node.kind == .cellRange,
                  payload(node)["semanticKind"] as? String == "cell",
                  payload(node)["hidden"] as? Bool != true else { return nil }
            return resolvedText(node, in: result)
        }
    }

    private func hasHeaderEdge(
        from node: ExtractedStructureNode,
        to header: ExtractedStructureNode,
        in result: ExtractionResult
    ) -> Bool {
        result.structure.edges.contains {
            $0.kind == .headerFor && $0.fromNodeKey == node.nodeKey && $0.toNodeKey == header.nodeKey
        }
    }

    private func resolvedText(_ node: ExtractedStructureNode, in result: ExtractionResult) -> String? {
        if let textContent = node.textContent { return textContent }
        guard result.parts.indices.contains(node.partIndex),
              let start = node.charStart,
              let end = node.charEnd else { return nil }
        let text = result.parts[node.partIndex].text
        guard start >= 0, end >= start, end <= text.count else { return nil }
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(text.startIndex, offsetBy: end)
        return String(text[lower..<upper])
    }

    private func payload(_ node: ExtractedStructureNode) -> [String: Any] {
        guard let json = node.payloadJSON,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}
