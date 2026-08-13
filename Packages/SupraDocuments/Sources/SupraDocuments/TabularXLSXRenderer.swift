import Foundation
import SupraCore
import ZIPFoundation

/// A format-neutral, rectangular workbook description for deterministic local
/// spreadsheet exports. Text is always emitted as formula-safe inline strings;
/// numeric and date values remain typed spreadsheet cells.
public struct TabularXLSXWorkbook: Sendable, Equatable {
    public struct Column: Sendable, Equatable {
        public let header: String
        public let width: Double

        public init(header: String, width: Double) {
            self.header = header
            self.width = width
        }
    }

    public enum TextStyle: Sendable, Equatable {
        case body
        case positive
        case information
        case attention
        case danger
        case muted
    }

    public enum Cell: Sendable, Equatable {
        case text(String, style: TextStyle = .body)
        case integer(Int)
        case dateTime(Date)
    }

    public struct Sheet: Sendable, Equatable {
        public let name: String
        public let tableName: String
        public let columns: [Column]
        public let rows: [[Cell]]
        public let freezeRows: Int
        public let freezeColumns: Int
        public let showsGridLines: Bool
        public let hasAutoFilter: Bool

        public init(
            name: String,
            tableName: String,
            columns: [Column],
            rows: [[Cell]],
            freezeRows: Int,
            freezeColumns: Int,
            showsGridLines: Bool,
            hasAutoFilter: Bool
        ) {
            self.name = name
            self.tableName = tableName
            self.columns = columns
            self.rows = rows
            self.freezeRows = freezeRows
            self.freezeColumns = freezeColumns
            self.showsGridLines = showsGridLines
            self.hasAutoFilter = hasAutoFilter
        }
    }

    public let sheets: [Sheet]

    public init(sheets: [Sheet]) {
        self.sheets = sheets
    }
}

public enum TabularXLSXRenderer {
    public enum RenderError: Error, LocalizedError, Equatable, Sendable {
        case emptyWorkbook
        case invalidSheetName(String)
        case duplicateSheetName(String)
        case invalidTableName(String)
        case duplicateTableName(String)
        case invalidColumnCount(sheet: String)
        case invalidColumnHeader(sheet: String, column: Int)
        case duplicateColumnHeader(sheet: String, header: String)
        case invalidColumnWidth(sheet: String, column: Int)
        case invalidFreezePane(sheet: String)
        case inconsistentRow(sheet: String, row: Int, expected: Int, actual: Int)
        case invalidCellText(sheet: String, row: Int, column: Int)
        case invalidDate(sheet: String, row: Int, column: Int)
        case archiveUnavailable

        public var errorDescription: String? {
            switch self {
            case .emptyWorkbook:
                "The workbook must contain at least one worksheet."
            case let .invalidSheetName(name):
                "The worksheet name is invalid: \(name)"
            case let .duplicateSheetName(name):
                "The worksheet name is duplicated: \(name)"
            case let .invalidTableName(name):
                "The table name is invalid: \(name)"
            case let .duplicateTableName(name):
                "The table name is duplicated: \(name)"
            case let .invalidColumnCount(sheet):
                "Worksheet \(sheet) exceeds the supported spreadsheet row or column limits."
            case let .invalidColumnHeader(sheet, column):
                "Worksheet \(sheet) has a header in column \(column) with unsupported text or more than 32,767 spreadsheet characters."
            case let .duplicateColumnHeader(sheet, header):
                "Worksheet \(sheet) has a duplicated header: \(header)"
            case let .invalidColumnWidth(sheet, column):
                "Worksheet \(sheet) has an invalid width in column \(column)."
            case let .invalidFreezePane(sheet):
                "Worksheet \(sheet) has an invalid freeze pane."
            case let .inconsistentRow(sheet, row, expected, actual):
                "Worksheet \(sheet) row \(row) has \(actual) cells; expected \(expected)."
            case let .invalidCellText(sheet, row, column):
                "Worksheet \(sheet) row \(row), column \(column) contains unsupported text or exceeds the 32,767-character spreadsheet cell limit."
            case let .invalidDate(sheet, row, column):
                "Worksheet \(sheet) row \(row), column \(column) contains an invalid date."
            case .archiveUnavailable:
                "The XLSX archive could not be completed."
            }
        }
    }

