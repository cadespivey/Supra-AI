import XCTest
@testable import SupraSessions

final class ArchitectureUXTWorkflowMemory01Tests: XCTestCase {
    func testGeneratedMemoryNeedsExactMatterSourcesAndOwnerApproval() {
        let source = WorkflowSourceReference(matterID: "matter-713", sourceID: "source-719", version: 7, digest: "digest-727")
        let approved = WorkflowMemoryCandidate(matterID: "matter-713", recordID: "record-713", recordVersion: 7, valueDigest: "digest-733", sourceReferences: [source], ownerApproved: true)
        XCTAssertEqual(WorkflowMemoryGate.evaluate(approved, targetMatterID: "matter-713"), .persist)
        XCTAssertNotEqual(WorkflowMemoryGate.evaluate(WorkflowMemoryCandidate(matterID: "matter-713", recordID: "record-713", recordVersion: 7, valueDigest: "digest-733", sourceReferences: [source], ownerApproved: false), targetMatterID: "matter-713"), .persist)
        XCTAssertNotEqual(WorkflowMemoryGate.evaluate(approved, targetMatterID: "DEFAULT-000"), .persist)
    }
}
