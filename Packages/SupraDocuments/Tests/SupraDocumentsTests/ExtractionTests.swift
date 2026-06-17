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

    func testPlainTextAndMarkdown() async throws {
        let txt = try write("notes.txt", "Wire transfer on 2024-03-03 for $5,000.")
        let result = try await service.extract(fileURL: txt)
        XCTAssertEqual(result.parts.first?.sourceKind, .text)
        XCTAssertTrue(result.combinedText.contains("Wire transfer"))

        let md = try write("intake.md", "# Intake\n\nClient: Acme Corp")
        let mdResult = try await service.extract(fileURL: md)
        XCTAssertEqual(mdResult.parts.first?.sourceKind, .markdown)
        XCTAssertTrue(mdResult.combinedText.contains("Acme Corp"))
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
        let xml = try write("metadata.xml", "<doc author=\"Jane Roe\"><title>Contract</title><note>Signed 2023</note></doc>")
        let result = try await service.extract(fileURL: xml)
        XCTAssertEqual(result.parts.first?.sourceKind, .xml)
        let text = result.combinedText
        XCTAssertTrue(text.contains("Jane Roe"))
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
            sharedStrings: ["Invoice", "Amount", "Acme Corp"],
            cells: [("A1", "s", "0"), ("B1", "s", "1"), ("A2", "s", "2"), ("B2", nil, "5000")]
        )
        let result = try await service.extract(fileURL: xlsx)
        XCTAssertEqual(result.method, "xlsx")
        let part = try XCTUnwrap(result.parts.first)
        XCTAssertEqual(part.sheetName, "Invoices")
        XCTAssertEqual(part.cellRange, "A1:B2")
        XCTAssertTrue(part.text.contains("Acme Corp"))
        XCTAssertTrue(part.text.contains("5000"))
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
}
