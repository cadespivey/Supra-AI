import Foundation
import SupraCore
import ZIPFoundation

/// Extracts `.xlsx` workbooks into the historical flat grid projection plus a
/// revision-mappable structural graph. Hidden evidence remains in the full text
/// but is explicitly flagged so later retrieval can disclose it.
public struct SpreadsheetExtractor: DocumentExtractor {
    private let policy: ImportPolicy

    public init(policy: ImportPolicy = .default) { self.policy = policy }

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "xlsx" else {
            throw ExtractionError.unsupportedFormat("Legacy .\(ext) spreadsheets are not supported; convert to .xlsx.")
        }

        let archive = try ZipArchiveReader.validatedArchive(at: fileURL, policy: policy)
        let sharedStrings = try Self.loadSharedStrings(archive: archive, policy: policy)
        let cellFormats = try Self.loadCellFormats(archive: archive, policy: policy)
        let sheets = try Self.loadSheets(archive: archive, policy: policy)
        let workbookName = fileURL.lastPathComponent
        let macrosPresent = archive["xl/vbaProject.bin"] != nil

        var extractedSheets: [ExtractedSheet] = []
        for (index, sheet) in sheets.enumerated() {
            try Task.checkCancellation()
            let sheetPath = sheet.path ?? "xl/worksheets/sheet\(index + 1).xml"
            guard let data = try ZipArchiveReader.entryData(
                in: archive,
                path: sheetPath,
                policy: policy
            ) else { continue }
            try policy.validateXMLData(data)
            let worksheet = Self.parseWorksheet(
                data: data,
                sharedStrings: sharedStrings,
                cellFormats: cellFormats
            )
            guard !worksheet.cells.isEmpty else { continue }
            let grid = Self.renderGrid(worksheet.cells)
            let range = Self.usedRange(worksheet.cells)
            let header = "\(workbookName) > \(sheet.name)\(range.map { "!\($0)" } ?? "")"
            let part = ExtractedPart(
                sourceKind: .spreadsheetCellRange,
                text: "\(header)\n\(grid)",
                sheetName: sheet.name,
                cellRange: range
            )
            let tables = try Self.loadTables(
                archive: archive,
                worksheetPath: sheetPath,
                relationshipIDs: worksheet.tableRelationshipIDs,
                policy: policy
            )
            extractedSheets.append(ExtractedSheet(
                ref: sheet,
                worksheet: worksheet,
                tables: tables,
                part: part
            ))
        }

        if extractedSheets.isEmpty {
            let part = ExtractedPart(
                sourceKind: .spreadsheetCellRange,
                text: workbookName,
                sheetName: sheets.first?.name
            )
            let result = ExtractionResult(parts: [part], method: "xlsx")
            try policy.validateDecodedText(result.combinedText)
            return result
        }

