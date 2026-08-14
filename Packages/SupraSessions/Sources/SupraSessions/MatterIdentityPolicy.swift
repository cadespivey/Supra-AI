import CryptoKit
import Foundation
import SupraCore
import SupraDraftingCore
import SupraResearch
import SupraStore

public struct MatterCourtPresentation: Equatable, Sendable {
    public let matterID: String
    public let identityRevision: Int
    public let savedCourtText: String?
    public let actionTitle: String
    public let resolvedCourtName: String?
    public let resolvedJurisdictionName: String?
    public let authorityScope: JurisdictionAuthorityScope?
    public let courtListenerIDs: [String]
    public let canRunCourtScopedResearch: Bool
    public let canDraftCourtFiling: Bool
}

/// Presents court identity without interpreting legacy free text. Canonical IDs
/// must bind the exact version and digest of the catalog supplied by composition.
public struct MatterCourtPresentationBuilder: Sendable {
    private let catalog: JurisdictionCatalog

    public init(catalog: JurisdictionCatalog) {
        self.catalog = catalog
    }

    public func makePresentation(for snapshot: MatterIdentitySnapshot) -> MatterCourtPresentation {
        guard snapshot.courtResolutionState == .court,
              snapshot.canonicalCatalogVersion == catalog.catalogVersion,
              snapshot.canonicalCatalogDigestSHA256 == catalog.identityDigestSHA256,
              let jurisdictionID = snapshot.canonicalJurisdictionID?.rawValue,
              let courtID = snapshot.canonicalCourtID?.rawValue,
              let jurisdiction = catalog.option(id: jurisdictionID),
              let court = catalog.option(id: courtID),
              court.level != .jurisdiction
        else {
            return unresolvedPresentation(for: snapshot)
        }

        guard catalog.canonicalJurisdictionOption(
            forSelectedOptionID: court.id
        )?.id == jurisdiction.id else {
            return unresolvedPresentation(for: snapshot)
        }
        let scope = catalog.authorityScope(for: court)
        return MatterCourtPresentation(
            matterID: snapshot.matterID,
            identityRevision: snapshot.identityRevision,
            savedCourtText: snapshot.legacyCourtText,
            actionTitle: "Change Court",
            resolvedCourtName: court.displayName,
            resolvedJurisdictionName: scope.jurisdictionName,
            authorityScope: scope,
            courtListenerIDs: scope.courtListenerIDs,
            canRunCourtScopedResearch: true,
            canDraftCourtFiling: true
        )
    }

    private func unresolvedPresentation(
        for snapshot: MatterIdentitySnapshot
    ) -> MatterCourtPresentation {
        MatterCourtPresentation(
            matterID: snapshot.matterID,
            identityRevision: snapshot.identityRevision,
            savedCourtText: snapshot.legacyCourtText,
            actionTitle: "Choose Court",
            resolvedCourtName: nil,
            resolvedJurisdictionName: nil,
            authorityScope: nil,
            courtListenerIDs: [],
            canRunCourtScopedResearch: false,
            canDraftCourtFiling: false
        )
    }
}

public struct DraftPartyDefaults: Equatable, Sendable {
    public let matterID: String
    public let identityRevision: Int
    public let representedClientID: String
    public let representedClientName: String
    public let representedDesignation: String
    public let opposingPartyID: String
    public let opposingPartyName: String
    public let opposingDesignation: String
    public let captionParties: [PartyLine]
    public let serviceRepresentationID: String
    public let serviceRecipient: ServiceRecipient
}

public enum DraftPartyDefaultsError: Error, Equatable, Sendable {
    case incoherentMatterOwnership
    case duplicateIdentity
    case representedPartyChoiceRequired
    case opposingPartyChoiceRequired
    case unsupportedPartyRole
    case serviceRecipientChoiceRequired
    case incompleteServiceRecipient
}

public struct DraftPartySelection: Equatable, Sendable {
    public let matterID: String
    public let identityRevision: Int
    public let representedPartyID: String
    public let confirmationReceiptID: String?
    public let confirmationRequestDigestSHA256: String?

    public init(
        matterID: String,
        identityRevision: Int,
        representedPartyID: String,
        confirmationReceiptID: String?,
        confirmationRequestDigestSHA256: String?
    ) {
        self.matterID = matterID
        self.identityRevision = identityRevision
        self.representedPartyID = representedPartyID
        self.confirmationReceiptID = confirmationReceiptID
        self.confirmationRequestDigestSHA256 = confirmationRequestDigestSHA256
    }
}

public enum DraftPartySelectionBlocker: Equatable, Sendable {
    case identityIncoherent
    case requestedPartyUnavailable
    case confirmationReceiptMismatch
}

