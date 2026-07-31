import CoreGraphics
@testable import SupraSessions
import XCTest

final class OCRPreviewOverlayTests: XCTestCase {
    func testVersionedPayloadDecodesTextConfidenceAndHighlightedRegion() {
        let json = #"{"schemaVersion":1,"regions":[{"x":0.1,"y":0.2,"w":0.3,"h":0.1,"confidence":0.91,"text":"Payment due March 3"},{"x":0.2,"y":0.7,"w":0.4,"h":0.08,"confidence":0.62,"text":"Other line"}]}"#

        let overlay = OCRPreviewOverlayParser.parse(json, highlightedText: "payment due")

        XCTAssertNil(overlay.warning)
        XCTAssertEqual(overlay.schemaVersion, 1)
        XCTAssertEqual(overlay.regions.count, 2)
        XCTAssertEqual(overlay.regions[0].text, "Payment due March 3")
        XCTAssertEqual(overlay.regions[0].confidence, 0.91, accuracy: 0.0001)
        XCTAssertTrue(overlay.regions[0].isHighlighted)
        XCTAssertFalse(overlay.regions[1].isHighlighted)
    }

    func testLegacyArrayRemainsReadableWithoutInventingText() {
        let json = #"[{"x":0.1,"y":0.2,"w":0.3,"h":0.1,"confidence":0.75}]"#

        let overlay = OCRPreviewOverlayParser.parse(json)

        XCTAssertNil(overlay.warning)
        XCTAssertEqual(overlay.schemaVersion, 0)
        XCTAssertEqual(overlay.regions.count, 1)
        XCTAssertNil(overlay.regions[0].text)
        XCTAssertFalse(overlay.regions[0].isHighlighted)
    }

    func testUnknownVersionAndMalformedCoordinatesFailVisibleWithoutRegions() {
        let unknown = OCRPreviewOverlayParser.parse(#"{"schemaVersion":9,"regions":[]}"#)
        XCTAssertEqual(unknown.regions, [])
        XCTAssertEqual(unknown.warning, "OCR highlight data uses an unsupported version.")

        let malformed = OCRPreviewOverlayParser.parse(
            #"{"schemaVersion":1,"regions":[{"x":-0.1,"y":0.2,"w":0.3,"h":0.1,"confidence":0.9,"text":"Outside"},{"x":0.9,"y":0.2,"w":0.3,"h":0.1,"confidence":0.8,"text":"Escapes"}]}"#
        )
        XCTAssertEqual(malformed.regions, [])
        XCTAssertEqual(malformed.warning, "OCR highlight data could not be displayed safely.")
    }

    func testVisionCoordinatesMapIntoAspectFitImageWithVerticalAxisInversion() throws {
        let region = OCRPreviewRegion(
            id: 0,
            x: 0.25,
            y: 0.2,
            width: 0.5,
            height: 0.4,
            confidence: 0.9,
            text: "Mapped",
            isHighlighted: true
        )

        let rect = try XCTUnwrap(OCRPreviewGeometry.displayRect(
            for: region,
            imageSize: CGSize(width: 400, height: 200),
            containerSize: CGSize(width: 200, height: 200)
        ))

        XCTAssertEqual(rect.minX, 50, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 90, accuracy: 0.001)
        XCTAssertEqual(rect.width, 100, accuracy: 0.001)
        XCTAssertEqual(rect.height, 40, accuracy: 0.001)
    }

    func testPortraitDisplayUsesOrientedImageSizeAndRejectsEmptyGeometry() throws {
        let region = OCRPreviewRegion(
            id: 0,
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            confidence: 0.8,
            text: nil,
            isHighlighted: false
        )
        let portrait = try XCTUnwrap(OCRPreviewGeometry.displayRect(
            for: region,
            imageSize: CGSize(width: 200, height: 400),
            containerSize: CGSize(width: 300, height: 200)
        ))
        XCTAssertEqual(portrait, CGRect(x: 100, y: 0, width: 100, height: 200))
        XCTAssertNil(OCRPreviewGeometry.displayRect(
            for: region,
            imageSize: .zero,
            containerSize: CGSize(width: 300, height: 200)
        ))
    }
}
