import Foundation
@testable import SupraCore
import XCTest

final class PropositionSupportTests: XCTestCase {
    func testACRSupport001StatusSerializationUsesStableWireValues() throws {
        // Expected RED: PropositionSupportStatus does not exist before WP0-03.
        let encoded = try JSONEncoder().encode([
            PropositionSupportStatus.supported,
            .unsupported,
            .unverifiable,
        ])

        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            #"["supported","unsupported","unverifiable"]"#
        )
        XCTAssertEqual(
            try JSONDecoder().decode([PropositionSupportStatus].self, from: encoded),
            [.supported, .unsupported, .unverifiable]
        )
    }

    func testACRSupport002SupportedResultRejectsMissingEvidence() throws {
        // Expected RED: no fail-closed proposition result constructor exists before WP0-03.
        XCTAssertThrowsError(
            try PropositionSupportResult(
                propositionID: "proposition-001",
                status: .supported,
                reasons: [],
                evidence: [],
                timestamp: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ) { error in
            XCTAssertEqual(error as? PropositionSupportContractError, .supportedResultRequiresEvidence)
        }
    }

    func testACRSupport003JSONRoundTripRetainsExactPropositionAndEvidenceProvenance() throws {
        // Expected RED: the proposition/evidence provenance types do not exist before WP0-03.
        let proposition = CitedProposition(
            id: "proposition-042",
            text: "The payment was due on March 3, 2024.",
            citationLabels: ["S1"],
            outputRange: 17..<58
        )
        let evidence = SupportEvidence(
            sourceID: "chunk-900",
            sourceLabel: "S1",
            locator: "Contract.pdf, page 7, paragraph 2",
            retainedExcerpt: "Payment shall be due March 3, 2024 — without demand.",
            verifierName: "DocumentSupportVerifier",
            verifierVersion: "support-contract/1.0"
        )
        let timestamp = Date(timeIntervalSince1970: 1_700_000_123)
        let result = try PropositionSupportResult(
            propositionID: proposition.id,
            status: .supported,
            reasons: ["direct_textual_support"],
            evidence: [evidence],
            timestamp: timestamp
        )

        let encoder = DateCoding.encoder
        let payload = try encoder.encode(result)
        let decoded = try DateCoding.decoder.decode(PropositionSupportResult.self, from: payload)

        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.evidence.single?.retainedExcerpt, evidence.retainedExcerpt)
        XCTAssertEqual(decoded.evidence.single?.locator, evidence.locator)
        XCTAssertEqual(decoded.evidence.single?.verifierVersion, evidence.verifierVersion)
        XCTAssertEqual(proposition.outputRange, 17..<58)
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