    private enum CellStyle: Int {
        case body = 1
        case header = 2
        case integer = 3
        case dateTime = 4
        case positive = 5
        case information = 6
        case attention = 7
        case danger = 8
        case muted = 9
    }

    private static let fixedEntryDate = Date(timeIntervalSince1970: 315_532_800)
    private static let maximumColumns = 16_384
    private static let maximumDataRows = 1_048_575
    private static let maximumCellCharacters = 32_767

    public static func render(_ workbook: TabularXLSXWorkbook) throws -> Data {
        try validate(workbook)

        let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
        let sheetCount = workbook.sheets.count
        try addEntry(archive, path: "[Content_Types].xml", text: contentTypes(sheetCount: sheetCount))
        try addEntry(archive, path: "_rels/.rels", text: rootRelationships)
        try addEntry(archive, path: "xl/workbook.xml", text: workbookXML(workbook.sheets))
        try addEntry(
            archive,
            path: "xl/_rels/workbook.xml.rels",
            text: workbookRelationships(sheetCount: sheetCount)
        )
        try addEntry(archive, path: "xl/styles.xml", text: stylesXML)

        for (index, sheet) in workbook.sheets.enumerated() {
            let number = index + 1
            try addEntry(
                archive,
                path: "xl/worksheets/sheet\(number).xml",
                text: worksheetXML(sheet, number: number)
            )
        }
        for index in workbook.sheets.indices {
            let number = index + 1
            try addEntry(
                archive,
                path: "xl/worksheets/_rels/sheet\(number).xml.rels",
                text: sheetRelationships(number: number)
            )
        }
        for (index, sheet) in workbook.sheets.enumerated() {
            let number = index + 1
            try addEntry(
                archive,
                path: "xl/tables/table\(number).xml",
                text: tableXML(sheet, number: number)
            )
        }

        guard let data = archive.data else { throw RenderError.archiveUnavailable }
        return data
    }

    private static func validate(_ workbook: TabularXLSXWorkbook) throws {
        guard !workbook.sheets.isEmpty else { throw RenderError.emptyWorkbook }

        var sheetNames = Set<String>()
        var tableNames = Set<String>()
        for sheet in workbook.sheets {
            guard isValidSheetName(sheet.name) else {
                throw RenderError.invalidSheetName(sheet.name)
            }
            guard sheetNames.insert(foldedIdentifier(sheet.name)).inserted else {
                throw RenderError.duplicateSheetName(sheet.name)
            }
            guard isValidTableName(sheet.tableName) else {
                throw RenderError.invalidTableName(sheet.tableName)
            }
            guard tableNames.insert(foldedIdentifier(sheet.tableName)).inserted else {
                throw RenderError.duplicateTableName(sheet.tableName)
            }
            guard (1...maximumColumns).contains(sheet.columns.count),
                  sheet.rows.count <= maximumDataRows else {
                throw RenderError.invalidColumnCount(sheet: sheet.name)
            }
            guard sheet.freezeRows >= 0,
                  sheet.freezeRows <= sheet.rows.count + 1,
                  sheet.freezeColumns >= 0,
                  sheet.freezeColumns <= sheet.columns.count else {
                throw RenderError.invalidFreezePane(sheet: sheet.name)
            }

            var headers = Set<String>()
            for (columnIndex, column) in sheet.columns.enumerated() {
                guard !column.header.isEmpty,
                      let safeHeader = validatedSpreadsheetText(column.header) else {
                    throw RenderError.invalidColumnHeader(
                        sheet: sheet.name,
                        column: columnIndex + 1
                    )
                }
                guard headers.insert(foldedIdentifier(safeHeader)).inserted else {
                    throw RenderError.duplicateColumnHeader(
                        sheet: sheet.name,
                        header: safeHeader
                    )
                }
                guard column.width.isFinite, column.width > 0, column.width <= 255 else {
                    throw RenderError.invalidColumnWidth(
                        sheet: sheet.name,
                        column: columnIndex + 1
                    )
                }
            }

            for (rowIndex, row) in sheet.rows.enumerated() {
                guard row.count == sheet.columns.count else {
                    throw RenderError.inconsistentRow(
                        sheet: sheet.name,
                        row: rowIndex + 2,
                        expected: sheet.columns.count,
                        actual: row.count
                    )
                }
                for (columnIndex, cell) in row.enumerated() {
                    switch cell {
                    case let .text(value, _):
                        guard validatedSpreadsheetText(value) != nil else {
                            throw RenderError.invalidCellText(
                                sheet: sheet.name,
                                row: rowIndex + 2,
                                column: columnIndex + 1
                            )
                        }
                    case .integer:
                        break
                    case let .dateTime(date):
                        guard date.timeIntervalSinceReferenceDate.isFinite else {
                            throw RenderError.invalidDate(
                                sheet: sheet.name,
                                row: rowIndex + 2,
                                column: columnIndex + 1
                            )
                        }
                    }
                }
            }
        }
    }