public enum DraftPartySelectionDecision: Equatable, Sendable {
    case canonical(DraftPartySelection)
    case confirmationRequired(PartyConflictConfirmationRequest)
    case confirmedOverride(DraftPartySelection)
    case blocked(DraftPartySelectionBlocker)
}

/// Derives caption, represented-side, opposing-side, and service defaults from
/// one coherent identity snapshot. Ambiguity is an explicit blocker; the builder
/// never selects a first party or invents counsel/address data.
public struct DraftPartyDefaultsBuilder: Sendable {
    public init() {}

    public func canonicalDefaults(for snapshot: MatterIdentitySnapshot) throws -> DraftPartyDefaults {
        let identity = try validatedIdentity(snapshot)
        let representedDesignation = try Self.designation(for: identity.represented.baseRole)
        let opposingDesignation = try Self.designation(for: identity.opposing.baseRole)
        let address = try Self.officeBlock(from: identity.representation)
        guard let firm = identity.representation.firmName,
              !firm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !identity.representation.representativeName
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !identity.representation.serviceEmails.isEmpty
        else {
            throw DraftPartyDefaultsError.incompleteServiceRecipient
        }

        let captionParties = try snapshot.parties
            .sorted {
                if $0.captionOrder != $1.captionOrder {
                    return $0.captionOrder < $1.captionOrder
                }
                return $0.id < $1.id
            }
            .enumerated()
            .map { index, party in
                let label = try Self.designation(for: party.baseRole)
                let punctuation = index == snapshot.parties.count - 1 ? "." : ","
                return PartyLine(name: party.captionName, designation: label + punctuation)
            }

        return DraftPartyDefaults(
            matterID: snapshot.matterID,
            identityRevision: snapshot.identityRevision,
            representedClientID: identity.represented.id,
            representedClientName: identity.represented.displayName,
            representedDesignation: representedDesignation,
            opposingPartyID: identity.opposing.id,
            opposingPartyName: identity.opposing.displayName,
            opposingDesignation: opposingDesignation,
            captionParties: captionParties,
            serviceRepresentationID: identity.representation.id,
            serviceRecipient: ServiceRecipient(
                name: identity.representation.representativeName,
                firm: firm,
                address: address,
                emails: identity.representation.serviceEmails,
                role: "Counsel for \(opposingDesignation)"
            )
        )
    }

    public func selectionDecision(
        for snapshot: MatterIdentitySnapshot,
        requestedRepresentedPartyID: String,
        purpose: String,
        confirmationReceipt: PartyConflictConfirmationReceipt?
    ) -> DraftPartySelectionDecision {
        let identity: ValidatedIdentity
        do {
            identity = try validatedIdentity(snapshot)
        } catch {
            return .blocked(.identityIncoherent)
        }
        guard snapshot.parties.contains(where: { $0.id == requestedRepresentedPartyID }) else {
            return .blocked(.requestedPartyUnavailable)
        }
        if requestedRepresentedPartyID == identity.represented.id {
            return .canonical(DraftPartySelection(
                matterID: snapshot.matterID,
                identityRevision: snapshot.identityRevision,
                representedPartyID: identity.represented.id,
                confirmationReceiptID: nil,
                confirmationRequestDigestSHA256: nil
            ))
        }

        let digest = Self.confirmationRequestDigest(
            matterID: snapshot.matterID,
            identityRevision: snapshot.identityRevision,
            canonicalRepresentedPartyID: identity.represented.id,
            requestedRepresentedPartyID: requestedRepresentedPartyID,
            purpose: purpose
        )
        let request = PartyConflictConfirmationRequest(
            matterID: snapshot.matterID,
            identityRevision: snapshot.identityRevision,
            canonicalRepresentedPartyID: identity.represented.id,
            requestedRepresentedPartyID: requestedRepresentedPartyID,
            purpose: purpose,
            requestDigestSHA256: digest
        )
        guard let confirmationReceipt else {
            return .confirmationRequired(request)
        }
        guard !confirmationReceipt.id.isEmpty,
              !confirmationReceipt.actor.isEmpty,
              confirmationReceipt.matterID == request.matterID,
              confirmationReceipt.identityRevision == request.identityRevision,
              confirmationReceipt.canonicalRepresentedPartyID
                == request.canonicalRepresentedPartyID,
              confirmationReceipt.requestedRepresentedPartyID
                == request.requestedRepresentedPartyID,
              confirmationReceipt.purpose == request.purpose,
              confirmationReceipt.requestDigestSHA256 == request.requestDigestSHA256
        else {
            return .blocked(.confirmationReceiptMismatch)
        }
        return .confirmedOverride(DraftPartySelection(
            matterID: snapshot.matterID,
            identityRevision: snapshot.identityRevision,
            representedPartyID: requestedRepresentedPartyID,
            confirmationReceiptID: confirmationReceipt.id,
            confirmationRequestDigestSHA256: digest
        ))
    }

