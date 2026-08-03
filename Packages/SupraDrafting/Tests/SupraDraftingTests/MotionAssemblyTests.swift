import Foundation
import SupraDrafting
import SupraDraftingCore
import SupraExports
import XCTest

/// motionToDismiss skeleton assembly + render (MotionToDismiss §1.4 / §3.1). Proves the
/// houseMotionFL sequence lays out numbered facts and hanging-indent point headings per the golden.
final class MotionAssemblyTests: XCTestCase {

    private var motionEvidence: MotionVerificationEvidence {
        MotionVerificationEvidence(
            facts: [
                MotionFactEvidence(factID: "fact-1", text: "The parties are alleged to have entered an agreement.", sourceID: "revision-1", locator: "p. 1"),
                MotionFactEvidence(factID: "fact-2", text: "The Complaint does not attach the agreement.", sourceID: "revision-2", locator: "p. 2"),
                MotionFactEvidence(factID: "fact-3", text: "The breach allegation is conclusory.", sourceID: "revision-3", locator: "p. 3")
            ],
            authorities: [
                MotionAuthorityEvidence(
                    authorityID: "authority-1",
                    citation: "Example v. Fictional, 123 So. 3d 456 (Fla. 1st DCA 2020)",
                    reviewedExcerpt: "A plaintiff must allege a valid contract, breach, and damages.",
                    groundKey: "mtd.failureToStateClaim"
                ),
                MotionAuthorityEvidence(
                    authorityID: "authority-2",
                    citation: "Sample v. Placeholder, 789 So. 3d 101 (Fla. 2d DCA 2021)",
                    reviewedExcerpt: "A written-instrument claim must set forth its essential terms.",
                    groundKey: "mtd.failureToStateClaim"
                )
            ]
        )
    }

    private var signature: SignatureBlockModel {
        SignatureBlockModel(
            respectfullySubmitted: DateOnly(year: 2026, month: 6, day: 25),
            firmName: "Pearson Specter Litt", signingAttorney: "Harvey Specter",
            attorneys: [AttorneyLine(name: "Harvey Specter", barNumber: "Florida Bar No. 100847")],
            office: OfficeBlock(street: "200 West Forsyth Street", suite: "Suite 1400",
                                city: "Jacksonville", state: "Florida", zip: "32202",
                                phone: "(904) 555-0142", fax: "(904) 555-0143"),
            partyRepresented: "Defendant",
            emails: EmailDesignation(primary: "hspecter@pearsonspecterlitt.example", secondary: [])
        )
    }

    private var caption: CaptionModel {
        CaptionModel(
            courtHeader: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            parties: [PartyLine(name: "MCKERNON MOTORS, INC.,", designation: "Plaintiff,"),
                      PartyLine(name: "LIBERTY RAIL, LLC,", designation: "Defendant.")],
            caseNumber: "2026-CA-001847", division: "CV-G", judge: nil
        )
    }

    private func certificate() -> CertificateModel {
        CertificateModel(date: DateOnly(year: 2026, month: 6, day: 25), clause: .flEPortal,
                         documentTitle: "MOTION TO DISMISS",
                         recipients: [ServiceRecipient(name: "Daniel Hardman, Esq.", firm: "Hardman & Tanner, LLP",
                                                       address: OfficeBlock(street: "1 Independent Drive", suite: "Suite 2400",
                                                                            city: "Jacksonville", state: "Florida", zip: "32202", phone: "", fax: nil),
                                                       emails: ["dhardman@hardmantanner.example"], role: "Counsel for Plaintiff")],
                         signOffAttorney: "Harvey Specter")
    }

    private func buildMotion() -> DocumentModel {
        MotionToDismiss.assemble(
            caption: caption,
            title: MotionToDismiss.title(party: "Liberty Rail, LLC", partyRole: "Defendant", pleading: "Plaintiff's Complaint"),
            introduction: [.paragraph("Defendant moves to dismiss the Complaint.")],
            numberedFacts: ["The parties are alleged to have entered an agreement.",
                            "The Complaint does not attach the agreement.",
                            "The breach allegation is conclusory."],
            argumentPoints: [
                MotionToDismiss.ArgumentPoint(
                    heading: "THE COMPLAINT FAILS TO STATE A CAUSE OF ACTION FOR BREACH OF CONTRACT.",
                    body: [.paragraph(motionEvidence.authorities[0].canonicalParagraph)],
                    subPoints: [MotionToDismiss.ArgumentPoint(
                        heading: "McKernon Fails to Allege the Essential Terms of a Valid Contract.",
                        body: [.paragraph(motionEvidence.authorities[1].canonicalParagraph)]
                    )]
                ),
                MotionToDismiss.ArgumentPoint(
                    heading: "THE COMPLAINT IS AN IMPERMISSIBLE SHOTGUN PLEADING.",
                    body: [.paragraph("By incorporating every allegation into one count, the Complaint deprives Liberty Rail of fair notice.")]
                )
            ],
            conclusion: "WHEREFORE, Defendant respectfully requests that this Court dismiss the Complaint.",
            signature: signature,
            certificate: certificate()
        )
    }

    func testMotionTitleUppercased() {
        let model = buildMotion()
        XCTAssertEqual(model.title, "DEFENDANT LIBERTY RAIL, LLC'S MOTION TO DISMISS PLAINTIFF'S COMPLAINT")
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
        let result = try await pipeline.runMotion(model: buildMotion(), evidence: motionEvidence, style: .defaultFL)
        XCTAssertEqual(Array(result.docx.prefix(2)), [0x50, 0x4B])
        XCTAssertFalse(result.followUps.contains { $0.severity == .blocking })
    }
}
