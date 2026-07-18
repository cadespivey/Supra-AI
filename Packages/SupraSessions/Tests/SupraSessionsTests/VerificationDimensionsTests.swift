import Foundation
import SupraCore
import SupraDocuments
@testable import SupraSessions
import XCTest

final class VerificationDimensionsTests: XCTestCase {
    func testTDIM01ExistingVerifierOutcomesMapToNamedDimensionsWithoutChangingAggregateStatus() throws {
        // T-DIM-01 expected RED: support reports have only the aggregate enum and
        // no parity-preserving named-dimension mapper.
        let supported = try report(
            answer: "Payment was due March 3, 2025 [S1].",
            text: "The agreement requires payment no later than March 3, 2025."
        )
        let unresolved = try report(
            answer: "Payment was due March 3, 2025 [S9].",
            text: "Payment was due March 3, 2025."
        )
        let lowOCR = try report(
            answer: "Payment was due March 3, 2025 [S1].",
            text: "Payment was due March 3, 2025.",
            lowConfidence: true
        )
        let truncated = try report(
            answer: "Payment was due March 3, 2025 [S1].",
            text: "Payment was due March 3, 2025. …[source text truncated to fit the context window]"
        )
        let valueMismatch = try report(
            answer: "Alpha paid Beta $900 and Gamma $500 [S1].",
            text: "Alpha paid Beta $500 and Gamma $900."
        )

        XCTAssertEqual(
            [supported, unresolved, lowOCR, truncated, valueMismatch].map(\.verificationStatus),
            [.allSupported, .needsReview, .needsReview, .needsReview, .needsReview],
            "named dimensions must not change the established aggregate outcome"
        )

        let supportedDimensions = VerificationDimensionsMapper.dimensions(for: supported)
        XCTAssertEqual(supportedDimensions.result(for: .propositionSupport).status, .satisfied)
        XCTAssertEqual(supportedDimensions.result(for: .citationResolution).status, .satisfied)
        XCTAssertEqual(supportedDimensions.result(for: .criticalValueFidelity).status, .satisfied)
        XCTAssertEqual(supportedDimensions.result(for: .lowConfidenceHandling).status, .satisfied)
        XCTAssertEqual(
            supportedDimensions.result(for: .propositionSupport).evidence.first?.sourceID,
            "matter-a/chunk-1"
        )

        let unresolvedDimensions = VerificationDimensionsMapper.dimensions(for: unresolved)
        XCTAssertEqual(unresolvedDimensions.result(for: .propositionSupport).status, .failed)
        XCTAssertEqual(unresolvedDimensions.result(for: .citationResolution).status, .failed)
        XCTAssertTrue(unresolvedDimensions.result(for: .citationResolution).reason?.contains("S9") == true)
        XCTAssertEqual(unresolvedDimensions.result(for: .criticalValueFidelity).status, .notRun)

        let lowDimensions = VerificationDimensionsMapper.dimensions(for: lowOCR)
        XCTAssertEqual(lowDimensions.result(for: .citationResolution).status, .satisfied)
        XCTAssertEqual(lowDimensions.result(for: .lowConfidenceHandling).status, .failed)
        XCTAssertTrue(lowDimensions.result(for: .lowConfidenceHandling).reason?.contains("S1") == true)
        XCTAssertEqual(lowDimensions.result(for: .criticalValueFidelity).status, .notRun)

        let truncatedDimensions = VerificationDimensionsMapper.dimensions(for: truncated)
        XCTAssertEqual(truncatedDimensions.result(for: .citationResolution).status, .satisfied)
        XCTAssertEqual(truncatedDimensions.result(for: .lowConfidenceHandling).status, .satisfied)
        XCTAssertEqual(truncatedDimensions.result(for: .criticalValueFidelity).status, .notRun)
        XCTAssertTrue(truncatedDimensions.result(for: .propositionSupport).reason?.contains("truncated") == true)

        let mismatchDimensions = VerificationDimensionsMapper.dimensions(for: valueMismatch)
        XCTAssertEqual(mismatchDimensions.result(for: .citationResolution).status, .satisfied)
        XCTAssertEqual(mismatchDimensions.result(for: .lowConfidenceHandling).status, .satisfied)
        XCTAssertEqual(mismatchDimensions.result(for: .criticalValueFidelity).status, .failed)
        XCTAssertTrue(mismatchDimensions.result(for: .criticalValueFidelity).reason?.contains("fidelity") == true)

        let factored = Set([
            VerificationDimensionName.propositionSupport,
            .citationResolution,
            .criticalValueFidelity,
            .lowConfidenceHandling,
        ])
        XCTAssertTrue(supportedDimensions.results
            .filter { !factored.contains($0.dimension) }
            .allSatisfy { $0.status == .notRun })
    }

    func testTDIM03NotRunRendersIndependentlyAndBlocksOnlyWhenRequired() {
        // T-DIM-03 expected RED: there is no per-dimension presentation model or
        // required-dimension gate; only the aggregate status is displayable.
        let dimensions = VerificationDimensions.complete(overrides: [
            .init(
                dimension: .propositionSupport,
                status: .satisfied,
                reason: "NONDEFAULT SUPPORT SATISFIED"
            ),
            .init(
                dimension: .contraryEvidence,
                status: .notRun,
                reason: "NONDEFAULT CONTRARY SWEEP NOT RUN"
            ),
        ])
        let rows = VerificationDimensionPresenter.rows(from: dimensions)
        let support = rows.first { $0.dimension == .propositionSupport }
        let contrary = rows.first { $0.dimension == .contraryEvidence }

        XCTAssertEqual(support?.statusLabel, "Satisfied")
        XCTAssertEqual(contrary?.statusLabel, "Not run")
        XCTAssertEqual(contrary?.reason, "NONDEFAULT CONTRARY SWEEP NOT RUN")
        XCTAssertFalse(contrary?.displayText.contains("Satisfied") == true)
        XCTAssertTrue(dimensions.satisfies(required: [.propositionSupport]))
        XCTAssertFalse(dimensions.satisfies(required: [.propositionSupport, .contraryEvidence]))
    }

    private func report(
        answer: String,
        text: String,
        lowConfidence: Bool = false
    ) throws -> DocumentSupportReport {
        try DocumentSupportVerifier.verify(
            answer: answer,
            sources: [DocumentSupportSource(
                sourceID: "matter-a/chunk-1",
                label: "S1",
                locator: "p. 4, chars 20-96",
                text: text,
                lowConfidence: lowConfidence
            )],
            scopeFullyIndexed: true,
            timestamp: Date(timeIntervalSinceReferenceDate: 69)
        )
    }
}
