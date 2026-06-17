import Foundation
import SupraCore

/// Extracts visible cell values from `.xlsx` workbooks (plan §3.3): workbook /
/// sheet names, visible cell values, and row/column coordinates. Formulas,
/// hidden sheets/rows, comments, and macros are out of scope. Legacy `.xls` is
/// reported as unsupported rather than silently skipped.
public struct SpreadsheetExtractor: DocumentExtractor {
    public init() {}

    public func extract(fileURL: URL) async throws -> ExtractionResult {
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "xlsx" else {
            throw ExtractionError.unsupportedFormat("Legacy .\(ext) spreadsheets are not supported; convert to .xlsx.")
        }

        let sharedStrings = try Self.loadSharedStrings(fileURL: fileURL)
        let sheets = try Self.loadSheets(fileURL: fileURL)
        let workbookName = fileURL.lastPathComponent

        var parts: [ExtractedPart] = []
        for (index, sheet) in sheets.enumerated() {
            // Resolve each tab to its actual worksheet part via the r:id relationship;
            // fall back to positional sheet{N}.xml only when relationships are absent.
            let sheetPath = sheet.path ?? "xl/worksheets/sheet\(index + 1).xml"
            guard let data = try ZipArchiveReader.entryData(in: fileURL, path: sheetPath) else { continue }
            let cells = Self.parseCells(data: data, sharedStrings: sharedStrings)
            guard !cells.isEmpty else { continue }
            let grid = Self.renderGrid(cells)
            let range = Self.usedRange(cells)
            let header = "\(workbookName) > \(sheet.name)\(range.map { "!\($0)" } ?? "")"
            parts.append(ExtractedPart(
                sourceKind: .spreadsheetCellRange,
                text: "\(header)\n\(grid.text)",
                sheetName: sheet.name,
                cellRange: range
            ))
        }

        if parts.isEmpty {
            parts.append(ExtractedPart(sourceKind: .spreadsheetCellRange, text: workbookName, sheetName: sheets.first?.name))
        }
        return ExtractionResult(parts: parts, method: "xlsx")
    }

    // MARK: - Shared strings

    private static func loadSharedStrings(fileURL: URL) throws -> [String] {
        guard let data = try ZipArchiveReader.entryData(in: fileURL, path: "xl/sharedStrings.xml") else {
            return []
        }
        let collector = SharedStringsCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        return collector.strings
    }

    // MARK: - Sheet names & worksheet resolution

    /// A workbook tab paired with the worksheet part it actually points at. Per
    /// OOXML, the physical filename is the sheet's `r:id` relationship target in
    /// xl/_rels/workbook.xml.rels — NOT the tab order — so reordered or deleted
    /// sheets don't get cell values attributed to the wrong sheet name. `path`
    /// is nil when no relationship resolves, signalling positional fallback.
    private struct SheetRef {
        let name: String
        let path: String?
    }

    private static func loadSheets(fileURL: URL) throws -> [SheetRef] {
        guard let data = try ZipArchiveReader.entryData(in: fileURL, path: "xl/workbook.xml") else {
            return [SheetRef(name: "Sheet1", path: nil)]
        }
        let collector = WorkbookSheetsCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        guard !collector.sheets.isEmpty else {
            return [SheetRef(name: "Sheet1", path: nil)]
        }
        let relationships = try Self.loadWorkbookRelationships(fileURL: fileURL)
        return collector.sheets.map { sheet in
            let path = sheet.relationshipId
                .flatMap { relationships[$0] }
                .map(Self.resolveWorksheetPath)
            return SheetRef(name: sheet.name, path: path)
        }
    }

    /// Parses xl/_rels/workbook.xml.rels into a `[Relationship Id: Target]` map.
    /// Returns an empty map when the rels part is absent (minimal writers),
    /// which makes `loadSheets` fall back to positional worksheet mapping.
    private static func loadWorkbookRelationships(fileURL: URL) throws -> [String: String] {
        guard let data = try ZipArchiveReader.entryData(in: fileURL, path: "xl/_rels/workbook.xml.rels") else {
            return [:]
        }
        let collector = RelationshipsCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        return collector.targetsById
    }

