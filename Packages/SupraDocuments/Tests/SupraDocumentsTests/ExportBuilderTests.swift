import Foundation
import PDFKit
import SupraCore
@testable import SupraDocuments
import XCTest

final class ExportBuilderTests: XCTestCase {
    private var dir = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var payload: DocumentExportPayload {
        DocumentExportPayload(
            title: "Q&A: payment date",
            contentMarkdown: "Payment was due on March 3, 2024 [S1].",
            reviewWarning: "Verify before external use.",
            sources: [
                .init(label: "S1", documentName: "agreement.pdf", locator: "p. 3", excerpt: "Payment due March 3, 2024.", warnings: "low OCR confidence")
            ]
        )
    }

    func testMarkdownContainsOutputAndAppendix() throws {
        let url = dir.appendingPathComponent("o.md")
        try DocumentExportBuilder.write(payload, format: .markdown, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("Payment was due on March 3, 2024 [S1]."))
        XCTAssertTrue(text.contains("## Sources"))
        XCTAssertTrue(text.contains("agreement.pdf"))
        XCTAssertTrue(text.contains("Verify before external use."))
    }

    func testCSVHasHeaderAndSourceRow() throws {
        let url = dir.appendingPathComponent("o.csv")
        try DocumentExportBuilder.write(payload, format: .csv, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("Label,Document,Locator,Warnings,Excerpt"))
        XCTAssertTrue(text.contains("\"S1\""))
        XCTAssertTrue(text.contains("agreement.pdf"))
    }

    func testPDFIsReadableWithText() throws {
        let url = dir.appendingPathComponent("o.pdf")
        try DocumentExportBuilder.write(payload, format: .pdf, to: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThanOrEqual(document.pageCount, 1)
        let text = document.string ?? ""
        XCTAssertTrue(text.contains("Payment was due"))
    }

    func testDOCXContainsOutputText() throws {
        let url = dir.appendingPathComponent("o.docx")
        try DocumentExportBuilder.write(payload, format: .docx, to: url)
        let data = try XCTUnwrap(ZipArchiveReader.entryData(in: url, path: "word/document.xml"))
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(xml.contains("Payment was due on March 3, 2024 [S1]."))
        XCTAssertTrue(xml.contains("agreement.pdf"))
    }

    func testXLSXContainsAppendixRows() throws {
        let url = dir.appendingPathComponent("o.xlsx")
        try DocumentExportBuilder.write(payload, format: .xlsx, to: url)
        let data = try XCTUnwrap(ZipArchiveReader.entryData(in: url, path: "xl/worksheets/sheet1.xml"))
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(xml.contains("S1"))
        XCTAssertTrue(xml.contains("agreement.pdf"))
        XCTAssertTrue(xml.contains("Label"))
    }
}
