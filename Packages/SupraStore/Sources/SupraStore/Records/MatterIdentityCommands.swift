import SupraCore

/// One atomic request to create a matter and publish its canonical legal
/// identity graph. Legacy strings remain source evidence; only the explicit
/// party and representation values become structured identity.
public struct MatterIdentityCreateCommand: Sendable {
  public let matterID: String
  public let name: String
  public let legacyJurisdictionText: String
  public let legacyCourtText: String?
  public let legacyPartyPerspective: PartyPerspective
  public let legacyClientNames: String?
  public let courtResolutionState: MatterCourtResolutionState
  public let canonicalCatalogVersion: String
  public let canonicalCatalogDigestSHA256: String
  public let canonicalJurisdictionID: CanonicalJurisdictionID?
  public let canonicalCourtID: CanonicalCourtID?
  public let parties: [MatterPartyIdentity]
  public let representations: [MatterRepresentationIdentity]

  public init(
    matterID: String,
    name: String,
    legacyJurisdictionText: String,
    legacyCourtText: String?,
    legacyPartyPerspective: PartyPerspective,
    legacyClientNames: String?,
    courtResolutionState: MatterCourtResolutionState,
    canonicalCatalogVersion: String,
    canonicalCatalogDigestSHA256: String,
    canonicalJurisdictionID: CanonicalJurisdictionID?,
    canonicalCourtID: CanonicalCourtID?,
    parties: [MatterPartyIdentity],
    representations: [MatterRepresentationIdentity]
  ) {
    self.matterID = matterID
    self.name = name
    self.legacyJurisdictionText = legacyJurisdictionText
    self.legacyCourtText = legacyCourtText
    self.legacyPartyPerspective = legacyPartyPerspective
    self.legacyClientNames = legacyClientNames
    self.courtResolutionState = courtResolutionState
    self.canonicalCatalogVersion = canonicalCatalogVersion
    self.canonicalCatalogDigestSHA256 = canonicalCatalogDigestSHA256
    self.canonicalJurisdictionID = canonicalJurisdictionID
    self.canonicalCourtID = canonicalCourtID
    self.parties = parties
    self.representations = representations
  }
}

/// One optimistic, atomic replacement of a matter's canonical legal identity
/// graph. The expected revision makes exact retries idempotent and rejects a
/// different payload after that revision has already been consumed.
public struct MatterIdentityUpdateCommand: Sendable {
  public let matterID: String
  public let expectedIdentityRevision: Int
  public let legacyJurisdictionText: String
  public let legacyCourtText: String?
  public let legacyPartyPerspective: PartyPerspective
  public let legacyClientNames: String?
  public let courtResolutionState: MatterCourtResolutionState
  public let canonicalCatalogVersion: String
  public let canonicalCatalogDigestSHA256: String
  public let canonicalJurisdictionID: CanonicalJurisdictionID?
  public let canonicalCourtID: CanonicalCourtID?
  public let parties: [MatterPartyIdentity]
  public let representations: [MatterRepresentationIdentity]

  public init(
    matterID: String,
    expectedIdentityRevision: Int,
    legacyJurisdictionText: String,
    legacyCourtText: String?,
    legacyPartyPerspective: PartyPerspective,
    legacyClientNames: String?,
    courtResolutionState: MatterCourtResolutionState,
    canonicalCatalogVersion: String,
    canonicalCatalogDigestSHA256: String,
    canonicalJurisdictionID: CanonicalJurisdictionID?,
    canonicalCourtID: CanonicalCourtID?,
    parties: [MatterPartyIdentity],
    representations: [MatterRepresentationIdentity]
  ) {
    self.matterID = matterID
    self.expectedIdentityRevision = expectedIdentityRevision
    self.legacyJurisdictionText = legacyJurisdictionText
    self.legacyCourtText = legacyCourtText
    self.legacyPartyPerspective = legacyPartyPerspective
    self.legacyClientNames = legacyClientNames
    self.courtResolutionState = courtResolutionState
    self.canonicalCatalogVersion = canonicalCatalogVersion
    self.canonicalCatalogDigestSHA256 = canonicalCatalogDigestSHA256
    self.canonicalJurisdictionID = canonicalJurisdictionID
    self.canonicalCourtID = canonicalCourtID
    self.parties = parties
    self.representations = representations
  }
}
