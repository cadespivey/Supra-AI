import Foundation
@testable import SupraTestKit
import XCTest

/// Validation tests over the generated corpus are added once the matter specs are
/// authored (see CorpusValidationTests).
final class SupraTestKitTests: XCTestCase {
    func testRenderersProduceFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TKSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try CorpusRenderers.writeBornDigitalPDF(text: "Born-digital PDF body with the term indemnification.", to: dir.appendingPathComponent("a.pdf"))
        try CorpusRenderers.writeScannedPDF(text: "Scanned page text.", to: dir.appendingPathComponent("scan.pdf"))
        try CorpusRenderers.writeImagePNG(text: "Image text.", to: dir.appendingPathComponent("img.png"))
        try CorpusRenderers.writeDOCX(text: "Word body.", to: dir.appendingPathComponent("d.docx"))
        try CorpusRenderers.writeXLSX(sheets: [SheetSpec(sheet: "S1", cells: [["A", "B"], ["1", "Acme"]])], to: dir.appendingPathComponent("s.xlsx"))
        try CorpusRenderers.writeEML(EmailSpec(from: "a@x.com", to: "b@x.com", subject: "Hi", date: "Mon, 1 Jan 2024 09:00:00 -0500", body: "Body.", attachmentFilename: "att.txt", attachmentBody: "Attached."), to: dir.appendingPathComponent("m.eml"))

        for name in ["a.pdf", "scan.pdf", "img.png", "d.docx", "s.xlsx", "m.eml"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), "missing \(name)")
        }
    }
}
