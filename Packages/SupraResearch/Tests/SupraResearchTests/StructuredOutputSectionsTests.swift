import SupraCore
import SupraResearch
import XCTest

final class StructuredOutputSectionsTests: XCTestCase {

    func testAllRequiredHeadingsPresent() {
        let contract = StructuredOutputContracts.contract(for: .ruleSynthesis)!
        let markdown = contract.requiredHeadings.joined(separator: "\n\nsome body text\n\n")
        let analysis = StructuredOutputSections.analyze(markdown: markdown, requiredHeadings: contract.requiredHeadings)
        XCTAssertTrue(analysis.missing.isEmpty)
        XCTAssertEqual(analysis.present.count, contract.requiredHeadings.count)
    }

    func testCaseAndWhitespaceInsensitiveButSynonymsAndLevelMatter() {
        let contract = StructuredOutputContracts.contract(for: .ruleSynthesis)!
        // Every required heading except "## Distinctions", with case/whitespace noise.
        let markdown = """
        #   rule synthesis
        ## RULE STATEMENT
        ##   Controlling   Authorities
        ## Persuasive Authorities
        ## Counterarguments
        ## Missing Authority
        ## Drafting Notes
        """
        let analysis = StructuredOutputSections.analyze(markdown: markdown, requiredHeadings: contract.requiredHeadings)
        XCTAssertEqual(analysis.missing, ["## Distinctions"])
    }

    func testNeedsContentPlaceholderSectionCountsAsMissing() {
        let required = ["## Rule Statement", "## Analysis"]
        // Rule Statement is filled only with the repair placeholder; Analysis has prose.
        let markdown = "## Rule Statement\n\n[NEEDS CONTENT]\n\n## Analysis\n\nThe rule applies because…"
        let analysis = StructuredOutputSections.analyze(markdown: markdown, requiredHeadings: required)
        XCTAssertEqual(analysis.missing, ["## Rule Statement"], "a placeholder-only section is not complete")
        XCTAssertEqual(analysis.present, ["## Analysis"])
    }

    func testEmptyBodyHeadingStillCountsAsPresent() {
        // A heading with no body (e.g. the last heading) is still present — only an
        // explicit [NEEDS CONTENT] placeholder marks a section incomplete.
        let required = ["## A", "## B"]
        let analysis = StructuredOutputSections.analyze(markdown: "## A\n\nsome text\n\n## B", requiredHeadings: required)
        XCTAssertTrue(analysis.missing.isEmpty)
    }

    func testWrongHeadingLevelCountsAsMissing() {
        let required = ["## Rule Statement"]
        let analysis = StructuredOutputSections.analyze(markdown: "### Rule Statement", requiredHeadings: required)
        XCTAssertEqual(analysis.missing, ["## Rule Statement"])
    }

    func testBuildPromptFillsContextAndKeepsHeadings() throws {
        let contract = StructuredOutputContracts.contract(for: .legalIssueSpotting)!
        let prompt = try StructuredOutputPromptBuilder.buildPrompt(for: contract, context: "THE ISSUE TEXT")
        XCTAssertTrue(prompt.contains("THE ISSUE TEXT"))
        XCTAssertFalse(prompt.contains("{{context}}"))
        XCTAssertTrue(prompt.contains("## Issues Identified"))
    }

    func testEveryTemplatedTypeHasH1AndSections() throws {
        for type in StructuredOutputContracts.templatedTypes {
            let contract = try XCTUnwrap(StructuredOutputContracts.contract(for: type))
            XCTAssertTrue(contract.requiredHeadings.first?.hasPrefix("# ") == true, "\(type) needs an H1")
            XCTAssertGreaterThan(contract.requiredHeadings.count, 1, "\(type) needs sections")
        }
    }

    func testDocumentOutputTypesHaveNoResearchContract() {
        for type in StructuredOutputType.allCases where type.isDocumentOutput {
            XCTAssertNil(StructuredOutputContracts.contract(for: type), "\(type) should have no research contract")
        }
    }
}
