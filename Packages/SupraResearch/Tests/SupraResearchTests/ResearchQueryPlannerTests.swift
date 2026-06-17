import SupraResearch
import XCTest

final class ResearchQueryPlannerTests: XCTestCase {
    private let planner = ResearchQueryPlanner()

    func testBuildPromptFillsAllPlaceholders() throws {
        let prompt = try planner.buildPrompt(
            issueText: "Whether a non-compete is enforceable",
            jurisdiction: "California",
            partyPerspective: "defendant",
            preferredCourts: ["Cal. Sup. Ct."],
            excludedCourts: [],
            dateRange: "2015–2020"
        )
        XCTAssertFalse(prompt.contains("{{"), "no unfilled placeholders should remain")
        XCTAssertTrue(prompt.contains("California"))
        XCTAssertTrue(prompt.contains("defendant"))
        XCTAssertTrue(prompt.contains("Cal. Sup. Ct."))
        XCTAssertTrue(prompt.contains("None"))   // empty excluded courts
        XCTAssertTrue(prompt.contains("Whether a non-compete is enforceable"))
    }

    func testParsesFiveWellFormedQueries() {
        let output = """
        # Research Queries

        ## Query 1
        non-compete enforceability California

        ## Query 2
        restrictive covenant employment

        ## Query 3
        trade secret misappropriation

        ## Query 4
        injunction non-solicitation

        ## Query 5
        liquidated damages employment contract
        """
        let queries = planner.parseQueries(from: output)
        XCTAssertEqual(queries.count, 5)
        XCTAssertEqual(queries.first, "non-compete enforceability California")
        XCTAssertEqual(queries.last, "liquidated damages employment contract")
    }

    func testStripsReasoningBeforeParsing() {
        let output = """
        Thinking Process: first I weigh the issue and jurisdiction.
        </think>

        # Research Queries

        ## Query 1
        first query

        ## Query 2
        second query
        """
        let queries = planner.parseQueries(from: output)
        XCTAssertEqual(queries, ["first query", "second query"])
    }

    func testFewerThanFiveQueriesReturnedAsIs() {
        let output = """
        # Research Queries

        ## Query 1
        only one query here
        """
        XCTAssertEqual(planner.parseQueries(from: output).count, 1)
    }

    func testGarbageOutputYieldsNoQueries() {
        XCTAssertTrue(planner.parseQueries(from: "I could not generate queries.").isEmpty)
    }

    func testCapturesInlineHeadingQueryText() {
        let output = """
        ## Query 1: breach of contract damages
        ## Query 2 — promissory estoppel
        ## Query 3
        unjust enrichment restitution
        """
        let queries = planner.parseQueries(from: output)
        XCTAssertEqual(queries, [
            "breach of contract damages",
            "promissory estoppel",
            "unjust enrichment restitution"
        ])
    }

    func testEchoedPlaceholdersAreIgnored() {
        let output = """
        ## Query 1
        <your first query>

        ## Query 2
        real query text
        """
        XCTAssertEqual(planner.parseQueries(from: output), ["real query text"])
    }
}
