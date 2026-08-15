import XCTest
@testable import SupraSessions

final class ArchitectureUXTOutcome01Tests: XCTestCase {
    func testTerminalSuccessRequiresEveryAuthoritativePostcondition() {
        let verified = WorkflowPostcondition.verified(identity: "record-713-v7", digest: "digest-719")
        XCTAssertEqual(WorkflowOutcomeGate.evaluate([verified]), .completed)
        XCTAssertEqual(WorkflowOutcomeGate.evaluate([]), .unknown)
        XCTAssertEqual(WorkflowOutcomeGate.evaluate([verified, .unknown(identity: "file-727")]), .unknown)
        XCTAssertEqual(WorkflowOutcomeGate.evaluate([verified, .failed(expectedIdentity: "record-713-v7", observedIdentity: "DEFAULT-000")]), .failed)
    }
}
