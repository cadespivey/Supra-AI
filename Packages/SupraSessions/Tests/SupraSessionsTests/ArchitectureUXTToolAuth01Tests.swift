import XCTest
@testable import SupraSessions

final class ArchitectureUXTToolAuth01Tests: XCTestCase {
    func testEffectsRequireExactGrantAndAdvancedDoesNotBroadenAuthority() {
        for effect in WorkflowToolEffectClass.allCases {
            let intent = WorkflowToolIntent(taskID: "task-731", matterID: "matter-713", toolID: "provider-713", effect: effect, payloadDigest: "QUERY-CANARY-719", version: 7)
            XCTAssertNotEqual(WorkflowToolAuthorizer.authorize(intent, grant: nil, advancedEnabled: true), .allowed)
            if effect == .unknown {
                XCTAssertNotEqual(WorkflowToolAuthorizer.authorize(intent, grant: WorkflowEffectGrant(matching: intent)), .allowed)
            } else {
                XCTAssertEqual(WorkflowToolAuthorizer.authorize(intent, grant: WorkflowEffectGrant(matching: intent)), .allowed)
            }
            let unrelated = WorkflowToolIntent(taskID: "task-731", matterID: "DEFAULT-000", toolID: "provider-713", effect: effect, payloadDigest: "DEFAULT-BODY-000", version: 7)
            XCTAssertNotEqual(WorkflowToolAuthorizer.authorize(intent, grant: WorkflowEffectGrant(matching: unrelated)), .allowed)
        }
    }
}