        let parts = extractedSheets.map(\.part)
        let result = ExtractionResult(
            parts: parts,
            structure: Self.buildStructure(
                sheets: extractedSheets,
                macrosPresent: macrosPresent
            ),
            method: "xlsx"
        )
        try policy.validateDecodedText(result.combinedText)
        return result
    }

    // MARK: - Shared strings and styles

    private static func loadSharedStrings(archive: Archive, policy: ImportPolicy) throws -> [String] {
        guard let data = try ZipArchiveReader.entryData(
            in: archive,
            path: "xl/sharedStrings.xml",
            policy: policy
        ) else { return [] }
        try policy.validateXMLData(data)
        let collector = SharedStringsCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        return collector.strings
    }

    fileprivate struct CellFormats {
        var numberFormatByStyleIndex: [Int]
        var customFormatCodes: [Int: String]

        func numberFormatID(for styleIndex: Int?) -> Int {
            guard let styleIndex else { return 0 }
            return numberFormatByStyleIndex.indices.contains(styleIndex)
                ? numberFormatByStyleIndex[styleIndex]
                : 0
        }

        func inferredNumberType(numberFormatID: Int) -> String {
            if Self.dateFormatIDs.contains(numberFormatID) { return "date_serial" }
            if Self.percentageFormatIDs.contains(numberFormatID) { return "percentage" }
            if let code = customFormatCodes[numberFormatID]?.lowercased() {
                if code.contains("%") { return "percentage" }
                if code.contains("yy") || code.contains("dd") || code.contains("hh") {
                    return "date_serial"
                }
            }
            return "number"
        }

        private static let dateFormatIDs = Set(14...22).union(Set(45...47))
        private static let percentageFormatIDs: Set<Int> = [9, 10]
    }

    private static func loadCellFormats(archive: Archive, policy: ImportPolicy) throws -> CellFormats {
        guard let data = try ZipArchiveReader.entryData(
            in: archive,
            path: "xl/styles.xml",
            policy: policy
        ) else {
            return CellFormats(numberFormatByStyleIndex: [0], customFormatCodes: [:])
        }
        try policy.validateXMLData(data)
        let collector = StylesCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        return CellFormats(
            numberFormatByStyleIndex: collector.numberFormatByStyleIndex.isEmpty
                ? [0]
                : collector.numberFormatByStyleIndex,
            customFormatCodes: collector.customFormatCodes
        )
    }

    // MARK: - Workbook and relationships

    private struct SheetRef {
        let name: String
        let path: String?
        let state: String

        var isHidden: Bool { state != "visible" }
    }

    private static func loadSheets(archive: Archive, policy: ImportPolicy) throws -> [SheetRef] {
        guard let data = try ZipArchiveReader.entryData(
            in: archive,
            path: "xl/workbook.xml",
            policy: policy
        ) else {
            return [SheetRef(name: "Sheet1", path: nil, state: "visible")]
        }
        try policy.validateXMLData(data)
        let collector = WorkbookSheetsCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        guard !collector.sheets.isEmpty else {
            return [SheetRef(name: "Sheet1", path: nil, state: "visible")]
        }
        let relationships = try loadRelationships(
            archive: archive,
            path: "xl/_rels/workbook.xml.rels",
            policy: policy
        )
        return collector.sheets.map { sheet in
            SheetRef(
                name: sheet.name,
                path: sheet.relationshipID
                    .flatMap { relationships[$0] }
                    .map { resolvePartPath($0, relativeTo: "xl/workbook.xml") },
                state: sheet.state
            )
        }
    }

    private static func loadRelationships(
        archive: Archive,
        path: String,
        policy: ImportPolicy
    ) throws -> [String: String] {
        guard let data = try ZipArchiveReader.entryData(in: archive, path: path, policy: policy) else {
            return [:]
        }
        try policy.validateXMLData(data)
        let collector = RelationshipsCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        return collector.targetsByID
    }

    private static func resolvePartPath(_ target: String, relativeTo sourcePart: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var components = sourcePart.split(separator: "/").dropLast().map(String.init)
        for segment in target.split(separator: "/") {
            switch segment {
            case "..": if !components.isEmpty { components.removeLast() }
            case ".": continue
            default: components.append(String(segment))
            }
        }
        return components.joined(separator: "/")
    }

    private static func relationshipsPath(for partPath: String) -> String {
        var components = partPath.split(separator: "/").map(String.init)
        guard let fileName = components.popLast() else { return "_rels/.rels" }
        let directory = components.joined(separator: "/")
        return "\(directory)/_rels/\(fileName).rels"
    }

    // MARK: - Worksheet cells and tables

    struct Cell {
        let ref: String
        let column: String
        let row: Int
        let columnIndex: Int
        let rawValue: String
        let value: String
        let formula: String?
        let sourceType: String?
        let styleIndex: Int?
        let numberFormatID: Int
        let cellType: String
    }

    fileprivate struct ColumnSpan {
        let minimum: Int
        let maximum: Int

        func contains(_ column: Int) -> Bool { (minimum...maximum).contains(column) }
    }

    private struct WorksheetData {
        var cells: [Cell]
        var hiddenRows: Set<Int>
        var hiddenColumns: [ColumnSpan]
        var merges: [String]
        var tableRelationshipIDs: [String]
    }

    fileprivate struct TableDefinition {
        var name: String
        var displayName: String
        var range: String
        var headerRowCount: Int
        var totalsRowCount: Int
        var columnNames: [String]
    }

    private struct ExtractedSheet {
        var ref: SheetRef
        var worksheet: WorksheetData
        var tables: [TableDefinition]
        var part: ExtractedPart
    }

    private static func parseWorksheet(
        data: Data,
        sharedStrings: [String],
        cellFormats: CellFormats
    ) -> WorksheetData {
        let collector = WorksheetCollector(
            sharedStrings: sharedStrings,
            cellFormats: cellFormats
        )
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        return WorksheetData(
            cells: collector.cells,
            hiddenRows: collector.hiddenRows,
            hiddenColumns: collector.hiddenColumns,
            merges: collector.merges,
            tableRelationshipIDs: collector.tableRelationshipIDs
        )
    }

    private static func loadTables(
        archive: Archive,
        worksheetPath: String,
        relationshipIDs: [String],
        policy: ImportPolicy
    ) throws -> [TableDefinition] {
        guard !relationshipIDs.isEmpty else { return [] }
        let relationships = try loadRelationships(
            archive: archive,
            path: relationshipsPath(for: worksheetPath),
            policy: policy
        )
        var tables: [TableDefinition] = []
        for relationshipID in relationshipIDs {
            guard let target = relationships[relationshipID] else { continue }
            let path = resolvePartPath(target, relativeTo: worksheetPath)
            guard let data = try ZipArchiveReader.entryData(in: archive, path: path, policy: policy) else {
                continue
            }
            try policy.validateXMLData(data)
            let collector = TableCollector()
            let parser = XMLParser(data: data)
            parser.delegate = collector
            _ = parser.parse()
            if let table = collector.table { tables.append(table) }
        }
        return tables
    }

    private static func renderGrid(_ cells: [Cell]) -> String {
        let byRow = Dictionary(grouping: cells, by: \.row)
        return byRow.keys.sorted().compactMap { row -> String? in
            let rowCells = (byRow[row] ?? []).sorted { $0.columnIndex < $1.columnIndex }
            let line = rowCells.map { "\($0.ref): \($0.value)" }.joined(separator: "\t")
            return line.isEmpty ? nil : line
        }.joined(separator: "\n")
    }

    private static func usedRange(_ cells: [Cell]) -> String? {
        guard let minCol = cells.min(by: { $0.columnIndex < $1.columnIndex }),
              let maxCol = cells.max(by: { $0.columnIndex < $1.columnIndex }),
              let minRow = cells.map(\.row).min(),
              let maxRow = cells.map(\.row).max() else { return nil }
        return "\(minCol.column)\(minRow):\(maxCol.column)\(maxRow)"
    }

    static func columnIndex(forLetters letters: String) -> Int {
        var index = 0
        for scalar in letters.uppercased().unicodeScalars where scalar.value >= 65 && scalar.value <= 90 {
            index = index * 26 + Int(scalar.value - 64)
        }
        return index
    }

    static func splitRef(_ ref: String) -> (column: String, row: Int)? {
        let normalized = ref.replacingOccurrences(of: "$", with: "")
        let letters = String(normalized.prefix { $0.isLetter })
        let digits = String(normalized.drop { $0.isLetter })
        guard !letters.isEmpty, let row = Int(digits) else { return nil }
        return (letters, row)
    }

    private struct GridRange {
        let minColumn: Int
        let maxColumn: Int
        let minRow: Int
        let maxRow: Int

        func contains(_ cell: Cell) -> Bool {
            (minColumn...maxColumn).contains(cell.columnIndex)
                && (minRow...maxRow).contains(cell.row)
        }
    }

    private static func gridRange(_ value: String) -> GridRange? {
        let endpoints = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = endpoints.first.flatMap(splitRef) else { return nil }
        let second = endpoints.count == 2 ? splitRef(endpoints[1]) : first
        guard let second else { return nil }
        let firstColumn = columnIndex(forLetters: first.column)
        let secondColumn = columnIndex(forLetters: second.column)
        return GridRange(
            minColumn: min(firstColumn, secondColumn),
            maxColumn: max(firstColumn, secondColumn),
            minRow: min(first.row, second.row),
            maxRow: max(first.row, second.row)
        )
    }

    // MARK: - Structure projection

    private static func buildStructure(
        sheets: [ExtractedSheet],
        macrosPresent: Bool
    ) -> ExtractedDocumentStructure {
        var nodes = [ExtractedStructureNode(
            nodeKey: "document",
            partIndex: 0,
            ordinal: 0,
            kind: .document,
            payloadJSON: payloadJSON(["macrosPresent": macrosPresent])
        )]
        var edges: [ExtractedStructureEdge] = []
        var edgeKeys = Set<String>()

        for (partIndex, sheet) in sheets.enumerated() {
            let sheetKey = "xlsx/sheet/\(partIndex)"
            nodes.append(ExtractedStructureNode(
                nodeKey: sheetKey,
                parentNodeKey: "document",
                partIndex: partIndex,
                ordinal: partIndex,
                kind: .sheet,
                payloadJSON: payloadJSON([
                    "sheetName": sheet.ref.name,
                    "state": sheet.ref.state,
                    "hidden": sheet.ref.isHidden,
                    "sourceKind": "sheet",
                    "macrosPresent": macrosPresent,
                ])
            ))

            var tableKeys: [Int: String] = [:]
            for (tableIndex, table) in sheet.tables.enumerated() {
                let key = "\(sheetKey)/table/\(tableIndex)"
                tableKeys[tableIndex] = key
                nodes.append(ExtractedStructureNode(
                    nodeKey: key,
                    parentNodeKey: sheetKey,
                    partIndex: partIndex,
                    ordinal: tableIndex,
                    kind: .table,
                    payloadJSON: payloadJSON([
                        "name": table.name,
                        "displayName": table.displayName,
                        "range": table.range,
                        "headerRowCount": table.headerRowCount,
                        "totalsRowCount": table.totalsRowCount,
                        "columns": table.columnNames,
                    ])
                ))
            }

            for (mergeIndex, merge) in sheet.worksheet.merges.enumerated() {
                nodes.append(ExtractedStructureNode(
                    nodeKey: "\(sheetKey)/merge/\(mergeIndex)",
                    parentNodeKey: sheetKey,
                    partIndex: partIndex,
                    ordinal: sheet.tables.count + mergeIndex,
                    kind: .cellRange,
                    textContent: merge,
                    payloadJSON: payloadJSON([
                        "semanticKind": "merge",
                        "range": merge,
                        "sheetName": sheet.ref.name,
                    ])
                ))
            }

            let ranges = cellTextRanges(in: sheet.part.text, cells: sheet.worksheet.cells)
            var nodeKeyByRef: [String: String] = [:]
            for (cellIndex, cell) in sheet.worksheet.cells.enumerated() {
                let key = "\(sheetKey)/cell/\(cell.ref)"
                nodeKeyByRef[cell.ref] = key
                let tableIndex = sheet.tables.firstIndex { table in
                    gridRange(table.range)?.contains(cell) == true
                }
                let parentKey = tableIndex.flatMap { tableKeys[$0] } ?? sheetKey
                var hiddenSources: [String] = []
                if sheet.ref.isHidden { hiddenSources.append("sheet") }
                if sheet.worksheet.hiddenRows.contains(cell.row) { hiddenSources.append("row") }
                if sheet.worksheet.hiddenColumns.contains(where: { $0.contains(cell.columnIndex) }) {
                    hiddenSources.append("column")
                }
                var payload: [String: Any] = [
                    "semanticKind": "cell",
                    "sourceKind": "spreadsheet_cell",
                    "sheetName": sheet.ref.name,
                    "cellRef": cell.ref,
                    "column": cell.column,
                    "columnIndex": cell.columnIndex,
                    "row": cell.row,
                    "rawValue": cell.rawValue,
                    "displayValue": cell.value,
                    "cellType": cell.cellType,
                    "sourceType": cell.sourceType ?? "n",
                    "styleIndex": cell.styleIndex ?? 0,
                    "numberFormatId": cell.numberFormatID,
                    "hidden": !hiddenSources.isEmpty,
                    "hiddenSources": hiddenSources,
                ]
                if let formula = cell.formula {
                    payload["formula"] = formula
                    payload["cachedValue"] = cell.rawValue
                }
                let range = ranges[cell.ref]
                nodes.append(ExtractedStructureNode(
                    nodeKey: key,
                    parentNodeKey: parentKey,
                    partIndex: partIndex,
                    ordinal: cellIndex,
                    kind: .cellRange,
                    charStart: range?.lowerBound,
                    charEnd: range?.upperBound,
                    payloadJSON: payloadJSON(payload)
                ))
            }

            func appendHeaderEdge(from cell: Cell, to header: Cell?) {
                guard let header,
                      let fromKey = nodeKeyByRef[cell.ref],
                      let toKey = nodeKeyByRef[header.ref],
                      fromKey != toKey else { return }
                let identity = "\(fromKey)->\(toKey)"
                guard edgeKeys.insert(identity).inserted else { return }
                edges.append(ExtractedStructureEdge(
                    fromNodeKey: fromKey,
                    toNodeKey: toKey,
                    kind: .headerFor
                ))
            }

            if sheet.tables.isEmpty {
                addHeuristicHeaderEdges(
                    cells: sheet.worksheet.cells,
                    merges: sheet.worksheet.merges,
                    append: appendHeaderEdge
                )
            } else {
                for table in sheet.tables {
                    guard let range = gridRange(table.range), table.headerRowCount > 0 else { continue }
                    let tableCells = sheet.worksheet.cells.filter(range.contains)
                    for cell in tableCells where cell.row > range.minRow {
                        appendHeaderEdge(
                            from: cell,
                            to: headerCell(
                                column: cell.columnIndex,
                                row: range.minRow,
                                cells: tableCells,
                                merges: sheet.worksheet.merges
                            )
                        )
                        if cell.columnIndex > range.minColumn {
                            appendHeaderEdge(
                                from: cell,
                                to: tableCells.first {
                                    $0.row == cell.row && $0.columnIndex == range.minColumn
                                }
                            )
                        }
                    }
                }
            }
        }
        return ExtractedDocumentStructure(nodes: nodes, edges: edges)
    }

    private static func addHeuristicHeaderEdges(
        cells: [Cell],
        merges: [String],
        append: (Cell, Cell?) -> Void
    ) {
        guard let minRow = cells.map(\.row).min(),
              let maxRow = cells.map(\.row).max(),
              let minColumn = cells.map(\.columnIndex).min(),
              let maxColumn = cells.map(\.columnIndex).max(),
              minRow < maxRow,
              minColumn < maxColumn else { return }
        for cell in cells where cell.row > minRow {
            append(
                cell,
                headerCell(column: cell.columnIndex, row: minRow, cells: cells, merges: merges)
            )
            if cell.columnIndex > minColumn {
                append(cell, cells.first { $0.row == cell.row && $0.columnIndex == minColumn })
            }
        }
    }

    private static func headerCell(
        column: Int,
        row: Int,
        cells: [Cell],
        merges: [String]
    ) -> Cell? {
        if let direct = cells.first(where: { $0.row == row && $0.columnIndex == column }) {
            return direct
        }
        for merge in merges {
            guard let range = gridRange(merge),
                  range.minRow == row,
                  range.minRow == range.maxRow,
                  (range.minColumn...range.maxColumn).contains(column) else { continue }
            return cells.first {
                $0.row == range.minRow && $0.columnIndex == range.minColumn
            }
        }
        return nil
    }

    private static func cellTextRanges(in text: String, cells: [Cell]) -> [String: Range<Int>] {
        let ordered = cells.sorted {
            $0.row == $1.row ? $0.columnIndex < $1.columnIndex : $0.row < $1.row
        }
        var cursor = text.startIndex
        var result: [String: Range<Int>] = [:]
        for cell in ordered {
            let prefix = "\(cell.ref): "
            let token = prefix + cell.value
            guard let match = text.range(of: token, range: cursor..<text.endIndex) else { continue }
            let valueStart = text.index(match.lowerBound, offsetBy: prefix.count)
            let lower = text.distance(from: text.startIndex, to: valueStart)
            let upper = text.distance(from: text.startIndex, to: match.upperBound)
            result[cell.ref] = lower..<upper
            cursor = match.upperBound
        }
        return result
    }

    private static func payloadJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - SAX collectors

