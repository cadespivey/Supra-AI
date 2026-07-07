import Foundation
import SupraDraftingCore
@testable import SupraExports
import XCTest

/// WIRE-PROOF (PLAN M1-T5/T6) — each renders a NON-DEFAULT FirmStyleProfile value and asserts the
/// customized token IS present AND the default token IS absent, at EXACT-`<w:t>`-ELEMENT or
/// TARGET-PARAGRAPH scope (never a whole-document short/shared substring). Every renderer `<w:t>`
/// run carries xml:space="preserve" unconditionally (Ooxml/OoxmlWriter.swift), so exact runs take
/// the form `<w:t xml:space="preserve">…</w:t>`.
///
/// RED-first: this file COMPILES against the M1 foundation (FirmStyleProfile exists), so the RED
/// state is an ASSERTION FAILURE per test — the customized token is absent and the baked default
/// token is present — until CourtFLRenderer / LetterheadRenderer read the style fields (M1-T5/T6).
/// (T-BODY-04 is already GREEN from the foundation: the renderer already reads `style.body.justify`.)
final class FirmStyleWireProofTests: XCTestCase {

    // MARK: - Shared fixtures (mirror CourtFLRendererTests / LetterheadRendererTests)

    private func captionModel(judge: String? = nil) -> CaptionModel {
        CaptionModel(
            courtHeader: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            parties: [PartyLine(name: "MCKERNON MOTORS, INC.,", designation: "Plaintiff,"),
                      PartyLine(name: "LIBERTY RAIL, LLC,", designation: "Defendant.")],
            caseNumber: "2026-CA-001847", division: "CV-G", judge: judge)
    }

    private func signature(respectfullySubmitted: DateOnly? = nil,
                           secondary: [String] = ["litdocket@pearsonspecterlitt.example"]) -> SignatureBlockModel {
        SignatureBlockModel(
            respectfullySubmitted: respectfullySubmitted, firmName: "Pearson Specter Litt",
            signingAttorney: "Harvey Specter",
            attorneys: [AttorneyLine(name: "Harvey Specter", barNumber: "Florida Bar No. 100847")],
            office: OfficeBlock(street: "200 West Forsyth Street", suite: "Suite 1400",
                                city: "Jacksonville", state: "Florida", zip: "32202",
                                phone: "(904) 555-0142", fax: "(904) 555-0143"),
            partyRepresented: "Defendant",
            emails: EmailDesignation(primary: "hspecter@pearsonspecterlitt.example",
                                     secondary: secondary))
    }

    private func certificate() -> CertificateModel {
        CertificateModel(
            date: DateOnly(year: 2026, month: 6, day: 25), clause: .flEPortal,
            documentTitle: "NOTICE OF APPEARANCE",
            recipients: [ServiceRecipient(
                name: "Daniel Hardman, Esq.", firm: "Hardman & Tanner, LLP",
                address: OfficeBlock(street: "1 Independent Drive", suite: "Suite 2400",
                                     city: "Jacksonville", state: "Florida", zip: "32202",
                                     phone: "", fax: nil),
                emails: ["dhardman@hardmantanner.example"], role: "Counsel for Plaintiff")],
            signOffAttorney: "Harvey Specter")
    }

    /// Notice: single plain-paragraph body, judge nil, secondary email present.
    private var noticeModel: DocumentModel {
        DocumentModel(caption: captionModel(), title: "NOTICE OF APPEARANCE",
                      body: [.paragraph("PLEASE TAKE NOTICE that the undersigned attorney appears.")],
                      signature: signature(), certificate: certificate())
    }

    /// Caption variant WITH a judge — exercises the judgeLabel line.
    private var judgeCaptionModel: DocumentModel {
        DocumentModel(caption: captionModel(judge: "Hon. Jane Roe"), title: "NOTICE OF APPEARANCE",
                      body: [.paragraph("PLEASE TAKE NOTICE that the undersigned attorney appears.")],
                      signature: signature(), certificate: certificate())
    }

    /// Signature variant with NO secondary email — exercises the primary-only emailLabel branch.
    private var noSecondaryEmailModel: DocumentModel {
        DocumentModel(caption: captionModel(), title: "NOTICE OF APPEARANCE",
                      body: [.paragraph("PLEASE TAKE NOTICE that the undersigned attorney appears.")],
                      signature: signature(secondary: []), certificate: certificate())
    }

