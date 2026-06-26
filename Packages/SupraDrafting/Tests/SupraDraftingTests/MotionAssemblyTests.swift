import Foundation
import SupraDrafting
import SupraDraftingCore
import SupraExports
import XCTest

/// motionToDismiss skeleton assembly + render (MotionToDismiss §1.4 / §3.1). Proves the
/// houseMotionFL sequence lays out numbered facts and hanging-indent point headings per the golden.
final class MotionAssemblyTests: XCTestCase {

    private var signature: SignatureBlockModel {
        SignatureBlockModel(
            respectfullySubmitted: DateOnly(year: 2026, month: 6, day: 25),
            firmName: "Harwell & Branch, P.A.", signingAttorney: "Jordan A. Reyes",
            attorneys: [AttorneyLine(name: "Jordan A. Reyes", barNumber: "Florida Bar No. 100847")],
            office: OfficeBlock(street: "200 West Forsyth Street", suite: "Suite 1400",
                                city: "Jacksonville", state: "Florida", zip: "32202",
                                phone: "(904) 555-0142", fax: "(904) 555-0143"),
            partyRepresented: "Defendant",
            emails: EmailDesignation(primary: "jreyes@harwellbranch.example", secondary: [])
        )
    }

    private var caption: CaptionModel {
        CaptionModel(
            courtHeader: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            parties: [PartyLine(name: "MERIDIAN CAPITAL PARTNERS, LLC,", designation: "Plaintiff,"),
                      PartyLine(name: "ATLANTIC RIDGE HOLDINGS, INC.,", designation: "Defendant.")],
            caseNumber: "2026-CA-001847", division: "CV-G", judge: nil
        )
    }

    private func certificate() -> CertificateModel {
        CertificateModel(date: DateOnly(year: 2026, month: 6, day: 25), clause: .flEPortal,
                         documentTitle: "MOTION TO DISMISS",
                         recipients: [ServiceRecipient(name: "Marcus T. Whitfield, Esq.", firm: "Caldwell & Pierce, LLP",
                                                       address: OfficeBlock(street: "1 Independent Drive", suite: "Suite 2400",
                                                                            city: "Jacksonville", state: "Florida", zip: "32202", phone: "", fax: nil),
                                                       emails: ["mwhitfield@caldwellpierce.example"], role: "Counsel for Plaintiff")],
                         signOffAttorney: "Jordan A. Reyes")
    }

    private func buildMotion() -> DocumentModel {
        MotionToDismiss.assemble(
            caption: caption,
            title: MotionToDismiss.title(party: "Atlantic Ridge Holdings, Inc.", partyRole: "Defendant", pleading: "Plaintiff's Complaint"),
            introduction: [.paragraph("Defendant moves to dismiss the Complaint.")],
            numberedFacts: ["The parties are alleged to have entered an agreement.",
                            "The Complaint does not attach the agreement.",
                            "The breach allegation is conclusory."],
            argumentPoints: [
                MotionToDismiss.ArgumentPoint(
                    heading: "THE COMPLAINT FAILS TO STATE A CAUSE OF ACTION FOR BREACH OF CONTRACT.",
                    body: [.paragraph("To state a claim, a plaintiff must allege a valid contract, breach, and damages. [cite]")],
                    subPoints: [MotionToDismiss.ArgumentPoint(
                        heading: "Meridian Fails to Allege the Essential Terms of a Valid Contract.",
                        body: [.paragraph("A claim on a written instrument must set forth its essential terms. [cite]")]
                    )]
                ),
                MotionToDismiss.ArgumentPoint(
                    heading: "THE COMPLAINT IS AN IMPERMISSIBLE SHOTGUN PLEADING.",
                    body: [.paragraph("By incorporating every allegation into one count, the Complaint deprives Atlantic Ridge of fair notice.")]
                )
            ],
            conclusion: "WHEREFORE, Defendant respectfully requests that this Court dismiss the Complaint.",
            signature: signature,
            certificate: certificate()
        )
    }

    func testMotionTitleUppercased() {
        let model = buildMotion()
        XCTAssertEqual(model.title, "DEFENDANT ATLANTIC RIDGE HOLDINGS, INC.'S MOTION TO DISMISS PLAINTIFF'S COMPLAINT")
    }

    func testSkeletonLaysOutSectionsInOrder() {
        let model = buildMotion()
        // Find the section headings in order.
        let headings = model.body.compactMap { block -> String? in
            if case let .sectionHeading(t) = block { return t }
            return nil
        }
        XCTAssertEqual(headings, ["STATEMENT OF FACTS", "MEMORANDUM OF LAW"])

        // Point headings: I., A. (sub), II., III. (conclusion).
        let pointNumerals = model.body.compactMap { block -> String? in
            if case let .pointHeading(_, numeral, _) = block { return numeral }
            return nil
        }
        XCTAssertEqual(pointNumerals, ["I.", "A.", "II.", "III."])
    }

    func testNumberedFactsAreSequential() {
        let model = buildMotion()
        let numbers = model.body.compactMap { block -> Int? in
            if case let .numberedAllegation(n, _) = block { return n }
            return nil
        }
        XCTAssertEqual(numbers, [1, 2, 3])
    }

    func testMotionRendersWithHangingIndentPointHeadingsAndRespectfullySubmitted() throws {
        let xml = try CourtFLRenderer().documentXML(buildMotion(), style: .defaultFL)
        // Level-1 "I." hanging indent.
        XCTAssertTrue(xml.contains(#"<w:ind w:left="720" w:hanging="720"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">I.</w:t></w:r>"#))
        // Level-2 "A." at 1440.
        XCTAssertTrue(xml.contains(#"<w:ind w:left="1440" w:hanging="720"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">A.</w:t></w:r>"#))
        // Dated "Respectfully submitted:" left-aligned firstLine 720.
        XCTAssertTrue(xml.contains(#"<w:ind w:firstLine="720"/></w:pPr><w:r><w:t xml:space="preserve">Respectfully submitted: June 25, 2026</w:t></w:r>"#))
        // Statement of facts centered bold heading (not underlined).
        XCTAssertTrue(xml.contains(#"<w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">STATEMENT OF FACTS</w:t></w:r>"#))
    }

    func testRomanNumeralHelper() {
        XCTAssertEqual(MotionToDismiss.roman(1), "I")
        XCTAssertEqual(MotionToDismiss.roman(3), "III")
        XCTAssertEqual(MotionToDismiss.roman(4), "IV")
        XCTAssertEqual(MotionToDismiss.roman(9), "IX")
    }

    func testMotionPipelineRenders() async throws {
        let pipeline = DraftPipeline(verifier: DraftVerifier(), renderer: CourtFLRenderer())
        let result = try await pipeline.runMotion(model: buildMotion(), style: .defaultFL)
        XCTAssertEqual(Array(result.docx.prefix(2)), [0x50, 0x4B])
        XCTAssertFalse(result.followUps.contains { $0.severity == .blocking })
    }
}