private final class SharedStringsCollector: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var current = ""
    private var capturing = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if elementName == "si" { current = "" }
        if elementName == "t" { capturing = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { current += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "t" { capturing = false }
        if elementName == "si" { strings.append(current) }
    }
}

private final class StylesCollector: NSObject, XMLParserDelegate {
    private(set) var numberFormatByStyleIndex: [Int] = []
    private(set) var customFormatCodes: [Int: String] = [:]
    private var inCellFormats = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if elementName == "numFmt",
           let id = attributeDict["numFmtId"].flatMap(Int.init),
           let code = attributeDict["formatCode"] {
            customFormatCodes[id] = code
        } else if elementName == "cellXfs" {
            inCellFormats = true
        } else if elementName == "xf", inCellFormats {
            numberFormatByStyleIndex.append(attributeDict["numFmtId"].flatMap(Int.init) ?? 0)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "cellXfs" { inCellFormats = false }
    }
}

private final class WorkbookSheetsCollector: NSObject, XMLParserDelegate {
    struct Sheet {
        let name: String
        let relationshipID: String?
        let state: String
    }

    private(set) var sheets: [Sheet] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard elementName == "sheet", let name = attributeDict["name"] else { return }
        sheets.append(Sheet(
            name: name,
            relationshipID: relationshipID(in: attributeDict),
            state: attributeDict["state"] ?? "visible"
        ))
    }
}

