import SupraCore
import SupraResearch
import XCTest

final class StructuredOutputSectionsTests: XCTestCase {

    func testAllRequiredHeadingsPresent() {
        let contract = StructuredOutputContracts.contract(for: .ruleSynthesis)
        let markdown = contract.requiredHeadings.joined(separator: "\n\nsome body text\n\n")
        let analysis = StructuredOutputSections.analyze(markdown: markdown, requiredHeadings: contract.requiredHeadings)
        XCTAssertTrue(analysis.missing.isEmpty)
        XCTAssertEqual(analysis.present.count, contract.requiredHeadings.count)
    }

    func testCaseAndWhitespaceInsensitiveButSynonymsAndLevelMatter() {
        let contract = StructuredOutputContracts.contract(for: .ruleSynthesis)
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

    func testWrongHeadingLevelCountsAsMissing() {
        let required = ["## Rule Statement"]
        let analysis = StructuredOutputSections.analyze(markdown: "### Rule Statement", requiredHeadings: required)
        XCTAssertEqual(analysis.missing, ["## Rule Statement"])
    }

    func testBuildPromptFillsContextAndKeepsHeadings() throws {
        let contract = StructuredOutputContracts.contract(for: .legalIssueSpotting)
        let prompt = try StructuredOutputPromptBuilder.buildPrompt(for: contract, context: "THE ISSUE TEXT")
        XCTAssertTrue(prompt.contains("THE ISSUE TEXT"))
        XCTAssertFalse(prompt.contains("{{context}}"))
        XCTAssertTrue(prompt.contains("## Issues Identified"))
    }

    func testEveryTypeHasH1AndSections() {
        for type in StructuredOutputType.allCases {
            let contract = StructuredOutputContracts.contract(for: type)
            XCTAssertTrue(contract.requiredHeadings.first?.hasPrefix("# ") == true, "\(type) needs an H1")
            XCTAssertGreaterThan(contract.requiredHeadings.count, 1, "\(type) needs sections")
        }
    }
}
