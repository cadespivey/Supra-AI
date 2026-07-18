import Foundation
@testable import SupraTestKit
import XCTest

final class TypedStructureEvidenceBenchmarkTests: XCTestCase {
    func testTBEN07ScoresTypedEvidenceInsteadOfFilenamePresenceAlone() throws {
        // T-BEN-07 expected RED: no typed-structure benchmark metric exists;
        // B-RET-02 currently treats these flat and typed results as identical.
        let expected = ["structured.docx", "damages.xlsx"]
        let flat = TypedStructureEvidenceBenchmark.observation(cases: [
            TypedStructureEvidenceCase(
                expectedDocumentNames: expected,
                candidates: [
                    .init(documentName: "structured.docx", unitKind: nil),
                    .init(documentName: "damages.xlsx", unitKind: nil),
                ]
            ),
        ])
        let typed = TypedStructureEvidenceBenchmark.observation(cases: [
            TypedStructureEvidenceCase(
                expectedDocumentNames: expected,
                candidates: [
                    .init(documentName: "structured.docx", unitKind: "comment"),
                    .init(documentName: "damages.xlsx", unitKind: "table_cell"),
                ]
            ),
        ])

        XCTAssertEqual(flat.metricID, "B-RET-02")
        XCTAssertEqual(flat.name, "typed_structure_evidence_recall")
        XCTAssertEqual(flat.result.value, 0)
        XCTAssertEqual(typed.result.value, 1)
        XCTAssertEqual(typed.result.numerator, 2)
        XCTAssertEqual(typed.result.denominator, 2)
    }
}