private final class RelationshipsCollector: NSObject, XMLParserDelegate {
    private(set) var targetsByID: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard elementName == "Relationship",
              let id = attributeDict["Id"],
              let target = attributeDict["Target"] else { return }
        targetsByID[id] = target
    }
}

private final class WorksheetCollector: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private let cellFormats: SpreadsheetExtractor.CellFormats

    private(set) var cells: [SpreadsheetExtractor.Cell] = []
    private(set) var hiddenRows = Set<Int>()
    private(set) var hiddenColumns: [SpreadsheetExtractor.ColumnSpan] = []
    private(set) var merges: [String] = []
    private(set) var tableRelationshipIDs: [String] = []

    private var currentRef: String?
    private var currentType: String?
    private var currentStyleIndex: Int?
    private var valueBuffer = ""
    private var inlineStringBuffer = ""
    private var formulaBuffer = ""
    private var inValue = false
    private var inInlineString = false
    private var inFormula = false

    init(sharedStrings: [String], cellFormats: SpreadsheetExtractor.CellFormats) {
        self.sharedStrings = sharedStrings
        self.cellFormats = cellFormats
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch elementName {
        case "row":
            if hidden(attributeDict["hidden"]), let row = attributeDict["r"].flatMap(Int.init) {
                hiddenRows.insert(row)
            }
        case "col":
            if hidden(attributeDict["hidden"]),
               let minimum = attributeDict["min"].flatMap(Int.init),
               let maximum = attributeDict["max"].flatMap(Int.init) {
                hiddenColumns.append(.init(minimum: minimum, maximum: maximum))
            }
        case "mergeCell":
            if let ref = attributeDict["ref"] { merges.append(ref) }
        case "tablePart":
            if let id = relationshipID(in: attributeDict) { tableRelationshipIDs.append(id) }
        case "c":
            currentRef = attributeDict["r"]
            currentType = attributeDict["t"]
            currentStyleIndex = attributeDict["s"].flatMap(Int.init)
            valueBuffer = ""
            inlineStringBuffer = ""
            formulaBuffer = ""
        case "v": inValue = true
        case "t" where currentRef != nil: inInlineString = true
        case "f": inFormula = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { valueBuffer += string }
        if inInlineString { inlineStringBuffer += string }
        if inFormula { formulaBuffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "v": inValue = false
        case "t": inInlineString = false
        case "f": inFormula = false
        case "c": finishCell()
        default: break
        }
    }

    private func finishCell() {
        defer {
            currentRef = nil
            currentType = nil
            currentStyleIndex = nil
            valueBuffer = ""
            inlineStringBuffer = ""
            formulaBuffer = ""
        }
        guard let ref = currentRef, let split = SpreadsheetExtractor.splitRef(ref) else { return }
        let raw = (currentType == "inlineStr" ? inlineStringBuffer : valueBuffer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String
        if currentType == "s", let index = Int(raw), sharedStrings.indices.contains(index) {
            resolved = sharedStrings[index]
        } else {
            resolved = raw
        }
        let value = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let formulaText = formulaBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let formula = formulaText.isEmpty
            ? nil
            : (formulaText.hasPrefix("=") ? formulaText : "=\(formulaText)")
        let numberFormatID = cellFormats.numberFormatID(for: currentStyleIndex)
        let cellType: String
        if formula != nil {
            cellType = "formula"
        } else {
            switch currentType {
            case "s", "inlineStr", "str": cellType = "string"
            case "b": cellType = "boolean"
            case "e": cellType = "error"
            case "d": cellType = "date"
            default: cellType = cellFormats.inferredNumberType(numberFormatID: numberFormatID)
            }
        }
        cells.append(SpreadsheetExtractor.Cell(
            ref: ref,
            column: split.column,
            row: split.row,
            columnIndex: SpreadsheetExtractor.columnIndex(forLetters: split.column),
            rawValue: raw,
            value: value,
            formula: formula,
            sourceType: currentType,
            styleIndex: currentStyleIndex,
            numberFormatID: numberFormatID,
            cellType: cellType
        ))
    }
}

private final class TableCollector: NSObject, XMLParserDelegate {
    private(set) var table: SpreadsheetExtractor.TableDefinition?
    private var name = ""
    private var displayName = ""
    private var range = ""
    private var headerRowCount = 1
    private var totalsRowCount = 0
    private var columnNames: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if elementName == "table" {
            name = attributeDict["name"] ?? attributeDict["displayName"] ?? "Table"
            displayName = attributeDict["displayName"] ?? name
            range = attributeDict["ref"] ?? ""
            headerRowCount = attributeDict["headerRowCount"].flatMap(Int.init) ?? 1
            totalsRowCount = attributeDict["totalsRowCount"].flatMap(Int.init) ?? 0
        } else if elementName == "tableColumn", let columnName = attributeDict["name"] {
            columnNames.append(columnName)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "table", !range.isEmpty {
            table = SpreadsheetExtractor.TableDefinition(
                name: name,
                displayName: displayName,
                range: range,
                headerRowCount: headerRowCount,
                totalsRowCount: totalsRowCount,
                columnNames: columnNames
            )
        }
    }
}

private func relationshipID(in attributes: [String: String]) -> String? {
    if let id = attributes["r:id"] { return id }
    return attributes.first { $0.key == "id" || $0.key.hasSuffix(":id") }?.value
}

private func hidden(_ value: String?) -> Bool {
    value == "1" || value?.lowercased() == "true"
}
