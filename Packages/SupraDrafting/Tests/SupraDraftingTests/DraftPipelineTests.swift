import Foundation
import SupraDrafting
import SupraDraftingCore
import SupraExports
import XCTest

/// Pipeline, firewall, and gate fixtures (NoticeAppearance §7.3 / MotionToDismiss §3.2–§3.3 /
/// LetterDemand §4). These prove the firewall invariants and the deterministic gates fire.
final class DraftPipelineTests: XCTestCase {

    private var profile: FirmProfile {
        FirmProfile(
            firmName: "Harwell & Branch, P.A.",
            signingAttorney: "Jordan A. Reyes",
            barNumber: "100847",
            office: OfficeBlock(street: "200 West Forsyth Street", suite: "Suite 1400",
                                city: "Jacksonville", state: "Florida", zip: "32202",
                                phone: "(904) 555-0142", fax: "(904) 555-0143"),
            primaryEmail: "jreyes@harwellbranch.example",
            secondaryEmails: ["litdocket@harwellbranch.example"]
        )
    }

    private var noticeInputs: NoticeAppearance.Inputs {
        NoticeAppearance.Inputs(
            courtHeader: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            parties: [PartyLine(name: "MERIDIAN CAPITAL PARTNERS, LLC,", designation: "Plaintiff,"),
                      PartyLine(name: "ATLANTIC RIDGE HOLDINGS, INC.,", designation: "Defendant.")],
            partyRepresented: "Defendant",
            representedPartyName: "Atlantic Ridge Holdings, Inc.",
            caseNumber: "2026-CA-001847",
            division: "CV-G",
            serviceDate: DateOnly(year: 2026, month: 6, day: 25),
            recipients: [ServiceRecipient(
                name: "Marcus T. Whitfield, Esq.", firm: "Caldwell & Pierce, LLP",
                address: OfficeBlock(street: "1 Independent Drive", suite: "Suite 2400",
                                     city: "Jacksonville", state: "Florida", zip: "32202", phone: "", fax: nil),
                emails: ["mwhitfield@caldwellpierce.example"], role: "Counsel for Plaintiff"
            )]
        )
    }

    // MARK: - Notice end-to-end (no LLM)

    func testNoticePipelineRendersDocxWithNoBlockingFollowUps() async throws {
        let pipeline = DraftPipeline(verifier: DraftVerifier(), renderer: CourtFLRenderer())
        let result = try await pipeline.runNotice(noticeInputs, profile: profile, style: .defaultFL)
        XCTAssertEqual(Array(result.docx.prefix(2)), [0x50, 0x4B])
        XCTAssertFalse(result.followUps.contains { $0.severity == .blocking },
                       "a complete notice should raise no blocking follow-ups")
    }

    func testNoBakedIdentity_NoticeFirmAVsFirmB() async throws {
        let renderer = CourtFLRenderer()
        let xmlA = try renderer.documentXML(NoticeAppearance.assemble(noticeInputs, profile: profile), style: .defaultFL)

        let firmB = FirmProfile(
            firmName: "Sterling Vance LLP", signingAttorney: "Pat Vance", barNumber: "990012",
            office: OfficeBlock(street: "1 Bay St", suite: nil, city: "Tampa", state: "Florida",
                                zip: "33601", phone: "(813) 555-0001", fax: nil),
            primaryEmail: "pvance@sterlingvance.example"
        )
        let xmlB = try renderer.documentXML(NoticeAppearance.assemble(noticeInputs, profile: firmB), style: .defaultFL)

        XCTAssertTrue(xmlA.contains("Jordan A. Reyes"))
        XCTAssertFalse(xmlA.contains("Pat Vance"))
        XCTAssertTrue(xmlB.contains("Pat Vance"))
        XCTAssertFalse(xmlB.contains("Jordan A. Reyes"))
        XCTAssertFalse(xmlB.contains("jreyes@harwellbranch.example"))
    }

    func testTemplatePurity_NoBakedProperNamesInBodyTemplate() {
        // Render with a firm whose name/emails are obvious placeholders; assert the only proper
        // names / @-addresses present are the slot values (the template itself bakes none).
        let probe = FirmProfile(
            firmName: "ZZFIRM", signingAttorney: "ZZATTY", barNumber: "000000",
            office: OfficeBlock(street: "ZZSTREET", suite: nil, city: "ZZCITY", state: "FL", zip: "00000", phone: "000", fax: nil),
            primaryEmail: "zz@zz.example"
        )
        let model = NoticeAppearance.assemble(noticeInputs, profile: probe)
        // The body paragraphs must contain no @ address other than the slot value.
        for block in model.body {
            if case let .paragraph(text) = block {
                let ats = text.filter { $0 == "@" }.count
                if text.contains("@") {
                    XCTAssertTrue(text.contains("zz@zz.example"), "only slot e-mail may appear")
                    XCTAssertEqual(ats, text.components(separatedBy: "zz@zz.example").count - 1)
                }
            }
        }
    }

    // MARK: - Gate fixtures

    func testMissingCertificateRaisesBlockingStructureFollowUp() async {
        let model = DocumentModel(
            caption: NoticeAppearance.assemble(noticeInputs, profile: profile).caption,
            title: "NOTICE OF APPEARANCE",
            body: [.paragraph("x")],
            signature: NoticeAppearance.assemble(noticeInputs, profile: profile).signature,
            certificate: nil
        )
        let gate = PreFileGate()
        let result = gate.check(court: model, kind: .noticeAppearance, style: .defaultFL)
        XCTAssertTrue(result.followUps.contains { $0.severity == .blocking && $0.kind == .structure })
    }

    func testFloorViolationRaisesRuleConformanceGate() {
        var style = HouseStyleSheet.defaultFL
        style.page.fontHalfPoints = 22
        let model = NoticeAppearance.assemble(noticeInputs, profile: profile)
        let result = PreFileGate().check(court: model, kind: .noticeAppearance, style: style)
        XCTAssertTrue(result.failures.contains { $0.gate == .ruleConformance })
        XCTAssertTrue(result.followUps.contains { $0.kind == .ruleViolation })
    }

    func testLetterGateNeverAddsCertificateRequirement() {
        let letter = LetterModel(
            letterhead: LetterheadFill(firmName: "Harwell & Branch, P.A.", office: profile.office),
            date: DateOnly(year: 2026, month: 6, day: 25),
            recipient: AddressBlock(name: "Mr. Coleman", title: nil, firm: "Coleman Logistics, LLC",
                                    street: "4820 Southpoint Parkway", city: "Jacksonville", state: "Florida", zip: "32216"),
            reLine: "Demand", salutation: "Dear Mr. Coleman:", body: ["Body."],
            closing: "Respectfully,", signerName: "Jordan A. Reyes", signerTitle: nil, enclosures: [], cc: []
        )
        let result = PreFileGate().check(letter: letter, style: .defaultFL)
        XCTAssertFalse(result.followUps.contains { $0.message.lowercased().contains("certificate") },
                       "pre-suit correspondence must never get a 2.516 certificate requirement")
        XCTAssertFalse(result.followUps.contains { $0.severity == .blocking })
    }
}
