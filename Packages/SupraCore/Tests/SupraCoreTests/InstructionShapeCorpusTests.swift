import Foundation
import SupraCore
import XCTest

final class InstructionShapeCorpusTests: XCTestCase {
    private struct Example: Decodable {
        let id: String
        let category: String
        let text: String
    }

    /// T-SEC5-02/04/05: executable metrics over committed inputs. This is deliberately a
    /// measurement of the narrow rejection policy, not a claim that regexes detect attacks.
    func testCommittedCorpusReportsBlockingRecallAndPrecision() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "instruction-shape-corpus",
            withExtension: "json"
        ))
        let examples = try JSONDecoder().decode([Example].self, from: Data(contentsOf: url))
        let injections = examples.filter { $0.category == "injection" }
        let legalProse = examples.filter { $0.category == "legal_prose" }
        XCTAssertEqual(examples.count, 29, "corpus denominator changed")
        XCTAssertEqual(injections.count, 20, "injection denominator changed")
        XCTAssertEqual(legalProse.count, 9, "legal-prose denominator changed")

        let blockedInjections = injections.filter { InstructionShapeDetector.isBlocking($0.text) }
        let blockedLegalProse = legalProse.filter { InstructionShapeDetector.isBlocking($0.text) }
        let recall = Double(blockedInjections.count) / Double(injections.count)
        let precisionDenominator = blockedInjections.count + blockedLegalProse.count
        let precision = precisionDenominator == 0
            ? 0
            : Double(blockedInjections.count) / Double(precisionDenominator)

        print(
            "Phase 5 instruction corpus: blocking recall \(blockedInjections.count)/\(injections.count) " +
            "(\(recall)); blocking precision \(blockedInjections.count)/\(precisionDenominator) " +
            "(\(precision)); false-positive IDs \(blockedLegalProse.map(\.id))"
        )
        XCTAssertFalse(blockedInjections.isEmpty, "the narrow rejection policy must remain wired")
        XCTAssertLessThan(
            blockedInjections.count,
            injections.count,
            "regex policy must not masquerade as an exhaustive injection boundary"
        )
        XCTAssertTrue(
            blockedLegalProse.isEmpty,
            "ordinary legal prose must never be rejected: \(blockedLegalProse.map(\.id))"
        )
    }
}
