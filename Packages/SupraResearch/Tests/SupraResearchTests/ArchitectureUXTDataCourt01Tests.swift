import SupraResearch
import XCTest

/// T-DATA-COURT-01 — a persisted legacy court string may become canonical identity
/// only through the versioned catalog's explicit alias map. Search and `bestMatch`
/// are intentionally absent from this test because fuzzy similarity is not authority
/// to persist a legally significant court identity.
///
/// Expected RED: `JurisdictionCatalog` does not yet expose `catalogVersion`,
/// `identityDigestSHA256`, `explicitPersistedCourtAliasKeys`, or
/// `resolvePersistedCourtIdentity(_:)`, so the selected test target must fail to
/// compile on those missing production APIs. Once they exist, the non-default wires
/// below must resolve the district court exactly and must not select the similarly
/// named bankruptcy court or invent an identity for an unknown string.
final class ArchitectureUXTDataCourt01Tests: XCTestCase {
    private let catalog = JurisdictionCatalog.shared

    private let districtOptionID =
        "federal-florida-united-states-district-court-for-the-southern-district-of-florida"
    private let bankruptcyOptionID =
        "federal-florida-united-states-bankruptcy-court-for-the-southern-district-of-florida"

    func testExplicitPersistedAliasResolvesOnlyApprovedDistrictCourtIdentity() throws {
        let district: JurisdictionOption = try XCTUnwrap(
            catalog.resolvePersistedCourtIdentity("S.D. Fla.")
        )

        XCTAssertEqual(district.id, districtOptionID)
        XCTAssertEqual(catalog.option(id: districtOptionID), district)
        XCTAssertEqual(district.level, .federalTrial)
        XCTAssertEqual(district.courtListenerIDs, ["flsd"])

        // Scoped forbidden-default proof: the result itself must carry none of the
        // identity fields from the similarly named bankruptcy tribunal.
        XCTAssertNotEqual(district.id, bankruptcyOptionID)
        XCTAssertNotEqual(district.level, .bankruptcy)
        XCTAssertNil(district.courtListenerIDs.firstIndex(of: "flsb"))

        // Prove that the forbidden alternative is a real catalog option, rather
        // than letting the negative assertions pass because the fixture is absent.
        let bankruptcy = try XCTUnwrap(catalog.option(id: bankruptcyOptionID))
        XCTAssertEqual(bankruptcy.level, .bankruptcy)
        XCTAssertEqual(bankruptcy.courtListenerIDs, ["flsb"])
    }

    func testUnknownPersistedCourtStringDoesNotReceiveFuzzyIdentity() {
        let unknown: JurisdictionOption? = catalog.resolvePersistedCourtIdentity(
            "S.D. Fla. 731 Tribunal"
        )

        XCTAssertNil(unknown)
    }

    func testPersistedIdentityAcceptsOnlyLiteralIDNameOrExplicitAliasKey() throws {
        let canonicalName =
            "United States District Court for the Southern District of Florida"

        XCTAssertEqual(
            catalog.resolvePersistedCourtIdentity(districtOptionID)?.id,
            districtOptionID
        )
        XCTAssertEqual(
            catalog.resolvePersistedCourtIdentity(canonicalName)?.id,
            districtOptionID
        )

        // These are plausible interactive-search inputs, but none is an exact
        // persisted ID/name or a reviewed alias key. Admitting them would turn
        // normalization into a hidden, unversioned legal-identity alias map.
        for forbiddenImplicitAlias in [
            "s.d. fla.",
            " S.D. Fla. ",
            "S D Fla",
            "United States District Court for the Southern District of Florida ",
            "Southern District of Florida",
        ] {
            XCTAssertNil(
                catalog.resolvePersistedCourtIdentity(forbiddenImplicitAlias),
                "Implicit alias was not explicitly reviewed: \(forbiddenImplicitAlias)"
            )
        }

        XCTAssertNotEqual(
            try XCTUnwrap(catalog.resolvePersistedCourtIdentity(canonicalName)).id,
            bankruptcyOptionID
        )
    }

    func testExplicitAliasCatalogHasUniqueKeysAndPinnedIdentity() {
        let aliasKeys = catalog.explicitPersistedCourtAliasKeys

        XCTAssertTrue(aliasKeys.contains("S.D. Fla."))
        XCTAssertFalse(aliasKeys.contains("S.D. Fla. 731 Tribunal"))
        XCTAssertEqual(aliasKeys.count, Set(aliasKeys).count, "explicit alias keys must be unique")

        XCTAssertEqual(catalog.catalogVersion, "jurisdiction-courts-v1")
        XCTAssertNotEqual(catalog.catalogVersion, "default")
        XCTAssertEqual(
            catalog.sourceResourceSHA256,
            "41ea70e290a002b966506c4359c5c8f89caef19cb153b64430d56e189ab07d98"
        )
        XCTAssertEqual(
            catalog.identityDigestSHA256,
            "0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3"
        )
        XCTAssertNotEqual(catalog.identityDigestSHA256, String(repeating: "0", count: 64))
    }

    func testFixtureCatalogCannotImpersonateVersionedBundledIdentity() {
        let fixture = JurisdictionCatalog(text: """
        Federal and State Courts
        FEDERAL COURTS AND TRIBUNALS
        United States District Court for the Southern District of Florida
        STATE, COUNTY, AND MUNICIPAL COURTS
        """)

        XCTAssertEqual(fixture.catalogVersion, "unversioned-fixture")
        XCTAssertTrue(fixture.explicitPersistedCourtAliasKeys.isEmpty)
        XCTAssertNil(fixture.resolvePersistedCourtIdentity("S.D. Fla."))
        XCTAssertNotEqual(fixture.sourceResourceSHA256, catalog.sourceResourceSHA256)
        XCTAssertNotEqual(fixture.identityDigestSHA256, catalog.identityDigestSHA256)
    }
}
