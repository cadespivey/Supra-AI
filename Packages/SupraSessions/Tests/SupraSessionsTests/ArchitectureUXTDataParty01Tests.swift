import SupraCore
import SupraDraftingCore
@testable import SupraSessions
import SupraStore
import XCTest

/// T-DATA-PARTY-01 — canonical plaintiff representation drives every related
/// caption and service default as one coherent projection.
///
/// Expected RED: structured matter identity and `DraftPartyDefaultsBuilder` do
/// not yet exist; the app still initializes the represented party as Defendant
/// and the recipient as Counsel for Plaintiff.
final class ArchitectureUXTDataParty01Tests: XCTestCase {
    func testPlaintiffClientProducesCoherentOppositeSideDefaults() throws {
        let snapshot = MatterIdentitySnapshot(
            matterID: "matter-731",
            identityRevision: 7,
            courtResolutionState: .court,
            canonicalCatalogVersion: "jurisdiction-courts-v1",
            canonicalCatalogDigestSHA256:
                "0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3",
            canonicalJurisdictionID: CanonicalJurisdictionID(
                rawValue: "federal-united-states-court-of-appeals-for-the-eleventh-circuit"
            ),
            canonicalCourtID: CanonicalCourtID(
                rawValue:
                    "federal-florida-united-states-district-court-for-the-southern-district-of-florida"
            ),
            legacyJurisdictionText: "Florida",
            legacyCourtText: "S.D. Fla.",
            parties: [
                MatterPartyIdentity(
                    id: "party-713",
                    matterID: "matter-731",
                    displayName: "Meridian Fabrication",
                    captionName: "MERIDIAN FABRICATION, LLC,",
                    baseRole: .plaintiff,
                    captionOrder: 0,
                    clientStatus: .represented
                ),
                MatterPartyIdentity(
                    id: "party-719",
                    matterID: "matter-731",
                    displayName: "Harbor Logistics",
                    captionName: "HARBOR LOGISTICS, INC.,",
                    baseRole: .defendant,
                    captionOrder: 1,
                    clientStatus: .notRepresented
                ),
            ],
            representations: [
                MatterRepresentationIdentity(
                    id: "representation-727",
                    matterID: "matter-731",
                    representedPartyID: "party-719",
                    relationshipKind: .counsel,
                    representativeName: "Jordan Rowan, Esq.",
                    firmName: "Rowan Legal Group",
                    serviceAddress: MatterServiceAddress(
                        street: "727 Anchor Way",
                        city: "Miami",
                        state: "Florida",
                        postalCode: "33131"
                    ),
                    serviceEmails: ["service+727@example.test"],
                    serviceOrder: 0
                ),
            ]
        )

        let defaults = try DraftPartyDefaultsBuilder().canonicalDefaults(for: snapshot)

        XCTAssertEqual(defaults.matterID, "matter-731")
        XCTAssertEqual(defaults.identityRevision, 7)
        XCTAssertEqual(defaults.representedClientID, "party-713")
        XCTAssertEqual(defaults.representedClientName, "Meridian Fabrication")
        XCTAssertEqual(defaults.representedDesignation, "Plaintiff")
        XCTAssertEqual(defaults.opposingPartyID, "party-719")
        XCTAssertEqual(defaults.opposingPartyName, "Harbor Logistics")
        XCTAssertEqual(defaults.opposingDesignation, "Defendant")
        XCTAssertEqual(defaults.captionParties, [
            PartyLine(name: "MERIDIAN FABRICATION, LLC,", designation: "Plaintiff,"),
            PartyLine(name: "HARBOR LOGISTICS, INC.,", designation: "Defendant."),
        ])
        XCTAssertEqual(defaults.serviceRepresentationID, "representation-727")
        XCTAssertEqual(defaults.serviceRecipient.name, "Jordan Rowan, Esq.")
        XCTAssertEqual(defaults.serviceRecipient.firm, "Rowan Legal Group")
        XCTAssertEqual(defaults.serviceRecipient.address.street, "727 Anchor Way")
        XCTAssertEqual(defaults.serviceRecipient.emails, ["service+727@example.test"])
        XCTAssertEqual(defaults.serviceRecipient.role, "Counsel for Defendant")

        XCTAssertNotEqual(defaults.representedDesignation, "Defendant")
        XCTAssertNotEqual(defaults.serviceRecipient.role, "Counsel for Plaintiff")
        XCTAssertFalse(defaults.serviceRecipient.role.contains("DEFAULT-000"))
    }
}
