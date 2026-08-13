import Foundation
@testable import SupraDocuments
import XCTest
import ZIPFoundation

final class TabularXLSXRendererTests: XCTestCase {
    private let fixedEntryDate = Date(timeIntervalSince1970: 315_532_800)
    private let exportedAt = Date(timeIntervalSince1970: 1_786_301_100)

    func testTRPXLSXDOC01RendersDeterministicRelationshipMappedThreeSheetWorkbook() throws {
        // T-RPXLSXDOC01 expected RED: SupraDocuments has no format-neutral
        // tabular workbook model or deterministic XLSX renderer, so Review cannot
        // produce three relationship-mapped, typed, styled, usable worksheets.
        let workbook = TabularXLSXWorkbook(sheets: [
            .init(
                name: "Matrix",
                tableName: "ReviewMatrix",
                columns: [
                    .init(header: "Row", width: 7),
                    .init(header: "Finding", width: 34),
                    .init(header: "Reviewed at (UTC)", width: 24),
                    .init(header: "Review state", width: 16),
                ],
                rows: [
                    [
                        .integer(7),
                        .text("alpha-finding", style: .information),
                        .dateTime(exportedAt),
                        .text("Reviewed", style: .positive),
                    ],
                    [
                        .integer(11),
                        .text("beta-finding", style: .danger),
                        .dateTime(exportedAt.addingTimeInterval(60)),
                        .text("Needs review", style: .attention),
                    ],
                ],
                freezeRows: 1,
                freezeColumns: 2,
                showsGridLines: false,
                hasAutoFilter: true
            ),
            .init(
                name: "Sources",
                tableName: "ReviewSources",
                columns: [
                    .init(header: "Finding row", width: 11),
                    .init(header: "Citation", width: 12),
                    .init(header: "Relationship", width: 14),
                ],
                rows: [[
                    .integer(7),
                    .text("E1"),
                    .text("Supporting", style: .positive),
                ]],
                freezeRows: 1,
                freezeColumns: 2,
                showsGridLines: false,
                hasAutoFilter: true
            ),
            .init(
                name: "Project",
                tableName: "ReviewProject",
                columns: [
                    .init(header: "Field", width: 34),
                    .init(header: "Value", width: 76),
                ],
                rows: [[
                    .text("Exported at (UTC)", style: .muted),
                    .dateTime(exportedAt),
                ]],
                freezeRows: 1,
                freezeColumns: 0,
                showsGridLines: false,
                hasAutoFilter: true
            ),
        ])

        let first = try TabularXLSXRenderer.render(workbook)
        let second = try TabularXLSXRenderer.render(workbook)

        XCTAssertEqual(first, second, "identical workbook input must produce identical XLSX bytes")
        try DocumentExportValidator.validate(first, as: .xlsx)
        let probe = try OOXMLWorkbookProbe(data: first)
        XCTAssertEqual(
            probe.paths.sorted(),
            [
                "[Content_Types].xml",
                "_rels/.rels",
                "xl/workbook.xml",
                "xl/_rels/workbook.xml.rels",
                "xl/styles.xml",
                "xl/worksheets/sheet1.xml",
                "xl/worksheets/sheet2.xml",
                "xl/worksheets/sheet3.xml",
                "xl/worksheets/_rels/sheet1.xml.rels",
                "xl/worksheets/_rels/sheet2.xml.rels",
                "xl/worksheets/_rels/sheet3.xml.rels",
                "xl/tables/table1.xml",
                "xl/tables/table2.xml",
                "xl/tables/table3.xml",
            ].sorted(),
            "the canonical workbook must contain exactly the approved OOXML parts"
        )
        for entry in probe.entries {
            XCTAssertEqual(entry.type, .file)
            XCTAssertEqual(
                entry.fileAttributes[.modificationDate] as? Date,
                fixedEntryDate,
                "ZIP entry timestamps must not read the wall clock"
            )
            XCTAssertEqual(
                (entry.fileAttributes[.posixPermissions] as? NSNumber)?.intValue,
                0o644
            )
        }

        let sheets = try probe.workbookSheets()
        XCTAssertEqual(sheets.map(\.name), ["Matrix", "Sources", "Project"])
        XCTAssertEqual(sheets.map(\.relationshipID), ["rId1", "rId2", "rId3"])
        let workbookRelationships = try probe.relationships(at: "xl/_rels/workbook.xml.rels")
        XCTAssertEqual(
            try sheets.map { sheet in
                try XCTUnwrap(workbookRelationships[sheet.relationshipID]).resolvedTarget(
                    relativeTo: "xl/workbook.xml"
                )
            },
            [
                "xl/worksheets/sheet1.xml",
                "xl/worksheets/sheet2.xml",
                "xl/worksheets/sheet3.xml",
            ],
            "sheet names must resolve through workbook relationships, never tab position alone"
        )

        let matrix = try probe.worksheet(at: "xl/worksheets/sheet1.xml")
        XCTAssertEqual(matrix.showGridLines, false)
        XCTAssertEqual(matrix.pane?.xSplit, 2)
        XCTAssertEqual(matrix.pane?.ySplit, 1)
        XCTAssertEqual(matrix.pane?.topLeftCell, "C2")
        XCTAssertEqual(matrix.pane?.state, "frozen")
        XCTAssertEqual(matrix.autoFilterReference, "A1:D3")
        XCTAssertEqual(matrix.widths, [1: 7, 2: 34, 3: 24, 4: 16])
        XCTAssertEqual(matrix.cells["A1"]?.type, "inlineStr")
        XCTAssertEqual(matrix.cells["A1"]?.value, "Row")
        XCTAssertEqual(matrix.cells["A2"]?.type, nil)
        XCTAssertEqual(matrix.cells["A2"]?.value, "7")
        XCTAssertEqual(matrix.cells["B2"]?.type, "inlineStr")
        XCTAssertEqual(matrix.cells["B2"]?.value, "alpha-finding")
        XCTAssertEqual(matrix.cells["B3"]?.value, "beta-finding")
        XCTAssertEqual(matrix.cells["C2"]?.type, nil)
        XCTAssertEqual(matrix.cells["C2"]?.value, "46243.78125")
        XCTAssertEqual(matrix.cells["D2"]?.type, "inlineStr")
        XCTAssertEqual(matrix.cells["D2"]?.value, "Reviewed")
        XCTAssertEqual(matrix.cells["D3"]?.value, "Needs review")
        XCTAssertFalse(matrix.sawFormula)

        let sources = try probe.worksheet(at: "xl/worksheets/sheet2.xml")
        XCTAssertEqual(sources.showGridLines, false)
        XCTAssertEqual(sources.pane?.xSplit, 2)
        XCTAssertEqual(sources.pane?.ySplit, 1)
        XCTAssertEqual(sources.pane?.topLeftCell, "C2")
        XCTAssertEqual(sources.autoFilterReference, "A1:C2")
        XCTAssertEqual(sources.widths, [1: 11, 2: 12, 3: 14])

        let project = try probe.worksheet(at: "xl/worksheets/sheet3.xml")
        XCTAssertEqual(project.showGridLines, false)
        XCTAssertEqual(project.pane?.xSplit, nil)
        XCTAssertEqual(project.pane?.ySplit, 1)
        XCTAssertEqual(project.pane?.topLeftCell, "A2")
        XCTAssertEqual(project.autoFilterReference, "A1:B2")
        XCTAssertEqual(project.widths, [1: 34, 2: 76])
        let styleSheet = try probe.styles()
        let headerStyle = try styleSheet.resolve(try XCTUnwrap(matrix.cells["A1"]))
        XCTAssertTrue(headerStyle.bold)
        XCTAssertEqual(headerStyle.fontRGB, "FFFFFFFF")
        XCTAssertEqual(headerStyle.fillPatternType, "solid")
        XCTAssertEqual(headerStyle.fillRGB, "FF1F4E78")
        XCTAssertEqual(headerStyle.wrapText, true)
        XCTAssertEqual(headerStyle.verticalAlignment, "center")

        let integerStyle = try styleSheet.resolve(try XCTUnwrap(matrix.cells["A2"]))
        XCTAssertEqual(integerStyle.numberFormatCode, "0")
        let matrixDateStyle = try styleSheet.resolve(try XCTUnwrap(matrix.cells["C2"]))
        XCTAssertEqual(matrixDateStyle.numberFormatCode, #"yyyy-mm-dd"T"hh:mm:ss"Z""#)
        let projectDateStyle = try styleSheet.resolve(try XCTUnwrap(project.cells["B2"]))
        XCTAssertEqual(projectDateStyle.numberFormatCode, #"yyyy-mm-dd"T"hh:mm:ss"Z""#)

        let positiveStyle = try styleSheet.resolve(try XCTUnwrap(matrix.cells["D2"]))
        assertSemanticStyle(positiveStyle, fillRGB: "FFE2F0D9", fontRGB: "FF385723")
        let attentionStyle = try styleSheet.resolve(try XCTUnwrap(matrix.cells["D3"]))
        assertSemanticStyle(attentionStyle, fillRGB: "FFFFF2CC", fontRGB: "FF7F6000")
        let informationStyle = try styleSheet.resolve(try XCTUnwrap(matrix.cells["B2"]))
        assertSemanticStyle(informationStyle, fillRGB: "FFDDEBF7", fontRGB: "FF1F4E78")
        let dangerStyle = try styleSheet.resolve(try XCTUnwrap(matrix.cells["B3"]))
        assertSemanticStyle(dangerStyle, fillRGB: "FFFCE4D6", fontRGB: "FFC65911")
        let mutedStyle = try styleSheet.resolve(try XCTUnwrap(project.cells["A2"]))
        assertSemanticStyle(mutedStyle, fillRGB: "FFF2F2F2", fontRGB: "FF666666")
        let bodyStyle = try styleSheet.resolve(try XCTUnwrap(sources.cells["B2"]))
        XCTAssertEqual(bodyStyle.wrapText, true)
        XCTAssertEqual(bodyStyle.verticalAlignment, "top")

        let worksheetParts = [
            "xl/worksheets/sheet1.xml",
            "xl/worksheets/sheet2.xml",
            "xl/worksheets/sheet3.xml",
        ]
        let expectedTables = [
            (name: "ReviewMatrix", ref: "A1:D3", headers: ["Row", "Finding", "Reviewed at (UTC)", "Review state"]),
            (name: "ReviewSources", ref: "A1:C2", headers: ["Finding row", "Citation", "Relationship"]),
            (name: "ReviewProject", ref: "A1:B2", headers: ["Field", "Value"]),
        ]
        for (index, worksheetPath) in worksheetParts.enumerated() {
            let sheet = try probe.worksheet(at: worksheetPath)
            XCTAssertEqual(sheet.tableRelationshipIDs, ["rIdTable\(index + 1)"])
            let relationshipPath = "xl/worksheets/_rels/sheet\(index + 1).xml.rels"
            let relationships = try probe.relationships(at: relationshipPath)
            let relationship = try XCTUnwrap(relationships["rIdTable\(index + 1)"])
            let tablePath = relationship.resolvedTarget(relativeTo: worksheetPath)
            XCTAssertEqual(tablePath, "xl/tables/table\(index + 1).xml")
            let table = try probe.table(at: tablePath)
            XCTAssertEqual(table.name, expectedTables[index].name)
            XCTAssertEqual(table.displayName, expectedTables[index].name)
            XCTAssertEqual(table.reference, expectedTables[index].ref)
            XCTAssertEqual(table.headers, expectedTables[index].headers)
        }

    }

    func testTRPXLSXDOC02NeutralizesHostileTextAndEmitsNoExecutableWorkbookParts() throws {
        // T-RPXLSXDOC02 expected RED: no shared tabular renderer proves that every
        // worksheet/header cell is inline text, formula-neutralized before XML
        // escaping, and isolated from formulas, links, macros, and shared strings.
        let workbook = TabularXLSXWorkbook(sheets: [
            .init(
                name: "Safe Data",
                tableName: "SafeData",
                columns: [
                    .init(header: "=Header", width: 18),
                    .init(header: "Document", width: 24),
                    .init(header: "Locator", width: 18),
                    .init(header: "Warnings", width: 24),
                    .init(header: "Excerpt", width: 42),
                ],
                rows: [[
                    .text(#"=HYPERLINK("https://evil.invalid","open")"#),
                    .text("\u{FEFF}@document"),
                    .text("  -2"),
                    .text("\t=cmd"),
                    .text("+SUM(1,1)"),
                ]],
                freezeRows: 1,
                freezeColumns: 1,
                showsGridLines: false,
                hasAutoFilter: true
            ),
        ])

        let data = try TabularXLSXRenderer.render(workbook)
        try DocumentExportValidator.validate(data, as: .xlsx)
        let probe = try OOXMLWorkbookProbe(data: data)
        XCTAssertFalse(probe.paths.contains("xl/sharedStrings.xml"))
        XCTAssertFalse(probe.paths.contains("xl/vbaProject.bin"))
        XCTAssertFalse(probe.paths.contains { $0.hasPrefix("xl/externalLinks/") })
        XCTAssertFalse(probe.paths.contains { $0.lowercased().contains("macro") })

        let sheet = try probe.worksheet(at: "xl/worksheets/sheet1.xml")
        XCTAssertEqual(sheet.cells["A1"]?.value, "'=Header")
        XCTAssertEqual(sheet.cells["A2"]?.value, #"'=HYPERLINK("https://evil.invalid","open")"#)
        XCTAssertEqual(
            sheet.cells["B2"]?.value,
            "'@document",
            "Foundation XMLParser omits U+FEFF from parsed element text"
        )
        XCTAssertTrue(
            try probe.text(at: "xl/worksheets/sheet1.xml").contains(
                #"<t xml:space="preserve">&apos;&#xFEFF;@document</t>"#
            ),
            "the raw worksheet must preserve the neutralized hidden-prefix canary"
        )
        XCTAssertEqual(sheet.cells["C2"]?.value, "'  -2")
        XCTAssertEqual(sheet.cells["D2"]?.value, "'\t=cmd")
        XCTAssertEqual(sheet.cells["E2"]?.value, "'+SUM(1,1)")
        XCTAssertTrue(sheet.cells.values.allSatisfy { $0.type == "inlineStr" })
        XCTAssertFalse(sheet.sawFormula)

        let table = try probe.table(at: "xl/tables/table1.xml")
        XCTAssertEqual(table.headers.first, "'=Header")
        for path in probe.paths where path.hasSuffix(".xml") || path.hasSuffix(".rels") {
            let text = try probe.text(at: path)
            XCTAssertFalse(
                text.range(of: #"<f(?:\s|>)"#, options: .regularExpression) != nil,
                "dynamic text escaped into a formula in \(path)"
            )
            XCTAssertFalse(text.contains(#"TargetMode="External""#), "external relationship in \(path)")
            XCTAssertFalse(text.contains("vbaProject"), "macro relationship in \(path)")
        }
    }

    func testTRPXLSXDOC03RejectsUnsafeOrInconsistentWorkbookContracts() {
        // T-RPXLSXDOC03 expected RED: no renderer validation fails closed on
        // duplicate/unsafe worksheet or table names, malformed row shapes,
        // invalid widths, or XML-forbidden dynamic text before archive creation.
        let twoColumns = [
            TabularXLSXWorkbook.Column(header: "Key", width: 20),
            TabularXLSXWorkbook.Column(header: "Value", width: 20),
        ]
        let safeSheet = contractSheet(name: "Safe", tableName: "SafeTable")
        let invalid: [(String, TabularXLSXWorkbook)] = [
            (
                "case-insensitive duplicate sheet names",
                .init(sheets: [
                    safeSheet,
                    contractSheet(name: "safe", tableName: "SecondTable"),
                ])
            ),
            (
                "worksheet name contains a forbidden slash",
                .init(sheets: [contractSheet(name: "Unsafe/Sheet", tableName: "UnsafeSheet")])
            ),
            (
                "worksheet name exceeds 31 characters",
                .init(sheets: [contractSheet(
                    name: String(repeating: "S", count: 32),
                    tableName: "LongSheet"
                )])
            ),
            (
                "case-insensitive duplicate table names",
                .init(sheets: [
                    safeSheet,
                    contractSheet(name: "Second", tableName: "safetable"),
                ])
            ),
            (
                "table name contains whitespace",
                .init(sheets: [contractSheet(name: "Unsafe Table", tableName: "Unsafe Table")])
            ),
            (
                "table name is an A1 cell reference",
                .init(sheets: [contractSheet(name: "Cell Reference", tableName: "A1")])
            ),
            (
                "row has fewer cells than headers",
                .init(sheets: [contractSheet(
                    name: "Bad Row",
                    tableName: "BadRow",
                    columns: twoColumns,
                    rows: [[.text("only one")]]
                )])
            ),
            (
                "row has more cells than headers",
                .init(sheets: [contractSheet(
                    name: "Wide Row",
                    tableName: "WideRow",
                    columns: twoColumns,
                    rows: [[.text("one"), .text("two"), .text("three")]]
                )])
            ),
            (
                "zero width",
                .init(sheets: [contractSheet(name: "Zero Width", tableName: "ZeroWidth", width: 0)])
            ),
            (
                "non-finite width",
                .init(sheets: [contractSheet(name: "NaN Width", tableName: "NaNWidth", width: .nan)])
            ),
            (
                "width exceeds SpreadsheetML maximum",
                .init(sheets: [contractSheet(name: "Wide", tableName: "TooWide", width: 256)])
            ),
            (
                "XML-forbidden scalar",
                .init(sheets: [contractSheet(
                    name: "Control",
                    tableName: "ControlText",
                    rows: [[.text("before\u{0000}after")]]
                )])
            ),
            (
                "XML-forbidden header scalar",
                .init(sheets: [contractSheet(
                    name: "Header Control",
                    tableName: "HeaderControl",
                    columns: [.init(header: "before\u{0000}after", width: 20)]
                )])
            ),
        ]

        for (label, workbook) in invalid {
            XCTAssertThrowsError(
                try TabularXLSXRenderer.render(workbook),
                "renderer accepted \(label)"
            )
        }
    }

    func testTRPXLSXDOC04ValidatesFinalNeutralizedUTF16CellLength() throws {
        // T-RPXLSXDOC04 expected RED: renderer validation counts the original
        // grapheme clusters before formula neutralization. A maximum-length
        // dangerous header therefore grows past Excel's cell limit, while one
        // grapheme containing too many combining scalars bypasses it entirely.
        let maximumSafeText = String(repeating: "a", count: 32_767)
        XCTAssertNoThrow(try TabularXLSXRenderer.render(.init(sheets: [
            contractSheet(
                name: "Maximum Safe",
                tableName: "MaximumSafe",
                rows: [[.text(maximumSafeText)]]
            ),
        ])))

        let expandingHeader = "=" + String(repeating: "h", count: 32_766)
        XCTAssertThrowsError(try TabularXLSXRenderer.render(.init(sheets: [
            contractSheet(
                name: "Expanded Header",
                tableName: "ExpandedHeader",
                columns: [.init(header: expandingHeader, width: 20)]
            ),
        ])))

        let combiningOverflow = "a" + String(repeating: "\u{0301}", count: 32_767)
        XCTAssertEqual(combiningOverflow.count, 1, "the canary must defeat grapheme counting")
        XCTAssertGreaterThan(combiningOverflow.utf16.count, 32_767)
        XCTAssertThrowsError(try TabularXLSXRenderer.render(.init(sheets: [
            contractSheet(
                name: "Combining Overflow",
                tableName: "CombiningOverflow",
                rows: [[.text(combiningOverflow)]]
            ),
        ])))
    }

    func testTRPXLSXDOC05DisabledAutoFilterIsAbsentFromWorksheetAndTable() throws {
        // T-RPXLSXDOC05 expected RED: the renderer omits a disabled worksheet
        // filter but still writes an active filter into the related table part.
        let data = try TabularXLSXRenderer.render(.init(sheets: [
            contractSheet(
                name: "No Filter",
                tableName: "NoFilter",
                hasAutoFilter: false
            ),
        ]))
        let probe = try OOXMLWorkbookProbe(data: data)

        XCTAssertNil(try probe.worksheet(at: "xl/worksheets/sheet1.xml").autoFilterReference)
        XCTAssertFalse(
            try probe.text(at: "xl/tables/table1.xml").contains("<autoFilter"),
            "a disabled sheet filter must also be absent from the related table"
        )
    }

    func testTRPXLSXDOC06UsesNumbersCompatibleArialForEveryDeclaredFont() throws {
        // T-RPXLSXDOC06 expected RED: live Numbers Creator Studio QA reports a
        // missing-font warning because every declared workbook font is Aptos.
        let data = try TabularXLSXRenderer.render(.init(sheets: [
            contractSheet(name: "Native Font", tableName: "NativeFont"),
        ]))
        let probe = try OOXMLWorkbookProbe(data: data)
        let styles = try probe.styles()

        XCTAssertEqual(
            styles.fonts.map(\.name),
            Array(repeating: "Arial", count: 7),
            "all seven declared fonts must use the native-spreadsheet-safe Arial family"
        )
        XCTAssertFalse(
            try probe.text(at: "xl/styles.xml").localizedCaseInsensitiveContains("Aptos"),
            "the live Numbers warning's Aptos fallback must be absent from the style part"
        )
    }

    private func assertSemanticStyle(
        _ style: OOXMLWorkbookProbe.ResolvedStyle,
        fillRGB: String,
        fontRGB: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(style.fillPatternType, "solid", file: file, line: line)
        XCTAssertEqual(style.fillRGB, fillRGB, file: file, line: line)
        XCTAssertEqual(style.fontRGB, fontRGB, file: file, line: line)
        XCTAssertEqual(style.wrapText, true, file: file, line: line)
        XCTAssertEqual(style.verticalAlignment, "top", file: file, line: line)
    }

    private func contractSheet(
        name: String,
        tableName: String,
        width: Double = 20,
        columns: [TabularXLSXWorkbook.Column]? = nil,
        rows: [[TabularXLSXWorkbook.Cell]] = [[.text("safe")]],
        hasAutoFilter: Bool = true
    ) -> TabularXLSXWorkbook.Sheet {
        .init(
            name: name,
            tableName: tableName,
            columns: columns ?? [.init(header: "Value", width: width)],
            rows: rows,
            freezeRows: 1,
            freezeColumns: 0,
            showsGridLines: false,
            hasAutoFilter: hasAutoFilter
        )
    }
}

private struct OOXMLWorkbookProbe {
    struct WorkbookSheet: Equatable {
        var name: String
        var relationshipID: String
    }

    struct Relationship: Equatable {
        var id: String
        var target: String
        var targetMode: String?

        func resolvedTarget(relativeTo source: String) -> String {
            if target.hasPrefix("/") {
                return String(target.drop(while: { $0 == "/" }))
            }
            var components = source.split(separator: "/").dropLast().map(String.init)
            for component in target.split(separator: "/") {
                switch component {
                case "", ".":
                    continue
                case "..":
                    if !components.isEmpty { components.removeLast() }
                default:
                    components.append(String(component))
                }
            }
            return components.joined(separator: "/")
        }
    }

    struct Cell: Equatable {
        var type: String?
        var style: Int?
        var value: String
    }

    struct Pane: Equatable {
        var xSplit: Int?
        var ySplit: Int?
        var topLeftCell: String?
        var state: String?
    }

    struct Worksheet: Equatable {
        var showGridLines: Bool?
        var pane: Pane?
        var autoFilterReference: String?
        var widths: [Int: Double]
        var tableRelationshipIDs: [String]
        var cells: [String: Cell]
        var sawFormula: Bool
    }

    struct Table: Equatable {
        var name: String?
        var displayName: String?
        var reference: String?
        var headers: [String]
    }

    struct FontStyle: Equatable {
        var name: String?
        var bold: Bool
        var rgb: String?
    }

    struct FillStyle: Equatable {
        var patternType: String?
        var rgb: String?
    }

    struct CellFormat: Equatable {
        var numberFormatID: Int
        var fontID: Int
        var fillID: Int
        var wrapText: Bool?
        var verticalAlignment: String?
        var horizontalAlignment: String?
    }

    struct ResolvedStyle: Equatable {
        var numberFormatCode: String
        var bold: Bool
        var fontRGB: String?
        var fillPatternType: String?
        var fillRGB: String?
        var wrapText: Bool?
        var verticalAlignment: String?
        var horizontalAlignment: String?
    }

    struct StyleSheet: Equatable {
        var numberFormats: [Int: String]
        var fonts: [FontStyle]
        var fills: [FillStyle]
        var cellFormats: [CellFormat]

        func resolve(_ cell: Cell) throws -> ResolvedStyle {
            guard let styleIndex = cell.style,
                  cellFormats.indices.contains(styleIndex) else {
                throw ProbeError.malformedXML("xl/styles.xml cell style")
            }
            let format = cellFormats[styleIndex]
            guard fonts.indices.contains(format.fontID),
                  fills.indices.contains(format.fillID) else {
                throw ProbeError.malformedXML("xl/styles.xml style references")
            }
            let builtInNumberFormats = [0: "General", 1: "0"]
            guard let numberFormatCode = numberFormats[format.numberFormatID]
                    ?? builtInNumberFormats[format.numberFormatID] else {
                throw ProbeError.malformedXML("xl/styles.xml number format")
            }
            let font = fonts[format.fontID]
            let fill = fills[format.fillID]
            return ResolvedStyle(
                numberFormatCode: numberFormatCode,
                bold: font.bold,
                fontRGB: font.rgb,
                fillPatternType: fill.patternType,
                fillRGB: fill.rgb,
                wrapText: format.wrapText,
                verticalAlignment: format.verticalAlignment,
                horizontalAlignment: format.horizontalAlignment
            )
        }
    }

    enum ProbeError: Error {
        case unreadableArchive
        case missingPart(String)
        case invalidUTF8(String)
        case malformedXML(String)
    }

    let archive: Archive

    init(data: Data) throws {
        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: nil) else {
            throw ProbeError.unreadableArchive
        }
        self.archive = archive
    }

    var entries: [Entry] { Array(archive) }
    var paths: [String] { entries.map(\.path) }

    func text(at path: String) throws -> String {
        let data = try entryData(at: path)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProbeError.invalidUTF8(path)
        }
        return text
    }

    func workbookSheets() throws -> [WorkbookSheet] {
        let collector = WorkbookSheetCollector()
        try parse(path: "xl/workbook.xml", delegate: collector)
        return collector.sheets
    }

    func relationships(at path: String) throws -> [String: Relationship] {
        let collector = RelationshipCollector()
        try parse(path: path, delegate: collector)
        return Dictionary(
            collector.relationships.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func worksheet(at path: String) throws -> Worksheet {
        let collector = WorksheetCollector()
        try parse(path: path, delegate: collector)
        return Worksheet(
            showGridLines: collector.showGridLines,
            pane: collector.pane,
            autoFilterReference: collector.autoFilterReference,
            widths: collector.widths,
            tableRelationshipIDs: collector.tableRelationshipIDs,
            cells: collector.cells,
            sawFormula: collector.sawFormula
        )
    }

    func table(at path: String) throws -> Table {
        let collector = TableCollector()
        try parse(path: path, delegate: collector)
        return Table(
            name: collector.name,
            displayName: collector.displayName,
            reference: collector.reference,
            headers: collector.headers
        )
    }

    func styles() throws -> StyleSheet {
        let collector = StylesCollector()
        try parse(path: "xl/styles.xml", delegate: collector)
        return StyleSheet(
            numberFormats: collector.numberFormats,
            fonts: collector.fonts,
            fills: collector.fills,
            cellFormats: collector.cellFormats
        )
    }

    private func entryData(at path: String) throws -> Data {
        guard let entry = archive[path] else { throw ProbeError.missingPart(path) }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    private func parse(path: String, delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: try entryData(at: path))
        parser.delegate = delegate
        guard parser.parse() else { throw ProbeError.malformedXML(path) }
    }
}

private final class WorkbookSheetCollector: NSObject, XMLParserDelegate {
    var sheets: [OOXMLWorkbookProbe.WorkbookSheet] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "sheet",
              let name = attributeDict["name"],
              let relationshipID = attributeDict["r:id"] else { return }
        sheets.append(.init(name: name, relationshipID: relationshipID))
    }
}

private final class RelationshipCollector: NSObject, XMLParserDelegate {
    var relationships: [OOXMLWorkbookProbe.Relationship] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "Relationship",
              let id = attributeDict["Id"],
              let target = attributeDict["Target"] else { return }
        relationships.append(.init(
            id: id,
            target: target,
            targetMode: attributeDict["TargetMode"]
        ))
    }
}

private final class WorksheetCollector: NSObject, XMLParserDelegate {
    var showGridLines: Bool?
    var pane: OOXMLWorkbookProbe.Pane?
    var autoFilterReference: String?
    var widths: [Int: Double] = [:]
    var tableRelationshipIDs: [String] = []
    var cells: [String: OOXMLWorkbookProbe.Cell] = [:]
    var sawFormula = false

    private var cellReference: String?
    private var cellType: String?
    private var cellStyle: Int?
    private var cellValue = ""
    private var capturesCellValue = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "sheetView":
            if let value = attributeDict["showGridLines"] {
                showGridLines = value != "0"
            }
        case "pane":
            pane = .init(
                xSplit: attributeDict["xSplit"].flatMap(Int.init),
                ySplit: attributeDict["ySplit"].flatMap(Int.init),
                topLeftCell: attributeDict["topLeftCell"],
                state: attributeDict["state"]
            )
        case "col":
            guard let minimum = attributeDict["min"].flatMap(Int.init),
                  let maximum = attributeDict["max"].flatMap(Int.init),
                  let width = attributeDict["width"].flatMap(Double.init) else { return }
            for index in minimum...maximum { widths[index] = width }
        case "autoFilter":
            autoFilterReference = attributeDict["ref"]
        case "tablePart":
            if let id = attributeDict["r:id"] { tableRelationshipIDs.append(id) }
        case "c":
            cellReference = attributeDict["r"]
            cellType = attributeDict["t"]
            cellStyle = attributeDict["s"].flatMap(Int.init)
            cellValue = ""
        case "t", "v":
            if cellReference != nil { capturesCellValue = true }
        case "f":
            sawFormula = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturesCellValue { cellValue += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "t", "v":
            capturesCellValue = false
        case "c":
            if let cellReference {
                cells[cellReference] = .init(
                    type: cellType,
                    style: cellStyle,
                    value: cellValue
                )
            }
            cellReference = nil
            cellType = nil
            cellStyle = nil
            cellValue = ""
            capturesCellValue = false
        default:
            break
        }
    }
}

private final class TableCollector: NSObject, XMLParserDelegate {
    var name: String?
    var displayName: String?
    var reference: String?
    var headers: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "table":
            name = attributeDict["name"]
            displayName = attributeDict["displayName"]
            reference = attributeDict["ref"]
        case "tableColumn":
            if let header = attributeDict["name"] { headers.append(header) }
        default:
            break
        }
    }
}

private final class StylesCollector: NSObject, XMLParserDelegate {
    private enum Section {
        case numberFormats
        case fonts
        case fills
        case cellFormats
        case ignored
    }

    var numberFormats: [Int: String] = [:]
    var fonts: [OOXMLWorkbookProbe.FontStyle] = []
    var fills: [OOXMLWorkbookProbe.FillStyle] = []
    var cellFormats: [OOXMLWorkbookProbe.CellFormat] = []

    private var section: Section?
    private var currentFont: OOXMLWorkbookProbe.FontStyle?
    private var currentFill: OOXMLWorkbookProbe.FillStyle?
    private var currentCellFormat: OOXMLWorkbookProbe.CellFormat?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "numFmts":
            section = .numberFormats
        case "fonts":
            section = .fonts
        case "fills":
            section = .fills
        case "cellXfs":
            section = .cellFormats
        case "cellStyleXfs", "borders", "cellStyles":
            section = .ignored
        case "numFmt" where section == .numberFormats:
            if let id = attributeDict["numFmtId"].flatMap(Int.init),
               let code = attributeDict["formatCode"] {
                numberFormats[id] = code
            }
        case "font" where section == .fonts:
            currentFont = .init(name: nil, bold: false, rgb: nil)
        case "name" where currentFont != nil:
            currentFont?.name = attributeDict["val"]
        case "b" where currentFont != nil:
            currentFont?.bold = true
        case "color" where currentFont != nil:
            currentFont?.rgb = attributeDict["rgb"]
        case "fill" where section == .fills:
            currentFill = .init(patternType: nil, rgb: nil)
        case "patternFill" where currentFill != nil:
            currentFill?.patternType = attributeDict["patternType"]
        case "fgColor" where currentFill != nil:
            currentFill?.rgb = attributeDict["rgb"]
        case "xf" where section == .cellFormats:
            guard let numberFormatID = attributeDict["numFmtId"].flatMap(Int.init),
                  let fontID = attributeDict["fontId"].flatMap(Int.init),
                  let fillID = attributeDict["fillId"].flatMap(Int.init) else { return }
            currentCellFormat = .init(
                numberFormatID: numberFormatID,
                fontID: fontID,
                fillID: fillID,
                wrapText: nil,
                verticalAlignment: nil,
                horizontalAlignment: nil
            )
        case "alignment" where currentCellFormat != nil:
            if let value = attributeDict["wrapText"] {
                currentCellFormat?.wrapText = value == "1" || value.lowercased() == "true"
            }
            currentCellFormat?.verticalAlignment = attributeDict["vertical"]
            currentCellFormat?.horizontalAlignment = attributeDict["horizontal"]
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "font":
            if let currentFont { fonts.append(currentFont) }
            currentFont = nil
        case "fill":
            if let currentFill { fills.append(currentFill) }
            currentFill = nil
        case "xf" where section == .cellFormats:
            if let currentCellFormat { cellFormats.append(currentCellFormat) }
            currentCellFormat = nil
        case "numFmts", "fonts", "fills", "cellXfs", "cellStyleXfs", "borders", "cellStyles":
            section = nil
        default:
            break
        }
    }
}
