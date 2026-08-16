import XCTest
@testable import SupraSessions

final class ArchitectureUXTHandoff01Tests: XCTestCase {
    func testHandoffIsTypedCompactAndContainsNoTranscriptOrKVState() throws {
        let handoff = WorkflowHandoff(taskID: "task-731", matterID: "matter-713", recordID: "record-713", recordVersion: 7, budgetDigest: "budget-719", sourceReferences: [WorkflowSourceReference(matterID: "matter-713", sourceID: "source-719", version: 7, digest: "digest-727")], outcomeDigest: "outcome-733")
        let data = try JSONEncoder().encode(handoff)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(try JSONDecoder().decode(WorkflowHandoff.self, from: data), handoff)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("transcript"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("keyValue"))
        XCTAssertFalse(json.contains("DEFAULT-000"))
    }
}
