import Foundation
import GRDB
import SupraCore

extension MatterIdentityRepository {
    public func createMatter(
        command: MatterIdentityCreateCommand
    ) throws -> MatterIdentitySnapshot {
        try MatterIdentityWrite.validate(command)
        let expected = MatterIdentityWrite.snapshot(
            command: command,
            identityRevision: 1
        )

        return try writeIdentity { db in
            if try MatterIdentityWrite.matterExists(db, matterID: command.matterID) {
                guard try MatterIdentityWrite.matchesPersistedWrite(
                    db,
                    matterID: command.matterID,
                    expectedName: command.name,
                    sourceKind: "create",
                    identityRevision: 1,
                    legacyPartyPerspective: command.legacyPartyPerspective,
                    legacyClientNames: command.legacyClientNames,
                    expectedSnapshot: expected
                ) else {
                    throw MatterIdentityRepositoryError.conflictingWrite
                }
                return expected
            }

            let timestamp = Date()
            try MatterRecord(
                id: command.matterID,
                name: command.name,
                jurisdiction: command.legacyJurisdictionText,
                partyPerspective: command.legacyPartyPerspective.rawValue,
                court: command.legacyCourtText,
                clientNames: command.legacyClientNames,
                createdAt: timestamp,
                updatedAt: timestamp
            ).insert(db)
            try MatterIdentityWrite.insertSourceReceipt(
                db,
                matterID: command.matterID,
                sourceKind: "create",
                identityRevision: 1,
                courtResolutionState: command.courtResolutionState,
                legacyJurisdictionText: command.legacyJurisdictionText,
                legacyCourtText: command.legacyCourtText,
                legacyPartyPerspective: command.legacyPartyPerspective,
                legacyClientNames: command.legacyClientNames,
                canonicalJurisdictionID: command.canonicalJurisdictionID,
                canonicalCourtID: command.canonicalCourtID,
                canonicalCatalogVersion: command.canonicalCatalogVersion,
                canonicalCatalogDigestSHA256: command.canonicalCatalogDigestSHA256,
                createdAt: timestamp
            )
            try db.execute(
                sql: """
                    UPDATE matters
                    SET canonical_jurisdiction_id = ?, canonical_court_id = ?,
                        court_resolution_state = ?, canonical_catalog_version = ?,
                        canonical_catalog_digest_sha256 = ?, updated_at = ?
                    WHERE id = ? AND identity_revision = 1 AND deleted_at IS NULL
                    """,
                arguments: [
                    command.canonicalJurisdictionID?.rawValue,
                    command.canonicalCourtID?.rawValue,
                    command.courtResolutionState.rawValue,
                    command.canonicalCatalogVersion,
                    command.canonicalCatalogDigestSHA256,
                    timestamp,
                    command.matterID,
                ]
            )
            guard db.changesCount == 1 else {
                throw MatterIdentityRepositoryError.conflictingWrite
            }
            try MatterIdentityWrite.insertGraph(
                db,
                parties: expected.parties,
                representations: expected.representations,
                timestamp: timestamp
            )
            guard let snapshot = try MatterIdentityWrite.fetchSnapshot(
                db,
                matterID: command.matterID
            ), snapshot == expected else {
                throw MatterIdentityRepositoryError.identityIncoherent
            }
            return snapshot
        }
    }

