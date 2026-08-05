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

    func testMotionGroundSpecsAcceptNormalizedLockedAliases() throws {
        // Expected RED: the registry recognizes only disconnected required tokens, so the
        // locked cause-of-action and rule-number aliases are not accepted.
        let aliases = [
            "failure to state a claim",
            "  FAILURE   TO STATE A CLAIM  ",
            "failure to state a cause of action",
            "Rule 1.140(b)(6)"
        ]

        for alias in aliases {
            let ground = try MotionGroundSpec.knownGround(for: alias)
            XCTAssertEqual(ground.key, "mtd.failureToStateClaim", "alias: \(alias)")
        }
    }

    func testMotionGroundSpecsRejectDisconnectedTokensAndCompoundProse() {
        // Expected RED: the registry currently accepts any prose containing the three
        // tokens "failure", "state", and "claim", even when they do not name one ground.
        let unsupportedInputs = [
            "failure of process, state immunity, and claim preclusion",
            "failure to state a claim and lack of personal jurisdiction"
        ]

        for input in unsupportedInputs {
            XCTAssertThrowsError(try MotionGroundSpec.knownGround(for: input), "input: \(input)") { error in
                XCTAssertEqual(error as? DraftKindRegistryError, .unsupported(.motionToDismiss))
            }
        }
    }
}
