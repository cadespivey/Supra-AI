import Foundation
import XCTest

final class ArchitectureUXDrRagExperiment01Tests: XCTestCase {
    func testEveryOptionalChallengerHasOneVariableAndExplicitNoChangeDecision() throws {
        let decision = try String(contentsOf: repositoryRoot.appendingPathComponent("Docs/Architecture/Remediation/Optional-Architecture-Decisions.yml"), encoding: .utf8)
        for id in ["DR-RAG-EXPERIMENT-01", "DR-RERANK-01", "DR-PARSER-01", "DR-CHUNK-01", "DR-EMBED-ART-01", "DR-ANN-01"] {
            let marker = "- id: \(id)"
            let start = try XCTUnwrap(decision.range(of: marker), id)
            let remainder = decision[start.lowerBound...]
            let end = remainder.dropFirst(marker.count).range(of: "\n    - id:")?.lowerBound ?? decision.endIndex
            let entry = String(decision[start.lowerBound..<end])
            XCTAssertEqual(entry.components(separatedBy: "variable:").count - 1, 1, id)
            XCTAssertTrue(entry.contains("disposition: no_change"), id)
            XCTAssertTrue(entry.contains("reason:"), id)
        }
        XCTAssertTrue(decision.contains("client_data_allowed: false"))
        XCTAssertTrue(decision.contains("new_runtime_processes_allowed: 0"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
