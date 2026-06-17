import CoreGraphics
import Foundation
import ImageIO
import SupraDocuments
import SupraStore
@testable import SupraSessions
import XCTest

/// Regression guard for the Milestone 3 app-run validation OCR scenario.
///
/// `DocumentValidationRunController`'s `ocr` check ("Image OCR persisted with
/// confidence") asserts the fixture image imports with a non-nil OCR confidence
/// summary. The fixture previously wrote literal `"png-bytes"` to
/// `scanned-notice.png`, which Vision cannot decode ("Could not decode image for
/// OCR"), so the import failed and the check could never pass on device. These
/// tests pin the fixture to a real, decodable, OCR-able image.
final class Milestone3ValidationFixturesTests: XCTestCase {

    func testScannedNoticeFixtureIsADecodableImage() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("M3Fix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let root = try Milestone3ValidationFixtures.write(into: base)
        let png = root.appendingPathComponent("Images/scanned-notice.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), "fixture image missing")

        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("scanned-notice.png is not a decodable image (the exact OCR failure)")
        }
        XCTAssertGreaterThan(image.width, 100)
        XCTAssertGreaterThan(image.height, 100)
    }

    func testFixtureImageImportsWithOCRConfidence() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("M3Fix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let root = try Milestone3ValidationFixtures.write(into: base)
        let store = try SupraStore(url: base.appendingPathComponent("test.sqlite"))
        let matter = try store.matters.createMatter(name: "M3 Fixture OCR")
        let storage = DocumentStorage(root: base.appendingPathComponent("storage", isDirectory: true))

        // Same wiring as the app: real Vision OCR.
        let importer = DocumentImportService(store: store, storage: storage, ocr: VisionOCRService())
        _ = try await importer.importSources([root], matterID: matter.id)

        let docs = try store.documentLibrary.fetchDocuments(matterID: matter.id)
        let image = try XCTUnwrap(docs.first { $0.displayName == "scanned-notice.png" }, "image fixture not imported")
        XCTAssertNotEqual(image.status, "failed", "scanned image should import via OCR, not fail")
        XCTAssertNotNil(
            image.ocrConfidenceSummary,
            "OCR confidence summary must be persisted — exactly what the app's `ocr` validation check asserts"
        )
    }
}