    public func updateMatter(
        command: MatterIdentityUpdateCommand
    ) throws -> MatterIdentitySnapshot {
        try MatterIdentityWrite.validate(command)
        let resultRevision = command.expectedIdentityRevision + 1
        let expected = MatterIdentityWrite.snapshot(
            command: command,
            identityRevision: resultRevision
        )

        return try writeIdentity { db in
            guard let currentRevision = try Int.fetchOne(
                db,
                sql: """
                    SELECT identity_revision
                    FROM matters
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                arguments: [command.matterID]
            ) else {
                throw MatterIdentityRepositoryError.matterUnavailable
            }

            if currentRevision == resultRevision {
                guard try MatterIdentityWrite.matchesPersistedWrite(
                    db,
                    matterID: command.matterID,
                    expectedName: nil,
                    sourceKind: "update",
                    identityRevision: resultRevision,
                    legacyPartyPerspective: command.legacyPartyPerspective,
                    legacyClientNames: command.legacyClientNames,
                    expectedSnapshot: expected
                ) else {
                    throw MatterIdentityRepositoryError.conflictingWrite
                }
                return expected
            }
            guard currentRevision == command.expectedIdentityRevision else {
                throw MatterIdentityRepositoryError.staleIdentityRevision
            }

            let timestamp = Date()
            try MatterIdentityWrite.insertSourceReceipt(
                db,
                matterID: command.matterID,
                sourceKind: "update",
                identityRevision: resultRevision,
                courtResolutionState: command.courtResolutionState,
                legacyJurisdictionText: command.legacyJurisdictionText,
                legacyCourtText: command.legacyCourtText,
                legacyPartyPerspective: command.legacyPartyPerspective,
                legacyClientNames: command.legacyClientNames,
                canonicalJurisdictionID: command.canonicalJurisdictionID,
                canonicalCourtID: command.canonicalCourtID,
                canonicalCatalogVersion: command.canonicalCatalogVersion,
                canonicalCatalogDigestSHA256: command.canonicalCatalogDigestSHA256,
                createdAt: timestamp
            )
            try db.execute(
                sql: """
                    UPDATE matters
                    SET jurisdiction = ?, court = ?, party_perspective = ?,
                        client_names = ?, canonical_jurisdiction_id = ?,
                        canonical_court_id = ?, court_resolution_state = ?,
                        canonical_catalog_version = ?,
                        canonical_catalog_digest_sha256 = ?,
                        identity_revision = ?, updated_at = ?
                    WHERE id = ? AND identity_revision = ? AND deleted_at IS NULL
                    """,
                arguments: [
                    command.legacyJurisdictionText,
                    command.legacyCourtText,
                    command.legacyPartyPerspective.rawValue,
                    command.legacyClientNames,
                    command.canonicalJurisdictionID?.rawValue,
                    command.canonicalCourtID?.rawValue,
                    command.courtResolutionState.rawValue,
                    command.canonicalCatalogVersion,
                    command.canonicalCatalogDigestSHA256,
                    resultRevision,
                    timestamp,
                    command.matterID,
                    command.expectedIdentityRevision,
                ]
            )
            guard db.changesCount == 1 else {
                throw MatterIdentityRepositoryError.staleIdentityRevision
            }
            try db.execute(
                sql: "DELETE FROM matter_representations WHERE matter_id = ?",
                arguments: [command.matterID]
            )
            try db.execute(
                sql: "DELETE FROM matter_parties WHERE matter_id = ?",
                arguments: [command.matterID]
            )
            try MatterIdentityWrite.insertGraph(
                db,
                parties: expected.parties,
                representations: expected.representations,
                timestamp: timestamp
            )
            guard let snapshot = try MatterIdentityWrite.fetchSnapshot(
                db,
                matterID: command.matterID
            ), snapshot == expected else {
                throw MatterIdentityRepositoryError.identityIncoherent
            }
            return snapshot
        }
    }
}

private enum MatterIdentityWrite {
    static let canonicalCatalogVersion = "jurisdiction-courts-v1"
    static let canonicalCatalogDigestSHA256 =
        "0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3"

    static func validate(_ command: MatterIdentityCreateCommand) throws {
        try requireExactNonempty(command.name, field: "name")
        try validateIdentity(
            matterID: command.matterID,
            legacyJurisdictionText: command.legacyJurisdictionText,
            legacyCourtText: command.legacyCourtText,
            legacyClientNames: command.legacyClientNames,
            courtResolutionState: command.courtResolutionState,
            canonicalCatalogVersion: command.canonicalCatalogVersion,
            canonicalCatalogDigestSHA256: command.canonicalCatalogDigestSHA256,
            canonicalJurisdictionID: command.canonicalJurisdictionID,
            canonicalCourtID: command.canonicalCourtID,
            parties: command.parties,
            representations: command.representations
        )
    }

    static func validate(_ command: MatterIdentityUpdateCommand) throws {
        guard command.expectedIdentityRevision >= 1,
              command.expectedIdentityRevision < Int.max else {
            throw MatterIdentityRepositoryError.staleIdentityRevision
        }
        try validateIdentity(
            matterID: command.matterID,
            legacyJurisdictionText: command.legacyJurisdictionText,
            legacyCourtText: command.legacyCourtText,
            legacyClientNames: command.legacyClientNames,
            courtResolutionState: command.courtResolutionState,
            canonicalCatalogVersion: command.canonicalCatalogVersion,
            canonicalCatalogDigestSHA256: command.canonicalCatalogDigestSHA256,
            canonicalJurisdictionID: command.canonicalJurisdictionID,
            canonicalCourtID: command.canonicalCourtID,
            parties: command.parties,
            representations: command.representations
        )
    }

    private static func validateIdentity(
        matterID: String,
        legacyJurisdictionText: String,
        legacyCourtText: String?,
        legacyClientNames: String?,
        courtResolutionState: MatterCourtResolutionState,
        canonicalCatalogVersion: String,
        canonicalCatalogDigestSHA256: String,
        canonicalJurisdictionID: CanonicalJurisdictionID?,
        canonicalCourtID: CanonicalCourtID?,
        parties: [MatterPartyIdentity],
        representations: [MatterRepresentationIdentity]
    ) throws {
        try requireExactNonempty(matterID, field: "matterID")
        try requireExactNonempty(
            legacyJurisdictionText,
            field: "legacyJurisdictionText"
        )
        try validateOptionalExactString(legacyCourtText, field: "legacyCourtText")
        try validateOptionalExactString(legacyClientNames, field: "legacyClientNames")
        guard canonicalCatalogVersion == self.canonicalCatalogVersion else {
            throw MatterIdentityRepositoryError.invalidField(
                "canonicalCatalogVersion"
            )
        }
        guard canonicalCatalogDigestSHA256 == self.canonicalCatalogDigestSHA256 else {
            throw MatterIdentityRepositoryError.invalidField(
                "canonicalCatalogDigestSHA256"
            )
        }
        if let canonicalJurisdictionID {
            try requireExactNonempty(
                canonicalJurisdictionID.rawValue,
                field: "canonicalJurisdictionID"
            )
        }
        if let canonicalCourtID {
            try requireExactNonempty(
                canonicalCourtID.rawValue,
                field: "canonicalCourtID"
            )
        }
        switch courtResolutionState {
        case .unresolved, .notApplicable:
            guard canonicalJurisdictionID == nil, canonicalCourtID == nil else {
                throw MatterIdentityRepositoryError.identityIncoherent
            }
        case .jurisdictionOnly:
            guard canonicalJurisdictionID != nil, canonicalCourtID == nil else {
                throw MatterIdentityRepositoryError.identityIncoherent
            }
        case .court:
            guard canonicalJurisdictionID != nil, canonicalCourtID != nil else {
                throw MatterIdentityRepositoryError.identityIncoherent
            }
        }

        var partyIDs = Set<String>()
        var captionOrders = Set<Int>()
        for party in parties {
            try requireExactNonempty(party.id, field: "party.id")
            guard party.matterID == matterID else {
                throw MatterIdentityRepositoryError.identityIncoherent
            }
            try requireExactNonempty(party.displayName, field: "party.displayName")
            try requireExactNonempty(party.captionName, field: "party.captionName")
            guard party.captionOrder >= 0,
                  partyIDs.insert(party.id).inserted,
                  captionOrders.insert(party.captionOrder).inserted else {
                throw MatterIdentityRepositoryError.identityIncoherent
            }
        }

        var representationIDs = Set<String>()
        for representation in representations {
            try requireExactNonempty(representation.id, field: "representation.id")
            guard representation.matterID == matterID,
                  partyIDs.contains(representation.representedPartyID),
                  representationIDs.insert(representation.id).inserted else {
                throw MatterIdentityRepositoryError.identityIncoherent
            }
            try requireExactNonempty(
                representation.representativeName,
                field: "representation.representativeName"
            )
            try validateOptionalExactString(
                representation.firmName,
                field: "representation.firmName"
            )
            if let address = representation.serviceAddress {
                try requireExactNonempty(address.street, field: "serviceAddress.street")
                try requireExactNonempty(address.city, field: "serviceAddress.city")
                try requireExactNonempty(address.state, field: "serviceAddress.state")
                try requireExactNonempty(
                    address.postalCode,
                    field: "serviceAddress.postalCode"
                )
            }
            for email in representation.serviceEmails {
                try requireExactNonempty(email, field: "representation.serviceEmail")
            }
            if let serviceOrder = representation.serviceOrder, serviceOrder < 0 {
                throw MatterIdentityRepositoryError.identityIncoherent
            }
        }
    }

    private static func requireExactNonempty(
        _ value: String,
        field: String
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value else {
            throw MatterIdentityRepositoryError.invalidField(field)
        }
    }

    private static func validateOptionalExactString(
        _ value: String?,
        field: String
    ) throws {
        guard let value else { return }
        try requireExactNonempty(value, field: field)
    }

    static func snapshot(
        command: MatterIdentityCreateCommand,
        identityRevision: Int
    ) -> MatterIdentitySnapshot {
        snapshot(
            matterID: command.matterID,
            identityRevision: identityRevision,
            courtResolutionState: command.courtResolutionState,
            canonicalCatalogVersion: command.canonicalCatalogVersion,
            canonicalCatalogDigestSHA256: command.canonicalCatalogDigestSHA256,
            canonicalJurisdictionID: command.canonicalJurisdictionID,
            canonicalCourtID: command.canonicalCourtID,
            legacyJurisdictionText: command.legacyJurisdictionText,
            legacyCourtText: command.legacyCourtText,
            parties: command.parties,
            representations: command.representations
        )
    }

    static func snapshot(
        command: MatterIdentityUpdateCommand,
        identityRevision: Int
    ) -> MatterIdentitySnapshot {
        snapshot(
            matterID: command.matterID,
            identityRevision: identityRevision,
            courtResolutionState: command.courtResolutionState,
            canonicalCatalogVersion: command.canonicalCatalogVersion,
            canonicalCatalogDigestSHA256: command.canonicalCatalogDigestSHA256,
            canonicalJurisdictionID: command.canonicalJurisdictionID,
            canonicalCourtID: command.canonicalCourtID,
            legacyJurisdictionText: command.legacyJurisdictionText,
            legacyCourtText: command.legacyCourtText,
            parties: command.parties,
            representations: command.representations
        )
    }

    private static func snapshot(
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
    ) -> MatterIdentitySnapshot {
        MatterIdentitySnapshot(
            matterID: matterID,
            identityRevision: identityRevision,
            courtResolutionState: courtResolutionState,
            canonicalCatalogVersion: canonicalCatalogVersion,
            canonicalCatalogDigestSHA256: canonicalCatalogDigestSHA256,
            canonicalJurisdictionID: canonicalJurisdictionID,
            canonicalCourtID: canonicalCourtID,
            legacyJurisdictionText: legacyJurisdictionText,
            legacyCourtText: legacyCourtText,
            parties: parties.sorted {
                ($0.captionOrder, $0.id) < ($1.captionOrder, $1.id)
            },
            representations: representations.sorted(by: representationOrder)
        )
    }

    private static func representationOrder(
        _ lhs: MatterRepresentationIdentity,
        _ rhs: MatterRepresentationIdentity
    ) -> Bool {
        switch (lhs.serviceOrder, rhs.serviceOrder) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id < rhs.id
        }
    }

    static func matterExists(_ db: Database, matterID: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM matters WHERE id = ?)",
            arguments: [matterID]
        ) ?? false
    }

    static func matchesPersistedWrite(
        _ db: Database,
        matterID: String,
        expectedName: String?,
        sourceKind: String,
        identityRevision: Int,
        legacyPartyPerspective: PartyPerspective,
        legacyClientNames: String?,
        expectedSnapshot: MatterIdentitySnapshot
    ) throws -> Bool {
        guard let matter = try Row.fetchOne(
            db,
            sql: """
                SELECT name, party_perspective, client_names
                FROM matters
                WHERE id = ? AND deleted_at IS NULL
                """,
            arguments: [matterID]
        ), let source = try Row.fetchOne(
            db,
            sql: """
                SELECT *
                FROM matter_identity_conversion_receipts
                WHERE id = ? AND matter_id = ? AND identity_revision = ?
                """,
            arguments: [
                sourceReceiptID(matterID: matterID, revision: identityRevision),
                matterID,
                identityRevision,
            ]
        ), let persisted = try fetchSnapshot(db, matterID: matterID) else {
            return false
        }

        let persistedName: String = matter["name"]
        let persistedPartyPerspective: String = matter["party_perspective"]
        let persistedClientNames: String? = matter["client_names"]
        let sourceMigration: String? = source["source_migration"]
        let sourceLegacyCourt: String? = source["legacy_court"]
        let sourceLegacyClientNames: String? = source["legacy_client_names"]
        let sourceCanonicalJurisdictionID: String? = source["canonical_jurisdiction_id"]
        let sourceCanonicalCourtID: String? = source["canonical_court_id"]

        return (expectedName == nil || persistedName == expectedName)
            && persistedPartyPerspective == legacyPartyPerspective.rawValue
            && persistedClientNames == legacyClientNames
            && source["source_kind"] as String == sourceKind
            && sourceMigration == nil
            && source["court_resolution_state"] as String
                == expectedSnapshot.courtResolutionState.rawValue
            && source["resolution_reason"] as String
                == resolutionReason(for: expectedSnapshot.courtResolutionState)
            && source["legacy_jurisdiction"] as String
                == expectedSnapshot.legacyJurisdictionText
            && sourceLegacyCourt == expectedSnapshot.legacyCourtText
            && source["legacy_party_perspective"] as String
                == legacyPartyPerspective.rawValue
            && sourceLegacyClientNames == legacyClientNames
            && sourceCanonicalJurisdictionID
                == expectedSnapshot.canonicalJurisdictionID?.rawValue
            && sourceCanonicalCourtID == expectedSnapshot.canonicalCourtID?.rawValue
            && source["canonical_catalog_version"] as String
                == expectedSnapshot.canonicalCatalogVersion
            && source["canonical_catalog_digest_sha256"] as String
                == expectedSnapshot.canonicalCatalogDigestSHA256
            && persisted == expectedSnapshot
    }

    static func insertSourceReceipt(
        _ db: Database,
        matterID: String,
        sourceKind: String,
        identityRevision: Int,
        courtResolutionState: MatterCourtResolutionState,
        legacyJurisdictionText: String,
        legacyCourtText: String?,
        legacyPartyPerspective: PartyPerspective,
        legacyClientNames: String?,
        canonicalJurisdictionID: CanonicalJurisdictionID?,
        canonicalCourtID: CanonicalCourtID?,
        canonicalCatalogVersion: String,
        canonicalCatalogDigestSHA256: String,
        createdAt: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO matter_identity_conversion_receipts (
                    id, matter_id, source_kind, source_migration,
                    identity_revision, court_resolution_state,
                    resolution_reason, legacy_jurisdiction, legacy_court,
                    legacy_party_perspective, legacy_client_names,
                    canonical_jurisdiction_id, canonical_court_id,
                    canonical_catalog_version,
                    canonical_catalog_digest_sha256, created_at
                ) VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                sourceReceiptID(matterID: matterID, revision: identityRevision),
                matterID,
                sourceKind,
                identityRevision,
                courtResolutionState.rawValue,
                resolutionReason(for: courtResolutionState),
                legacyJurisdictionText,
                legacyCourtText,
                legacyPartyPerspective.rawValue,
                legacyClientNames,
                canonicalJurisdictionID?.rawValue,
                canonicalCourtID?.rawValue,
                canonicalCatalogVersion,
                canonicalCatalogDigestSHA256,
                createdAt,
            ]
        )
    }

    static func insertGraph(
        _ db: Database,
        parties: [MatterPartyIdentity],
        representations: [MatterRepresentationIdentity],
        timestamp: Date
    ) throws {
        for party in parties {
            try db.execute(
                sql: """
                    INSERT INTO matter_parties (
                        id, matter_id, display_name, caption_name, base_role,
                        caption_order, client_status, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    party.id,
                    party.matterID,
                    party.displayName,
                    party.captionName,
                    party.baseRole.rawValue,
                    party.captionOrder,
                    party.clientStatus.rawValue,
                    timestamp,
                    timestamp,
                ]
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for representation in representations {
            let addressJSON: String?
            if let address = representation.serviceAddress {
                addressJSON = String(
                    decoding: try encoder.encode(address),
                    as: UTF8.self
                )
            } else {
                addressJSON = nil
            }
            let emailsJSON = String(
                decoding: try encoder.encode(representation.serviceEmails),
                as: UTF8.self
            )
            try db.execute(
                sql: """
                    INSERT INTO matter_representations (
                        id, matter_id, represented_party_id, relationship_kind,
                        representative_name, firm_name, service_address_json,
                        service_emails_json, service_order, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    representation.id,
                    representation.matterID,
                    representation.representedPartyID,
                    representation.relationshipKind.rawValue,
                    representation.representativeName,
                    representation.firmName,
                    addressJSON,
                    emailsJSON,
                    representation.serviceOrder,
                    timestamp,
                    timestamp,
                ]
            )
        }
    }

    private static func sourceReceiptID(matterID: String, revision: Int) -> String {
        "identity-source:\(matterID):r\(revision)"
    }

    private static func resolutionReason(
        for state: MatterCourtResolutionState
    ) -> String {
        switch state {
        case .unresolved: "unknown"
        case .jurisdictionOnly: "jurisdiction_only"
        case .court: "unchanged_canonical"
        case .notApplicable: "not_applicable"
        }
    }

    static func fetchSnapshot(
        _ db: Database,
        matterID: String
    ) throws -> MatterIdentitySnapshot? {
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
                      ) else {
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
