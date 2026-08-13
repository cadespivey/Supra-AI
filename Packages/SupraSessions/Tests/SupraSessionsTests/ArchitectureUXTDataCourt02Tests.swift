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

    /// Expected RED: exact identifiers that are individually valid must still
    /// fail closed when the persisted jurisdiction and court do not belong to
    /// one coherent authority scope.
    func testExactCourtPairedWithWrongCircuitDoesNotBecomeResolved() {
        let snapshot = MatterIdentitySnapshot(
            matterID: "matter-733",
            identityRevision: 7,
            courtResolutionState: .court,
            canonicalCatalogVersion: JurisdictionCatalog.shared.catalogVersion,
            canonicalCatalogDigestSHA256: JurisdictionCatalog.shared.identityDigestSHA256,
            canonicalJurisdictionID: CanonicalJurisdictionID(
                rawValue: "federal-united-states-court-of-appeals-for-the-fifth-circuit"
            ),
            canonicalCourtID: CanonicalCourtID(
                rawValue:
                    "federal-florida-united-states-district-court-for-the-southern-district-of-florida"
            ),
            legacyJurisdictionText: "Synthetic mismatched circuit 733",
            legacyCourtText: "S.D. Fla.",
            parties: [],
            representations: []
        )

        let presentation = MatterCourtPresentationBuilder(
            catalog: JurisdictionCatalog.shared
        ).makePresentation(for: snapshot)

        XCTAssertEqual(presentation.matterID, "matter-733")
        XCTAssertEqual(presentation.savedCourtText, "S.D. Fla.")
        XCTAssertEqual(presentation.actionTitle, "Choose Court")
        XCTAssertNil(presentation.resolvedCourtName)
        XCTAssertNil(presentation.resolvedJurisdictionName)
        XCTAssertNil(presentation.authorityScope)
        XCTAssertEqual(presentation.courtListenerIDs, [])
        XCTAssertFalse(presentation.canRunCourtScopedResearch)
        XCTAssertFalse(presentation.canDraftCourtFiling)
        XCTAssertFalse(presentation.courtListenerIDs.contains("ca5"))
        XCTAssertFalse(presentation.courtListenerIDs.contains("flsd"))
        XCTAssertFalse(String(describing: presentation).contains("DEFAULT-000"))
    }

    func testExactCourtPairedWithItsGoverningCircuitBecomesResolved() throws {
        let snapshot = MatterIdentitySnapshot(
            matterID: "matter-739",
            identityRevision: 7,
            courtResolutionState: .court,
            canonicalCatalogVersion: JurisdictionCatalog.shared.catalogVersion,
            canonicalCatalogDigestSHA256: JurisdictionCatalog.shared.identityDigestSHA256,
            canonicalJurisdictionID: CanonicalJurisdictionID(
                rawValue: "federal-united-states-court-of-appeals-for-the-eleventh-circuit"
            ),
            canonicalCourtID: CanonicalCourtID(
                rawValue:
                    "federal-florida-united-states-district-court-for-the-southern-district-of-florida"
            ),
            legacyJurisdictionText: "Florida",
            legacyCourtText: "S.D. Fla.",
            parties: [],
            representations: []
        )

        let presentation = MatterCourtPresentationBuilder(
            catalog: JurisdictionCatalog.shared
        ).makePresentation(for: snapshot)

        XCTAssertEqual(presentation.matterID, "matter-739")
        XCTAssertEqual(presentation.actionTitle, "Change Court")
        XCTAssertEqual(
            presentation.resolvedCourtName,
            "United States District Court for the Southern District of Florida"
        )
        XCTAssertEqual(
            presentation.resolvedJurisdictionName,
            "United States Court of Appeals for the Eleventh Circuit"
        )
        XCTAssertEqual(
            try XCTUnwrap(presentation.authorityScope).selectedCourtName,
            presentation.resolvedCourtName
        )
        XCTAssertEqual(presentation.courtListenerIDs, ["flsd", "ca11", "scotus"])
        XCTAssertTrue(presentation.canRunCourtScopedResearch)
        XCTAssertTrue(presentation.canDraftCourtFiling)
        XCTAssertFalse(presentation.courtListenerIDs.contains("flsb"))
        XCTAssertFalse(String(describing: presentation).contains("DEFAULT-000"))
    }
}
