import Foundation
import SupraCore
@testable import SupraDocuments
import XCTest

final class DocumentFoundationTests: XCTestCase {

    func testSupportedTypesCoverRequiredFormats() {
        for ext in ["pdf", "png", "jpg", "jpeg", "tif", "tiff", "txt", "md", "markdown",
                    "rtf", "html", "htm", "xml", "doc", "docx", "dotx", "xls", "xlsx", "eml", "msg"] {
            XCTAssertTrue(SupportedDocumentTypes.supportedExtensions.contains(ext), "missing \(ext)")
        }
        XCTAssertEqual(SupportedDocumentTypes.format(for: URL(fileURLWithPath: "/x/a.PDF"))?.family, .pdf)
        XCTAssertEqual(SupportedDocumentTypes.format(for: URL(fileURLWithPath: "/x/a.xlsx"))?.sourceKind, .spreadsheetCellRange)
        XCTAssertNil(SupportedDocumentTypes.format(for: URL(fileURLWithPath: "/x/a.exe")))
        XCTAssertFalse(SupportedDocumentTypes.isSupported(URL(fileURLWithPath: "/x/a.exe")))
    }

    func testBlobRelativePathShardsBySha256Prefix() {
        let path = DocumentStorage.blobRelativePath(sha256: "abcdef1234", fileExtension: "pdf")
        XCTAssertEqual(path, "blobs/ab/abcdef1234.pdf")
        XCTAssertEqual(DocumentStorage.blobRelativePath(sha256: "ffee00", fileExtension: ".PDF"), "blobs/ff/ffee00.pdf")
    }

    func testStorageInitializeCreatesLayoutAndHashes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupraDocsTests-\(UUID().uuidString)", isDirectory: true)
        let storage = DocumentStorage(root: root)
        XCTAssertFalse(storage.isInitialized())
        try storage.initializeStorage()
        XCTAssertTrue(storage.isInitialized())

        // Hash a file and a buffer; both agree for identical content.
        let fileURL = storage.tempDirectory.appendingPathComponent("a.txt")
        let content = Data("hello world".utf8)
        try content.write(to: fileURL)
        XCTAssertEqual(try DocumentStorage.sha256Hex(ofFileAt: fileURL), DocumentStorage.sha256Hex(of: content))

        try? FileManager.default.removeItem(at: root)
    }

    func testToolchainReportsBaselineCapabilities() {
        let capabilities = DocumentToolchain.detectCapabilities()
        XCTAssertEqual(capabilities.version, DocumentToolchain.version)
        XCTAssertTrue(capabilities.pdfText)
        XCTAssertTrue(capabilities.supportedFamilies.contains("pdf"))
        // OCR availability depends on the host; the field is populated either way.
        XCTAssertEqual(capabilities.ocr, !capabilities.ocrLanguages.isEmpty)
    }
}
