import Foundation
import SupraCore
import SupraDraftingCore
@testable import SupraSessions
import SupraStore
import XCTest

/// T-DATA-PARTY-02 — defendant representation produces the inverse defaults,
/// and a conflicting requested side is usable only with an exact matter/revision/
/// party/purpose/digest-bound confirmation receipt.
///
/// Expected RED: no canonical builder, typed confirmation request, or receipt
/// validation exists; current drafting callers accept arbitrary strings.
final class ArchitectureUXTDataParty02Tests: XCTestCase {
    private let purpose = "notice_of_appearance:wire-831"

    func testDefendantClientInvertsDefaultsAndConflictRequiresExactReceipt() throws {
        let snapshot = makeSnapshot()
        let builder = DraftPartyDefaultsBuilder()

        let defaults = try builder.canonicalDefaults(for: snapshot)
        XCTAssertEqual(defaults.representedClientID, "party-813")
        XCTAssertEqual(defaults.representedClientName, "Harbor Logistics")
        XCTAssertEqual(defaults.representedDesignation, "Defendant")
        XCTAssertEqual(defaults.opposingPartyID, "party-817")
        XCTAssertEqual(defaults.opposingPartyName, "Meridian Fabrication")
        XCTAssertEqual(defaults.opposingDesignation, "Plaintiff")
        XCTAssertEqual(defaults.serviceRepresentationID, "representation-823")
        XCTAssertEqual(defaults.serviceRecipient.name, "Avery Quinn, Esq.")
        XCTAssertEqual(defaults.serviceRecipient.emails, ["service+823@example.test"])
        XCTAssertEqual(defaults.serviceRecipient.role, "Counsel for Plaintiff")

        let firstDecision = builder.selectionDecision(
            for: snapshot,
            requestedRepresentedPartyID: "party-817",
            purpose: purpose,
            confirmationReceipt: nil
        )
        guard case let .confirmationRequired(request) = firstDecision else {
            return XCTFail("conflicting requested party must require confirmation")
        }
        XCTAssertEqual(request.matterID, "matter-831")
        XCTAssertEqual(request.identityRevision, 7)
        XCTAssertEqual(request.canonicalRepresentedPartyID, "party-813")
        XCTAssertEqual(request.requestedRepresentedPartyID, "party-817")
        XCTAssertEqual(request.purpose, purpose)
        XCTAssertEqual(request.requestDigestSHA256.count, 64)
        XCTAssertNotEqual(request.requestDigestSHA256, String(repeating: "0", count: 64))

        for mismatched in [
            confirmedReceipt(from: request, matterID: "matter-DEFAULT-000"),
            confirmedReceipt(from: request, identityRevision: 8),
            confirmedReceipt(from: request, requestedPartyID: "party-DEFAULT-000"),
            confirmedReceipt(from: request, requestDigestSHA256: String(repeating: "0", count: 64)),
        ] {
            XCTAssertEqual(
                builder.selectionDecision(
                    for: snapshot,
                    requestedRepresentedPartyID: "party-817",
                    purpose: purpose,
                    confirmationReceipt: mismatched
                ),
                .blocked(.confirmationReceiptMismatch)
            )
        }

        let accepted = confirmedReceipt(from: request)
        let acceptedDecision = builder.selectionDecision(
            for: snapshot,
            requestedRepresentedPartyID: "party-817",
            purpose: purpose,
            confirmationReceipt: accepted
        )
        XCTAssertEqual(
            acceptedDecision,
            .confirmedOverride(
                DraftPartySelection(
                    matterID: "matter-831",
                    identityRevision: 7,
                    representedPartyID: "party-817",
                    confirmationReceiptID: "receipt-827",
                    confirmationRequestDigestSHA256: request.requestDigestSHA256
                )
            )
        )
    }

    private func makeSnapshot() -> MatterIdentitySnapshot {
        MatterIdentitySnapshot(
            matterID: "matter-831",
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
                    id: "party-813",
                    matterID: "matter-831",
                    displayName: "Harbor Logistics",
                    captionName: "HARBOR LOGISTICS, INC.,",
                    baseRole: .defendant,
                    captionOrder: 1,
                    clientStatus: .represented
                ),
                MatterPartyIdentity(
                    id: "party-817",
                    matterID: "matter-831",
                    displayName: "Meridian Fabrication",
                    captionName: "MERIDIAN FABRICATION, LLC,",
                    baseRole: .plaintiff,
                    captionOrder: 0,
                    clientStatus: .notRepresented
                ),
            ],
            representations: [
                MatterRepresentationIdentity(
                    id: "representation-823",
                    matterID: "matter-831",
                    representedPartyID: "party-817",
                    relationshipKind: .counsel,
                    representativeName: "Avery Quinn, Esq.",
                    firmName: "Quinn Trial Group",
                    serviceAddress: MatterServiceAddress(
                        street: "823 Harbor Street",
                        city: "Miami",
                        state: "Florida",
                        postalCode: "33131"
                    ),
                    serviceEmails: ["service+823@example.test"],
                    serviceOrder: 0
                ),
            ]
        )
    }

    private func confirmedReceipt(
        from request: PartyConflictConfirmationRequest,
        matterID: String? = nil,
        identityRevision: Int? = nil,
        requestedPartyID: String? = nil,
        requestDigestSHA256: String? = nil
    ) -> PartyConflictConfirmationReceipt {
        PartyConflictConfirmationReceipt(
            id: "receipt-827",
            matterID: matterID ?? request.matterID,
            identityRevision: identityRevision ?? request.identityRevision,
            canonicalRepresentedPartyID: request.canonicalRepresentedPartyID,
            requestedRepresentedPartyID:
                requestedPartyID ?? request.requestedRepresentedPartyID,
            purpose: request.purpose,
            requestDigestSHA256: requestDigestSHA256 ?? request.requestDigestSHA256,
            actor: "synthetic-attorney-829",
            confirmedAt: Date(timeIntervalSince1970: 1_946_160_827)
        )
    }
}
