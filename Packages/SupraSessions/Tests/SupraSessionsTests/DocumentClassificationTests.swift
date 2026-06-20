import Foundation
@testable import SupraSessions
import XCTest

/// Covers the deterministic parts of the 1.3.2 document classifier: decoding the
/// model's JSON, coercing it onto the approved taxonomy, tolerant tag lookup,
/// JSON extraction from messy model output, and the prompt contents.
final class DocumentClassificationTests: XCTestCase {

    // MARK: - Decoding

    func testDecodesRealisticModelJSON() throws {
        let json = """
        {
          "primary_tag": "motions_and_briefs",
          "secondary_tags": ["case_law"],
          "confidence": 0.92,
          "reasoning_summary": "Summary-judgment brief citing authority.",
          "document_function": "Argues for summary judgment.",
          "is_privileged_likely": false,
          "is_confidential_likely": false,
          "is_court_filed_likely": true,
          "is_discovery_material_likely": false,
          "detected_document_date": "2025-03-04",
          "detected_parties_or_entities": ["Acme Corp", "Beta LLC"],
          "detected_jurisdiction": "N.D. Cal.",
          "warnings": []
        }
        """
        let result = try JSONDecoder().decode(DocumentClassification.self, from: Data(json.utf8))
        XCTAssertEqual(result.primaryCategory, .motionsAndBriefs)
        XCTAssertEqual(result.secondaryCategories, [.caseLaw])
        XCTAssertEqual(result.confidence, 0.92, accuracy: 0.0001)
        XCTAssertTrue(result.isCourtFiledLikely)
        XCTAssertEqual(result.detectedDocumentDate, "2025-03-04")
        XCTAssertEqual(result.detectedPartiesOrEntities, ["Acme Corp", "Beta LLC"])
        XCTAssertEqual(result.detectedJurisdiction, "N.D. Cal.")
    }

