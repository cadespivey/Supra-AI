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
                name: "Alex Counsel",
                firm: "Example LLP",
                address: OfficeBlock(street: "1 Main St", suite: nil, city: "Jacksonville", state: "FL", zip: "32202", phone: "904-555-0100", fax: nil),
                emails: ["alex@example.com"],
                role: "Counsel for Plaintiff"
            )
        ])

        XCTAssertEqual(officeSpec.validator, .none)
        XCTAssertEqual(officeSpec.type, .officeBlock)
        XCTAssertEqual(amount, .money(Decimal(1250), currency: "USD"))
        XCTAssertEqual(serviceRecipients.serviceRecipientValues?.first?.emails, ["alex@example.com"])
    }

    func testVerifyUnitCarriesFactsAndAuthoritiesForAsyncVerifier() async {
        let section = GeneratedSection(
            blocks: [.paragraph("Atlantic Ridge failed to pay [S1].")],
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
}

private struct CapturingVerifier: Verifier {
    func verify(_ unit: VerifyUnit, kind: DraftKindID, style: HouseStyleSheet) async -> VerificationResult {
        switch unit {
        case let .section(section, _, facts, authorities):
            XCTAssertEqual(section.assertedFacts, [FactRef(label: "[S1]")])
            XCTAssertEqual(facts.first?.label, "[S1]")
            XCTAssertTrue(authorities.isEmpty)
        default:
            XCTFail("Expected section verification")
        }
        return VerificationResult(failures: [], followUps: [])
    }
}
