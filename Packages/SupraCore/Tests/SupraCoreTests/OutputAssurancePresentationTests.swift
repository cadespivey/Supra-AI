import SupraCore
import XCTest

final class OutputAssurancePresentationTests: XCTestCase {
    func testTUX01EveryAssuranceStateRendersItsPinnedStringWithoutConflation() {
        // T-UX-01 expected RED: the domain state has no shared presentation
        // contract, so app surfaces fall back to lifecycle/verification wording.
        let expected: [(OutputAssuranceState, String)] = [
            (.preliminary, "Preliminary — ranked sources only"),
            (.supportNeedsReview, "Support needs review"),
            (.propositionSupported, "Propositions supported — completeness not assessed"),
            (.corpusIncomplete, "Corpus incomplete — review gaps"),
            (.corpusComplete, "Corpus complete for this task and scope"),
            (.negativeBlocked, "Negative conclusion blocked"),
            (.stale, "Stale — sources or processing changed"),
        ]

        XCTAssertEqual(OutputAssuranceState.allCases.count, 7)
        XCTAssertEqual(expected.map(\.0), OutputAssuranceState.allCases)
        for (state, text) in expected {
            XCTAssertEqual(OutputAssurancePresentation.text(for: state), text)
        }

        let incompleteRow = OutputAssurancePresentation.text(for: .corpusIncomplete)
        XCTAssertFalse(incompleteRow.contains("Propositions supported"))
        XCTAssertTrue(OutputAssurancePresentation.isExportEligible(.propositionSupported))
        XCTAssertTrue(OutputAssurancePresentation.isExportEligible(.corpusComplete))
        XCTAssertFalse(OutputAssurancePresentation.isExportEligible(.corpusIncomplete))
        XCTAssertFalse(OutputAssurancePresentation.isExportEligible(.stale))
    }
}