    /// Motion: numbered allegations + a level-1 point heading + respectfullySubmitted date.
    /// Exercises numberFormat (#25), baseIndent/spaceAfter (#26-29) and submittedLabel (#16).
    private var motionModel: DocumentModel {
        DocumentModel(
            caption: captionModel(), title: "DEFENDANT'S MOTION TO DISMISS",
            body: [
                .numberedAllegation(1, "Plaintiff filed its complaint on June 1, 2026."),
                .numberedAllegation(2, "The complaint fails to state a cause of action."),
                .pointHeading(1, "I.", "THE COMPLAINT FAILS TO STATE A CLAIM"),
                .paragraph("For these reasons the motion should be granted.")
            ],
            signature: signature(respectfullySubmitted: DateOnly(year: 2026, month: 6, day: 25)),
            certificate: certificate())
    }

    private var letterModel: LetterModel {
        LetterModel(
            letterhead: LetterheadFill(firmName: "Pearson Specter Litt",
                office: OfficeBlock(street: "200 West Forsyth Street", suite: "Suite 1400",
                                    city: "Jacksonville", state: "Florida", zip: "32202",
                                    phone: "(904) 555-0142", fax: "(904) 555-0143")),
            date: DateOnly(year: 2026, month: 6, day: 25),
            recipient: AddressBlock(name: "Mr. Charles Forstman", title: nil, firm: "Forstman Capital, LLC",
                                    street: "4820 Southpoint Parkway", city: "Jacksonville", state: "Florida", zip: "32216"),
            reLine: "Outstanding Balance Owed to McKernon Motors — Demand for Payment",
            salutation: "Dear Mr. Forstman:",
            body: ["This firm represents McKernon Motors."],
            closing: "Respectfully,", signerName: "Harvey Specter", signerTitle: nil,
            enclosures: ["Statement of Unpaid Invoices"], cc: ["McKernon Motors"])
    }

    private func style(_ mutate: (inout FirmStyleProfile) -> Void) -> HouseStyleSheet {
        var p = FirmStyleProfile(); mutate(&p); return p.resolved(over: .defaultFL)
    }

    /// Returns the `<w:p>…</w:p>` fragment that contains `text` — the paragraph-scoping helper the
    /// toggle/format wire-proofs use so an absence assert cannot be contaminated by the same
    /// formatting run on an unrelated element. XCTUnwrap (no silent guard-return).
    private func paragraph(containing text: String, in xml: String) throws -> String {
        let frags = xml.components(separatedBy: "</w:p>")
        let hit = try XCTUnwrap(frags.first(where: { $0.contains(text) }),
                                "no paragraph contained \(text)")
        return hit + "</w:p>"
    }

    // MARK: - CourtFLRenderer — caption (#8–13 + toggles)

