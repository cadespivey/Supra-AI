import Foundation
import SupraStore
@testable import SupraSessions
import XCTest

/// Phase 2 (retrieve-before-route) SHADOW: the pure comparison that grades where the
/// evidence-based corpus-coverage signal agrees with the legacy keyword router and where it
/// would change the routing decision. Tested without a store or model — the candidate primary
/// rule is "coverage grounds iff strength == .strong".
///
/// Expected RED before `CoverageRoutingShadow` exists: the type/function is undefined, so the
/// suite does not compile. Each case asserts a specific comparison distinct from the others, so
/// a stub returning any single default value fails at least three assertions.
final class CoverageRoutingShadowTests: XCTestCase {

    private func signal(_ strength: CoverageStrength, count: Int) -> CoverageSignal {
        CoverageSignal(strength: strength, matchedSourceCount: count, scopeFullyIndexed: true)
    }

    func testKeywordGroundsWithStrongCoverageAgreesToGround() {
        XCTAssertEqual(
            CoverageRoutingShadow.compare(keywordGrounds: true, coverage: signal(.strong, count: 3)),
            .agreeGround
        )
    }

    func testKeywordSkipsWithNoCoverageAgreesToSkip() {
        XCTAssertEqual(
            CoverageRoutingShadow.compare(keywordGrounds: false, coverage: signal(.none, count: 0)),
            .agreeSkip
        )
    }

    func testKeywordMissWithStrongCoverageWouldGround() {
        // The R2 target: keyword routing said "not about documents", but the corpus strongly
        // covers the question — coverage would pull it into the documents.
        XCTAssertEqual(
            CoverageRoutingShadow.compare(keywordGrounds: false, coverage: signal(.strong, count: 2)),
            .coverageWouldGround
        )
    }

    func testKeywordOverGroundsWithNoCoverageWouldSkip() {
        // Keyword hit a phrase but the corpus has nothing — coverage would send it to the legal route.
        XCTAssertEqual(
            CoverageRoutingShadow.compare(keywordGrounds: true, coverage: signal(.none, count: 0)),
            .coverageWouldSkip
        )
    }

    func testWeakCoverageIsMarginalRegardlessOfKeyword() {
        XCTAssertEqual(
            CoverageRoutingShadow.compare(keywordGrounds: true, coverage: signal(.weak, count: 1)),
            .marginal
        )
        XCTAssertEqual(
            CoverageRoutingShadow.compare(keywordGrounds: false, coverage: signal(.weak, count: 1)),
            .marginal
        )
    }
}
