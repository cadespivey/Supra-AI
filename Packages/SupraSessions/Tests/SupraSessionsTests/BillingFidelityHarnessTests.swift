import Foundation
import SupraCore
import SupraStore
@testable import SupraSessions
import XCTest

@MainActor
final class BillingFidelityHarnessTests: XCTestCase {

    private let timekeeper = BillingTimekeeper(
        id: "TK-1001", name: "Harvey Specter", classification: "PARTNER", defaultRate: 450, lawFirmID: "98-7654321"
    )

    func testScorerDiscriminatesGoodFromBad() {
        let expected = [
            BillingFidelityExpectation(matterID: "m1", subjectKeywords: ["motion to compel"], hours: 0.6),
            BillingFidelityExpectation(matterID: "m1", subjectKeywords: ["opposition"], hours: 1.3)
        ]
        let good = [
            BillingFidelityScorer.Line(matterID: "m1", narrative: "Reviewed the motion to compel.", hours: 0.6),
            BillingFidelityScorer.Line(matterID: "m1", narrative: "Drafted opposition brief.", hours: 1.3)
        ]
        let goodScore = BillingFidelityScorer.score(expected: expected, actual: good)
        XCTAssertEqual(goodScore.lineAccuracy, 1.0, accuracy: 0.001)
        XCTAssertEqual(goodScore.timeAccuracy, 1.0, accuracy: 0.001)

        let bad = [BillingFidelityScorer.Line(matterID: "other", narrative: "Attention to file.", hours: 5.0)]
        let badScore = BillingFidelityScorer.score(expected: expected, actual: bad)
        XCTAssertEqual(badScore.lineAccuracy, 0.0, accuracy: 0.001)

        // Right subject + matter but wrong time: counts as a line match, not a time match.
        let offTime = [
            BillingFidelityScorer.Line(matterID: "m1", narrative: "Reviewed the motion to compel.", hours: 2.0),
            BillingFidelityScorer.Line(matterID: "m1", narrative: "Drafted opposition brief.", hours: 1.3)
        ]
        let offTimeScore = BillingFidelityScorer.score(expected: expected, actual: offTime)
        XCTAssertEqual(offTimeScore.lineAccuracy, 1.0, accuracy: 0.001)
        XCTAssertEqual(offTimeScore.timeAccuracy, 0.5, accuracy: 0.001)
    }

    func testHarnessScoresCorrectGeneratorHigh() async {
        let json = """
        {"lineItems":[
          {"matterID":"m-vystar","narrative":"Reviewed Defendant's motion to compel.","hours":0.6,"taskCode":"L350","activityCode":"A104","confidence":"medium"},
          {"matterID":"m-vystar","narrative":"Drafted opposition to the motion to compel.","hours":1.3,"taskCode":"L350","activityCode":"A103","confidence":"high"}
        ]}
        """
        let result = await BillingFidelityHarness.run(BillingFidelityFixtures.vyStarLitigationDay, timekeeper: timekeeper) { _, _ in json }
        XCTAssertTrue(result.parsed)
        XCTAssertEqual(result.score?.lineAccuracy, 1.0)
        XCTAssertEqual(result.score?.timeAccuracy, 1.0)
    }

    func testHarnessScoresWrongGeneratorLow() async {
        let json = """
        {"lineItems":[{"matterID":"m-vystar","narrative":"Attention to file.","hours":3.0}]}
        """
        let result = await BillingFidelityHarness.run(BillingFidelityFixtures.vyStarLitigationDay, timekeeper: timekeeper) { _, _ in json }
        XCTAssertTrue(result.parsed)
        XCTAssertEqual(result.score?.lineAccuracy, 0.0)
    }

    func testHarnessReportsUnparseable() async {
        let result = await BillingFidelityHarness.run(BillingFidelityFixtures.vyStarLitigationDay, timekeeper: timekeeper) { _, _ in "I can't help with that." }
        XCTAssertFalse(result.parsed)
        XCTAssertNil(result.score)
    }
}
