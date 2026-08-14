import SupraCore

/// The non-identity fields that ship with a canonical matter create/edit.
/// Supplying this value asks the identity repository to persist the complete
/// workspace in the same transaction as the identity revision. `nil` retains
/// the narrow identity-only command used by migrations and focused fixtures.
public struct MatterIdentityWorkspaceDetails: Sendable, Equatable {
  public let name: String
  public let judge: String?
  public let docketNumber: String?
  public let practiceArea: String?
  public let matterDescription: String?
  public let internalMatterID: String?
  public let clientID: String?
  public let clientMatterID: String?
  public let notes: String?
  public let starterFolderNames: [String]

  public init(
    name: String,
    judge: String?,
    docketNumber: String?,
    practiceArea: String?,
    matterDescription: String?,
    internalMatterID: String?,
    clientID: String?,
    clientMatterID: String?,
    notes: String?,
    starterFolderNames: [String] = []
  ) {
    self.name = name
    self.judge = judge
    self.docketNumber = docketNumber
    self.practiceArea = practiceArea
    self.matterDescription = matterDescription
    self.internalMatterID = internalMatterID
    self.clientID = clientID
    self.clientMatterID = clientMatterID
    self.notes = notes
    self.starterFolderNames = starterFolderNames
  }
}

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
  public let workspaceDetails: MatterIdentityWorkspaceDetails?

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
    representations: [MatterRepresentationIdentity],
    workspaceDetails: MatterIdentityWorkspaceDetails? = nil
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
    self.workspaceDetails = workspaceDetails
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
  public let workspaceDetails: MatterIdentityWorkspaceDetails?

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
    representations: [MatterRepresentationIdentity],
    workspaceDetails: MatterIdentityWorkspaceDetails? = nil
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
    self.workspaceDetails = workspaceDetails
  }
}
