import Foundation
import SupraDocuments
import SupraDrafting
import SupraDraftingCore
import SupraResearch
import XCTest

final class AttorneySupportCorpusTests: XCTestCase {
    private struct Corpus: Decodable {
        var schemaVersion: Int
        var reviewStatus: String
        var cases: [CorpusCase]
    }

    private struct CorpusCase: Decodable {
        var id: String
        var category: String
        var claim: String
        var source: String
        var expectedOutcome: String
        var expectedStatus: String
        var rationale: String
        var sourceCondition: String
        var expectedJurisdiction: String?
        var sourceJurisdiction: String?
    }

    private let requiredCategories: Set<String> = [
        "direct_quote", "faithful_paraphrase", "overbroad_holding",
        "dicta_holding_confusion", "jurisdiction_mismatch", "adverse_authority",
        "short_snippet", "ocr_corruption", "contradictory_documents",
        "critical_values", "prompt_injection",
    ]

    func testCorpusContainsEveryAttorneyCalibrationCategory() throws {
        // ACR-CORPUS-01 expected RED: the initial shared fixture omits the
        // domain categories required by WP3-01.
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.reviewStatus, "pending_attorney_review")
        XCTAssertEqual(Set(corpus.cases.map(\.category)), requiredCategories)
        XCTAssertEqual(Set(corpus.cases.map(\.id)).count, corpus.cases.count)
        XCTAssertTrue(corpus.cases.allSatisfy { ["supported", "unsupported", "unverifiable"].contains($0.expectedStatus) })
        XCTAssertTrue(corpus.cases.allSatisfy { !$0.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    func testSameCorpusNeverProducesFalseCleanAcrossAdapters() async throws {
        // ACR-CORPUS-02 expected RED if any package-specific adapter upgrades a
        // blocking shared case to clean. Stricter package outcomes are allowed.
        let corpus = try loadCorpus()
        for fixture in corpus.cases {
            let shouldSupport = fixture.expectedOutcome == "supported"

            let legal = LegalCitationVerifier.verify(
                answer: fixture.claim + " [A1].",
                authorities: [LegalAuthority(
                    id: fixture.id,
                    authorityType: .case,
                    caseName: "Synthetic Calibration Authority",
                    citation: "999 F.4th 999",
                    citations: ["999 F.4th 999"],
                    jurisdiction: fixture.sourceJurisdiction,
                    text: fixture.source,
                    textKind: .fullText
                )],
                expectedJurisdiction: fixture.expectedJurisdiction,
                sourceFailuresByAuthorityID: sourceFailures(for: fixture)
            )
            let legalClean = legal.passed
                && !legal.supportResults.isEmpty
                && legal.supportResults.allSatisfy { $0.status == .supported }

            let document = try DocumentSupportVerifier.verify(
                answer: fixture.claim + " [S1].",
                sources: [DocumentSupportSource(
                    sourceID: fixture.id,
                    label: "S1",
                    locator: "synthetic:\(fixture.id)",
                    text: fixture.source,
                    lowConfidence: fixture.sourceCondition == "ocr"
                )],
                scopeFullyIndexed: true
            )
            let documentClean = document.verificationStatus == .allSupported

            let drafting = await DraftVerifier().verify(
                .letter(
                    GeneratedLetter(paragraphProvenance: [GeneratedLetterParagraph(
                        text: fixture.claim,
                        factLabels: ["S1"],
                        citationLabels: []
                    )]),
                    model: dummyLetter(body: fixture.claim),
                    facts: [GroundedFact(
                        text: fixture.source,
                        label: "S1",
                        docId: fixture.id,
                        locator: "synthetic:\(fixture.id)"
                    )]
                ),
                kind: .letterDemand,
                style: .defaultFL
            )
            let draftingClean = drafting.failures.isEmpty
                && !drafting.propositionSupport.isEmpty
                && drafting.propositionSupport.allSatisfy { $0.status == .supported }

            let outcomes = [legalClean, documentClean, draftingClean]
            if shouldSupport {
                XCTAssertEqual(outcomes, [true, true, true], fixture.id)
            } else {
                XCTAssertEqual(outcomes, [false, false, false], "false-clean: \(fixture.id)")
            }
        }
    }

    private func sourceFailures(for fixture: CorpusCase) -> [String: LegalAuthorityTextFailure] {
        switch fixture.sourceCondition {
        case "short", "ocr": return [fixture.id: .insufficientText]
        default: return [:]
        }
    }

    private func loadCorpus() throws -> Corpus {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "attorney-support-corpus",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func dummyLetter(body: String) -> LetterModel {
        let office = OfficeBlock(
            street: "1 Synthetic Way", suite: nil, city: "Testville",
            state: "FL", zip: "00000", phone: "000-000-0000", fax: nil
        )
        return LetterModel(
            letterhead: LetterheadFill(firmName: "Synthetic Firm", office: office),
            date: DateOnly(year: 2026, month: 7, day: 13),
            recipient: AddressBlock(
                name: "Synthetic Recipient", title: nil, firm: nil,
                street: "2 Fixture Lane", city: "Testville", state: "FL", zip: "00000"
            ),
            reLine: "Synthetic calibration", salutation: "Dear Reviewer:",
            body: [body], closing: "Respectfully,", signerName: "Synthetic Reviewer",
            signerTitle: nil, enclosures: [], cc: []
        )
    }
}
