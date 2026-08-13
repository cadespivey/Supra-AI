import SupraSessions
import XCTest

/// Package-level presentation contract supporting T-UX-DELETE-01/02. Native
/// XCUITests separately prove these typed semantics reach the shipping controls.
///
/// Expected RED: `DeletionActionPresentation` and its typed target/action/tone
/// values do not exist; current matter/chat surfaces use destructive controls
/// and falsely say a restorable soft deletion cannot be undone.
final class ArchitectureUXTDeleteSemanticsTests: XCTestCase {
    private let wireName = "T_UX_DELETE_01_WIRE_731"
    private let forbiddenDefault = "DEFAULT-000"

    func testSoftDeletionIsNeutralAndNamesRecycleBinRestore() {
        for target in DeletionTargetKind.allCases {
            let presentation = DeletionActionPresentation.make(
                action: .moveToRecycleBin,
                target: target,
                displayName: wireName
            )

            XCTAssertEqual(presentation.actionTitle, "Move to Recycle Bin", target.rawValue)
            XCTAssertEqual(presentation.tone, .neutral, target.rawValue)
            XCTAssertTrue(presentation.confirmationTitle.contains(wireName), target.rawValue)
            XCTAssertTrue(presentation.message.contains("Recycle Bin"), target.rawValue)
            XCTAssertTrue(presentation.message.localizedCaseInsensitiveContains("restore"), target.rawValue)
            XCTAssertFalse(presentation.message.localizedCaseInsensitiveContains("cannot be undone"))
            XCTAssertFalse(presentation.message.localizedCaseInsensitiveContains("can't be undone"))
            XCTAssertFalse(presentation.confirmationTitle.contains(forbiddenDefault))
            XCTAssertFalse(presentation.message.contains(forbiddenDefault))
        }
    }

    func testPermanentDeletionAloneIsDestructiveAndIrreversible() {
        for target in DeletionTargetKind.allCases {
            let presentation = DeletionActionPresentation.make(
                action: .deletePermanently,
                target: target,
                displayName: wireName
            )

            XCTAssertEqual(presentation.actionTitle, "Delete Permanently", target.rawValue)
            XCTAssertEqual(presentation.tone, .destructive, target.rawValue)
            XCTAssertTrue(presentation.confirmationTitle.contains(wireName), target.rawValue)
            XCTAssertTrue(
                presentation.message.localizedCaseInsensitiveContains("cannot be undone"),
                target.rawValue
            )
            XCTAssertFalse(presentation.message.contains(forbiddenDefault))
        }
    }

    func testDestinationNavigationIsOrdinaryNotADeletionAction() {
        let presentation = RecycleBinNavigationPresentation.standard
        XCTAssertEqual(presentation.title, "Recycle Bin")
        XCTAssertEqual(presentation.tone, .neutral)
        XCTAssertEqual(presentation.accessibilityDescription, "Restorable deleted items")
        XCTAssertFalse(presentation.accessibilityDescription.contains(forbiddenDefault))
    }
}
