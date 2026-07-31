import Foundation
@testable import SupraDocuments
import XCTest

final class RichExportDocumentTests: XCTestCase {
    func testTEXP01MapsHeadingsParagraphsAndCitationsToSemanticNodes() {
        let payload = makePayload(content: "## Payment\n\nPayment was due [S1] and extended by [S-2].")

        let document = RichExportDocument(payload: payload)

        XCTAssertEqual(document.blocks, [
            .title([.text("Export title")]),
            .reviewBanner([.text("Verify before external use.")]),
            .heading(level: 2, content: [.text("Payment")]),
            .paragraph([
                .text("Payment was due "),
                .citation("S1"),
                .text(" and extended by "),
                .citation("S-2"),
                .text("."),
            ]),
            .sourceAppendix([source]),
        ])
    }

    func testTEXP02MapsUnorderedAndOrderedListsWithoutFlatteningItems() {
        let payload = makePayload(content: "- First item\n- Second **important** item\n\n3. Third\n4. Fourth")

        let document = RichExportDocument(payload: payload)

        XCTAssertTrue(document.blocks.contains(.unorderedList(items: [
            [.text("First item")],
            [.text("Second "), .strong("important"), .text(" item")],
        ])))
        XCTAssertTrue(document.blocks.contains(.orderedList(start: 3, items: [
            [.text("Third")],
            [.text("Fourth")],
        ])))
    }

    func testTEXP03MapsMarkdownTableWithAlignmentAndInlineContent() throws {
        let payload = makePayload(content: """
        | Date | Amount | Source |
        | :--- | ---: | :---: |
        | March 3 | **$500** | [S1] |
        """)

        let document = RichExportDocument(payload: payload)

        let table = try XCTUnwrap(document.blocks.compactMap { block -> RichExportDocument.Table? in
            guard case let .table(table) = block else { return nil }
            return table
        }.first)
        XCTAssertEqual(table.headers, [[.text("Date")], [.text("Amount")], [.text("Source")]])
        XCTAssertEqual(table.alignments, [.leading, .trailing, .center])
        XCTAssertEqual(table.rows, [[
            [.text("March 3")],
            [.strong("$500")],
            [.citation("S1")],
        ]])
    }

    func testTEXP04UnsupportedMarkupDegradesToLiteralParagraphText() {
        let payload = makePayload(content: ":::callout\n<widget mode=\"x\">keep</widget>\n**unclosed")

        let document = RichExportDocument(payload: payload)

        XCTAssertTrue(document.blocks.contains(.paragraph([
            .text(":::callout <widget mode=\"x\">keep</widget> **unclosed"),
        ])))
    }

    func testTEXP04BracketedOrdinaryProseIsNotInventedAsACitation() {
        let payload = makePayload(content: "See [Appendix] for the complete schedule and [S1] for the cited term.")

        let document = RichExportDocument(payload: payload)

        XCTAssertTrue(document.blocks.contains(.paragraph([
            .text("See [Appendix] for the complete schedule and "),
            .citation("S1"),
            .text(" for the cited term."),
        ])))
    }

    func testTEXP05MarkdownGoldenRemainsByteExact() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RichExportMarkdown-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("output.md")

        try DocumentExportBuilder.write(makePayload(content: "Payment was due [S1]."), format: .markdown, to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), """
        # Export title

        > Verify before external use.

        Payment was due [S1].

        ## Sources
        - **[S1]** agreement.pdf — p. 3 ⚠️ low OCR confidence
          > Payment due March 3.

        """)
    }

    func testTEXP06CSVGoldenRemainsByteExact() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RichExportCSV-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("output.csv")

        try DocumentExportBuilder.write(makePayload(content: "Payment was due [S1]."), format: .csv, to: url)

        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "Label,Document,Locator,Warnings,Excerpt\n\"S1\",\"agreement.pdf\",\"p. 3\",\"low OCR confidence\",\"Payment due March 3.\""
        )
    }

    func testTEXP07WarningAndSourceAppendixAreExplicitExactlyOnce() {
        let document = RichExportDocument(payload: makePayload(content: "Body"))

        XCTAssertEqual(document.blocks.filter {
            if case .reviewBanner = $0 { return true }
            return false
        }.count, 1)
        XCTAssertEqual(document.blocks.filter {
            if case .sourceAppendix = $0 { return true }
            return false
        }.count, 1)
    }

    private var source: RichExportDocument.Source {
        .init(
            label: "S1",
            documentName: "agreement.pdf",
            locator: "p. 3",
            excerpt: "Payment due March 3.",
            warnings: "low OCR confidence"
        )
    }

    private func makePayload(content: String) -> DocumentExportPayload {
        DocumentExportPayload(
            title: "Export title",
            contentMarkdown: content,
            reviewWarning: "Verify before external use.",
            sources: [
                .init(
                    label: "S1",
                    documentName: "agreement.pdf",
                    locator: "p. 3",
                    excerpt: "Payment due March 3.",
                    warnings: "low OCR confidence"
                )
            ]
        )
    }
}