    private struct ValidatedIdentity {
        let represented: MatterPartyIdentity
        let opposing: MatterPartyIdentity
        let representation: MatterRepresentationIdentity
    }

    private func validatedIdentity(_ snapshot: MatterIdentitySnapshot) throws -> ValidatedIdentity {
        guard snapshot.identityRevision >= 1,
              snapshot.parties.allSatisfy({ $0.matterID == snapshot.matterID }),
              snapshot.representations.allSatisfy({ $0.matterID == snapshot.matterID })
        else {
            throw DraftPartyDefaultsError.incoherentMatterOwnership
        }
        guard Set(snapshot.parties.map(\.id)).count == snapshot.parties.count,
              Set(snapshot.parties.map(\.captionOrder)).count == snapshot.parties.count,
              Set(snapshot.representations.map(\.id)).count == snapshot.representations.count
        else {
            throw DraftPartyDefaultsError.duplicateIdentity
        }
        let represented = snapshot.parties.filter { $0.clientStatus == .represented }
        guard represented.count == 1 else {
            throw DraftPartyDefaultsError.representedPartyChoiceRequired
        }
        let opponents = snapshot.parties.filter { $0.clientStatus == .notRepresented }
        guard opponents.count == 1 else {
            throw DraftPartyDefaultsError.opposingPartyChoiceRequired
        }
        let representedParty = represented[0]
        let opposingParty = opponents[0]
        guard Self.areOppositeRoles(representedParty.baseRole, opposingParty.baseRole) else {
            throw DraftPartyDefaultsError.unsupportedPartyRole
        }
        let serviceRepresentations = snapshot.representations.filter {
            $0.representedPartyID == opposingParty.id && $0.relationshipKind == .counsel
        }
        guard serviceRepresentations.count == 1 else {
            throw DraftPartyDefaultsError.serviceRecipientChoiceRequired
        }
        guard snapshot.representations.allSatisfy({ representation in
            snapshot.parties.contains(where: { $0.id == representation.representedPartyID })
        }) else {
            throw DraftPartyDefaultsError.incoherentMatterOwnership
        }
        return ValidatedIdentity(
            represented: representedParty,
            opposing: opposingParty,
            representation: serviceRepresentations[0]
        )
    }

    private static func areOppositeRoles(
        _ lhs: MatterPartyBaseRole,
        _ rhs: MatterPartyBaseRole
    ) -> Bool {
        switch (lhs, rhs) {
        case (.plaintiff, .defendant), (.defendant, .plaintiff),
             (.petitioner, .respondent), (.respondent, .petitioner),
             (.appellant, .appellee), (.appellee, .appellant):
            true
        default:
            false
        }
    }

    private static func designation(for role: MatterPartyBaseRole) throws -> String {
        switch role {
        case .plaintiff: "Plaintiff"
        case .defendant: "Defendant"
        case .petitioner: "Petitioner"
        case .respondent: "Respondent"
        case .appellant: "Appellant"
        case .appellee: "Appellee"
        case .movant: "Movant"
        case .thirdParty: "Third Party"
        case .nonparty: "Nonparty"
        case .other: throw DraftPartyDefaultsError.unsupportedPartyRole
        }
    }

    private static func officeBlock(
        from representation: MatterRepresentationIdentity
    ) throws -> OfficeBlock {
        guard let address = representation.serviceAddress,
              !address.street.isEmpty,
              !address.city.isEmpty,
              !address.state.isEmpty,
              !address.postalCode.isEmpty
        else {
            throw DraftPartyDefaultsError.incompleteServiceRecipient
        }
        return OfficeBlock(
            street: address.street,
            suite: nil,
            city: address.city,
            state: address.state,
            zip: address.postalCode,
            phone: "",
            fax: nil
        )
    }

    private static func confirmationRequestDigest(
        matterID: String,
        identityRevision: Int,
        canonicalRepresentedPartyID: String,
        requestedRepresentedPartyID: String,
        purpose: String
    ) -> String {
        let values = [
            "supra-party-conflict-confirmation-v1", matterID,
            String(identityRevision), canonicalRepresentedPartyID,
            requestedRepresentedPartyID, purpose,
        ]
        var data = Data()
        for value in values {
            let bytes = Data(value.utf8)
            data.append(Data("\(bytes.count):".utf8))
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
