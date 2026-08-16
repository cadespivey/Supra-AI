import Foundation
import SupraOOXML
@testable import SupraDocuments
import XCTest

/// T-OOXML-01
///
/// Expected RED: the existing package root exposes only the drafting-coupled `SupraExports`
/// product. `SupraOOXML` and its neutral style compiler do not exist, so Documents cannot use
/// typed WordprocessingML without inheriting the drafting-specific target closure.
final class ArchitectureUXTOoxml01Tests: XCTestCase {
    private enum Wire {
        static let marker = "T_OOXML_01_WIRE_731"
        static let recordID = "record-713"
        static let forbiddenDefault = "DEFAULT-000"
    }

    func testNeutralWriterPackagePartsStylesAndRelationshipsAreByteExact() throws {
        let document = OoxmlDocument(
            body: [.paragraph(OoxmlParagraph(
                style: Wire.marker,
                props: ParaProps(jc: .both, spaceAfterTwips: 8),
                runs: [.text(
                    "\(Wire.marker) & \(Wire.recordID)",
                    props: RunProps(bold: true, fontHalfPoints: 28, colorHex: "713713")
                )]
            ))],
            section: SectionProps(
                pageWidthTwips: 713,
                pageHeightTwips: 719,
                marginTopTwips: 7,
                marginRightTwips: 8,
                marginBottomTwips: 9,
                marginLeftTwips: 10,
                pageNumberStart: 7
            )
        )
        let documentXML = OoxmlWriter.documentXML(document)
        let expectedDocumentXML = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body><w:p><w:pPr><w:pStyle w:val="T_OOXML_01_WIRE_731"/><w:spacing w:after="8"/><w:jc w:val="both"/></w:pPr><w:r><w:rPr><w:b/><w:color w:val="713713"/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr><w:t xml:space="preserve">T_OOXML_01_WIRE_731 &amp; record-713</w:t></w:r></w:p><w:sectPr><w:pgSz w:w="713" w:h="719"/><w:pgMar w:top="7" w:right="8" w:bottom="9" w:left="10" w:header="720" w:footer="720" w:gutter="0"/><w:pgNumType w:start="7"/></w:sectPr></w:body></w:document>
        """#
        XCTAssertEqual(documentXML, expectedDocumentXML)
        XCTAssertEqual(OoxmlNormalizer.normalize(documentXML), OoxmlNormalizer.normalize(expectedDocumentXML))

        let package = DocxPackage.richExport(
            documentXML: documentXML,
            stylesXML: "<styles>\(Wire.marker)-v7</styles>",
            settingsXML: "<settings>record-713-v7</settings>",
            numberingXML: "<numbering>7-8</numbering>",
            headerXML: "<header>\(Wire.marker)</header>",
            footerXML: "<footer>record-713</footer>",
            hyperlinks: [
                DocxHyperlinkRelationship(
                    id: "rIdHyperlink7",
                    target: "https://example.invalid/T_OOXML_01_WIRE_731/record-713"
                ),
            ]
        )
        XCTAssertEqual(package.parts.keys.sorted(), [
            "[Content_Types].xml",
            "_rels/.rels",
            "word/_rels/document.xml.rels",
            "word/document.xml",
            "word/footer1.xml",
            "word/header1.xml",
            "word/numbering.xml",
            "word/settings.xml",
            "word/styles.xml",
        ])
        XCTAssertEqual(package.parts["word/document.xml"], expectedDocumentXML)
        XCTAssertEqual(package.parts["word/styles.xml"], "<styles>\(Wire.marker)-v7</styles>")
        let relationships = try XCTUnwrap(package.parts["word/_rels/document.xml.rels"])
        XCTAssertEqual(
            OoxmlNormalizer.normalize(relationships),
            #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rIdSettings" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/><Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/><Relationship Id="rIdHeader1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/><Relationship Id="rIdFooter1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/><Relationship Id="rIdHyperlink7" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.invalid/T_OOXML_01_WIRE_731/record-713" TargetMode="External"/></Relationships>"#
        )
        XCTAssertTrue(OoxmlStyleSheet.richExportStylesXML().contains(#"w:styleId="ExportTitle""#))
        XCTAssertTrue(OoxmlStyleSheet.settingsXML().contains(#"w:val="15""#))

        let exactParts = [documentXML, relationships, package.parts["word/styles.xml", default: ""]]
        XCTAssertTrue(exactParts.joined().contains(Wire.marker))
        XCTAssertTrue(exactParts.joined().contains(Wire.recordID))
        XCTAssertFalse(exactParts.joined().contains(Wire.forbiddenDefault))
    }

    func testNeutralTargetAndDocumentsDependencyExcludeDraftingPolicy() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SupraDocumentsTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SupraDocuments
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository
        let exportsManifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Packages/SupraExports/Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(exportsManifest.contains(#".library(name: "SupraOOXML", targets: ["SupraOOXML"])"#))
        XCTAssertTrue(exportsManifest.contains(#"name: "SupraOOXML""#))

        let documentsManifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Packages/SupraDocuments/Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(documentsManifest.contains(#".product(name: "SupraOOXML", package: "SupraExports")"#))
        XCTAssertFalse(documentsManifest.contains(#".product(name: "SupraExports", package: "SupraExports")"#))

        let neutralRoot = repositoryRoot.appendingPathComponent(
            "Packages/SupraExports/Sources/SupraOOXML",
            isDirectory: true
        )
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: neutralRoot, includingPropertiesForKeys: nil))
        var swiftSources: [String] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "swift" {
                swiftSources.append(try String(contentsOf: url, encoding: .utf8))
            }
        }
        XCTAssertFalse(swiftSources.isEmpty)
        XCTAssertFalse(swiftSources.joined(separator: "\n").contains("import SupraDraftingCore"))
    }
}