    // T-CAP-01 — party separator. RED (unwired): exact <w:t>v.</w:t> run present.
    func testPartySeparatorIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.captionPartySeparator = "vs." })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">vs.</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">v.</w:t>"#))
    }

    // T-CAP-02 — closing-rule glyph. The bare "/" is contaminated by the /s/ signature marks,
    // so assert the EXACT glyph run. RED (unwired): exact <w:t>/</w:t> glyph run present.
    func testClosingRuleGlyphIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.captionClosingRuleGlyph = "§" })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">§</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">/</w:t>"#))   // NOT contains("/")
    }

    // T-CAP-03 — case-number label. RED: exact <w:t>CASE NO.: …</w:t> run present.
    func testCaseNumberLabelIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.captionCaseNumberLabel = "CASE NUMBER: " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">CASE NUMBER: 2026-CA-001847</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">CASE NO.: 2026-CA-001847</w:t>"#))
    }

    // T-CAP-04 — division label.
    func testDivisionLabelIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.captionDivisionLabel = "DIV: " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">DIV: CV-G</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">DIVISION: CV-G</w:t>"#))
    }

    // T-CAP-05 — judge label (fixture WITH a judge, else the line never renders).
    func testJudgeLabelIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(judgeCaptionModel, style: style { $0.captionJudgeLabel = "J.: " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">J.: Hon. Jane Roe</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">JUDGE: Hon. Jane Roe</w:t>"#))
    }

    // T-CAP-06 — designation indent, PARAGRAPH-SCOPED to the designation ("Plaintiff,").
    func testDesignationIndentIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.captionDesignationIndentTwips = 1000 })
        let designation = try paragraph(containing: "Plaintiff,", in: xml)
        XCTAssertTrue(designation.contains(#"w:left="1000""#))
        XCTAssertFalse(designation.contains(#"w:left="720""#))
    }

    // T-CAP-07 — headerBoldCentered toggle, PARAGRAPH-SCOPED (bold/center appear on many elements).
    func testHeaderBoldCenteredToggleIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.captionHeaderBoldCentered = false })
        let header = try paragraph(containing: "IN THE CIRCUIT COURT", in: xml)
        XCTAssertFalse(header.contains("<w:b/>"))
        XCTAssertFalse(header.contains(#"<w:jc w:val="center"/>"#))
    }

    // T-CAP-08 — closingRuleEndsInSlash=false ⇒ the closing-rule glyph run is gone, caption remains.
    func testClosingRuleEndsInSlashToggleIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.captionClosingRuleEndsInSlash = false })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">CASE NO.: 2026-CA-001847</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">/</w:t>"#))
    }

    // MARK: - CourtFLRenderer — signature (#14–21 + toggles)

    // T-SIG-01 — e-signature mark.
    func testESignatureMarkIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.signatureESignatureMark = "s/ " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">s/ Harvey Specter</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">/s/ Harvey Specter</w:t>"#))
    }

    // T-SIG-02 — "By: " prefix (signature block only; certificate sign-off has no prefix).
    func testByPrefixIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.signatureByPrefix = "BY: " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">BY: </w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">By: </w:t>"#))
    }

    // T-SIG-03 — submittedLabel, MOTION fixture (line renders only when respectfullySubmitted != nil).
    func testSubmittedLabelIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(motionModel, style: style { $0.signatureSubmittedLabel = "Respectfully yours: " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">Respectfully yours: June 25, 2026</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">Respectfully submitted: June 25, 2026</w:t>"#))
    }

    // T-SIG-04 — representationPrefix.
    func testRepresentationPrefixIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.signatureRepresentationPrefix = "Counsel for " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">Counsel for Defendant</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">Attorneys for Defendant</w:t>"#))
    }

    // T-SIG-05 — barNumberLabel. The EXACT default run breaks when the prefix is prepended, so
    // the absence assert is satisfiable (a loose substring would not be).
    func testBarNumberLabelIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.signatureBarNumberLabel = "Fla. Bar No. " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">Fla. Bar No. Florida Bar No. 100847</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">Florida Bar No. 100847</w:t>"#))
    }

    // T-SIG-06 — signature phone label.
    func testSignaturePhoneLabelIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.signaturePhoneLabel = "Tel: " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">Tel: (904) 555-0142</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">Telephone: (904) 555-0142</w:t>"#))
    }

    // T-SIG-07 — signature fax label.
    func testSignatureFaxLabelIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.signatureFaxLabel = "Fax: " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">Fax: (904) 555-0143</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">Facsimile: (904) 555-0143</w:t>"#))
    }

    // T-SIG-08 — email labels: TWO renders so BOTH branches (with-secondary + primary-only) are proven.
    func testEmailLabelsAreWired() throws {
        let withSecondary = try CourtFLRenderer().documentXML(
            noticeModel, style: style { $0.signatureEmailLabelWithSecondary = "E1/E2: " })
        XCTAssertTrue(withSecondary.contains(#"<w:t xml:space="preserve">E1/E2: </w:t>"#))
        XCTAssertFalse(withSecondary.contains(#"<w:t xml:space="preserve">Primary and Secondary E-Mail: </w:t>"#))

        let primaryOnly = try CourtFLRenderer().documentXML(
            noSecondaryEmailModel, style: style { $0.signatureEmailLabel = "E: " })
        XCTAssertTrue(primaryOnly.contains(#"<w:t xml:space="preserve">E: </w:t>"#))
        XCTAssertFalse(primaryOnly.contains(#"<w:t xml:space="preserve">Primary E-Mail: </w:t>"#))
    }

    // T-SIG-09 — firmNameBoldCaps toggle, PARAGRAPH-SCOPED to the bold-caps firm-name paragraph
    // (the FIRST paragraph containing the firm name).
    func testFirmNameBoldCapsToggleIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.signatureFirmNameBoldCaps = false })
        let firm = try paragraph(containing: "Pearson Specter Litt", in: xml)
        XCTAssertFalse(firm.contains("<w:b/>"))
        XCTAssertFalse(firm.contains("<w:caps/>"))
    }

    // T-SIG-10 — representationLineItalic toggle, PARAGRAPH-SCOPED to the representation line.
    func testRepresentationLineItalicToggleIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.signatureRepresentationLineItalic = false })
        let rep = try paragraph(containing: "Attorneys for Defendant", in: xml)
        XCTAssertFalse(rep.contains("<w:i/>"))
    }

    // MARK: - CourtFLRenderer — certificate (#22–24 + toggle)

    // T-CERT-01 — certificate heading.
    func testCertificateHeadingIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.certificateHeading = "CERTIFICATE OF SVC" })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">CERTIFICATE OF SVC</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">CERTIFICATE OF SERVICE</w:t>"#))
    }

    // T-CERT-02 — attestation prefix/suffix wired; middle connective ", I " preserved.
    func testAttestationPrefixSuffixWiredMiddleConnectivePreserved() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style {
            $0.certificateAttestationPrefix = "I CERTIFY on "
            $0.certificateAttestationSuffix = " upon:"
        })
        XCTAssertTrue(xml.contains("I CERTIFY on June 25, 2026, I "))   // prefix + middle ", I " preserved
        XCTAssertTrue(xml.contains(" upon:"))                           // suffix
        XCTAssertFalse(xml.contains("I HEREBY CERTIFY that on "))       // default prefix gone
    }

    // T-CERT-03 — per-clause override.
    func testClauseTextOverrideIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style {
            $0.certificateClauseText = [.flEPortal: "CUSTOM CLAUSE"]
        })
        XCTAssertTrue(xml.contains("CUSTOM CLAUSE"))
        XCTAssertFalse(xml.contains("electronically filed the foregoing with the Clerk of Court using the Florida Courts E-Filing Portal"))
    }

    // T-CERT-04 — headingCenteredBoldCaps toggle, PARAGRAPH-SCOPED to the certificate heading.
    func testCertificateHeadingBoldCapsToggleIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.certificateHeadingCenteredBoldCaps = false })
        let heading = try paragraph(containing: "CERTIFICATE OF SERVICE", in: xml)
        XCTAssertFalse(heading.contains("<w:b/>"))
        XCTAssertFalse(heading.contains("<w:caps/>"))
        XCTAssertFalse(heading.contains(#"<w:jc w:val="center"/>"#))
    }

    // MARK: - CourtFLRenderer — body / heading geometry (#25–29 + bodyJustify overlay)

    // T-BODY-01 — numberFormat, MOTION fixture (.numberedAllegation renders the number).
    func testNumberFormatIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(motionModel, style: style { $0.bodyNumberFormat = .numberParen })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">1)</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">1.</w:t>"#))
    }

    // T-BODY-02 — heading base indent, MOTION fixture (.pointHeading), PARAGRAPH-SCOPED to the heading.
    func testHeadingBaseIndentIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(motionModel, style: style { $0.bodyBaseIndentTwips = 1000 })
        let heading = try paragraph(containing: "THE COMPLAINT FAILS TO STATE A CLAIM", in: xml)
        XCTAssertTrue(heading.contains(#"w:left="1000""#))
        XCTAssertTrue(heading.contains(#"w:pos="1000""#))
        XCTAssertFalse(heading.contains(#"w:left="720""#))
        XCTAssertFalse(heading.contains(#"w:pos="720""#))
    }

    // T-BODY-03 — spaceAfterTwips, MOTION fixture (.pointHeading), PARAGRAPH-SCOPED to the heading.
    func testHeadingSpaceAfterIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(motionModel, style: style { $0.bodySpaceAfterTwips = 360 })
        let heading = try paragraph(containing: "THE COMPLAINT FAILS TO STATE A CLAIM", in: xml)
        XCTAssertTrue(heading.contains(#"w:after="360""#))
        XCTAssertFalse(heading.contains(#"w:after="240""#))
    }

    // T-BODY-04 — bodyJustify overlay, PARAGRAPH-SCOPED to the notice body. GREEN from the
    // foundation: the renderer already reads style.body.justify, so justify=false suppresses
    // <w:jc w:val="both"/> once resolved(over:) + FirmStyleProfile.bodyJustify exist (M1-T2/T4).
    func testBodyJustifyOverlaySuppressesJustification() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.bodyJustify = false })
        let body = try paragraph(containing: "PLEASE TAKE NOTICE that the undersigned attorney appears.", in: xml)
        XCTAssertFalse(body.contains(#"<w:jc w:val="both"/>"#))
    }

    // MARK: - LetterheadRenderer (#1–7 + bottomRule + bodyParagraphStyle)

    // T-LH-01 — letterhead tagline.
    func testTaglineIsWired() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: style { $0.letterheadTagline = "Counselors at Law" })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">Counselors at Law</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">Attorneys at Law</w:t>"#))
    }

    // T-LH-02 — letterhead phone label (masthead contact line is a single run).
    func testLetterheadPhoneLabelIsWired() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: style { $0.letterheadPhoneLabel = "Tel: " })
        XCTAssertTrue(xml.contains("Tel: (904) 555-0142"))
        XCTAssertFalse(xml.contains("Telephone: (904) 555-0142"))
    }

    // T-LH-03 — letterhead fax label.
    func testLetterheadFaxLabelIsWired() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: style { $0.letterheadFaxLabel = "Fax: " })
        XCTAssertTrue(xml.contains("Fax: (904) 555-0143"))
        XCTAssertFalse(xml.contains("Facsimile: (904) 555-0143"))
    }

    // T-LH-04 — RE label.
    func testRELabelIsWired() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: style { $0.letterheadRELabel = "Re:" })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">Re:</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">RE:</w:t>"#))
    }

    // T-LH-05 — RE indent/hanging: assert the CONTIGUOUS attribute pair (w:left=1440 alone is
    // contaminated by the signature indent).
    func testREIndentHangingWired() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: style {
            $0.letterheadREIndentTwips = 1000; $0.letterheadREHangingTwips = 300 })
        XCTAssertTrue(xml.contains(#"w:left="1000" w:hanging="300""#))
        XCTAssertFalse(xml.contains(#"w:left="1440" w:hanging="720""#))
    }

    // T-LH-06 — enclosure prefix.
    func testEnclosurePrefixIsWired() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: style { $0.letterheadEnclosurePrefix = "Encl: " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">Encl: Statement of Unpaid Invoices</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">Enclosure: Statement of Unpaid Invoices</w:t>"#))
    }

    // T-LH-07 — cc prefix (default has a double space).
    func testCCPrefixIsWired() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: style { $0.letterheadCCPrefix = "copy to: " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">copy to: McKernon Motors</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">cc:  McKernon Motors</w:t>"#))
    }

    // T-LH-08 — bottomRule toggle: false ⇒ the masthead rule paragraph is gone; the date remains.
    func testBottomRuleToggleIsWired() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: style { $0.letterheadBottomRule = false })
        XCTAssertTrue(xml.contains("June 25, 2026"))                              // date still present
        XCTAssertFalse(xml.contains(#"<w:pBdr><w:bottom w:val="single""#))       // masthead rule gone
    }

    // T-LH-09 — bodyParagraphStyle .indented ⇒ first-line indent on the body paragraph.
    func testLetterheadParagraphStyleIsWired() throws {
        let xml = LetterheadRenderer().documentXML(letterModel, style: style { $0.letterheadParagraphStyle = .indented })
        let body = try paragraph(containing: "This firm represents McKernon Motors.", in: xml)
        XCTAssertTrue(body.contains(#"<w:ind w:firstLine="720"/>"#))
        XCTAssertFalse(body.contains(#"w:firstLine="0""#))
    }
}
