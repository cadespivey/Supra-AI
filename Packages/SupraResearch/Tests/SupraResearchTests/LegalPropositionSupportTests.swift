import Foundation
import SupraResearch
import XCTest

final class LegalPropositionSupportTests: XCTestCase {
    private struct Corpus: Decodable {
        var schemaVersion: Int
        var reviewStatus: String
        var cases: [CorpusCase]
    }

    private struct CorpusCase: Decodable {
        var id: String
        var answer: String
        var authorities: [AuthorityFixture]
        var expectedStatuses: [String]
        var expectedPassed: Bool
    }

    private struct AuthorityFixture: Decodable {
        var id: String
        var caseName: String?
        var citation: String?
        var url: String?
        var snippet: String?
        var text: String?

        var authority: LegalAuthority {
            LegalAuthority(
                id: id,
                authorityType: .case,
                caseName: caseName,
                citation: citation,
                citations: citation.map { [$0] } ?? [],
                url: url,
                snippet: snippet,
                text: text
            )
        }
    }

    private struct SerializedReport: Decodable {
        var propositions: [SerializedProposition]?
        var supportResults: [SerializedSupportResult]?
    }

    private struct SerializedProposition: Decodable {
        var id: String
        var text: String
        var citationLabels: [String]
    }

    private struct SerializedSupportResult: Decodable {
        var propositionID: String
        var status: String
        var reasons: [String]
        var evidence: [SerializedEvidence]
    }

    private struct SerializedEvidence: Decodable {
        var sourceID: String
        var sourceLabel: String
        var locator: String
        var retainedExcerpt: String
        var verifierName: String
        var verifierVersion: String
    }

    func testSyntheticCorpusProducesFailClosedPropositionStatuses() throws {
        // ACR-LEGAL-02…07 expected RED: the current report has no proposition
        // support results, and short/contradictory sources can still pass.
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.reviewStatus, "pending_attorney_review")

        for fixture in corpus.cases {
            let report = LegalCitationVerifier.verify(
                answer: fixture.answer,
                authorities: fixture.authorities.map(\.authority)
            )
            let serialized = try serializedReport(report)
            let propositions = try XCTUnwrap(
                serialized.propositions,
                "\(fixture.id): verifier must emit extracted propositions"
            )
            let results = try XCTUnwrap(
                serialized.supportResults,
                "\(fixture.id): verifier must emit SupraCore support results"
            )

            XCTAssertEqual(report.passed, fixture.expectedPassed, fixture.id)
            XCTAssertEqual(results.map(\.status), fixture.expectedStatuses, fixture.id)
            XCTAssertEqual(results.map(\.propositionID), propositions.map(\.id), fixture.id)
            XCTAssertEqual(propositions.count, fixture.expectedStatuses.count, fixture.id)
            XCTAssertTrue(propositions.allSatisfy { !$0.text.isEmpty }, fixture.id)
            XCTAssertTrue(propositions.allSatisfy { !$0.citationLabels.isEmpty }, fixture.id)
            XCTAssertFalse(results.contains { $0.status == "supported" && $0.evidence.isEmpty }, fixture.id)
        }
    }

    func testFaithfulParaphraseRetainsPinpointExcerptAndVerifierIdentity() throws {
        // ACR-LEGAL-05 expected RED: the current verifier returns only issue flags,
        // so no exact supporting excerpt, locator, or verifier identity is retained.
        let fixture = try XCTUnwrap(loadCorpus().cases.first { $0.id == "faithful-paraphrase" })
        let report = LegalCitationVerifier.verify(
            answer: fixture.answer,
            authorities: fixture.authorities.map(\.authority)
        )
        let result = try XCTUnwrap(try serializedReport(report).supportResults?.first)
        let evidence = try XCTUnwrap(result.evidence.first)

        XCTAssertTrue(report.passed)
        XCTAssertEqual(result.status, "supported")
        XCTAssertEqual(evidence.sourceID, "supported-a1")
        XCTAssertEqual(evidence.sourceLabel, "[A1]")
        XCTAssertEqual(evidence.locator, "606 F.4th 606")
        XCTAssertTrue(evidence.retainedExcerpt.contains("two years after discovery"), evidence.retainedExcerpt)
        XCTAssertEqual(evidence.verifierName, "SupraLegalPropositionVerifier")
        XCTAssertFalse(evidence.verifierVersion.isEmpty)
    }

    private func loadCorpus() throws -> Corpus {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "legal-proposition-support",
                withExtension: "json",
                subdirectory: "Fixtures/Legal"
            )
        )
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func serializedReport(_ report: LegalVerificationReport) throws -> SerializedReport {
        try JSONDecoder().decode(SerializedReport.self, from: JSONEncoder().encode(report))
    }
}
