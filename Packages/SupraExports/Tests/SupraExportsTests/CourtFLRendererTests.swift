import Foundation
import SupraDraftingCore
@testable import SupraExports
import XCTest

/// Construct-level fidelity tests: assert the exact WML the renderer emits for each §4 construct,
/// and check it against the substrings the round-tripped Word goldens locked in.
final class CourtFLRendererTests: XCTestCase {

    private func loadGolden(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Docs/Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Fixtures (fictional — the design-render "Pearson Specter Litt / McKernon" set)

    private var harwellBranch: SignatureBlockModel {
        SignatureBlockModel(
            respectfullySubmitted: nil,
            firmName: "Pearson Specter Litt",
            signingAttorney: "Harvey Specter",
            attorneys: [AttorneyLine(name: "Harvey Specter", barNumber: "Florida Bar No. 100847")],
            office: OfficeBlock(street: "200 West Forsyth Street", suite: "Suite 1400",
                                city: "Jacksonville", state: "Florida", zip: "32202",
                                phone: "(904) 555-0142", fax: "(904) 555-0143"),
            partyRepresented: "Defendant",
            emails: EmailDesignation(primary: "hspecter@pearsonspecterlitt.example",
                                     secondary: ["litdocket@pearsonspecterlitt.example"])
        )
    }

    private var noticeModel: DocumentModel {
        DocumentModel(
            caption: CaptionModel(
                courtHeader: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
                parties: [PartyLine(name: "MCKERNON MOTORS, INC.,", designation: "Plaintiff,"),
                          PartyLine(name: "LIBERTY RAIL, LLC,", designation: "Defendant.")],
                caseNumber: "2026-CA-001847",
                division: "CV-G",
                judge: nil
            ),
            title: "NOTICE OF APPEARANCE",
            body: [.paragraph("PLEASE TAKE NOTICE that the undersigned attorney appears.")],
            signature: harwellBranch,
            certificate: CertificateModel(
                date: DateOnly(year: 2026, month: 6, day: 25),
                clause: .flEPortal,
                documentTitle: "NOTICE OF APPEARANCE",
                recipients: [ServiceRecipient(
                    name: "Daniel Hardman, Esq.", firm: "Hardman & Tanner, LLP",
                    address: OfficeBlock(street: "1 Independent Drive", suite: "Suite 2400",
                                         city: "Jacksonville", state: "Florida", zip: "32202",
                                         phone: "", fax: nil),
                    emails: ["dhardman@hardmantanner.example"],
                    role: "Counsel for Plaintiff"
                )],
                signOffAttorney: "Harvey Specter"
            )
        )
    }

    // MARK: - Caption (LOCKED, golden §4.1)

    func testCaptionIsTwoCellBorderlessTableNineThreeSixtyWide() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: .defaultFL)
        XCTAssertTrue(xml.contains(#"<w:tblW w:w="9360" w:type="dxa"/>"#))
        XCTAssertTrue(xml.contains(#"<w:tblInd w:w="10" w:type="dxa"/>"#))
        XCTAssertTrue(xml.contains(#"<w:tblLayout w:type="fixed"/>"#))
        XCTAssertTrue(xml.contains(#"<w:gridCol w:w="4680"/><w:gridCol w:w="4680"/>"#))
        // borderless
        XCTAssertTrue(xml.contains(#"<w:tblBorders><w:top w:val="nil"/><w:left w:val="nil"/><w:bottom w:val="nil"/><w:right w:val="nil"/><w:insideH w:val="nil"/><w:insideV w:val="nil"/></w:tblBorders>"#))
        // right cell content
        XCTAssertTrue(xml.contains("CASE NO.: 2026-CA-001847"))
        XCTAssertTrue(xml.contains("DIVISION: CV-G"))
    }

    func testClosingCaptionRuleIsBottomBorderedRightSlash() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: .defaultFL)
        XCTAssertTrue(xml.contains(#"<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="auto"/></w:pBdr><w:jc w:val="right"/>"#))
    }

    // MARK: - Title

    func testTitleIsCenteredBoldCapsUnderline() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: .defaultFL)
        XCTAssertTrue(xml.contains(#"<w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:b/><w:caps/><w:u w:val="single"/></w:rPr><w:t xml:space="preserve">NOTICE OF APPEARANCE</w:t></w:r>"#))
    }

    // MARK: - Body paragraph

    func testBodyParagraphIsDoubleSpacedFirstLineIndentJustified() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: .defaultFL)
        XCTAssertTrue(xml.contains(#"<w:spacing w:line="480" w:lineRule="auto"/><w:ind w:firstLine="720"/><w:jc w:val="both"/>"#))
    }

    // MARK: - e-signature line (LOCKED §4.2)

    func testESignatureLineIsSingleParagraphItalicUnderlinedNameAndPinnedTab() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: .defaultFL)
        // "By: " plain + italic+underlined "/s/ Name" + italic+underlined tab to pinned stop 4680+2880=7560.
        XCTAssertTrue(xml.contains(#"<w:tabs><w:tab w:val="left" w:pos="7560"/></w:tabs><w:ind w:left="4680"/></w:pPr><w:r><w:t xml:space="preserve">By: </w:t></w:r><w:r><w:rPr><w:i/><w:u w:val="single"/></w:rPr><w:t xml:space="preserve">/s/ Harvey Specter</w:t></w:r><w:r><w:rPr><w:i/><w:u w:val="single"/></w:rPr><w:tab/></w:r>"#))
    }

    // MARK: - Signature block order

    func testSignatureBlockEmailLabelBoldAndAttorneysForLineLast() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: .defaultFL)
        let text = OoxmlNormalizer.visibleText(xml)
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">Primary and Secondary E-Mail: </w:t>"#))
        // "Attorneys for Defendant" italic, and after the e-mails.
        XCTAssertTrue(xml.contains(#"<w:r><w:rPr><w:i/></w:rPr><w:t xml:space="preserve">Attorneys for Defendant</w:t></w:r>"#))
        let emailIdx = try XCTUnwrap(text.range(of: "hspecter@pearsonspecterlitt.example"))
        let attorneysIdx = try XCTUnwrap(text.range(of: "Attorneys for Defendant"))
        XCTAssertTrue(emailIdx.lowerBound < attorneysIdx.lowerBound, "Attorneys-for line must come after the e-mails")
        XCTAssertFalse(text.contains("Respectfully submitted"), "Notice carries no Respectfully submitted line")
    }

    // MARK: - Certificate

    func testCertificateClauseTextExact() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: .defaultFL)
        let text = OoxmlNormalizer.visibleText(xml)
        XCTAssertTrue(text.contains("I HEREBY CERTIFY that on June 25, 2026, I electronically filed the foregoing with the Clerk of Court using the Florida Courts E-Filing Portal, which will send a Notice of Electronic Filing to the following:"))
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">Counsel for Plaintiff</w:t>"#))
    }

    // MARK: - sectPr (LOCKED §4.6)

    func testSectionHasTitlePageBothFooterRefsAndMargins() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: .defaultFL)
        XCTAssertTrue(xml.contains(#"<w:footerReference w:type="default" r:id="rIdFooter1"/>"#))
        XCTAssertTrue(xml.contains(#"<w:footerReference w:type="first" r:id="rIdFooterEmpty"/>"#))
        XCTAssertTrue(xml.contains(#"<w:pgSz w:w="12240" w:h="15840"/>"#))
        XCTAssertTrue(xml.contains(#"<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440""#))
        XCTAssertTrue(xml.contains(#"<w:pgNumType w:start="1"/>"#))
        XCTAssertTrue(xml.contains("<w:titlePg/>"))
    }

    // MARK: - Numbered allegation (LOCKED §4.4)

    func testNumberedAllegationNumberAtMarginTabToHalfInch() throws {
        let model = DocumentModel(
            caption: noticeModel.caption, title: "MOTION",
            body: [.numberedAllegation(number: 1, text: "The parties entered an agreement.")],
            signature: harwellBranch, certificate: nil
        )
        let xml = try CourtFLRenderer().documentXML(model, style: .defaultFL)
        XCTAssertTrue(xml.contains(#"<w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs><w:spacing w:line="480" w:lineRule="auto"/><w:jc w:val="both"/></w:pPr><w:r><w:t xml:space="preserve">1.</w:t></w:r><w:r><w:tab/></w:r><w:r><w:t xml:space="preserve">The parties entered an agreement.</w:t></w:r>"#))
    }

    // MARK: - Point heading hanging indent (LOCKED §4.3)

    func testPointHeadingLevel1HangingIndentAndSpacingAfter() throws {
        let model = DocumentModel(
            caption: noticeModel.caption, title: "MOTION",
            body: [.pointHeading(level: 1, numeral: "I.", text: "THE COMPLAINT FAILS.")],
            signature: harwellBranch, certificate: nil
        )
        let xml = try CourtFLRenderer().documentXML(model, style: .defaultFL)
        XCTAssertTrue(xml.contains(#"<w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs><w:spacing w:after="240"/><w:ind w:left="720" w:hanging="720"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">I.</w:t></w:r><w:r><w:tab/></w:r><w:r><w:rPr><w:b/><w:caps/></w:rPr><w:t xml:space="preserve">THE COMPLAINT FAILS.</w:t></w:r>"#))
    }

    func testPointHeadingLevel2HasTabStopAt1440() throws {
        let model = DocumentModel(
            caption: noticeModel.caption, title: "MOTION",
            body: [.pointHeading(level: 2, numeral: "A.", text: "Sub point.")],
            signature: harwellBranch, certificate: nil
        )
        let xml = try CourtFLRenderer().documentXML(model, style: .defaultFL)
        XCTAssertTrue(xml.contains(#"<w:tab w:val="left" w:pos="1440"/></w:tabs><w:spacing w:after="240"/><w:ind w:left="1440" w:hanging="720"/>"#))
        // level-2 heading text is bold but NOT caps
        XCTAssertTrue(xml.contains(#"<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">Sub point.</w:t></w:r>"#))
    }

    // MARK: - Floor guard (LOCKED §3)

    func testFloorGuardThrowsBelow12pt() {
        var style = HouseStyleSheet.defaultFL
        style.page.fontHalfPoints = 22
        XCTAssertThrowsError(try CourtFLRenderer().documentXML(noticeModel, style: style)) { error in
            guard case DraftError.styleFloorViolation = error else {
                return XCTFail("Expected styleFloorViolation, got \(error)")
            }
        }
    }

    func testFloorGuardThrowsBelowOneInchMargin() {
        var style = HouseStyleSheet.defaultFL
        style.page.marginTwips = EdgeInsets(top: 1440, leading: 720, bottom: 1440, trailing: 1440)
        XCTAssertThrowsError(try CourtFLRenderer().documentXML(noticeModel, style: style)) { error in
            guard case DraftError.styleFloorViolation = error else {
                return XCTFail("Expected styleFloorViolation, got \(error)")
            }
        }
    }

    // MARK: - End-to-end: renders a real .docx whose visible text matches the notice golden

    func testRenderedNoticeMatchesGoldenVisibleTextKeyLines() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: .defaultFL)
        let text = OoxmlNormalizer.visibleText(xml)
        let golden = OoxmlNormalizer.visibleText(try loadGolden("noticeAppearance-golden.document.xml"))
        // Shared anchor lines present in both (renderer-owned, slot-driven).
        for anchor in ["IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,",
                       "MCKERNON MOTORS, INC.,", "Plaintiff,", "v.",
                       "LIBERTY RAIL, LLC,", "Defendant.",
                       "CASE NO.: 2026-CA-001847", "DIVISION: CV-G",
                       "NOTICE OF APPEARANCE", "Pearson Specter Litt",
                       "/s/ Harvey Specter", "Florida Bar No. 100847",
                       "Attorneys for Defendant", "CERTIFICATE OF SERVICE",
                       "Counsel for Plaintiff"] {
            XCTAssertTrue(text.contains(anchor), "renderer output missing anchor: \(anchor)")
            XCTAssertTrue(golden.contains(anchor), "golden missing anchor: \(anchor)")
        }
    }

    func testRenderProducesOpenableDocxBytes() throws {
        let data = try CourtFLRenderer().render(.court(noticeModel), style: .defaultFL)
        XCTAssertGreaterThan(data.count, 1000)
        // OPC zip magic
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B])
    }
}