    private static func isValidSheetName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 31, isValidXMLText(name),
              name.first != "'", name.last != "'" else { return false }
        return !name.contains { "[]:*?/\\".contains($0) }
    }

    private static func isValidTableName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255, isValidXMLText(name),
              !name.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              let first = name.unicodeScalars.first,
              isASCIILetter(first) || first == "_" || first == "\\" else { return false }
        guard name.unicodeScalars.dropFirst().allSatisfy({ scalar in
            isASCIILetter(scalar) || isASCIIDigit(scalar) || scalar == "_" || scalar == "."
        }) else { return false }
        let folded = foldedIdentifier(name)
        guard folded != "r", folded != "c", !isA1Reference(name), !isR1C1Reference(name) else {
            return false
        }
        return true
    }

    private static func isA1Reference(_ value: String) -> Bool {
        let scalars = Array(value.uppercased().unicodeScalars)
        let letters = scalars.prefix { isASCIILetter($0) }
        let digits = scalars.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy(isASCIIDigit),
              digits.first != "0", let row = Int(String(String.UnicodeScalarView(digits))),
              row <= 1_048_576 else { return false }
        var column = 0
        for scalar in letters {
            column = column * 26 + Int(scalar.value - 64)
            if column > maximumColumns { return false }
        }
        return true
    }

    private static func isR1C1Reference(_ value: String) -> Bool {
        let upper = value.uppercased()
        guard upper.first == "R", let cIndex = upper.dropFirst().firstIndex(of: "C") else {
            return false
        }
        let row = upper[upper.index(after: upper.startIndex)..<cIndex]
        let column = upper[upper.index(after: cIndex)...]
        return !row.isEmpty && !column.isEmpty
            && row.allSatisfy(\.isNumber) && column.allSatisfy(\.isNumber)
            && row.first != "0" && column.first != "0"
    }

    private static func isValidXMLText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D, 0x20...0xD7FF, 0xE000...0xFFFD:
                return scalar.value & 0xFFFF != 0xFFFE && scalar.value & 0xFFFF != 0xFFFF
            case 0x10000...0x10FFFF:
                return scalar.value & 0xFFFF != 0xFFFE && scalar.value & 0xFFFF != 0xFFFF
            default:
                return false
            }
        }
    }

    private static func validatedSpreadsheetText(_ value: String) -> String? {
        let safe = CSVCellSanitizer.neutralize(value)
        guard safe.utf16.count <= maximumCellCharacters, isValidXMLText(safe) else {
            return nil
        }
        return safe
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
    }

    private static func foldedIdentifier(_ value: String) -> String {
        value.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func contentTypes(sheetCount: Int) -> String {
        let worksheets = (1...sheetCount).map { number in
            #"<Override PartName="/xl/worksheets/sheet\#(number).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }.joined()
        let tables = (1...sheetCount).map { number in
            #"<Override PartName="/xl/tables/table\#(number).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/>"#
        }.joined()
        return xmlDeclaration
            + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"#
            + worksheets + tables + "</Types>"
    }

    private static let rootRelationships = xmlDeclaration
        + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#

    private static func workbookXML(_ sheets: [TabularXLSXWorkbook.Sheet]) -> String {
        let sheetXML = sheets.enumerated().map { index, sheet in
            #"<sheet name="\#(xmlEscape(sheet.name))" sheetId="\#(index + 1)" r:id="rId\#(index + 1)"/>"#
        }.joined()
        return xmlDeclaration
            + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"#
            + sheetXML + "</sheets></workbook>"
    }

    private static func workbookRelationships(sheetCount: Int) -> String {
        let sheets = (1...sheetCount).map { number in
            #"<Relationship Id="rId\#(number)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(number).xml"/>"#
        }.joined()
        return xmlDeclaration
            + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + sheets
            + #"<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#
    }

    private static func worksheetXML(
        _ sheet: TabularXLSXWorkbook.Sheet,
        number: Int
    ) -> String {
        let lastRow = sheet.rows.count + 1
        let reference = "A1:\(columnName(sheet.columns.count - 1))\(lastRow)"
        let widths = sheet.columns.enumerated().map { index, column in
            #"<col min="\#(index + 1)" max="\#(index + 1)" width="\#(decimal(column.width))" customWidth="1"/>"#
        }.joined()
        var rows = [rowXML(
            number: 1,
            cells: sheet.columns.map { .text($0.header, style: .body) },
            forcedStyle: .header
        )]
        rows.reserveCapacity(sheet.rows.count + 1)
        for (index, cells) in sheet.rows.enumerated() {
            rows.append(rowXML(number: index + 2, cells: cells, forcedStyle: nil))
        }
        let autoFilter = sheet.hasAutoFilter ? #"<autoFilter ref="\#(reference)"/>"# : ""
        return xmlDeclaration
            + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
            + sheetViewsXML(sheet)
            + #"<sheetFormatPr defaultRowHeight="15"/><cols>"# + widths + "</cols>"
            + "<sheetData>" + rows.joined() + "</sheetData>"
            + autoFilter
            + #"<tableParts count="1"><tablePart r:id="rIdTable\#(number)"/></tableParts></worksheet>"#
    }

    private static func sheetViewsXML(_ sheet: TabularXLSXWorkbook.Sheet) -> String {
        let gridLines = sheet.showsGridLines ? "1" : "0"
        guard sheet.freezeRows > 0 || sheet.freezeColumns > 0 else {
            return #"<sheetViews><sheetView workbookViewId="0" showGridLines="\#(gridLines)"/></sheetViews>"#
        }
        var paneAttributes: [String] = []
        if sheet.freezeColumns > 0 { paneAttributes.append(#"xSplit="\#(sheet.freezeColumns)""#) }
        if sheet.freezeRows > 0 { paneAttributes.append(#"ySplit="\#(sheet.freezeRows)""#) }
        let topLeft = "\(columnName(sheet.freezeColumns))\(sheet.freezeRows + 1)"
        let activePane: String
        if sheet.freezeColumns > 0, sheet.freezeRows > 0 {
            activePane = "bottomRight"
        } else if sheet.freezeColumns > 0 {
            activePane = "topRight"
        } else {
            activePane = "bottomLeft"
        }
        paneAttributes.append(#"topLeftCell="\#(topLeft)""#)
        paneAttributes.append(#"activePane="\#(activePane)""#)
        paneAttributes.append(#"state="frozen""#)
        return #"<sheetViews><sheetView workbookViewId="0" showGridLines="\#(gridLines)"><pane \#(paneAttributes.joined(separator: " "))/><selection pane="\#(activePane)" activeCell="\#(topLeft)" sqref="\#(topLeft)"/></sheetView></sheetViews>"#
    }

    private static func rowXML(
        number: Int,
        cells: [TabularXLSXWorkbook.Cell],
        forcedStyle: CellStyle?
    ) -> String {
        let values = cells.enumerated().map { column, cell in
            let reference = "\(columnName(column))\(number)"
            switch cell {
            case let .text(value, style):
                let cellStyle = forcedStyle ?? styleIndex(for: style)
                let safe = CSVCellSanitizer.neutralize(value)
                return #"<c r="\#(reference)" s="\#(cellStyle.rawValue)" t="inlineStr"><is><t xml:space="preserve">\#(xmlEscape(safe))</t></is></c>"#
            case let .integer(value):
                let cellStyle = forcedStyle ?? .integer
                return #"<c r="\#(reference)" s="\#(cellStyle.rawValue)"><v>\#(value)</v></c>"#
            case let .dateTime(date):
                let cellStyle = forcedStyle ?? .dateTime
                return #"<c r="\#(reference)" s="\#(cellStyle.rawValue)"><v>\#(excelDateSerial(date))</v></c>"#
            }
        }.joined()
        return #"<row r="\#(number)">\#(values)</row>"#
    }

    private static func styleIndex(for style: TabularXLSXWorkbook.TextStyle) -> CellStyle {
        switch style {
        case .body: .body
        case .positive: .positive
        case .information: .information
        case .attention: .attention
        case .danger: .danger
        case .muted: .muted
        }
    }

    private static func sheetRelationships(number: Int) -> String {
        xmlDeclaration
            + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdTable\#(number)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/table" Target="../tables/table\#(number).xml"/></Relationships>"#
    }

    private static func tableXML(_ sheet: TabularXLSXWorkbook.Sheet, number: Int) -> String {
        let reference = "A1:\(columnName(sheet.columns.count - 1))\(sheet.rows.count + 1)"
        let autoFilter = sheet.hasAutoFilter ? #"<autoFilter ref="\#(reference)"/>"# : ""
        let columns = sheet.columns.enumerated().map { index, column in
            let safe = CSVCellSanitizer.neutralize(column.header)
            return #"<tableColumn id="\#(index + 1)" name="\#(xmlEscape(safe))"/>"#
        }.joined()
        return xmlDeclaration
            + #"<table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" id="\#(number)" name="\#(xmlEscape(sheet.tableName))" displayName="\#(xmlEscape(sheet.tableName))" ref="\#(reference)" totalsRowShown="0">"#
            + autoFilter
            + #"<tableColumns count="\#(sheet.columns.count)">"#
            + columns
            + #"</tableColumns><tableStyleInfo name="TableStyleMedium2" showFirstColumn="0" showLastColumn="0" showRowStripes="1" showColumnStripes="0"/></table>"#
    }

    private static let stylesXML = xmlDeclaration + """
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy-mm-dd&quot;T&quot;hh:mm:ss&quot;Z&quot;"/></numFmts><fonts count="7"><font><sz val="11"/><name val="Arial"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Arial"/></font><font><color rgb="FF385723"/><sz val="11"/><name val="Arial"/></font><font><color rgb="FF1F4E78"/><sz val="11"/><name val="Arial"/></font><font><color rgb="FF7F6000"/><sz val="11"/><name val="Arial"/></font><font><color rgb="FFC65911"/><sz val="11"/><name val="Arial"/></font><font><color rgb="FF666666"/><sz val="11"/><name val="Arial"/></font></fonts><fills count="8"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F4E78"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFE2F0D9"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDDEBF7"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFCE4D6"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F2"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="10"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf><xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf numFmtId="0" fontId="2" fillId="3" borderId="0" xfId="0" applyFill="1" applyFont="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf numFmtId="0" fontId="3" fillId="4" borderId="0" xfId="0" applyFill="1" applyFont="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf numFmtId="0" fontId="4" fillId="5" borderId="0" xfId="0" applyFill="1" applyFont="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf numFmtId="0" fontId="5" fillId="6" borderId="0" xfId="0" applyFill="1" applyFont="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf numFmtId="0" fontId="6" fillId="7" borderId="0" xfId="0" applyFill="1" applyFont="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
    """

    private static let xmlDeclaration = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#

    private static func addEntry(_ archive: Archive, path: String, text: String) throws {
        let data = Data(text.utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            modificationDate: fixedEntryDate,
            permissions: 0o644,
            compressionMethod: .deflate
        ) { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        }
    }

    private static func excelDateSerial(_ date: Date) -> String {
        decimal(date.timeIntervalSince1970 / 86_400 + 25_569)
    }

    private static func decimal(_ value: Double) -> String {
        return String(value)
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            // Foundation's XMLParser discards a literal U+FEFF in element text.
            // A character reference round-trips the original hostile prefix.
            .replacingOccurrences(of: "\u{FEFF}", with: "&#xFEFF;")
    }

    private static func columnName(_ zeroBasedIndex: Int) -> String {
        var index = zeroBasedIndex
        var result = ""
        repeat {
            let scalar = UnicodeScalar(65 + index % 26)!
            result = String(Character(scalar)) + result
            index = index / 26 - 1
        } while index >= 0
        return result
    }
}
