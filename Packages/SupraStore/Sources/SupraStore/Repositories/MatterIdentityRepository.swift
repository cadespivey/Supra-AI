import CryptoKit
import Foundation
import GRDB
import SupraCore

public enum MatterIdentityRepositoryError: Error, Equatable, Sendable {
    case matterUnavailable
    case identityIncoherent
    case partyUnavailable
    case staleIdentityRevision
    case invalidRequestDigest
    case invalidField(String)
    case conflictingDecision
}

/// Authoritative Store owner for one-snapshot matter identity reads and durable
/// attorney-confirmation receipts. No Research search or alias logic crosses
/// this boundary.
public final class MatterIdentityRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func fetchSnapshot(matterID: String) throws -> MatterIdentitySnapshot? {
        try writer.read { db in
            guard let matter = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, identity_revision, court_resolution_state,
                           canonical_catalog_version,
                           canonical_catalog_digest_sha256,
                           canonical_jurisdiction_id, canonical_court_id,
                           jurisdiction, court
                    FROM matters
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                arguments: [matterID]
            ) else {
                return nil
            }

            let parties = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, matter_id, display_name, caption_name, base_role,
                           caption_order, client_status
                    FROM matter_parties
                    WHERE matter_id = ?
                    ORDER BY caption_order, id
                    """,
                arguments: [matterID]
            ).map { row in
                guard let role = MatterPartyBaseRole(rawValue: row["base_role"]),
                      let status = MatterPartyClientStatus(rawValue: row["client_status"])
                else {
                    throw MatterIdentityRepositoryError.identityIncoherent
                }
                return MatterPartyIdentity(
                    id: row["id"],
                    matterID: row["matter_id"],
                    displayName: row["display_name"],
                    captionName: row["caption_name"],
                    baseRole: role,
                    captionOrder: row["caption_order"],
                    clientStatus: status
                )
            }

            let representations = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, matter_id, represented_party_id,
                           relationship_kind, representative_name, firm_name,
                           service_address_json, service_emails_json,
                           service_order
                    FROM matter_representations
                    WHERE matter_id = ?
                    ORDER BY service_order IS NULL, service_order, id
                    """,
                arguments: [matterID]
            ).map { row in
                guard let relationship = MatterRepresentationRelationshipKind(
                    rawValue: row["relationship_kind"]
                ) else {
                    throw MatterIdentityRepositoryError.identityIncoherent
                }
                let address: MatterServiceAddress?
                if let json: String = row["service_address_json"] {
                    guard let data = json.data(using: .utf8),
                          let decoded = try? JSONDecoder().decode(
                              MatterServiceAddress.self,
                              from: data
                          )
                    else {
                        throw MatterIdentityRepositoryError.identityIncoherent
                    }
                    address = decoded
                } else {
                    address = nil
                }
                let emailsJSON: String = row["service_emails_json"]
                guard let emailsData = emailsJSON.data(using: .utf8),
                      let emails = try? JSONDecoder().decode([String].self, from: emailsData)
                else {
                    throw MatterIdentityRepositoryError.identityIncoherent
                }
                return MatterRepresentationIdentity(
                    id: row["id"],
                    matterID: row["matter_id"],
                    representedPartyID: row["represented_party_id"],
                    relationshipKind: relationship,
                    representativeName: row["representative_name"],
                    firmName: row["firm_name"],
                    serviceAddress: address,
                    serviceEmails: emails,
                    serviceOrder: row["service_order"]
                )
            }

            guard let state = MatterCourtResolutionState(
                rawValue: matter["court_resolution_state"]
            ) else {
                throw MatterIdentityRepositoryError.identityIncoherent
            }
            let jurisdictionID: String? = matter["canonical_jurisdiction_id"]
            let courtID: String? = matter["canonical_court_id"]
            return MatterIdentitySnapshot(
                matterID: matter["id"],
                identityRevision: matter["identity_revision"],
                courtResolutionState: state,
                canonicalCatalogVersion: matter["canonical_catalog_version"],
                canonicalCatalogDigestSHA256: matter["canonical_catalog_digest_sha256"],
                canonicalJurisdictionID: jurisdictionID.map {
                    CanonicalJurisdictionID(rawValue: $0)
                },
                canonicalCourtID: courtID.map { CanonicalCourtID(rawValue: $0) },
                legacyJurisdictionText: matter["jurisdiction"],
                legacyCourtText: matter["court"],
                parties: parties,
                representations: representations
            )
        }
    }

    public func fetchPartyConflictConfirmations(
        matterID: String
    ) throws -> [PartyConflictConfirmationReceipt] {
        try writer.read { db in
            try Self.fetchPartyConflictConfirmations(db, matterID: matterID)
        }
    }

    public func issuePartyConflictConfirmation(
        request: PartyConflictConfirmationRequest,
        receiptID: String,
        actor: String,
        confirmedAt: Date
    ) throws -> PartyConflictConfirmationReceipt {
        for (name, value) in [
            ("receiptID", receiptID),
            ("matterID", request.matterID),
            ("canonicalRepresentedPartyID", request.canonicalRepresentedPartyID),
            ("requestedRepresentedPartyID", request.requestedRepresentedPartyID),
            ("purpose", request.purpose),
            ("actor", actor),
        ] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == value else {
                throw MatterIdentityRepositoryError.invalidField(name)
            }
        }
        let expectedDigest = Self.partyConflictRequestDigest(
            matterID: request.matterID,
            identityRevision: request.identityRevision,
            canonicalRepresentedPartyID: request.canonicalRepresentedPartyID,
            requestedRepresentedPartyID: request.requestedRepresentedPartyID,
            purpose: request.purpose
        )
        return try writer.write { db in
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM matter_identity_decision_receipts WHERE id = ?",
                arguments: [receiptID]
            ) {
                guard existing["kind"] as String == "party_override",
                      existing["matter_id"] as String == request.matterID,
                      existing["prior_identity_revision"] as Int
                        == request.identityRevision,
                      existing["canonical_represented_party_id"] as String?
                        == request.canonicalRepresentedPartyID,
                      existing["requested_represented_party_id"] as String?
                        == request.requestedRepresentedPartyID,
                      existing["purpose"] as String == request.purpose,
                      existing["request_digest_sha256"] as String
                        == request.requestDigestSHA256,
                      request.requestDigestSHA256 == expectedDigest,
                      existing["actor"] as String == actor,
                      existing["decided_at"] as Date == confirmedAt
                else {
                    throw MatterIdentityRepositoryError.conflictingDecision
                }
                return try Self.partyReceipt(from: existing)
            }

            guard request.identityRevision >= 1,
                  request.canonicalRepresentedPartyID
                    != request.requestedRepresentedPartyID
            else {
                throw MatterIdentityRepositoryError.identityIncoherent
            }
            guard request.requestDigestSHA256 == expectedDigest else {
                throw MatterIdentityRepositoryError.invalidRequestDigest
            }

            guard let matterRevision = try Int.fetchOne(
                db,
                sql: "SELECT identity_revision FROM matters WHERE id = ? AND deleted_at IS NULL",
                arguments: [request.matterID]
            ) else {
                throw MatterIdentityRepositoryError.matterUnavailable
            }
            guard matterRevision == request.identityRevision else {
                throw MatterIdentityRepositoryError.staleIdentityRevision
            }
            let statuses = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, client_status
                    FROM matter_parties
                    WHERE matter_id = ? AND id IN (?, ?)
                    ORDER BY id
                    """,
                arguments: [
                    request.matterID, request.canonicalRepresentedPartyID,
                    request.requestedRepresentedPartyID,
                ]
            )
            guard statuses.count == 2,
                  statuses.contains(where: {
                      $0["id"] as String == request.canonicalRepresentedPartyID
                          && $0["client_status"] as String == "represented"
                  }),
                  statuses.contains(where: {
                      $0["id"] as String == request.requestedRepresentedPartyID
                  })
            else {
                throw MatterIdentityRepositoryError.partyUnavailable
            }

            let createdAt = Date()
            try db.execute(
                sql: """
                    INSERT INTO matter_identity_decision_receipts (
                        id, matter_id, kind, source_conversion_receipt_id,
                        prior_identity_revision, result_identity_revision,
                        legacy_court, canonical_jurisdiction_id,
                        canonical_court_id, canonical_represented_party_id,
                        requested_represented_party_id, resolution_source,
                        actor, purpose, canonical_catalog_version,
                        canonical_catalog_digest_sha256, request_digest_sha256,
                        decided_at, created_at
                    ) VALUES (
                        ?, ?, 'party_override', NULL, ?, ?, NULL, NULL, NULL,
                        ?, ?, 'attorney_confirmation', ?, ?, NULL, NULL, ?, ?, ?
                    )
                    """,
                arguments: [
                    receiptID, request.matterID, request.identityRevision,
                    request.identityRevision, request.canonicalRepresentedPartyID,
                    request.requestedRepresentedPartyID, actor, request.purpose,
                    expectedDigest, confirmedAt, createdAt,
                ]
            )
            return PartyConflictConfirmationReceipt(
                id: receiptID,
                matterID: request.matterID,
                identityRevision: request.identityRevision,
                canonicalRepresentedPartyID: request.canonicalRepresentedPartyID,
                requestedRepresentedPartyID: request.requestedRepresentedPartyID,
                purpose: request.purpose,
                requestDigestSHA256: expectedDigest,
                actor: actor,
                confirmedAt: confirmedAt
            )
        }
    }

    private static func fetchPartyConflictConfirmations(
        _ db: Database,
        matterID: String
    ) throws -> [PartyConflictConfirmationReceipt] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT *
                FROM matter_identity_decision_receipts
                WHERE matter_id = ? AND kind = 'party_override'
                ORDER BY decided_at, id
                """,
            arguments: [matterID]
        ).map(partyReceipt(from:))
    }

    private static func partyReceipt(from row: Row) throws -> PartyConflictConfirmationReceipt {
        guard let canonicalPartyID: String = row["canonical_represented_party_id"],
              let requestedPartyID: String = row["requested_represented_party_id"]
        else {
            throw MatterIdentityRepositoryError.identityIncoherent
        }
        return PartyConflictConfirmationReceipt(
            id: row["id"],
            matterID: row["matter_id"],
            identityRevision: row["prior_identity_revision"],
            canonicalRepresentedPartyID: canonicalPartyID,
            requestedRepresentedPartyID: requestedPartyID,
            purpose: row["purpose"],
            requestDigestSHA256: row["request_digest_sha256"],
            actor: row["actor"],
            confirmedAt: row["decided_at"]
        )
    }

    private static func partyConflictRequestDigest(
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
