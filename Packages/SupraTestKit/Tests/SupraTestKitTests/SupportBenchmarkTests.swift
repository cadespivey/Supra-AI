import Foundation
import SupraCore
import SupraDocuments
@testable import SupraTestKit
import XCTest

final class SupportBenchmarkTests: XCTestCase {
    func testBSUP01AdversarialSupportCasesEmitZeroFalseAccepts() throws {
        // B-SUP-01 expected RED: the benchmark catalog has no support
        // observation producer, so the deterministic report emits n/a.
        let cases = try [
            report(
                answer: "Payment was due March 3, 2025 [S9].",
                text: "Payment was due March 3, 2025."
            ),
            report(
                answer: "Payment was due March 3, 2025 [S1].",
                text: "Payment was due March 3, 2025.",
                lowConfidence: true
            ),
            report(
                answer: "Payment was due March 3, 2025 [S1].",
                text: "Payment was due March 3, 2025. …[source text truncated to fit the context window]"
            ),
            report(
                answer: "Alpha paid Beta $900 and Gamma $500 [S1].",
                text: "Alpha paid Beta $500 and Gamma $900."
            ),
        ].map {
            SupportBenchmarkCase(expectedSupported: false, actualStatus: $0.verificationStatus)
        }
        let observation = try XCTUnwrap(SupportBenchmark.observations(cases: cases).first)

        XCTAssertEqual(observation.metricID, "B-SUP-01")
        XCTAssertEqual(observation.name, "support_false_accept_rate")
        XCTAssertEqual(observation.result.numerator, 0)
        XCTAssertEqual(observation.result.denominator, 4)
        XCTAssertEqual(observation.result.value, 0)
    }

    private func report(
        answer: String,
        text: String,
        lowConfidence: Bool = false
    ) throws -> DocumentSupportReport {
        try DocumentSupportVerifier.verify(
            answer: answer,
            sources: [DocumentSupportSource(
                sourceID: "synthetic/support-source",
                label: "S1",
                locator: "chars 0-73",
                text: text,
                lowConfidence: lowConfidence
            )],
            scopeFullyIndexed: true,
            timestamp: Date(timeIntervalSinceReferenceDate: 69)
        )
    }
}
