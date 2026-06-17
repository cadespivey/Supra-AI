import SupraCore
import XCTest

final class AuthorityTransitionsTests: XCTestCase {

    func testAllowedTransitionsMatchSpec() {
        XCTAssertEqual(Set(AuthorityUseStatus.retrievedFromCourtListener.allowedTransitions),
                       [.needsCitatorCheck, .userMarkedVerified, .doNotUse])
        XCTAssertEqual(Set(AuthorityUseStatus.needsCitatorCheck.allowedTransitions),
                       [.userMarkedVerified, .doNotUse])
        XCTAssertEqual(Set(AuthorityUseStatus.unverified.allowedTransitions),
                       [.needsCitatorCheck, .userMarkedVerified, .doNotUse])
        XCTAssertEqual(Set(AuthorityUseStatus.userMarkedVerified.allowedTransitions),
                       [.needsCitatorCheck, .doNotUse])
        XCTAssertEqual(Set(AuthorityUseStatus.doNotUse.allowedTransitions),
                       [.needsCitatorCheck])
    }

    func testDisallowedTransitionsRejected() {
        // No status may transition to retrieved_from_courtlistener or unverified.
        for status in AuthorityUseStatus.allCases {
            XCTAssertFalse(status.canTransition(to: .retrievedFromCourtListener))
            XCTAssertFalse(status.canTransition(to: .unverified))
            XCTAssertFalse(status.canTransition(to: status), "a status never transitions to itself")
        }
        // needs_citator_check cannot go straight back to retrieved.
        XCTAssertFalse(AuthorityUseStatus.needsCitatorCheck.canTransition(to: .retrievedFromCourtListener))
        XCTAssertTrue(AuthorityUseStatus.userMarkedVerified.canTransition(to: .doNotUse))
    }
}
