import Foundation
@testable import SupraDocuments
import XCTest

final class LegalStructureRecognizerTests: XCTestCase {
    /// T-STR-19 expected RED: no deterministic legal structure pass recognizes
    /// numbered requests/responses or the objection nested in a response.
    func testDiscoveryRequestsResponsesAndObjectionsPairByNumber() throws {
        let text = """
        SYNTHETIC REQUESTS FOR PRODUCTION
        Request No. 7: Produce every audit schedule and attachment.
        Response to Request No. 7: Schedules A-C are produced; subject to synthetic relevance objection.
        Request No. 12: Produce communications concerning Exhibit G.
        Response to Request No. 12: After reasonable search, Exhibit G does not exist.
        """
        let enriched = LegalStructureRecognizer.enrich(ExtractionResult(
            parts: [ExtractedPart(sourceKind: .text, text: text)],
            method: "fixture"
        ))

        let requests = enriched.structure.nodes.filter { $0.kind == .discoveryRequest }
        let responses = enriched.structure.nodes.filter { $0.kind == .discoveryResponse }
        let objections = enriched.structure.nodes.filter { $0.kind == .objection }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(objections.count, 1)
        XCTAssertEqual(Set(try requests.map(number)), ["7", "12"])
        XCTAssertEqual(Set(try responses.map(number)), ["7", "12"])

        for response in responses {
            let responseNumber = try number(response)
            let paired = try XCTUnwrap(requests.first { (try? number($0)) == responseNumber })
            XCTAssertTrue(enriched.structure.edges.contains {
                $0.fromNodeKey == response.nodeKey
                    && $0.toNodeKey == paired.nodeKey
                    && $0.kind == .respondsTo
            })
        }
        let objection = try XCTUnwrap(objections.first)
        XCTAssertTrue(resolvedText(for: objection, in: text).contains("subject to synthetic relevance objection"))
        XCTAssertTrue(enriched.structure.edges.contains {
            $0.fromNodeKey == objection.nodeKey
                && responses.map(\.nodeKey).contains($0.toNodeKey)
                && $0.kind == .respondsTo
        })
        XCTAssertEqual(enriched.parts.first?.text, text, "recognition must not alter flat extraction text")
    }

    /// T-STR-20 expected RED: deposition turns are still flat text, so a
    /// multi-line answer has no exact ranged node or answer-to-question edge.
    func testDepositionQuestionAnswerPairingIncludesMultilineAnswers() throws {
        let text = """
        SYNTHETIC DEPOSITION OF DANA QUILL
        Page 44
         3 Q. What repair amount did you approve?
         4 A. I approved $185,000 after reviewing the estimates.
            The approval excluded delay damages.
         8 Q. Did that include delay?
         9 A. No.
        """
        let enriched = LegalStructureRecognizer.enrich(ExtractionResult(
            parts: [ExtractedPart(sourceKind: .text, text: text)],
            method: "fixture"
        ))

        let questions = enriched.structure.nodes.filter { $0.kind == .depositionQuestion }
        let answers = enriched.structure.nodes.filter { $0.kind == .depositionAnswer }
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(answers.count, 2)
        XCTAssertTrue(resolvedText(for: answers[0], in: text).contains("The approval excluded delay damages."))
        XCTAssertTrue(enriched.structure.edges.contains {
            $0.fromNodeKey == answers[0].nodeKey
                && $0.toNodeKey == questions[0].nodeKey
                && $0.kind == .respondsTo
        })
        XCTAssertTrue(enriched.structure.edges.contains {
            $0.fromNodeKey == answers[1].nodeKey
                && $0.toNodeKey == questions[1].nodeKey
                && $0.kind == .respondsTo
        })
    }

    /// T-STR-21 expected RED: the precision guard cannot be exercised until a
    /// recognizer exists. Ordinary pleading prose must remain unpaired.
    func testOrdinaryPleadingDoesNotProduceLegalPairs() throws {
        let text = """
        SYNTHETIC COMPLAINT
        Plaintiff requests relief and alleges that Defendant answered no correspondence.
        Question presented: whether delay caused loss. Answer: the pleading alleges it did.
        WHEREFORE, Plaintiff requests judgment.
        """
        let enriched = LegalStructureRecognizer.enrich(ExtractionResult(
            parts: [ExtractedPart(sourceKind: .text, text: text)],
            method: "fixture"
        ))

        let legalKinds: Set<DocumentStructureNodeKind> = [
            .discoveryRequest, .discoveryResponse, .objection,
            .depositionQuestion, .depositionAnswer,
        ]
        XCTAssertTrue(enriched.structure.nodes.allSatisfy { !legalKinds.contains($0.kind) })
        XCTAssertTrue(enriched.structure.edges.allSatisfy { $0.kind != .respondsTo })
    }

    private func number(_ node: ExtractedStructureNode) throws -> String {
        let data = try XCTUnwrap(node.payloadJSON?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["number"] as? String)
    }

    private func resolvedText(for node: ExtractedStructureNode, in source: String) -> String {
        guard let start = node.charStart, let end = node.charEnd else { return node.textContent ?? "" }
        let lower = source.index(source.startIndex, offsetBy: start)
        let upper = source.index(source.startIndex, offsetBy: end)
        return String(source[lower..<upper])
    }
}
