import Foundation
import SupraDraftingCore
@testable import SupraExports
import XCTest

/// Letterhead shell fidelity — LOCKED against letterDemand-golden.docx (Letter §3 / Exports §5).
final class LetterheadRendererTests: XCTestCase {

    private var profileOffice: OfficeBlock {
        OfficeBlock(street: "200 West Forsyth Street", suite: "Suite 1400",
                    city: "Jacksonville", state: "Florida", zip: "32202",
                    phone: "(904) 555-0142", fax: "(904) 555-0143")
    }

    private var letterModel: LetterModel {
        LetterModel(
            letterhead: LetterheadFill(firmName: "Harwell & Branch, P.A.", office: profileOffice),
            date: DateOnly(year: 2026, month: 6, day: 25),
            recipient: AddressBlock(name: "Mr. Daniel R. Coleman", title: nil, firm: "Coleman Logistics, LLC",
                                    street: "4820 Southpoint Parkway", city: "Jacksonville", state: "Florida", zip: "32216"),
            reLine: "Outstanding Balance Owed to Brightwater Supply Co. — Demand for Payment",
            salutation: "Dear Mr. Coleman:",
            body: ["This firm represents Brightwater Supply Co.",
                   "Demand is hereby made for payment of the full outstanding balance of $48,750.00."],
            closing: "Respectfully,",
            signerName: "Jordan A. Reyes",
            signerTitle: nil,
            enclosures: ["Statement of Unpaid Invoices"],
            cc: ["Brightwater Supply Co."]
        )
    }

    func testLetterheadIsCenteredFirmName16ptTaglineItalic10pt() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: .defaultFL)
        XCTAssertTrue(xml.contains(#"<w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:b/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr><w:t xml:space="preserve">Harwell &amp; Branch, P.A.</w:t></w:r>"#))
        XCTAssertTrue(xml.contains(#"<w:r><w:rPr><w:i/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr><w:t xml:space="preserve">Attorneys at Law</w:t></w:r>"#))
    }

    func testFullWidthRuleAfterLetterhead() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: .defaultFL)
        XCTAssertTrue(xml.contains(#"<w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="auto"/></w:pBdr></w:pPr>"#))
    }

    func testRELineBoldHangingIndent() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: .defaultFL)
        XCTAssertTrue(xml.contains(#"<w:ind w:left="1440" w:hanging="720"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">RE:</w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:tab/></w:r><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">Outstanding Balance Owed to Brightwater Supply Co. — Demand for Payment</w:t></w:r>"#))
    }

    func testBodyIsJustifiedBlockNoFirstLineIndent() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: .defaultFL)
        // body paragraph: jc both, no firstLine indent
        XCTAssertTrue(xml.contains(#"<w:p><w:pPr><w:jc w:val="both"/></w:pPr><w:r><w:t xml:space="preserve">This firm represents Brightwater Supply Co.</w:t></w:r></w:p>"#))
        XCTAssertFalse(xml.contains(#"<w:ind w:firstLine="720"/>"#), "letter body is block, not indented")
    }

    func testClosingAndSignatureInRightHalfNoSlash() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: .defaultFL)
        XCTAssertTrue(xml.contains(#"<w:p><w:pPr><w:ind w:left="4680"/></w:pPr><w:r><w:t xml:space="preserve">Respectfully,</w:t></w:r></w:p>"#))
        XCTAssertTrue(xml.contains(#"<w:p><w:pPr><w:ind w:left="4680"/></w:pPr><w:r><w:t xml:space="preserve">Jordan A. Reyes</w:t></w:r></w:p>"#))
        XCTAssertFalse(xml.contains("/s/"), "letter signature has no /s/ (wet signature in the gap)")
    }

    func testEnclosureAndCcAtLeftMargin() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: .defaultFL)
        XCTAssertTrue(xml.contains(#"<w:p><w:r><w:t xml:space="preserve">Enclosure: Statement of Unpaid Invoices</w:t></w:r></w:p>"#))
        XCTAssertTrue(xml.contains(#"<w:p><w:r><w:t xml:space="preserve">cc:  Brightwater Supply Co.</w:t></w:r></w:p>"#))
    }

    func testNoCaptionNoCertificateNoFooterOnLetterShell() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: .defaultFL)
        XCTAssertFalse(xml.contains("<w:tbl>"), "no caption table on a letter")
        XCTAssertFalse(xml.contains("CERTIFICATE OF SERVICE"))
        XCTAssertFalse(xml.contains("footerReference"))
        XCTAssertFalse(xml.contains("titlePg"))
    }

    func testLetterPackageOmitsFooterParts() throws {
        let data = try LetterheadRenderer().render(.letter(letterModel), style: .defaultFL)
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B])  // zip magic
    }

    func testNoBakedIdentityFirmAVsFirmB() {
        let firmB = LetterModel(
            letterhead: LetterheadFill(firmName: "Sterling Vance LLP",
                                       office: OfficeBlock(street: "1 Bay St", suite: nil, city: "Tampa",
                                                           state: "Florida", zip: "33601", phone: "(813) 555-0001", fax: nil)),
            date: DateOnly(year: 2026, month: 1, day: 2), recipient: letterModel.recipient,
            reLine: "X", salutation: "Dear Sir:", body: ["Body."], closing: "Respectfully,",
            signerName: "Pat Vance", signerTitle: nil, enclosures: [], cc: []
        )
        let xmlA = LetterheadRenderer().documentXML(letterModel, style: .defaultFL)
        let xmlB = LetterheadRenderer().documentXML(firmB, style: .defaultFL)
        XCTAssertTrue(xmlA.contains("Harwell"))
        XCTAssertFalse(xmlA.contains("Sterling Vance"))
        XCTAssertTrue(xmlB.contains("Sterling Vance"))
        XCTAssertFalse(xmlB.contains("Harwell"))
    }
}
