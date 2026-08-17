import Foundation
import XCTest

/// WP-3.2 refinement RED: every shipping generation owner must classify its
/// context explicitly. The DTO's current default silently labels grounded legal
/// evidence as ordinary chat, allowing the history-trim path to stand in for an
/// exact-source repack/defer decision.
final class ArchitectureUXTRuntimeContextOwnershipTests: XCTestCase {
    private let forbiddenDefault = "DEFAULT-000"

    func testGenerateRequestHasNoImplicitContextWorkload() throws {
        let source = try ArchitectureUXRuntimeBudgetWire.source(
            "Packages/SupraRuntimeInterface/Sources/SupraRuntimeInterface/DTOs/GenerateRequest.swift"
        )

        XCTAssertFalse(
            source.contains("contextWorkload: RuntimeContextWorkload ="),
            "a shipping caller must choose ordinary conversation or exact grounded evidence"
        )
        XCTAssertFalse(source.contains(forbiddenDefault))
    }

    func testEveryShippingSessionsConstructorClassifiesItsContext() throws {
        let expectedCalls: [String: Int] = [
            "RuntimeLetterGenerator.swift": 1,
            "AuthoritiesController.swift": 1,
            "ValidationRunner.swift": 1,
            "TypedGroundedGenerator.swift": 1,
            "StructuredOutputController.swift": 1,
            "ResearchSessionController.swift": 1,
            "FirmStyleExemplarParser.swift": 1,
            "BillingDraftService.swift": 1,
            "DocumentRerank.swift": 1,
            "DocumentQAController.swift": 1,
            "DocumentClassificationService.swift": 1,
            "DocumentChronologyController.swift": 1,
            "CorpusAnalysisQueueRunner.swift": 1,
            "SignedReleaseSmokeRunner.swift": 1,
            "TypedProseABProbe.swift": 1,
            "GlobalChatController.swift": 8,
        ]

        for (fileName, expectedCount) in expectedCalls.sorted(by: { $0.key < $1.key }) {
            let source = try ArchitectureUXRuntimeBudgetWire.source(
                "Packages/SupraSessions/Sources/SupraSessions/\(fileName)"
            )
            let requestCount = source.components(separatedBy: "GenerateRequest(").count - 1
            let classificationCount = source.components(
                separatedBy: "contextWorkload:"
            ).count - 1
            XCTAssertEqual(requestCount, expectedCount, "fixture inventory drifted for \(fileName)")
            XCTAssertEqual(
                classificationCount,
                requestCount,
                "every GenerateRequest in \(fileName) must explicitly classify context"
            )
            XCTAssertFalse(source.contains(forbiddenDefault))
        }
    }

    func testLegalEvidenceOwnersChooseGroundedExactEvidence() throws {
        let groundedFiles = [
            "RuntimeLetterGenerator.swift",
            "AuthoritiesController.swift",
            "ValidationRunner.swift",
            "TypedGroundedGenerator.swift",
            "StructuredOutputController.swift",
            "ResearchSessionController.swift",
            "FirmStyleExemplarParser.swift",
            "BillingDraftService.swift",
            "DocumentRerank.swift",
            "DocumentQAController.swift",
            "DocumentClassificationService.swift",
            "DocumentChronologyController.swift",
            "CorpusAnalysisQueueRunner.swift",
        ]

        for fileName in groundedFiles {
            let source = try ArchitectureUXRuntimeBudgetWire.source(
                "Packages/SupraSessions/Sources/SupraSessions/\(fileName)"
            )
            XCTAssertTrue(
                source.contains("contextWorkload: .groundedExactEvidence"),
                "\(fileName) owns exact legal evidence and must not use ordinary history trimming"
            )
        }

        let chat = try ArchitectureUXRuntimeBudgetWire.source(
            "Packages/SupraSessions/Sources/SupraSessions/GlobalChatController.swift"
        )
        let groundedChatCalls = chat.components(
            separatedBy: "contextWorkload: .groundedExactEvidence"
        ).count - 1
        XCTAssertGreaterThanOrEqual(
            groundedChatCalls,
            3,
            "critique, legal answer, and verified repair must preserve exact packet evidence"
        )
        XCTAssertFalse(chat.contains(forbiddenDefault))
    }
}