    /// Resolves a relationship Target (e.g. "worksheets/sheet2.xml") to an archive
    /// path. Targets are relative to the workbook part's directory ("xl/"); a
    /// leading "/" means relative to the package root.
    private static func resolveWorksheetPath(_ target: String) -> String {
        if target.hasPrefix("/") {
            return String(target.dropFirst())
        }
        var components = ["xl"]
        for segment in target.split(separator: "/") {
            switch segment {
            case "..": if !components.isEmpty { components.removeLast() }
            case ".": continue
            default: components.append(String(segment))
            }
        }
        return components.joined(separator: "/")
    }

    // MARK: - Cells

    struct Cell {
        let ref: String
        let column: String
        let row: Int
        let columnIndex: Int
        let value: String
    }

    private static func parseCells(data: Data, sharedStrings: [String]) -> [Cell] {
        let collector = SheetCellsCollector(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        return collector.cells
    }

    private static func renderGrid(_ cells: [Cell]) -> (text: String, rows: Int) {
        let byRow = Dictionary(grouping: cells, by: \.row)
        var lines: [String] = []
        for row in byRow.keys.sorted() {
            let rowCells = (byRow[row] ?? []).sorted { $0.columnIndex < $1.columnIndex }
            let line = rowCells.map { "\($0.ref): \($0.value)" }.joined(separator: "\t")
            if !line.isEmpty { lines.append(line) }
        }
        return (lines.joined(separator: "\n"), byRow.count)
    }

    private static func usedRange(_ cells: [Cell]) -> String? {
        guard !cells.isEmpty else { return nil }
        let minCol = cells.min { $0.columnIndex < $1.columnIndex }!
        let maxCol = cells.max { $0.columnIndex < $1.columnIndex }!
        let minRow = cells.map(\.row).min()!
        let maxRow = cells.map(\.row).max()!
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
        let letters = String(ref.prefix { $0.isLetter })
        let digits = String(ref.drop { $0.isLetter })
        guard !letters.isEmpty, let row = Int(digits) else { return nil }
        return (letters, row)
    }
}

// MARK: - SAX collectors

private final class SharedStringsCollector: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var current = ""
    private var capturing = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "si" { current = "" }
        if elementName == "t" { capturing = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { current += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" { capturing = false }
        if elementName == "si" { strings.append(current) }
    }
}

private final class WorkbookSheetsCollector: NSObject, XMLParserDelegate {
    struct Sheet {
        let name: String
        let relationshipId: String?
    }
    private(set) var sheets: [Sheet] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard elementName == "sheet", let name = attributeDict["name"] else { return }
        sheets.append(Sheet(name: name, relationshipId: Self.relationshipId(in: attributeDict)))
    }

    /// The sheet's relationship reference. Parsing is namespace-unaware, so the
    /// attribute key is the literal `r:id`; fall back to any `*:id`/`id` key for
    /// the rare non-`r` prefix, without matching unrelated keys like `sheetId`.
    private static func relationshipId(in attributes: [String: String]) -> String? {
        if let id = attributes["r:id"] { return id }
        return attributes.first { $0.key == "id" || $0.key.hasSuffix(":id") }?.value
    }
}

private final class RelationshipsCollector: NSObject, XMLParserDelegate {
    private(set) var targetsById: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard elementName == "Relationship", let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        targetsById[id] = target
    }
}

private final class SheetCellsCollector: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private(set) var cells: [SpreadsheetExtractor.Cell] = []

    private var currentRef: String?
    private var currentType: String?
    private var inValue = false
    private var inInlineString = false
    private var valueBuffer = ""

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        switch elementName {
        case "c":
            currentRef = attributeDict["r"]
            currentType = attributeDict["t"]
            valueBuffer = ""
        case "v":
            inValue = true
        case "t" where currentRef != nil:
            inInlineString = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue || inInlineString { valueBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v": inValue = false
        case "t": inInlineString = false
        case "c":
            defer { currentRef = nil; currentType = nil; valueBuffer = "" }
            guard let ref = currentRef, let split = SpreadsheetExtractor.splitRef(ref) else { return }
            let raw = valueBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return }
            let resolved: String
            if currentType == "s", let index = Int(raw), index >= 0, index < sharedStrings.count {
                resolved = sharedStrings[index]
            } else {
                resolved = raw
            }
            let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            cells.append(SpreadsheetExtractor.Cell(
                ref: ref,
                column: split.column,
                row: split.row,
                columnIndex: SpreadsheetExtractor.columnIndex(forLetters: split.column),
                value: trimmed
            ))
        default:
            break
        }
    }
}
