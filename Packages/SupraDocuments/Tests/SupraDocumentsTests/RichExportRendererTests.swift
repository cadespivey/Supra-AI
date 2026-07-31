import AppKit
import Foundation
import PDFKit
@testable import SupraDocuments
import XCTest
import ZIPFoundation

final class RichExportRendererTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RichExportRendererTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // T-EXP-10/11: PDFKit sees every semantic section and a measurable title/
    // heading/body hierarchy instead of one undifferentiated plain-text run.
    func testPDFPreservesSemanticTextAndTypographicHierarchy() throws {
        let url = directory.appendingPathComponent("rich.pdf")
        try DocumentExportBuilder.write(payload, format: .pdf, to: url)

        let document = try XCTUnwrap(PDFDocument(url: url))
        let attributed = try XCTUnwrap(document.page(at: 0)?.attributedString)
        let text = attributed.string

        XCTAssertTrue(text.contains("Quarterly Findings"))
        XCTAssertTrue(text.contains("Findings"))
        XCTAssertTrue(text.contains("Verify before external use."))
        XCTAssertTrue((document.string ?? "").contains("Sources"))
        XCTAssertTrue((document.string ?? "").contains("agreement.pdf"))

        let titleHeight = try selectionHeight(for: "Quarterly Findings", in: document)
        let headingHeight = try selectionHeight(for: "Findings", in: document, occurrence: 1)
        let bodyHeight = try selectionHeight(for: "Payment was due", in: document)
        XCTAssertGreaterThan(titleHeight, headingHeight)
        XCTAssertGreaterThan(headingHeight, bodyHeight)
    }

    // T-EXP-12/13/14: letter geometry is stable, page numbers are visible,
    // and table pagination never drops a row.
    func testPDFUsesLetterMarginsPageNumbersAndKeepsLongTableRows() throws {
        let rows = (1...140).map { "| ROW-\($0) | Value \($0) |" }.joined(separator: "\n")
        let longPayload = DocumentExportPayload(
            title: "Long table",
            contentMarkdown: """
            # Ledger

            | Identifier | Value |
            | --- | --- |
            \(rows)
            """,
            reviewWarning: "Review required.",
            sources: []
        )
        let url = directory.appendingPathComponent("long.pdf")
        try DocumentExportBuilder.write(longPayload, format: .pdf, to: url)

        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(document.pageCount, 1)
        let allText = document.string ?? ""
        for row in 1...140 {
            XCTAssertTrue(allText.contains("ROW-\(row)"), "missing row \(row)")
        }
        for pageIndex in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: pageIndex))
            XCTAssertEqual(page.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
            XCTAssertTrue(
                (page.string ?? "").contains("Page \(pageIndex + 1) of \(document.pageCount)"),
                "page \(pageIndex + 1) has no visible page number"
            )
        }
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let titleRange = ((firstPage.string ?? "") as NSString).range(of: "Long table")
        XCTAssertNotEqual(titleRange.location, NSNotFound)
        let titleSelection = try XCTUnwrap(firstPage.selection(for: titleRange))
        let titleBounds = titleSelection.bounds(for: firstPage)
        XCTAssertGreaterThanOrEqual(titleBounds.minX, 54)
        XCTAssertLessThanOrEqual(titleBounds.maxX, 558)
    }

    // T-EXP-15…19: independent ZIP/XML inspection finds styles, numbering,
    // tables, relationships, page footer, body, appendix, and review assurance.
    func testDOCXContainsReusableRichOOXMLPartsAndSemanticStructure() throws {
        let url = directory.appendingPathComponent("rich.docx")
        try DocumentExportBuilder.write(payload, format: .docx, to: url)

        let paths = Set(try ZipArchiveReader.entryPaths(in: url))
        let required = [
            "word/document.xml",
            "word/styles.xml",
            "word/settings.xml",
            "word/numbering.xml",
            "word/footer1.xml",
            "word/_rels/document.xml.rels",
        ]
        for path in required {
            XCTAssertTrue(paths.contains(path), "missing \(path)")
            _ = try parseXML(try entry(path, in: url))
        }

        let document = try entryString("word/document.xml", in: url)
        XCTAssertTrue(document.contains(#"<w:pStyle w:val="ExportTitle"/>"#))
        XCTAssertTrue(document.contains(#"<w:pStyle w:val="ExportHeading1"/>"#))
        XCTAssertTrue(document.contains(#"<w:pStyle w:val="ReviewBanner"/>"#))
        XCTAssertTrue(document.contains(#"<w:pStyle w:val="SourceHeading"/>"#))
        XCTAssertTrue(document.contains("<w:numPr>"))
        XCTAssertTrue(document.contains("<w:tbl>"))
        XCTAssertTrue(document.contains("Quarterly Findings"))
        XCTAssertTrue(document.contains("agreement.pdf"))
        XCTAssertFalse(document.contains("**material**"))
        XCTAssertFalse(document.contains("| --- |"))

        let styles = try entryString("word/styles.xml", in: url)
        XCTAssertTrue(styles.contains(#"w:styleId="ExportTitle""#))
        XCTAssertTrue(styles.contains(#"w:styleId="ExportHeading1""#))
        let numbering = try entryString("word/numbering.xml", in: url)
        XCTAssertTrue(numbering.contains(#"w:numFmt w:val="bullet""#))
        XCTAssertTrue(numbering.contains(#"w:numFmt w:val="decimal""#))
        let relationships = try entryString("word/_rels/document.xml.rels", in: url)
        XCTAssertTrue(relationships.contains(#"Target="styles.xml""#))
        XCTAssertTrue(relationships.contains(#"Target="numbering.xml""#))
        XCTAssertTrue(relationships.contains(#"Target="footer1.xml""#))
        XCTAssertTrue(try entryString("word/footer1.xml", in: url).contains(" PAGE "))
    }

    // T-EXP-20: a syntactically valid package with a dangling relationship is
    // rejected before DurableFileWriter can install it.
    func testDOCXValidatorRejectsDanglingDocumentRelationship() throws {
        let url = directory.appendingPathComponent("dangling.docx")
        try makeArchive(
            at: url,
            parts: [
                "[Content_Types].xml": #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#,
                "_rels/.rels": #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>"#,
                "word/document.xml": #"<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body/></w:document>"#,
                "word/_rels/document.xml.rels": #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#,
            ]
        )
        XCTAssertThrowsError(try DocumentExportValidator.validate(url, as: .docx))
    }

    // T-EXP-21…25: the workbook has a typed primary table and a complete
    // relationship-keyed Sources table, with frozen headers and explicit widths.
    func testXLSXContainsTypedOutputAndSourcesTablesWithUsabilityMetadata() throws {
        let hostile = DocumentExportPayload(
            title: "=Quarterly Findings",
            contentMarkdown: payload.contentMarkdown,
            reviewWarning: payload.reviewWarning,
            sources: payload.sources + [
                .init(label: "S2", documentName: "invoice.xlsx", locator: "Sheet1!B4", excerpt: "+5000")
            ]
        )
        let url = directory.appendingPathComponent("rich.xlsx")
        try DocumentExportBuilder.write(hostile, format: .xlsx, to: url)

        let workbook = try entryString("xl/workbook.xml", in: url)
        XCTAssertTrue(workbook.contains(#"name="Output" sheetId="1" r:id="rId1""#))
        XCTAssertTrue(workbook.contains(#"name="Sources" sheetId="2" r:id="rId2""#))
        let relationships = try entryString("xl/_rels/workbook.xml.rels", in: url)
        XCTAssertTrue(relationships.contains(#"Id="rId1""#))
        XCTAssertTrue(relationships.contains(#"Target="worksheets/sheet1.xml""#))
        XCTAssertTrue(relationships.contains(#"Id="rId2""#))
        XCTAssertTrue(relationships.contains(#"Target="worksheets/sheet2.xml""#))

        let output = try entryString("xl/worksheets/sheet1.xml", in: url)
        XCTAssertTrue(output.contains(#"state="frozen""#))
        XCTAssertTrue(output.contains("<cols>"))
        XCTAssertTrue(output.contains("<tableParts"))
        XCTAssertTrue(output.contains(#"<c r="A2" s="1"><v>1</v></c>"#))
        XCTAssertTrue(output.contains("'=Quarterly Findings"))
        XCTAssertTrue(output.contains("S1"))

        let sources = try entryString("xl/worksheets/sheet2.xml", in: url)
        XCTAssertTrue(sources.contains(#"state="frozen""#))
        XCTAssertTrue(sources.contains("<cols>"))
        XCTAssertTrue(sources.contains("S1"))
        XCTAssertTrue(sources.contains("S2"))
        XCTAssertTrue(sources.contains("agreement.pdf"))
        XCTAssertTrue(sources.contains("invoice.xlsx"))
        XCTAssertTrue(sources.contains("'+5000"))

        let paths = Set(try ZipArchiveReader.entryPaths(in: url))
        XCTAssertTrue(paths.contains("xl/styles.xml"))
        XCTAssertTrue(paths.contains("xl/tables/table1.xml"))
        XCTAssertTrue(paths.contains("xl/tables/table2.xml"))
        XCTAssertTrue(paths.contains("xl/worksheets/_rels/sheet1.xml.rels"))
        XCTAssertTrue(paths.contains("xl/worksheets/_rels/sheet2.xml.rels"))
    }

    // T-EXP-20/28 counterpart for SpreadsheetML relationship integrity.
    func testXLSXValidatorRejectsUnknownWorkbookRelationship() throws {
        let url = directory.appendingPathComponent("dangling.xlsx")
        try makeArchive(
            at: url,
            parts: [
                "[Content_Types].xml": #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#,
                "_rels/.rels": #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>"#,
                "xl/workbook.xml": #"<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Output" sheetId="1" r:id="rIdMissing"/></sheets></workbook>"#,
                "xl/_rels/workbook.xml.rels": #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"#,
                "xl/worksheets/sheet1.xml": #"<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData/></worksheet>"#,
            ]
        )
        XCTAssertThrowsError(try DocumentExportValidator.validate(url, as: .xlsx))
    }

    private var payload: DocumentExportPayload {
        .init(
            title: "Quarterly Findings",
            contentMarkdown: """
            # Findings

            Payment was **material** and due [S1].

            - Notice sent
            - Payment missed

            1. Review the agreement
            2. Confirm the ledger

            | Date | Amount |
            | --- | ---: |
            | 2024-03-03 | $5,000 |
            """,
            reviewWarning: "Verify before external use.",
            sources: [
                .init(
                    label: "S1",
                    documentName: "agreement.pdf",
                    locator: "p. 3",
                    excerpt: "Payment due March 3, 2024.",
                    warnings: "low OCR confidence"
                )
            ]
        )
    }

    private func selectionHeight(
        for needle: String,
        in document: PDFDocument,
        occurrence: Int = 0
    ) throws -> CGFloat {
        let selections = document.findString(needle, withOptions: [])
        XCTAssertGreaterThan(selections.count, occurrence)
        let selection = selections[occurrence]
        let page = try XCTUnwrap(selection.pages.first)
        return selection.bounds(for: page).height
    }

    private func entry(_ path: String, in archive: URL) throws -> Data {
        try XCTUnwrap(ZipArchiveReader.entryData(in: archive, path: path), "missing \(path)")
    }

    private func entryString(_ path: String, in archive: URL) throws -> String {
        String(decoding: try entry(path, in: archive), as: UTF8.self)
    }

    @discardableResult
    private func parseXML(_ data: Data) throws -> XMLParser {
        let parser = XMLParser(data: data)
        XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "XML parse failed")
        return parser
    }

    private func makeArchive(at url: URL, parts: [String: String]) throws {
        let archive = try XCTUnwrap(Archive(url: url, accessMode: .create, pathEncoding: nil))
        for (path, text) in parts.sorted(by: { $0.key < $1.key }) {
            let data = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
    }
}
