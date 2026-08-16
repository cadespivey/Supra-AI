import Foundation
import SupraCore

/// One coherent, content-minimal projection of the legal identities that own
/// matter-scoped research and drafting defaults.
///
/// This type deliberately does not reuse `MatterRecord`'s legacy free-text
/// fields as canonical authority. `MatterIdentityRepository` is the persisted
/// owner; callers may also construct synthetic snapshots for deterministic
/// policy tests.
public struct MatterIdentitySnapshot: Equatable, Sendable {
    public let matterID: String
    public let identityRevision: Int
    public let courtResolutionState: MatterCourtResolutionState
    public let canonicalCatalogVersion: String
    public let canonicalCatalogDigestSHA256: String
    public let canonicalJurisdictionID: CanonicalJurisdictionID?
    public let canonicalCourtID: CanonicalCourtID?
    public let legacyJurisdictionText: String
    public let legacyCourtText: String?
    public let parties: [MatterPartyIdentity]
    public let representations: [MatterRepresentationIdentity]

    public init(
        matterID: String,
        identityRevision: Int,
        courtResolutionState: MatterCourtResolutionState,
        canonicalCatalogVersion: String,
        canonicalCatalogDigestSHA256: String,
        canonicalJurisdictionID: CanonicalJurisdictionID?,
        canonicalCourtID: CanonicalCourtID?,
        legacyJurisdictionText: String,
        legacyCourtText: String?,
        parties: [MatterPartyIdentity],
        representations: [MatterRepresentationIdentity]
    ) {
        self.matterID = matterID
        self.identityRevision = identityRevision
        self.courtResolutionState = courtResolutionState
        self.canonicalCatalogVersion = canonicalCatalogVersion
        self.canonicalCatalogDigestSHA256 = canonicalCatalogDigestSHA256
        self.canonicalJurisdictionID = canonicalJurisdictionID
        self.canonicalCourtID = canonicalCourtID
        self.legacyJurisdictionText = legacyJurisdictionText
        self.legacyCourtText = legacyCourtText
        self.parties = parties
        self.representations = representations
    }
}
