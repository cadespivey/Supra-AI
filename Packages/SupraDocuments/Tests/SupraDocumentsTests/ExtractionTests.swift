import CoreGraphics
import CoreText
import Foundation
import SupraCore
@testable import SupraDocuments
import XCTest
import ZIPFoundation

final class ExtractionTests: XCTestCase {
    private let service = ExtractionService()
    private var tempDir = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ExtractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSafeAttachmentNameStripsTraversal() {
        // Attacker-controlled MIME filenames must be reduced to a bare component.
        XCTAssertEqual(EmailExtractor.safeAttachmentName("../../etc/passwd", index: 0), "passwd")
        XCTAssertEqual(EmailExtractor.safeAttachmentName("/Users/victim/secret.key", index: 1), "secret.key")
        XCTAssertEqual(EmailExtractor.safeAttachmentName("..", index: 2), "attachment-3")
        XCTAssertEqual(EmailExtractor.safeAttachmentName(nil, index: 4), "attachment-5")
        XCTAssertEqual(EmailExtractor.safeAttachmentName("invoice.pdf", index: 0), "invoice.pdf")
    }

    func testPlainTextAndMarkdown() async throws {
        let txt = try write("notes.txt", "Wire transfer on 2024-03-03 for $5,000.")
        let result = try await service.extract(fileURL: txt)
        XCTAssertEqual(result.parts.first?.sourceKind, .text)
        XCTAssertTrue(result.combinedText.contains("Wire transfer"))

        let md = try write("intake.md", "# Intake\n\nClient: McKernon Motors")
        let mdResult = try await service.extract(fileURL: md)
        XCTAssertEqual(mdResult.parts.first?.sourceKind, .markdown)
        XCTAssertTrue(mdResult.combinedText.contains("McKernon Motors"))
    }

    func testHTMLStripsTagsAndDecodesEntities() async throws {
        let html = try write("page.html", "<html><head><style>p{}</style></head><body><h1>Notice</h1><p>Amount &gt; $1,000 &amp; due.</p></body></html>")
        let result = try await service.extract(fileURL: html)
        XCTAssertEqual(result.parts.first?.sourceKind, .html)
        let text = result.combinedText
        XCTAssertTrue(text.contains("Notice"))
        XCTAssertTrue(text.contains("Amount > $1,000 & due."))
        XCTAssertFalse(text.contains("<"))
        XCTAssertFalse(text.contains("p{}"))
    }

