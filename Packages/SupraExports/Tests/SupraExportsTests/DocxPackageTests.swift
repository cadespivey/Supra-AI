import Foundation
import SupraExports
import XCTest
import ZIPFoundation

final class DocxPackageTests: XCTestCase {
    func testCourtPackageIncludesCanonicalFooterPartsAndRelationships() throws {
        let package = DocxPackage.court(
            documentXML: "<w:document/>",
            stylesXML: "<w:styles/>",
            settingsXML: "<w:settings/>",
            footerXML: "<w:ftr><w:p>PAGE</w:p></w:ftr>"
        )

        let data = try package.render()
        let archive = try XCTUnwrap(Archive(data: data, accessMode: .read))
        let entryPaths = Set(archive.map(\.path))

        XCTAssertTrue(entryPaths.contains("[Content_Types].xml"))
        XCTAssertTrue(entryPaths.contains("_rels/.rels"))
        XCTAssertTrue(entryPaths.contains("word/document.xml"))
        XCTAssertTrue(entryPaths.contains("word/styles.xml"))
        XCTAssertTrue(entryPaths.contains("word/settings.xml"))
        XCTAssertTrue(entryPaths.contains("word/footer1.xml"))
        XCTAssertTrue(entryPaths.contains("word/footerEmpty.xml"))
        XCTAssertTrue(entryPaths.contains("word/_rels/document.xml.rels"))

        let documentRelationships = try archive.readText(at: "word/_rels/document.xml.rels")
        XCTAssertTrue(documentRelationships.contains("rIdFooterEmpty"))
        XCTAssertTrue(documentRelationships.contains("http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"))
    }

    func testXMLNormalizerStripsWordOnlyNoiseButPreservesRendererOwnedStructure() throws {
        let noisy = """
        <w:p w:rsidR=\"001\" w14:paraId=\"ABC\" xmlns:w=\"w\" xmlns:w14=\"w14\">
          <w:proofErr w:type=\"spellStart\"/>
          <w:r><w:t>CASE NO.: 2026-CA-001847</w:t></w:r>
          <w:lastRenderedPageBreak/>
        </w:p>
        """

        let normalized = OoxmlNormalizer.normalize(noisy)

        XCTAssertFalse(normalized.contains("rsid"))
        XCTAssertFalse(normalized.contains("w14:"))
        XCTAssertFalse(normalized.contains("proofErr"))
        XCTAssertFalse(normalized.contains("lastRenderedPageBreak"))
        XCTAssertTrue(normalized.contains("CASE NO.: 2026-CA-001847"))
    }
}

private extension Archive {
    func readText(at path: String) throws -> String {
        let entry = try XCTUnwrap(self[path])
        var data = Data()
        _ = try extract(entry) { chunk in
            data.append(chunk)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
