import SupraCore
import SupraResearch
@testable import SupraSessions
import SupraStore
import XCTest

/// T-DATA-COURT-02 — unresolved persisted court text remains visible but cannot
/// silently acquire a jurisdiction, circuit, authority scope, or filing gate.
///
/// Expected RED: canonical matter-identity snapshots and
/// `MatterCourtPresentationBuilder` do not yet exist. Current matter consumers
/// still infer legal scope from free-text jurisdiction/court values.
final class ArchitectureUXTDataCourt02Tests: XCTestCase {
    func testUnknownCourtStaysVisibleAndBlocksCourtDependentWork() {
        let snapshot = MatterIdentitySnapshot(
            matterID: "matter-731",
            identityRevision: 7,
            courtResolutionState: .unresolved,
            canonicalCatalogVersion: "jurisdiction-courts-v1",
            canonicalCatalogDigestSHA256:
                "0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3",
            canonicalJurisdictionID: nil,
            canonicalCourtID: nil,
            legacyJurisdictionText: "Legacy Forum 719",
            legacyCourtText: "Fictional Maritime Claims Tribunal 731",
            parties: [],
            representations: []
        )

        let presentation = MatterCourtPresentationBuilder(
            catalog: JurisdictionCatalog.shared
        ).makePresentation(for: snapshot)

        XCTAssertEqual(presentation.matterID, "matter-731")
        XCTAssertEqual(presentation.identityRevision, 7)
        XCTAssertEqual(
            presentation.savedCourtText,
            "Fictional Maritime Claims Tribunal 731"
        )
        XCTAssertEqual(presentation.actionTitle, "Choose Court")
        XCTAssertNil(presentation.resolvedCourtName)
        XCTAssertNil(presentation.resolvedJurisdictionName)
        XCTAssertNil(presentation.authorityScope)
        XCTAssertEqual(presentation.courtListenerIDs, [])
        XCTAssertFalse(presentation.canRunCourtScopedResearch)
        XCTAssertFalse(presentation.canDraftCourtFiling)

        let scopedOutputElements = [
            presentation.resolvedCourtName,
            presentation.resolvedJurisdictionName,
            presentation.authorityScope?.selectedCourtName,
        ].compactMap { $0 } + presentation.courtListenerIDs
        XCTAssertFalse(scopedOutputElements.contains("Federal"))
        XCTAssertFalse(scopedOutputElements.contains("ca11"))
        XCTAssertFalse(scopedOutputElements.contains("flsd"))
        XCTAssertFalse(scopedOutputElements.contains("DEFAULT-000"))
    }
}
