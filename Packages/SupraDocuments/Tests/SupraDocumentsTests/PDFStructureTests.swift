import CoreGraphics
import CoreText
import Foundation
import PDFKit
@testable import SupraDocuments
import XCTest

final class PDFStructureTests: XCTestCase {
    private var tempDirectory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFStructureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testTSTR09PagesAndEmbeddedLinesProduceRangedRegionsWithNormalizedBoxes() async throws {
        // T-STR-09 expected RED: PDFs currently receive only the universal
        // document/paragraph wrapper, so page and line-region nodes are absent.
        let url = tempDirectory.appendingPathComponent("mixed-pages.pdf")
        try makePDF(at: url, pages: [
            ["FIRST-LINE-742", "SECOND-LINE-913"],
            [],
        ])

        let result = try await PDFExtractor(lowTextPerPageThreshold: 1).extract(fileURL: url)

        let pages = result.structure.nodes.filter { $0.kind == .page }
        XCTAssertEqual(pages.count, 2)
        let firstPage = try XCTUnwrap(pages.first)
        let secondPage = try XCTUnwrap(pages.dropFirst().first)
        XCTAssertEqual(pages.map(\.partIndex), [0, 1])
        XCTAssertEqual(payload(firstPage)["pageIndex"] as? Int, 0)
        XCTAssertEqual(payload(secondPage)["needsOCR"] as? Bool, true)

        let regions = result.structure.nodes.filter { $0.kind == .region && $0.partIndex == 0 }
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions.map { resolvedText($0, in: result) }, ["FIRST-LINE-742", "SECOND-LINE-913"])
        XCTAssertTrue(regions.allSatisfy { $0.parentNodeKey == firstPage.nodeKey })
        for region in regions {
            let box = try XCTUnwrap(payload(region)["box"] as? [String: Any])
            for coordinate in ["x", "y", "width", "height"] {
                let value = try XCTUnwrap(box[coordinate] as? Double)
                XCTAssertTrue((0...1).contains(value), "\(coordinate) must be normalized to page bounds")
            }
        }
        XCTAssertFalse(result.structure.nodes.contains { $0.kind == .region && $0.partIndex == 1 })
    }

    func testTSTR10FormValuesAndSignaturePresenceRemainStructuredOutsideBodyFlow() async throws {
        // T-STR-10 expected RED: widget values and signature widgets are ignored;
        // there is no form-field region or page-level signature signal.
        let url = tempDirectory.appendingPathComponent("form-and-signature.pdf")
        try makePDF(at: url, pages: [["BODY-TEXT-ALPHA"]])
        try addAnnotations(to: url) { page in
            let field = PDFAnnotation(
                bounds: CGRect(x: 72, y: 600, width: 180, height: 24),
                forType: .widget,
                withProperties: nil
            )
            field.widgetFieldType = .text
            field.fieldName = "invoice_number"
            field.widgetStringValue = "FORM-VALUE-742"
            page.addAnnotation(field)

            let signature = PDFAnnotation(
                bounds: CGRect(x: 72, y: 520, width: 220, height: 50),
                forType: .widget,
                withProperties: nil
            )
            signature.widgetFieldType = .signature
            signature.fieldName = "client_signature"
            page.addAnnotation(signature)
        }

        let result = try await PDFExtractor(lowTextPerPageThreshold: 1).extract(fileURL: url)

        XCTAssertFalse(result.combinedText.contains("FORM-VALUE-742"), "form values must not silently enter body flow")
        let formField = try XCTUnwrap(result.structure.nodes.first { node in
            node.kind == .region && node.textContent == "FORM-VALUE-742"
        })
        let formPayload = payload(formField)
        XCTAssertEqual(formPayload["semanticKind"] as? String, "form_field")
        XCTAssertEqual(formPayload["fieldName"] as? String, "invoice_number")
        XCTAssertEqual(formPayload["widgetType"] as? String, "text")
        let page = try XCTUnwrap(result.structure.nodes.first { $0.kind == .page })
        XCTAssertEqual(payload(page)["signaturePresent"] as? Bool, true)
        XCTAssertEqual(payload(page)["signatureFields"] as? [String], ["client_signature"])
    }

    func testTSTR11AnnotationTextRemainsStructuredOutsideBodyFlow() async throws {
        // T-STR-11 expected RED: annotation text is discarded and cannot be
        // recovered as an out-of-flow region with author/subtype provenance.
        let url = tempDirectory.appendingPathComponent("annotated.pdf")
        try makePDF(at: url, pages: [["BODY-TEXT-BETA"]])
        try addAnnotations(to: url) { page in
            let annotation = PDFAnnotation(
                bounds: CGRect(x: 300, y: 610, width: 32, height: 32),
                forType: .text,
                withProperties: nil
            )
            annotation.contents = "ANNOTATION-NONDEFAULT"
            annotation.userName = "Synthetic Reviewer"
            page.addAnnotation(annotation)
        }

        let result = try await PDFExtractor(lowTextPerPageThreshold: 1).extract(fileURL: url)

        XCTAssertFalse(result.combinedText.contains("ANNOTATION-NONDEFAULT"))
        let annotation = try XCTUnwrap(result.structure.nodes.first { node in
            node.kind == .region && node.textContent == "ANNOTATION-NONDEFAULT"
        })
        let annotationPayload = payload(annotation)
        XCTAssertEqual(annotationPayload["semanticKind"] as? String, "annotation")
        XCTAssertEqual(annotationPayload["subtype"] as? String, "Text")
        XCTAssertEqual(annotationPayload["userName"] as? String, "Synthetic Reviewer")
        XCTAssertNotNil(annotationPayload["box"] as? [String: Any])
    }

    private func makePDF(at url: URL, pages: [[String]]) throws {
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for lines in pages {
            context.beginPDFPage(nil)
            var baseline: CGFloat = 740
            for lineText in lines {
                let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
                let attributed = try XCTUnwrap(CFAttributedStringCreate(
                    nil,
                    lineText as CFString,
                    [kCTFontAttributeName: font, kCTLigatureAttributeName: NSNumber(value: 0)] as CFDictionary
                ))
                context.textPosition = CGPoint(x: 36, y: baseline)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                baseline -= 22
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func addAnnotations(to url: URL, mutate: (PDFPage) -> Void) throws {
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        mutate(page)
        XCTAssertTrue(document.write(to: url))
    }

    private func resolvedText(_ node: ExtractedStructureNode, in result: ExtractionResult) -> String? {
        if let textContent = node.textContent { return textContent }
        guard result.parts.indices.contains(node.partIndex),
              let start = node.charStart,
              let end = node.charEnd else { return nil }
        let text = result.parts[node.partIndex].text
        guard start >= 0, end >= start, end <= text.count else { return nil }
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(text.startIndex, offsetBy: end)
        return String(text[lower..<upper])
    }

    private func payload(_ node: ExtractedStructureNode) -> [String: Any] {
        guard let payloadJSON = node.payloadJSON,
              let data = payloadJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}
