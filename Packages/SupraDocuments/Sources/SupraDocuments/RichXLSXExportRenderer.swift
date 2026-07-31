import Foundation
import SupraCore
import ZIPFoundation

enum RichXLSXExportRenderer {
    private enum Cell {
        case number(Int)
        case text(String)
    }

    private struct OutputRow {
        var order: Int
        var type: String
        var headingLevel: Int?
        var content: String
        var sourceIDs: String
    }

    static func render(_ payload: DocumentExportPayload) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
        let outputRows = makeOutputRows(RichExportDocument(payload: payload))
        let sourceRows = payload.sources.map {
            [$0.label, $0.documentName, $0.locator, $0.warnings, $0.excerpt]
        }
        let outputLastRow = max(outputRows.count + 1, 1)
        let sourcesLastRow = max(sourceRows.count + 1, 1)

        let outputSheet = worksheetXML(
            widths: [10, 20, 14, 72, 18],
            headers: ["Order", "Block Type", "Heading Level", "Content", "Source IDs"],
            rows: outputRows.map { row in
                [
                    .number(row.order),
                    .text(row.type),
                    row.headingLevel.map(Cell.number) ?? .text(""),
                    .text(row.content),
                    .text(row.sourceIDs),
                ]
            },
            tableRelationshipID: "rIdTable1"
        )
        let sourcesSheet = worksheetXML(
            widths: [18, 30, 22, 28, 72],
            headers: ["Relationship ID", "Document", "Locator", "Warnings", "Excerpt"],
            rows: sourceRows.map { $0.map(Cell.text) },
            tableRelationshipID: "rIdTable2"
        )
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Output" sheetId="1" r:id="rId1"/><sheet name="Sources" sheetId="2" r:id="rId2"/></sheets></workbook>
        """
        let workbookRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """
        let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/tables/table1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/><Override PartName="/xl/tables/table2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/></Types>
        """

        try addEntry(archive, "[Content_Types].xml", contentTypes)
        try addEntry(archive, "_rels/.rels", rootRelationships)
        try addEntry(archive, "xl/workbook.xml", workbook)
        try addEntry(archive, "xl/_rels/workbook.xml.rels", workbookRelationships)
        try addEntry(archive, "xl/styles.xml", stylesXML)
        try addEntry(archive, "xl/worksheets/sheet1.xml", outputSheet)
        try addEntry(archive, "xl/worksheets/sheet2.xml", sourcesSheet)
        try addEntry(archive, "xl/worksheets/_rels/sheet1.xml.rels", sheetRelationships(table: "../tables/table1.xml", id: "rIdTable1"))
        try addEntry(archive, "xl/worksheets/_rels/sheet2.xml.rels", sheetRelationships(table: "../tables/table2.xml", id: "rIdTable2"))
        try addEntry(archive, "xl/tables/table1.xml", tableXML(
            id: 1,
            name: "OutputTable",
            reference: "A1:E\(outputLastRow)",
            headers: ["Order", "Block Type", "Heading Level", "Content", "Source IDs"]
        ))
        try addEntry(archive, "xl/tables/table2.xml", tableXML(
            id: 2,
            name: "SourcesTable",
            reference: "A1:E\(sourcesLastRow)",
            headers: ["Relationship ID", "Document", "Locator", "Warnings", "Excerpt"]
        ))
        guard let data = archive.data else {
            throw ExtractionError.fileUnreadable("Could not finish XLSX.")
        }
        return data
    }

    private static func makeOutputRows(_ document: RichExportDocument) -> [OutputRow] {
        var rows: [OutputRow] = []
        func append(type: String, level: Int? = nil, content: [RichExportDocument.Inline]) {
            rows.append(OutputRow(
                order: rows.count + 1,
                type: type,
                headingLevel: level,
                content: plainText(content),
                sourceIDs: citationIDs(content).joined(separator: ", ")
            ))
        }

        for block in document.blocks {
            switch block {
            case let .title(content): append(type: "Title", content: content)
            case let .reviewBanner(content):
                if !plainText(content).isEmpty { append(type: "Review Banner", content: content) }
            case let .heading(level, content): append(type: "Heading", level: level, content: content)
            case let .paragraph(content): append(type: "Paragraph", content: content)
            case let .blockQuote(content): append(type: "Block Quote", content: content)
            case let .unorderedList(items):
                for item in items { append(type: "Bullet Item", content: item) }
            case let .orderedList(start, items):
                for (offset, item) in items.enumerated() {
                    append(type: "Ordered Item \(start + offset)", content: item)
                }
            case let .table(table):
                append(type: "Table Header", content: joinedCells(table.headers))
                for row in table.rows {
                    append(type: "Table Row", content: joinedCells(row))
                }
            case .sourceAppendix:
                break
            }
        }
        return rows
    }

    private static func worksheetXML(
        widths: [Double],
        headers: [String],
        rows: [[Cell]],
        tableRelationshipID: String
    ) -> String {
        let columns = widths.enumerated().map { index, width in
            #"<col min="\#(index + 1)" max="\#(index + 1)" width="\#(width)" customWidth="1"/>"#
        }.joined()
        var rowsXML = rowXML(number: 1, cells: headers.map(Cell.text), style: 2)
        for (offset, cells) in rows.enumerated() {
            rowsXML += rowXML(number: offset + 2, cells: cells, style: 1)
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A2" sqref="A2"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/><cols>\(columns)</cols><sheetData>\(rowsXML)</sheetData><autoFilter ref="A1:E\(max(rows.count + 1, 1))"/><tableParts count="1"><tablePart r:id="\(tableRelationshipID)"/></tableParts></worksheet>
        """
    }

    private static func rowXML(number: Int, cells: [Cell], style: Int) -> String {
        let values = cells.enumerated().map { index, cell in
            let reference = "\(columnLetter(index))\(number)"
            switch cell {
            case let .number(value):
                return #"<c r="\#(reference)" s="\#(style)"><v>\#(value)</v></c>"#
            case let .text(value):
                let safe = CSVCellSanitizer.neutralize(value)
                return #"<c r="\#(reference)" s="\#(style)" t="inlineStr"><is><t xml:space="preserve">\#(xmlEscape(safe))</t></is></c>"#
            }
        }.joined()
        return "<row r=\"\(number)\">\(values)</row>"
    }

    private static func tableXML(id: Int, name: String, reference: String, headers: [String]) -> String {
        let columns = headers.enumerated().map { index, header in
            #"<tableColumn id="\#(index + 1)" name="\#(xmlEscape(header))"/>"#
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" id="\(id)" name="\(name)" displayName="\(name)" ref="\(reference)" totalsRowShown="0"><autoFilter ref="\(reference)"/><tableColumns count="\(headers.count)">\(columns)</tableColumns><tableStyleInfo name="TableStyleMedium2" showFirstColumn="0" showLastColumn="0" showRowStripes="1" showColumnStripes="0"/></table>
        """
    }

    private static func sheetRelationships(table: String, id: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="\(id)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/table" Target="\(table)"/></Relationships>
        """
    }

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Aptos"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Aptos"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F4E78"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
    """

    private static func addEntry(_ archive: Archive, _ path: String, _ contents: String) throws {
        let data = Data(contents.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        }
    }

    private static func plainText(_ nodes: [RichExportDocument.Inline]) -> String {
        nodes.map { node in
            switch node {
            case let .text(value), let .emphasis(value), let .strong(value), let .code(value): value
            case let .citation(label): "[\(label)]"
            case let .link(label, destination): "\(label) (\(destination))"
            }
        }.joined()
    }

    private static func joinedCells(_ cells: [[RichExportDocument.Inline]]) -> [RichExportDocument.Inline] {
        var result: [RichExportDocument.Inline] = []
        for (index, cell) in cells.enumerated() {
            if index > 0 { result.append(.text(" | ")) }
            result.append(contentsOf: cell)
        }
        return result
    }

    private static func citationIDs(_ nodes: [RichExportDocument.Inline]) -> [String] {
        var seen: Set<String> = []
        return nodes.compactMap { node in
            guard case let .citation(label) = node, seen.insert(label).inserted else { return nil }
            return label
        }
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func columnLetter(_ index: Int) -> String {
        var n = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters
            n = n / 26 - 1
        } while n >= 0
        return letters
    }
}
