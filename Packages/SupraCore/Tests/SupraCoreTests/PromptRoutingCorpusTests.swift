import Foundation
import SupraCore
import XCTest

final class PromptRoutingCorpusTests: XCTestCase {
    private struct Example: Decodable {
        let id: String
        let expected: String
        let prompt: String
    }

    /// T-RTE-07: fixed holdout inputs and executable scoring keep Phase 4's recall and
    /// precision claim reproducible. The corpus is balanced so a fail-closed route for
    /// every prompt cannot satisfy the precision gate.
    func testCommittedCorpusRecallAndPrecision() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "prompt-routing-corpus",
            withExtension: "json"
        ))
        let examples = try JSONDecoder().decode([Example].self, from: Data(contentsOf: url))
        let legalCount = examples.count { $0.expected == "legal" }
        let generalCount = examples.count { $0.expected == "general" }
        XCTAssertEqual(examples.count, 30, "corpus denominator changed")
        XCTAssertEqual(legalCount, 15, "legal denominator changed")
        XCTAssertEqual(generalCount, 15, "general denominator changed")

        let router = ModelRouter(configuration: LegalModelConfiguration(
            requireCitations: true,
            jurisdictionRequired: true
        ))
        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0

        for example in examples {
            let route = router.routePrompt(example.prompt).route
            let predictedLegal = route.requiresCitations && route.requiresJurisdiction
            if example.expected == "legal" {
                if predictedLegal { truePositive += 1 } else { falseNegative += 1 }
            } else if predictedLegal {
                falsePositive += 1
            }
        }

        let recall = Double(truePositive) / Double(truePositive + falseNegative)
        let precision = Double(truePositive) / Double(truePositive + falsePositive)
        print(
            "Phase 4 routing corpus: recall \(truePositive)/\(legalCount) " +
            "(\(recall)); precision \(truePositive)/\(truePositive + falsePositive) " +
            "(\(precision))"
        )
        XCTAssertEqual(recall, 1.0, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(precision, 0.90)
    }
}
