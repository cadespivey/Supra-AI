import SupraCore
import XCTest

final class Milestone2CoreTypesTests: XCTestCase {
    func testMilestone2IDsRoundTripThroughCodable() throws {
        let id = ResearchResultID()
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(ResearchResultID.self, from: data)

        XCTAssertEqual(decoded, id)
    }

    func testDomainEnumRawValuesMatchStorageContract() {
        XCTAssertEqual(PartyPerspective.neutral.rawValue, "neutral")
        XCTAssertEqual(ResearchSessionStatus.resultsReady.rawValue, "results_ready")
        XCTAssertEqual(ResearchResultReviewState.potentiallyAdverse.rawValue, "potentially_adverse")
        XCTAssertEqual(AuthorityUseStatus.retrievedFromCourtListener.rawValue, "retrieved_from_courtlistener")
        XCTAssertEqual(StructuredOutputType.ruleSynthesis.rawValue, "rule_synthesis")
        XCTAssertEqual(StructuredOutputStatus.needsReview.rawValue, "needs_review")
    }
}