    func testRTFExtractsPlainText() async throws {
        let rtf = try write("note.rtf", #"{\rtf1\ansi\deff0 {\fonttbl{\f0 Helvetica;}}\f0 Retainer agreement signed.\par}"#)
        let result = try await service.extract(fileURL: rtf)
        XCTAssertEqual(result.method, "nsattributedstring-rtf")
        XCTAssertTrue(result.combinedText.contains("Retainer agreement signed."))
    }

    func testXMLExtractsTextAndAttributes() async throws {
        let xml = try write("metadata.xml", "<doc author=\"Harvey Specter\"><title>Contract</title><note>Signed 2023</note></doc>")
        let result = try await service.extract(fileURL: xml)
        XCTAssertEqual(result.parts.first?.sourceKind, .xml)
        let text = result.combinedText
        XCTAssertTrue(text.contains("Harvey Specter"))
        XCTAssertTrue(text.contains("Contract"))
    }

    func testDocxExtractsParagraphText() async throws {
        let docx = try writeDocx("termination.docx", paragraphs: ["Termination Letter", "Effective March 3, 2024."])
        let result = try await service.extract(fileURL: docx)
        XCTAssertEqual(result.method, "ooxml-word")
        XCTAssertTrue(result.combinedText.contains("Termination Letter"))
        XCTAssertTrue(result.combinedText.contains("Effective March 3, 2024."))
    }

    func testXlsxExtractsVisibleCellValues() async throws {
        let xlsx = try writeXlsx(
            "invoice.xlsx",
            sheetName: "Invoices",
            sharedStrings: ["Invoice", "Amount", "McKernon Motors"],
            cells: [("A1", "s", "0"), ("B1", "s", "1"), ("A2", "s", "2"), ("B2", nil, "5000")]
        )
        let result = try await service.extract(fileURL: xlsx)
        XCTAssertEqual(result.method, "xlsx")
        let part = try XCTUnwrap(result.parts.first)
        XCTAssertEqual(part.sheetName, "Invoices")
        XCTAssertEqual(part.cellRange, "A1:B2")
        XCTAssertTrue(part.text.contains("McKernon Motors"))
        XCTAssertTrue(part.text.contains("5000"))
    }

    func testXlsxMapsSheetNamesByRelationshipNotTabOrder() async throws {
        // Tab order is "Summary" then "Detail", but the r:id targets are deliberately
        // NOT positional: rId1 -> worksheets/sheet2.xml, rId2 -> worksheets/sheet1.xml
        // (as happens when tabs are reordered or a sheet is deleted). Per OOXML the
        // worksheet part is chosen by relationship, not by tab order.
        let url = tempDir.appendingPathComponent("reordered.xlsx")
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)

        let workbook = """
        <workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets>\
        <sheet name="Summary" sheetId="1" r:id="rId1"/>\
        <sheet name="Detail" sheetId="2" r:id="rId2"/>\
        </sheets></workbook>
        """
        let rels = """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
        </Relationships>
        """
        // Physical files: sheet1.xml holds Detail's data, sheet2.xml holds Summary's data.
        let sheet1 = "<worksheet><sheetData><row><c r=\"A1\" t=\"inlineStr\"><is><t>DetailValue</t></is></c></row></sheetData></worksheet>"
        let sheet2 = "<worksheet><sheetData><row><c r=\"A1\" t=\"inlineStr\"><is><t>SummaryValue</t></is></c></row></sheetData></worksheet>"

        try addEntry(archive, "xl/workbook.xml", workbook)
        try addEntry(archive, "xl/_rels/workbook.xml.rels", rels)
        try addEntry(archive, "xl/worksheets/sheet1.xml", sheet1)
        try addEntry(archive, "xl/worksheets/sheet2.xml", sheet2)

        let result = try await service.extract(fileURL: url)
        XCTAssertEqual(result.method, "xlsx")

        let summary = try XCTUnwrap(result.parts.first { $0.sheetName == "Summary" })
        let detail = try XCTUnwrap(result.parts.first { $0.sheetName == "Detail" })
        // Each tab name must carry the cell values from the worksheet its r:id points at.
        XCTAssertTrue(summary.text.contains("SummaryValue"), "Summary should resolve to sheet2.xml via r:id; got: \(summary.text)")
        XCTAssertFalse(summary.text.contains("DetailValue"))
        XCTAssertTrue(detail.text.contains("DetailValue"), "Detail should resolve to sheet1.xml via r:id; got: \(detail.text)")
        XCTAssertFalse(detail.text.contains("SummaryValue"))
    }

