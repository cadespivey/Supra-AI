import SupraDraftingCore
import XCTest

final class DraftingCoreTypesTests: XCTestCase {
    func testDraftKindDefinitionsSeparateAuthorityFromFactGrounding() {
        let notice = DraftKindDefinition(
            id: .noticeAppearance,
            renderShell: .courtFL,
            defaultSkeleton: .none,
            blockType: .servicePipeline,
            groundingPolicy: .noMatterFacts,
            assertsLegalAuthority: false,
            slotSpecs: [],
            headingContract: HeadingContract(required: [.caption, .title, .body, .signature, .certificateOfService])
        )
        let letter = DraftKindDefinition(
            id: .letterDemand,
            renderShell: .letterhead,
            defaultSkeleton: .none,
            blockType: .routedSkill,
            groundingPolicy: .matterFactsRequired,
            assertsLegalAuthority: false,
            slotSpecs: [],
            headingContract: HeadingContract(required: [.wholeLetter])
        )
        let motion = DraftKindDefinition(
            id: .motionToDismiss,
            renderShell: .courtFL,
            defaultSkeleton: .houseMotionFL,
            blockType: .contract,
            groundingPolicy: .authorityAndFacts,
            assertsLegalAuthority: true,
            slotSpecs: [],
            headingContract: HeadingContract(required: [.caption, .title, .introduction, .statementOfFacts, .memorandumOfLaw, .argument, .conclusion, .signature, .certificateOfService])
        )

        XCTAssertFalse(notice.requiresFactProvenance)
        XCTAssertTrue(letter.requiresFactProvenance, "Demand letters are non-Auth but still grounded in matter facts")
        XCTAssertFalse(letter.assertsLegalAuthority)
        XCTAssertTrue(motion.requiresFactProvenance)
        XCTAssertTrue(motion.assertsLegalAuthority)
        XCTAssertEqual(motion.defaultSkeleton, .houseMotionFL)
    }

    func testSlotSpecsUseSerializableValidatorKeysAndTypedContent() {
        let officeSpec = SlotSpec(
            key: "office",
            type: .officeBlock,
            source: .assistantProfile,
            requirement: .required,
            validator: .none
        )
        let amount = SlotContent.money(Decimal(1250), currency: "USD")
        let serviceRecipients = SlotContent.serviceRecipients([
            ServiceRecipient(
                name: "Harvey Specter",
                firm: "Example LLP",
                address: OfficeBlock(street: "1 Main St", suite: nil, city: "Jacksonville", state: "FL", zip: "32202", phone: "904-555-0100", fax: nil),
                emails: ["hspecter@psl.com"],
                role: "Counsel for Plaintiff"
            )
        ])

        XCTAssertEqual(officeSpec.validator, .none)
        XCTAssertEqual(officeSpec.type, .officeBlock)
        XCTAssertEqual(amount, .money(Decimal(1250), currency: "USD"))
        XCTAssertEqual(serviceRecipients.serviceRecipientValues?.first?.emails, ["hspecter@psl.com"])
    }

    func testVerifyUnitCarriesFactsAndAuthoritiesForAsyncVerifier() async {
        let section = GeneratedSection(
            blocks: [.paragraph("Liberty Rail failed to pay [S1].")],
            citesUsed: [CitationRef(raw: "[cite]")],
            assertedFacts: [FactRef(label: "[S1]")]
        )
        let facts = [GroundedFact(text: "Invoice remains unpaid", label: "[S1]", docId: "doc-1", locator: "p.1")]
        let result = await CapturingVerifier().verify(
            .section(section, requirement: SectionRequirement(section: .argument, mustContain: [], elementKeys: []), facts: facts, authorities: []),
            kind: .motionToDismiss,
            style: .defaultFL
        )

        XCTAssertTrue(result.failures.isEmpty)
    }

    // MVS-01. Expected RED: MotionVerificationEvidence and VerifyUnit.motion do not exist.
    func testVerifyUnitCarriesOrderedMotionEvidence() async {
        let model = DocumentModel(
            caption: CaptionModel(
                courtHeader: "FICTIONAL COURT",
                parties: [PartyLine(name: "Alpha", designation: "Plaintiff"), PartyLine(name: "Beta", designation: "Defendant")],
                caseNumber: "2026-CV-001",
                division: nil,
                judge: nil
            ),
            title: "MOTION TO DISMISS",
            body: [],
            signature: nil,
            certificate: nil
        )
        let evidence = MotionVerificationEvidence(
            facts: [MotionFactEvidence(
                factID: "fact-nondefault",
                text: "The fictional complaint alleges a written agreement.",
                sourceID: "revision-nondefault",
                locator: "p. 7"
            )],
            authorities: [MotionAuthorityEvidence(
                authorityID: "authority-nondefault",
                citation: "Example v. Fictional, 123 So. 3d 456 (Fla. 1st DCA 2020)",
                reviewedExcerpt: "A complaint must plead ultimate facts.",
                groundKey: "mtd.failureToStateClaim"
            )],
            bodyContract: MotionBodyContract(
                introduction: "Defendant moves to dismiss.",
                argumentHeading: "THE COMPLAINT FAILS TO STATE A CLAIM.",
                conclusion: "WHEREFORE, Defendant requests dismissal."
            )
        )

        let result = await CapturingVerifier().verify(
            .motion(model: model, evidence: evidence),
            kind: .motionToDismiss,
            style: .defaultFL
        )

        XCTAssertTrue(result.failures.isEmpty)
    }
}

private struct CapturingVerifier: Verifier {
    let identity = DraftComponentIdentity(id: "test.capturing-verifier", version: "1")

    func verify(_ unit: VerifyUnit, kind: DraftKindID, style: HouseStyleSheet) async -> VerificationResult {
        switch unit {
        case let .section(section, _, facts, authorities):
            XCTAssertEqual(section.assertedFacts, [FactRef(label: "[S1]")])
            XCTAssertEqual(facts.first?.label, "[S1]")
            XCTAssertTrue(authorities.isEmpty)
        case let .motion(_, evidence):
            XCTAssertEqual(evidence.facts.map(\.factID), ["fact-nondefault"])
            XCTAssertEqual(evidence.authorities.map(\.authorityID), ["authority-nondefault"])
            XCTAssertEqual(evidence.authorities.first?.canonicalParagraph,
                           "Example v. Fictional, 123 So. 3d 456 (Fla. 1st DCA 2020): A complaint must plead ultimate facts.")
        default:
            XCTFail("Expected section verification")
        }
        return VerificationResult(failures: [], followUps: [])
    }
}
