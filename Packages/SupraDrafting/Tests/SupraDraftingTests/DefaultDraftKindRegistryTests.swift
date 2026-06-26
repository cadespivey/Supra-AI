import SupraDrafting
import SupraDraftingCore
import XCTest

final class DefaultDraftKindRegistryTests: XCTestCase {
    func testDefaultRegistryDefinesTheThreeVerticalSliceKinds() throws {
        let registry = DefaultDraftKindRegistry()

        let notice = try registry.definition(for: .noticeAppearance)
        XCTAssertEqual(notice.renderShell, .courtFL)
        XCTAssertEqual(notice.defaultSkeleton, .none)
        XCTAssertEqual(notice.blockType, .servicePipeline)
        XCTAssertEqual(notice.groundingPolicy, .noMatterFacts)
        XCTAssertFalse(notice.requiresFactProvenance)
        XCTAssertFalse(notice.assertsLegalAuthority)
        XCTAssertTrue(notice.slotSpecs.contains { $0.key == "office" && $0.type == .officeBlock })
        XCTAssertTrue(notice.slotSpecs.contains { $0.key == "recipients" && $0.type == .serviceRecipientList })

        let motion = try registry.definition(for: .motionToDismiss)
        XCTAssertEqual(motion.defaultSkeleton, .houseMotionFL)
        XCTAssertEqual(motion.groundingPolicy, .authorityAndFacts)
        XCTAssertTrue(motion.assertsLegalAuthority)
        XCTAssertTrue(motion.requiresFactProvenance)
        XCTAssertTrue(motion.slotSpecs.contains { $0.key == "grounds" && $0.source == .userPrompt })
        XCTAssertEqual(motion.headingContract.required, [.caption, .title, .introduction, .statementOfFacts, .memorandumOfLaw, .argument, .conclusion, .signature, .certificateOfService])

        let letter = try registry.definition(for: .letterDemand)
        XCTAssertEqual(letter.renderShell, .letterhead)
        XCTAssertEqual(letter.groundingPolicy, .matterFactsRequired)
        XCTAssertFalse(letter.assertsLegalAuthority)
        XCTAssertTrue(letter.requiresFactProvenance)
        XCTAssertEqual(letter.headingContract.required, [.wholeLetter])
        XCTAssertTrue(letter.slotSpecs.contains { $0.key == "demandAmount" && $0.type == .money })
    }

    func testMotionGroundSpecsProvideDeterministicAuthorityQueries() throws {
        let ground = try MotionGroundSpec.knownGround(for: "failure to state a claim")

        XCTAssertEqual(ground.key, "mtd.failureToStateClaim")
        XCTAssertEqual(ground.elementKeys, ["mtd.failureToStateClaim"])
        XCTAssertTrue(ground.authorityQueries.contains { $0.text.contains("Florida Rule of Civil Procedure 1.140(b)(6)") })
    }
}
