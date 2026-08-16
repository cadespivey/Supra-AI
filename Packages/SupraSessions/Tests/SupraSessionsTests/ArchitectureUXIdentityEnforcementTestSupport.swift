import Foundation
import SupraCore
import SupraDraftingCore
import SupraResearch
@testable import SupraSessions
import SupraStore

enum ArchitectureUXIdentityEnforcementWire {
    static let forbiddenDefault = "DEFAULT-000"
    static let resolvedMatterID = "matter-identity-enforcement-713"
    static let unresolvedMatterID = "matter-identity-enforcement-719"
    static let representedPartyID = "party-identity-enforcement-727"
    static let opposingPartyID = "party-identity-enforcement-733"
    static let representationID = "representation-identity-enforcement-739"
    static let representedName = "Aster Harbor Fabrication 727"
    static let representedCaption = "ASTER HARBOR FABRICATION 727,"
    static let opposingName = "Northline Rail Logistics 733"
    static let opposingCaption = "NORTHLINE RAIL LOGISTICS 733,"
    static let opposingCounsel = "Jordan Rowan 739, Esq."
    static let opposingFirm = "Rowan Legal Group 743"
    static let opposingEmail = "service+identity-751@example.test"
    static let legacyClientCanary = "LEGACY-CLIENT-IDENTITY-757"
    static let legacyJurisdictionCanary = "LEGACY-JURISDICTION-IDENTITY-761"
    static let legacyCourtCanary = "LEGACY-COURT-IDENTITY-769"
    static let recognizableLegacyJurisdiction = "Florida"
    static let recognizableLegacyCourt = "S.D. Fla."
    static let jurisdictionID = CanonicalJurisdictionID(
        rawValue: "federal-united-states-court-of-appeals-for-the-eleventh-circuit"
    )
    static let courtID = CanonicalCourtID(
        rawValue:
            "federal-florida-united-states-district-court-for-the-southern-district-of-florida"
    )
    static let courtName = "United States District Court for the Southern District of Florida"
    static let jurisdictionName = "United States Court of Appeals for the Eleventh Circuit"
    static let docketNumber = "IDENTITY-713-CV-719"
    static let researchTitle = "Identity enforcement plan 773"
    static let researchIssue = "Whether the synthetic renewal notice was timely under wire 773"
    static let researchQuery = "synthetic renewal notice timeliness wire 773"
    static let partyOverridePurpose = "notice_of_appearance:identity-enforcement-779"
}

func makeArchitectureUXIdentityEnforcementStore(
    prefix: String
) throws -> (root: URL, store: SupraStore) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ArchitectureUXIdentityEnforcement-\(prefix)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (root, try SupraStore(url: root.appendingPathComponent("test.sqlite")))
}

@discardableResult
func seedArchitectureUXIdentityMatter(
    store: SupraStore,
    matterID: String,
    state: MatterCourtResolutionState,
    legacyJurisdiction: String,
    legacyCourt: String?
) throws -> MatterIdentitySnapshot {
    let resolved = state == .court
    return try store.matterIdentity.createMatter(
        command: MatterIdentityCreateCommand(
            matterID: matterID,
            name: "Aster Harbor v. Northline \(matterID)",
            legacyJurisdictionText: legacyJurisdiction,
            legacyCourtText: legacyCourt,
            legacyPartyPerspective: .defendant,
            legacyClientNames: ArchitectureUXIdentityEnforcementWire.legacyClientCanary,
            courtResolutionState: state,
            canonicalCatalogVersion: JurisdictionCatalog.shared.catalogVersion,
            canonicalCatalogDigestSHA256: JurisdictionCatalog.shared.identityDigestSHA256,
            canonicalJurisdictionID: resolved
                ? ArchitectureUXIdentityEnforcementWire.jurisdictionID : nil,
            canonicalCourtID: resolved
                ? ArchitectureUXIdentityEnforcementWire.courtID : nil,
            parties: [
                MatterPartyIdentity(
                    id: ArchitectureUXIdentityEnforcementWire.representedPartyID,
                    matterID: matterID,
                    displayName: ArchitectureUXIdentityEnforcementWire.representedName,
                    captionName: ArchitectureUXIdentityEnforcementWire.representedCaption,
                    baseRole: .plaintiff,
                    captionOrder: 0,
                    clientStatus: .represented
                ),
                MatterPartyIdentity(
                    id: ArchitectureUXIdentityEnforcementWire.opposingPartyID,
                    matterID: matterID,
                    displayName: ArchitectureUXIdentityEnforcementWire.opposingName,
                    captionName: ArchitectureUXIdentityEnforcementWire.opposingCaption,
                    baseRole: .defendant,
                    captionOrder: 1,
                    clientStatus: .notRepresented
                ),
            ],
            representations: [
                MatterRepresentationIdentity(
                    id: ArchitectureUXIdentityEnforcementWire.representationID,
                    matterID: matterID,
                    representedPartyID: ArchitectureUXIdentityEnforcementWire.opposingPartyID,
                    relationshipKind: .counsel,
                    representativeName: ArchitectureUXIdentityEnforcementWire.opposingCounsel,
                    firmName: ArchitectureUXIdentityEnforcementWire.opposingFirm,
                    serviceAddress: MatterServiceAddress(
                        street: "739 Identity Avenue",
                        city: "Miami",
                        state: "Florida",
                        postalCode: "33131"
                    ),
                    serviceEmails: [ArchitectureUXIdentityEnforcementWire.opposingEmail],
                    serviceOrder: 0
                ),
            ],
            workspaceDetails: MatterIdentityWorkspaceDetails(
                name: "Aster Harbor v. Northline \(matterID)",
                judge: "Division 7",
                docketNumber: ArchitectureUXIdentityEnforcementWire.docketNumber,
                practiceArea: "Synthetic Identity Enforcement",
                matterDescription: "Synthetic matter identity enforcement fixture.",
                internalMatterID: "IDENTITY-713",
                clientID: "CLIENT-719",
                clientMatterID: "CLIENT-MATTER-727",
                notes: "Synthetic fixture only.",
                starterFolderNames: ["Identity Evidence 733"]
            )
        )
    )
}

func architectureUXIdentityProfile() -> AssistantProfile {
    var profile = AssistantProfile()
    profile.fullName = "Taylor Quinn 787"
    profile.organization = "Quinn Identity Law 797"
    profile.barNumber = "BAR-809"
    profile.officeStreet = "809 Verification Way"
    profile.officeCity = "Miami"
    profile.officeState = "Florida"
    profile.officeZip = "33131"
    profile.officePhone = "(305) 555-0811"
    profile.primaryEmail = "tquinn+identity-811@example.test"
    return profile
}