    func testLegacyXlsReportedUnsupported() async throws {
        let xls = try write("ledger.xls", "binary-ish")
        do {
            _ = try await service.extract(fileURL: xls)
            XCTFail("Expected unsupported error")
        } catch let error as ExtractionError {
            guard case .unsupportedFormat = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testEmlExtractsBodyAndAttachment() async throws {
        let attachmentData = Data("attached contract text".utf8).base64EncodedString()
        let eml = """
        From: counsel@example.com
        To: client@example.com
        Subject: Notice of Termination
        Date: Wed, 3 Apr 2024 10:00:00 +0000
        Content-Type: multipart/mixed; boundary="BOUNDARY"

        --BOUNDARY
        Content-Type: text/plain

        Please see the attached termination notice.
        --BOUNDARY
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="notice.txt"
        Content-Transfer-Encoding: base64

        \(attachmentData)
        --BOUNDARY--
        """
        let url = try write("notice.eml", eml)
        let result = try await service.extract(fileURL: url)
        XCTAssertEqual(result.parts.first?.sourceKind, .emailBody)
        XCTAssertTrue(result.combinedText.contains("attached termination notice"))
        XCTAssertTrue(result.combinedText.contains("Subject: Notice of Termination"))
        XCTAssertEqual(result.attachments.count, 1)
        XCTAssertEqual(result.attachments.first?.fileName, "notice.txt")
        XCTAssertEqual(String(data: result.attachments.first?.data ?? Data(), encoding: .utf8), "attached contract text")
    }

    func testMsgReportedUnsupported() async throws {
        let msg = try write("board.msg", "ole-binary")
        do {
            _ = try await service.extract(fileURL: msg)
            XCTFail("Expected unsupported error")
        } catch let error as ExtractionError {
            guard case .unsupportedFormat = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testCorruptDocxFails() async throws {
        let bad = try write("corrupt-file.docx", "this is not a zip archive")
        do {
            _ = try await service.extract(fileURL: bad)
            XCTFail("Expected malformed error")
        } catch is ExtractionError {
            // expected — captured per file, not a crash
        }
    }

    func testMixedPDFFlagsOnlySparsePagesForOCR() async throws {
        // Expected RED: does not compile — `ocrPageIndices` is not a member of
        // `ExtractionResult`. That build failure fails the whole SupraDocumentsTests
        // target and is the recorded, observable RED (methodology §2).
        let richText = "Retainer agreement between McKernon Motors and outside counsel, "
            + "executed on 2024 01 15. This page carries substantial embedded text so the "
            + "extractor treats it as a text page and not a scanned image. Distinctive anchor "
            + "token ZQXCANARY marks this page for scoped assertions. The remaining two pages "
            + "are intentionally blank so only they require OCR."
        let url = tempDir.appendingPathComponent("mixed-scan.pdf")
        try makePDF(at: url, pages: [.text(richText), .empty, .empty])

        let result = try await service.extract(fileURL: url)

        XCTAssertTrue(result.needsOCR, "a PDF with two blank pages still has OCR work to do")
        XCTAssertEqual(result.ocrPageIndices, [1, 2], "only the two blank pages are flagged for OCR")
    }

    // MARK: - Fixture authoring

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeDocx(_ name: String, paragraphs: [String]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        let body = paragraphs.map { "<w:p><w:r><w:t>\(xmlEscape($0))</w:t></w:r></w:p>" }.joined()
        let document = """
        <?xml version="1.0"?><w:document xmlns:w="http://x"><w:body>\(body)</w:body></w:document>
        """
        try addEntry(archive, "word/document.xml", document)
        return url
    }

    private func writeXlsx(
        _ name: String,
        sheetName: String,
        sharedStrings: [String],
        cells: [(ref: String, type: String?, value: String)]
    ) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        let workbook = "<workbook><sheets><sheet name=\"\(sheetName)\" sheetId=\"1\"/></sheets></workbook>"
        let sst = "<sst>" + sharedStrings.map { "<si><t>\(xmlEscape($0))</t></si>" }.joined() + "</sst>"
        let cellXML = cells.map { cell -> String in
            let typeAttr = cell.type.map { " t=\"\($0)\"" } ?? ""
            return "<c r=\"\(cell.ref)\"\(typeAttr)><v>\(xmlEscape(cell.value))</v></c>"
        }.joined()
        let sheet = "<worksheet><sheetData><row>\(cellXML)</row></sheetData></worksheet>"
        try addEntry(archive, "xl/workbook.xml", workbook)
        try addEntry(archive, "xl/sharedStrings.xml", sst)
        try addEntry(archive, "xl/worksheets/sheet1.xml", sheet)
        return url
    }

    private func addEntry(_ archive: Archive, _ path: String, _ contents: String) throws {
        let data = Data(contents.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Builds a real PDF whose `.text` pages carry extractable embedded text (drawn
    /// with Core Text so PDFKit's `page.string` recovers it) and whose `.empty`
    /// pages carry none. Mirrors HostileImportPolicyTests' CG `makePDF` pattern but
    /// adds text pages; kept private to this file so the hostile helper is untouched.
    private func makePDF(at url: URL, pages: [PDFPageContent]) throws {
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for page in pages {
            context.beginPDFPage(nil)
            if case let .text(string) = page {
                try drawTextPage(string, in: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Draws `text` into the current PDF page as word-wrapped Core Text lines. Words
    /// (including anchor tokens) are never split across lines, and ligatures are
    /// disabled, so PDFKit extraction recovers each token contiguously.
    private func drawTextPage(_ text: String, in context: CGContext) throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let ligaturesOff = NSNumber(value: 0)
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= 60 {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }

        var baseline: CGFloat = 740
        for lineText in lines {
            let attributed = try XCTUnwrap(CFAttributedStringCreate(
                nil,
                lineText as CFString,
                [kCTFontAttributeName: font, kCTLigatureAttributeName: ligaturesOff] as CFDictionary
            ))
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 36, y: baseline)
            CTLineDraw(line, context)
            baseline -= 18
        }
    }
}

/// Page descriptor for the text-bearing `makePDF` fixture helper.
private enum PDFPageContent {
    case text(String)
    case empty
}