    func testToleratesMissingFields() throws {
        // The model emits only the primary tag; everything else must default.
        let result = try JSONDecoder().decode(DocumentClassification.self, from: Data(#"{"primary_tag":"contracts_and_agreements"}"#.utf8))
        XCTAssertEqual(result.primaryCategory, .contractsAndAgreements)
        XCTAssertEqual(result.secondaryTags, [])
        XCTAssertEqual(result.confidence, 0)
        XCTAssertFalse(result.isPrivilegedLikely)
        XCTAssertNil(result.detectedDocumentDate)
        XCTAssertEqual(result.warnings, [])
    }

    // MARK: - Normalization

    func testNormalizeCoercesUnknownPrimaryTag() {
        let raw = DocumentClassification(primaryTag: "totally_made_up_tag", confidence: 0.8)
        XCTAssertEqual(raw.normalized().primaryCategory, .unknownOrMixed)
    }

    func testNormalizeDropsInvalidAndDuplicateSecondaries() {
        let raw = DocumentClassification(
            primaryTag: "pleadings",
            secondaryTags: ["pleadings", "evidence_and_exhibits", "bogus", "evidence_and_exhibits"],
            confidence: 0.7
        )
        let normalized = raw.normalized()
        // Primary excluded, unknown dropped, duplicate collapsed.
        XCTAssertEqual(normalized.secondaryTags, ["evidence_and_exhibits"])
    }

    func testNormalizeClampsConfidenceAndFlagsLowConfidence() {
        let high = DocumentClassification(primaryTag: "statutes", confidence: 1.7).normalized()
        XCTAssertEqual(high.confidence, 1.0, accuracy: 0.0001)

        let low = DocumentClassification(primaryTag: "statutes", confidence: 0.3).normalized()
        XCTAssertEqual(low.confidence, 0.3, accuracy: 0.0001)
        XCTAssertFalse(low.warnings.isEmpty, "Sub-0.50 confidence must carry a warning (spec rule).")
    }

    // MARK: - Taxonomy lookup

    func testCategoryLookupIsTolerant() {
        XCTAssertEqual(DocumentCategory.from(rawTag: "court_orders_and_opinions"), .courtOrdersAndOpinions)
        XCTAssertEqual(DocumentCategory.from(rawTag: "  Discovery_Requests  "), .discoveryRequests)
        XCTAssertNil(DocumentCategory.from(rawTag: "legal_research"))
    }

    func testTaxonomyHasThirtyTwoUniqueTags() {
        XCTAssertEqual(DocumentCategory.allCases.count, 32)
        XCTAssertEqual(Set(DocumentCategory.allCases.map(\.rawValue)).count, 32)
    }

    // MARK: - JSON extraction from model output

    func testExtractsJSONFromCodeFence() {
        let output = """
        Here is the classification:
        ```json
        {"primary_tag": "correspondence", "secondary_tags": []}
        ```
        """
        let json = DocumentClassificationService.extractJSONObject(from: output)
        XCTAssertEqual(json, #"{"primary_tag": "correspondence", "secondary_tags": []}"#)
    }

    func testExtractsJSONWithBracesInsideStrings() {
        // A brace inside a string value must not end the object early.
        let output = #"prose {"reasoning_summary": "uses a } brace", "primary_tag": "statutes"} trailing"#
        let json = DocumentClassificationService.extractJSONObject(from: output)
        XCTAssertEqual(json, #"{"reasoning_summary": "uses a } brace", "primary_tag": "statutes"}"#)
        XCTAssertNotNil(json.flatMap { try? JSONDecoder().decode(DocumentClassification.self, from: Data($0.utf8)) })
    }

    func testExtractReturnsNilWhenNoObject() {
        XCTAssertNil(DocumentClassificationService.extractJSONObject(from: "no json here"))
    }

    // MARK: - Prompt

    func testSystemPromptCoversTaxonomyAndSchema() {
        let prompt = DocumentClassificationPrompt.system()
        for category in DocumentCategory.allCases {
            XCTAssertTrue(prompt.contains(category.rawValue), "Prompt missing taxonomy tag \(category.rawValue)")
        }
        for key in ["primary_tag", "secondary_tags", "confidence", "is_privileged_likely", "detected_jurisdiction"] {
            XCTAssertTrue(prompt.contains(key), "Prompt missing schema key \(key)")
        }
    }

    func testUserContentTruncatesLongText() {
        let long = String(repeating: "a", count: 50_000)
        let content = DocumentClassificationPrompt.userContent(fileName: "big.txt", text: long, maxCharacters: 1_000)
        XCTAssertTrue(content.contains("big.txt"))
        XCTAssertTrue(content.contains("[Document truncated for classification.]"))
        XCTAssertLessThan(content.count, 2_000)
    }

    func testNormalizeDoesNotDuplicateConfidenceWarning() {
        // If the model already explained the low confidence, don't add a second.
        let raw = DocumentClassification(
            primaryTag: "statutes", confidence: 0.2,
            warnings: ["Low confidence due to sparse text."]
        )
        let warnings = raw.normalized().warnings.filter { $0.localizedCaseInsensitiveContains("confidence") }
        XCTAssertEqual(warnings.count, 1)
    }

    // MARK: - Storage round-trip

    func testStoreDecodeRoundTripPreservesFields() throws {
        // Mirrors the encode in DocumentClassificationService.store and the decode
        // in MatterDocumentsController.classification(forDocument:).
        let original = DocumentClassification(
            primaryTag: "depositions_and_testimony",
            secondaryTags: ["evidence_and_exhibits"],
            confidence: 0.81,
            reasoningSummary: "Deposition transcript with marked exhibits.",
            documentFunction: "Records sworn testimony.",
            isConfidentialLikely: true,
            isDiscoveryMaterialLikely: true,
            detectedDocumentDate: "2024-11-12",
            detectedPartiesOrEntities: ["Jane Roe"],
            detectedJurisdiction: "S.D.N.Y.",
            warnings: ["partial OCR"]
        ).normalized()

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DocumentClassification.self, from: data)

        XCTAssertEqual(decoded.primaryCategory, .depositionsAndTestimony)
        XCTAssertEqual(decoded.secondaryCategories, [.evidenceAndExhibits])
        XCTAssertEqual(decoded.confidence, 0.81, accuracy: 0.0001)
        XCTAssertTrue(decoded.isConfidentialLikely)
        XCTAssertTrue(decoded.isDiscoveryMaterialLikely)
        XCTAssertEqual(decoded.detectedDocumentDate, "2024-11-12")
        XCTAssertEqual(decoded.detectedPartiesOrEntities, ["Jane Roe"])
        XCTAssertEqual(decoded.detectedJurisdiction, "S.D.N.Y.")
        XCTAssertEqual(decoded.warnings, ["partial OCR"])
    }
}
