import XCTest
@testable import SupraDocuments

final class StructuralDiffTests: XCTestCase {
    func testTVER06PinsChangedInsertedDeletedUnitsAndResolvableLocators() throws {
        // Expected RED: StructuralDiff and its revision-independent node model are missing.
        let before = [
            node("before-root", key: "document", ordinal: 0, kind: .document, text: nil),
            node("before-payment", key: "section/payment", ordinal: 1, kind: .paragraph, text: "Payment is due in 30 days."),
            node("before-termination", key: "section/termination", ordinal: 2, kind: .paragraph, text: "Either party may terminate on notice."),
            node("before-cap", key: "table/liability/amount", ordinal: 3, kind: .tableCell, text: "$150,000"),
            node("before-stable", key: "section/notices", ordinal: 4, kind: .paragraph, text: "Notices must be written."),
        ]
        let after = [
            node("after-root", key: "document", ordinal: 0, kind: .document, text: nil),
            node("after-payment", key: "section/payment", ordinal: 1, kind: .paragraph, text: "Payment is due in 45 days."),
            node("after-audit", key: "section/audit", ordinal: 2, kind: .paragraph, text: "Records remain available for audit."),
            node("after-cap", key: "table/liability/amount", ordinal: 3, kind: .tableCell, text: "$275,000"),
            node("after-stable", key: "section/notices", ordinal: 4, kind: .paragraph, text: "Notices must be written."),
        ]

        let result = StructuralDiff.compare(before: before, after: after)

        XCTAssertEqual(result.changes.map(\.kind), [.changed, .deleted, .inserted, .changed])
        XCTAssertEqual(result.changed.map { "\($0.before?.nodeID ?? "nil")->\($0.after?.nodeID ?? "nil")" }, [
            "before-payment->after-payment",
            "before-cap->after-cap",
        ])
        XCTAssertEqual(result.deleted.map { $0.before?.nodeID }, ["before-termination"])
        XCTAssertEqual(result.inserted.map { $0.after?.nodeID }, ["after-audit"])
        XCTAssertEqual(result.changed.map { "\($0.before?.text ?? "nil") => \($0.after?.text ?? "nil")" }, [
            "Payment is due in 30 days. => Payment is due in 45 days.",
            "$150,000 => $275,000",
        ])
        XCTAssertFalse(result.changes.contains { change in
            change.before?.nodeID == "before-stable" || change.after?.nodeID == "after-stable"
        }, "unchanged structural units must stay out of the diff")

        let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.nodeID, $0) })
        let afterByID = Dictionary(uniqueKeysWithValues: after.map { ($0.nodeID, $0) })
        for change in result.changes {
            if let locator = change.before {
                XCTAssertEqual(beforeByID[locator.nodeID]?.nodeKey, locator.nodeKey)
                XCTAssertEqual(beforeByID[locator.nodeID]?.text, locator.text)
            }
            if let locator = change.after {
                XCTAssertEqual(afterByID[locator.nodeID]?.nodeKey, locator.nodeKey)
                XCTAssertEqual(afterByID[locator.nodeID]?.text, locator.text)
            }
        }
    }

    private func node(
        _ id: String,
        key: String,
        ordinal: Int,
        kind: DocumentStructureNodeKind,
        text: String?
    ) -> StructuralDiffNode {
        StructuralDiffNode(
            nodeID: id,
            nodeKey: key,
            parentNodeKey: key == "document" ? nil : "document",
            ordinal: ordinal,
            kind: kind,
            text: text
        )
    }
}
