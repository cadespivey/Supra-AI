import CryptoKit
import Foundation
import GRDB
import SupraCore

public final class MattersRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func createMatter(
        name: String,
        jurisdiction: String = "Unspecified",
        partyPerspective: PartyPerspective = .neutral,
        court: String? = nil,
        judge: String? = nil,
        docketNumber: String? = nil,
        practiceArea: String? = nil,
        clientNames: String? = nil,
        matterDescription: String? = nil,
        internalMatterID: String? = nil,
        clientID: String? = nil,
        clientMatterID: String? = nil,
        notes: String? = nil,
        defaultChatTitle: String? = nil
    ) throws -> MatterRecord {
        let normalized = try Self.validateMatterFields(
            name: name,
            jurisdiction: jurisdiction,
            partyPerspective: partyPerspective
        )
        let normalizedCourt = Self.trimOptional(court)
        let normalizedClientNames = Self.trimOptional(clientNames)
        let chatTitle = defaultChatTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try writer.write { db in
            let now = Date()
            let record = MatterRecord(
                name: normalized.name,
                jurisdiction: normalized.jurisdiction,
                partyPerspective: partyPerspective.rawValue,
                court: normalizedCourt,
                judge: Self.trimOptional(judge),
                docketNumber: Self.trimOptional(docketNumber),
                practiceArea: Self.trimOptional(practiceArea),
                clientNames: normalizedClientNames,
                matterDescription: Self.trimOptional(matterDescription),
                internalMatterID: Self.trimOptional(internalMatterID),
                clientID: Self.trimOptional(clientID),
                clientMatterID: Self.trimOptional(clientMatterID),
                notes: Self.trimOptional(notes),
                createdAt: now,
                updatedAt: now
            )
            try record.insert(db)
            if try db.tableExists("matter_identity_conversion_receipts") {
                try Self.insertIdentitySourceReceipt(
                    db,
                    id: "identity-source:\(record.id):r1",
                    matterID: record.id,
                    sourceKind: "create",
                    identityRevision: 1,
                    courtResolutionState: "unresolved",
                    resolutionReason: "unknown",
                    legacyJurisdiction: normalized.jurisdiction,
                    legacyCourt: normalizedCourt,
                    legacyPartyPerspective: partyPerspective.rawValue,
                    legacyClientNames: normalizedClientNames,
                    canonicalJurisdictionID: nil,
                    canonicalCourtID: nil,
                    createdAt: now
                )
            }
            // Create the default matter chat in the same transaction so a matter
            // never exists without it (spec §8.3); both roll back together.
            if let chatTitle, !chatTitle.isEmpty {
                try ChatRecord(title: chatTitle, scope: "matter", matterID: record.id).insert(db)
            }
            return record
        }
    }

    public func fetchMatters() throws -> [MatterRecord] {
        try writer.read { db in
            try MatterRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM matters
                WHERE deleted_at IS NULL
                ORDER BY updated_at DESC
                """
            )
        }
    }

    public func fetchMatter(id: String) throws -> MatterRecord? {
        try writer.read { db in
            try MatterRecord.fetchOne(
                db,
                sql: """
                SELECT * FROM matters
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [id]
            )
        }
    }

    public func fetchUnresolvedCourtResolutionQueue() throws -> [CourtIdentityResolutionQueueItem] {
        try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT matter.id AS matter_id,
                           conversion.legacy_court AS legacy_court,
                           conversion.id AS conversion_receipt_id,
                           matter.identity_revision AS identity_revision
                    FROM matters AS matter
                    JOIN matter_identity_conversion_receipts AS conversion
                      ON conversion.matter_id = matter.id
                     AND conversion.identity_revision = matter.identity_revision
                    WHERE matter.deleted_at IS NULL
                      AND matter.court_resolution_state = 'unresolved'
                      AND NOT EXISTS (
                          SELECT 1
                          FROM matter_identity_decision_receipts AS decision
                          WHERE decision.matter_id = matter.id
                            AND decision.kind = 'court_resolution'
                            AND decision.result_identity_revision = matter.identity_revision
                      )
                    ORDER BY matter.created_at, matter.id
                    """
            ).map { row in
                return CourtIdentityResolutionQueueItem(
                    matterID: row["matter_id"],
                    legacyCourtText: row["legacy_court"],
                    conversionReceiptID: row["conversion_receipt_id"],
                    identityRevision: row["identity_revision"]
                )
            }
        }
    }

    public func fetchCourtIdentityResolutionReceipts(
        matterID: String
    ) throws -> [CourtIdentityResolutionReceipt] {
        try writer.read { db in
            try CourtIdentityResolutionReceipt.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM matter_identity_decision_receipts
                    WHERE matter_id = ? AND kind = 'court_resolution'
                    ORDER BY result_identity_revision, id
                    """,
                arguments: [matterID]
            )
        }
    }

    public func resolveCourtIdentity(
        matterID: String,
        decisionID: String,
        sourceConversionReceiptID: String,
        expectedIdentityRevision: Int,
        canonicalJurisdictionID: String,
        canonicalCourtID: String,
        resolutionSource: String,
        actor: String,
        purpose: String,
        catalogVersion: String,
        catalogSemanticDigest: String,
        decidedAt: Date
    ) throws -> CourtIdentityResolutionReceipt {
        let fields: [(name: String, value: String)] = [
            ("matterID", matterID),
            ("decisionID", decisionID),
            ("sourceConversionReceiptID", sourceConversionReceiptID),
            ("canonicalJurisdictionID", canonicalJurisdictionID),
            ("canonicalCourtID", canonicalCourtID),
            ("resolutionSource", resolutionSource),
            ("actor", actor),
            ("purpose", purpose),
            ("catalogVersion", catalogVersion),
            ("catalogSemanticDigest", catalogSemanticDigest),
        ]
        for field in fields {
            let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == field.value else {
                throw CourtIdentityResolutionError.invalidField(field.name)
            }
        }
        guard expectedIdentityRevision >= 1 else {
            throw CourtIdentityResolutionError.staleIdentityRevision
        }
        guard catalogVersion == Self.canonicalCourtCatalogVersion else {
            throw CourtIdentityResolutionError.invalidField("catalogVersion")
        }
        guard Self.isLowercaseSHA256(catalogSemanticDigest),
              catalogSemanticDigest == Self.canonicalCourtCatalogDigestSHA256
        else {
            throw CourtIdentityResolutionError.invalidField("catalogSemanticDigest")
        }

        let requestDigest = Self.courtIdentityRequestDigest(
            matterID: matterID,
            decisionID: decisionID,
            sourceConversionReceiptID: sourceConversionReceiptID,
            expectedIdentityRevision: expectedIdentityRevision,
            canonicalJurisdictionID: canonicalJurisdictionID,
            canonicalCourtID: canonicalCourtID,
            resolutionSource: resolutionSource,
            actor: actor,
            purpose: purpose,
            catalogVersion: catalogVersion,
            catalogSemanticDigest: catalogSemanticDigest,
            decidedAt: decidedAt
        )

        return try writer.write { db in
            if let existingRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM matter_identity_decision_receipts WHERE id = ?",
                arguments: [decisionID]
            ) {
                guard existingRow["kind"] as String == "court_resolution",
                      existingRow["request_digest_sha256"] as String == requestDigest
                else {
                    throw CourtIdentityResolutionError.conflictingDecision
                }
                return try CourtIdentityResolutionReceipt(row: existingRow)
            }

            guard let matter = try Row.fetchOne(
                db,
                sql: """
                    SELECT court, identity_revision, court_resolution_state
                    FROM matters
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                arguments: [matterID]
            ) else {
                throw CourtIdentityResolutionError.matterUnavailable
            }
            let currentRevision: Int = matter["identity_revision"]
            guard currentRevision == expectedIdentityRevision,
                  matter["court_resolution_state"] as String == "unresolved"
            else {
                throw CourtIdentityResolutionError.staleIdentityRevision
            }
            guard let conversion = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, legacy_court
                    FROM matter_identity_conversion_receipts
                    WHERE id = ? AND matter_id = ? AND identity_revision = ?
                    """,
                arguments: [
                    sourceConversionReceiptID,
                    matterID,
                    expectedIdentityRevision,
                ]
            ) else {
                throw CourtIdentityResolutionError.sourceReceiptUnavailable
            }
            let legacyCourt: String? = conversion["legacy_court"]
            let resultRevision = expectedIdentityRevision + 1
            let createdAt = Date()
            try db.execute(
                sql: """
                    INSERT INTO matter_identity_decision_receipts (
                        id, matter_id, kind, source_conversion_receipt_id,
                        prior_identity_revision, result_identity_revision,
                        legacy_court, canonical_jurisdiction_id, canonical_court_id,
                        resolution_source, actor, purpose,
                        canonical_catalog_version,
                        canonical_catalog_digest_sha256, request_digest_sha256,
                        decided_at, created_at
                    ) VALUES (?, ?, 'court_resolution', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    decisionID, matterID, sourceConversionReceiptID,
                    expectedIdentityRevision, resultRevision,
                    legacyCourt, canonicalJurisdictionID, canonicalCourtID,
                    resolutionSource, actor, purpose, catalogVersion,
                    catalogSemanticDigest, requestDigest, decidedAt, createdAt,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE matters
                    SET canonical_jurisdiction_id = ?, canonical_court_id = ?,
                        court_resolution_state = 'court',
                        canonical_catalog_version = ?,
                        canonical_catalog_digest_sha256 = ?,
                        identity_revision = ?, updated_at = ?
                    WHERE id = ? AND identity_revision = ?
                      AND court_resolution_state = 'unresolved'
                    """,
                arguments: [
                    canonicalJurisdictionID, canonicalCourtID, catalogVersion,
                    catalogSemanticDigest, resultRevision, createdAt, matterID,
                    expectedIdentityRevision,
                ]
            )
            guard db.changesCount == 1 else {
                throw CourtIdentityResolutionError.staleIdentityRevision
            }
            return CourtIdentityResolutionReceipt(
                decisionID: decisionID,
                matterID: matterID,
                sourceConversionReceiptID: sourceConversionReceiptID,
                legacyCourtText: legacyCourt,
                priorIdentityRevision: expectedIdentityRevision,
                resultIdentityRevision: resultRevision,
                canonicalJurisdictionID: canonicalJurisdictionID,
                canonicalCourtID: canonicalCourtID,
                resolutionSource: resolutionSource,
                actor: actor,
                purpose: purpose,
                catalogVersion: catalogVersion,
                catalogSemanticDigest: catalogSemanticDigest,
                requestDigestSHA256: requestDigest,
                decidedAt: decidedAt
            )
        }
    }

    private static func courtIdentityRequestDigest(
        matterID: String,
        decisionID: String,
        sourceConversionReceiptID: String,
        expectedIdentityRevision: Int,
        canonicalJurisdictionID: String,
        canonicalCourtID: String,
        resolutionSource: String,
        actor: String,
        purpose: String,
        catalogVersion: String,
        catalogSemanticDigest: String,
        decidedAt: Date
    ) -> String {
        let values = [
            "supra-court-identity-decision-v1", matterID, decisionID,
            sourceConversionReceiptID, String(expectedIdentityRevision),
            canonicalJurisdictionID, canonicalCourtID, resolutionSource, actor,
            purpose, catalogVersion, catalogSemanticDigest,
            String(format: "%.6f", decidedAt.timeIntervalSince1970),
        ]
        var data = Data()
        for value in values {
            let bytes = Data(value.utf8)
            data.append(Data("\(bytes.count):".utf8))
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let canonicalCourtCatalogVersion = "jurisdiction-courts-v1"
    private static let canonicalCourtCatalogDigestSHA256 =
        "0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3"

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    public func renameMatter(id: String, name: String) throws {
        let trimmed = try Self.requireNonEmpty(name, fieldName: "name")
        try writer.write { db in
            try db.execute(
                sql: "UPDATE matters SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [trimmed, Date(), id]
            )
        }
    }

    public func updateMatter(
        id: String,
        name: String,
        jurisdiction: String,
        partyPerspective: PartyPerspective,
        court: String? = nil,
        judge: String? = nil,
        docketNumber: String? = nil,
        practiceArea: String? = nil,
        clientNames: String? = nil,
        matterDescription: String? = nil,
        internalMatterID: String? = nil,
        clientID: String? = nil,
        clientMatterID: String? = nil,
        notes: String? = nil
    ) throws {
        let normalized = try Self.validateMatterFields(
            name: name,
            jurisdiction: jurisdiction,
            partyPerspective: partyPerspective
        )
        let normalizedCourt = Self.trimOptional(court)
        let normalizedClientNames = Self.trimOptional(clientNames)
        let normalizedJudge = Self.trimOptional(judge)
        let normalizedDocketNumber = Self.trimOptional(docketNumber)
        let normalizedPracticeArea = Self.trimOptional(practiceArea)
        let normalizedMatterDescription = Self.trimOptional(matterDescription)
        let normalizedInternalMatterID = Self.trimOptional(internalMatterID)
        let normalizedClientID = Self.trimOptional(clientID)
        let normalizedClientMatterID = Self.trimOptional(clientMatterID)
        let normalizedNotes = Self.trimOptional(notes)
        try writer.write { db in
            let identitySchemaExists = try db.tableExists(
                "matter_identity_conversion_receipts"
            )
            let existingIdentity: Row?
            if identitySchemaExists {
                existingIdentity = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT jurisdiction, party_perspective, court, client_names,
                               canonical_jurisdiction_id, canonical_court_id,
                               court_resolution_state, canonical_catalog_version,
                               canonical_catalog_digest_sha256, identity_revision
                        FROM matters
                        WHERE id = ? AND deleted_at IS NULL
                        """,
                    arguments: [id]
                )
            } else {
                existingIdentity = nil
            }

            let identityInputChanged: Bool
            let courtInputChanged: Bool
            if let existingIdentity {
                identityInputChanged = existingIdentity["jurisdiction"] as String
                    != normalized.jurisdiction
                    || existingIdentity["party_perspective"] as String
                    != partyPerspective.rawValue
                    || existingIdentity["court"] as String? != normalizedCourt
                    || existingIdentity["client_names"] as String? != normalizedClientNames
                courtInputChanged = existingIdentity["jurisdiction"] as String
                    != normalized.jurisdiction
                    || existingIdentity["court"] as String? != normalizedCourt
            } else {
                identityInputChanged = false
                courtInputChanged = false
            }

            let now = Date()
            if let existingIdentity, identityInputChanged {
                let priorRevision: Int = existingIdentity["identity_revision"]
                let resultRevision = priorRevision + 1
                let priorState: String = existingIdentity["court_resolution_state"]
                let resultState = courtInputChanged ? "unresolved" : priorState
                let canonicalJurisdictionID: String? = courtInputChanged
                    ? nil
                    : existingIdentity["canonical_jurisdiction_id"]
                let canonicalCourtID: String? = courtInputChanged
                    ? nil
                    : existingIdentity["canonical_court_id"]
                let reason: String
                if courtInputChanged {
                    reason = "unknown"
                } else {
                    switch resultState {
                    case "court": reason = "unchanged_canonical"
                    case "jurisdiction_only": reason = "jurisdiction_only"
                    case "not_applicable": reason = "not_applicable"
                    default: reason = "unknown"
                    }
                }
                try Self.insertIdentitySourceReceipt(
                    db,
                    id: "identity-source:\(id):r\(resultRevision)",
                    matterID: id,
                    sourceKind: "update",
                    identityRevision: resultRevision,
                    courtResolutionState: resultState,
                    resolutionReason: reason,
                    legacyJurisdiction: normalized.jurisdiction,
                    legacyCourt: normalizedCourt,
                    legacyPartyPerspective: partyPerspective.rawValue,
                    legacyClientNames: normalizedClientNames,
                    canonicalJurisdictionID: canonicalJurisdictionID,
                    canonicalCourtID: canonicalCourtID,
                    createdAt: now
                )
                try db.execute(
                    sql: """
                    UPDATE matters
                    SET name = ?, jurisdiction = ?, party_perspective = ?, court = ?,
                        judge = ?, docket_number = ?, practice_area = ?, client_names = ?,
                        matter_description = ?, internal_matter_id = ?, client_id = ?,
                        client_matter_id = ?, notes = ?, canonical_jurisdiction_id = ?,
                        canonical_court_id = ?, court_resolution_state = ?,
                        identity_revision = ?, updated_at = ?
                    WHERE id = ? AND deleted_at IS NULL AND identity_revision = ?
                    """,
                    arguments: [
                        normalized.name, normalized.jurisdiction, partyPerspective.rawValue,
                        normalizedCourt, normalizedJudge, normalizedDocketNumber,
                        normalizedPracticeArea, normalizedClientNames,
                        normalizedMatterDescription, normalizedInternalMatterID,
                        normalizedClientID, normalizedClientMatterID, normalizedNotes,
                        canonicalJurisdictionID, canonicalCourtID, resultState,
                        resultRevision, now, id, priorRevision,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw CourtIdentityResolutionError.staleIdentityRevision
                }
                return
            }

            try db.execute(
                sql: """
                UPDATE matters
                SET name = ?,
                    jurisdiction = ?,
                    party_perspective = ?,
                    court = ?,
                    judge = ?,
                    docket_number = ?,
                    practice_area = ?,
                    client_names = ?,
                    matter_description = ?,
                    internal_matter_id = ?,
                    client_id = ?,
                    client_matter_id = ?,
                    notes = ?,
                    updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [
                    normalized.name,
                    normalized.jurisdiction,
                    partyPerspective.rawValue,
                    normalizedCourt,
                    normalizedJudge,
                    normalizedDocketNumber,
                    normalizedPracticeArea,
                    normalizedClientNames,
                    normalizedMatterDescription,
                    normalizedInternalMatterID,
                    normalizedClientID,
                    normalizedClientMatterID,
                    normalizedNotes,
                    now,
                    id
                ]
            )
        }
    }

    /// One (client number, client-name spelling) pair as used by live matters,
    /// with how many matters use it and how recently. The client directory is
    /// derived from these — there is no separate clients table to keep in sync.
    public struct ClientUsageRow: Sendable, Equatable {
        public let clientID: String?
        public let clientNames: String?
        public let matterCount: Int
        public let lastUsedAt: Date

        public init(clientID: String?, clientNames: String?, matterCount: Int, lastUsedAt: Date) {
            self.clientID = clientID
            self.clientNames = clientNames
            self.matterCount = matterCount
            self.lastUsedAt = lastUsedAt
        }
    }

    /// Every distinct (client number, client-name spelling) pair across live
    /// matters. Rows where both are empty are skipped — they carry no client.
    public func fetchClientUsage() throws -> [ClientUsageRow] {
        try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT client_id, client_names, COUNT(*) AS matter_count, MAX(updated_at) AS last_used_at
                FROM matters
                WHERE deleted_at IS NULL AND (client_id IS NOT NULL OR client_names IS NOT NULL)
                GROUP BY client_id, client_names
                """
            ).map { row in
                ClientUsageRow(
                    clientID: row["client_id"],
                    clientNames: row["client_names"],
                    matterCount: row["matter_count"],
                    lastUsedAt: row["last_used_at"]
                )
            }
        }
    }

    /// One practice-area spelling as used by live matters, with how many matters
    /// use it. Feeds the matter form's practice-area suggestions.
    public struct PracticeAreaUsageRow: Sendable, Equatable {
        public let name: String
        public let matterCount: Int

        public init(name: String, matterCount: Int) {
            self.name = name
            self.matterCount = matterCount
        }
    }

    /// Every distinct practice-area spelling across live matters.
    public func fetchPracticeAreaUsage() throws -> [PracticeAreaUsageRow] {
        try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT practice_area, COUNT(*) AS matter_count
                FROM matters
                WHERE deleted_at IS NULL AND practice_area IS NOT NULL
                GROUP BY practice_area
                """
            ).map { row in
                PracticeAreaUsageRow(name: row["practice_area"], matterCount: row["matter_count"])
            }
        }
    }

    /// Persists a manual sidebar ordering: each matter's `sort_order` becomes its
    /// index in `orderedIDs`. Leaves `updated_at` alone — reordering isn't a content
    /// edit and must not perturb the date-modified sort.
    public func updateMatterSortOrder(orderedIDs: [String]) throws {
        try writer.write { db in
            for (index, id) in orderedIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE matters SET sort_order = ? WHERE id = ?",
                    arguments: [index, id]
                )
            }
        }
    }

    /// Pins (or unpins) a matter to the top of the sidebar. Leaves `updated_at`
    /// alone — pinning isn't a content edit and must not perturb the
    /// date-modified sort.
    public func setMatterPinned(id: String, pinned: Bool, at date: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE matters SET pinned_at = ? WHERE id = ? AND deleted_at IS NULL",
                arguments: [pinned ? date : nil, id]
            )
        }
    }

    public func softDeleteMatter(id: String, deletedAt: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                UPDATE matters
                SET deleted_at = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                arguments: [deletedAt, deletedAt, id]
            )
            // Cascade the soft-delete to the matter's child rows that support it, so
            // deleting a matter doesn't leave its folders, documents, and outputs
            // visible and orphaned. (Other children are reached only via the now-hidden
            // matter.) Kept as soft-deletes for potential recovery.
            for table in ["document_folders", "matter_documents", "structured_outputs"] {
                try db.execute(
                    sql: "UPDATE \(table) SET deleted_at = ?, updated_at = ? WHERE matter_id = ? AND deleted_at IS NULL",
                    arguments: [deletedAt, deletedAt, id]
                )
            }
            // Processing jobs have no deleted_at; cancel any in-flight ones so a deleted
            // matter's imports stop consuming the queue.
            try db.execute(
                sql: """
                UPDATE document_processing_jobs
                SET status = ?, updated_at = ?
                WHERE matter_id = ? AND status IN ('queued', 'active', 'paused')
                """,
                arguments: [DocumentProcessingJobStatus.cancelled.rawValue, deletedAt, id]
            )
        }
    }

    /// Soft-deleted matters, newest deletion first — the Recycle Bin source.
    public func fetchSoftDeletedMatters() throws -> [MatterRecord] {
        try writer.read { db in
            try MatterRecord.fetchAll(
                db,
                sql: "SELECT * FROM matters WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC"
            )
        }
    }

    /// Restores a soft-deleted matter and the children that *this* delete cascaded
    /// (matched by the shared deletion timestamp), leaving documents that were trashed
    /// independently — before the matter — in the trash. Returns false if the matter
    /// isn't currently deleted.
    @discardableResult
    public func restoreMatter(id: String) throws -> Bool {
        try writer.write { db in
            guard let deletedAt = try Date.fetchOne(
                db,
                sql: "SELECT deleted_at FROM matters WHERE id = ? AND deleted_at IS NOT NULL",
                arguments: [id]
            ) else { return false }
            let now = Date()
            // sort_order is cleared: the manual list was densely reindexed while
            // this matter was deleted, so its old index would land it at an
            // arbitrary spot. Never-placed matters predictably join the end.
            try db.execute(
                sql: "UPDATE matters SET deleted_at = NULL, updated_at = ?, sort_order = NULL WHERE id = ?",
                arguments: [now, id]
            )
            for table in ["document_folders", "matter_documents", "structured_outputs"] {
                try db.execute(
                    sql: "UPDATE \(table) SET deleted_at = NULL, updated_at = ? WHERE matter_id = ? AND deleted_at = ?",
                    arguments: [now, id, deletedAt]
                )
            }
            return true
        }
    }

    /// Permanently deletes a matter and everything it owns. FK cascade removes the
    /// matter's chats, documents, folders, outputs, and research rows; the standalone
    /// FTS index and orphaned blob files are not FK-cascaded, so the document chunks'
    /// FTS rows are cleared here and the managed paths of any now-unreferenced blob are
    /// returned for the caller to delete from disk.
    @discardableResult
    public func permanentlyDeleteMatter(
        id: String,
        actor: String = "system",
        at timestamp: Date = Date()
    ) throws -> [String] {
        let normalizedActor = try Self.requireNonEmpty(actor, fieldName: "actor")
        return try writer.write { db in
            guard let matter = try MatterRecord.fetchOne(db, key: id) else { return [] }
            let docIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM matter_documents WHERE matter_id = ? ORDER BY id",
                arguments: [id]
            )
            try DocumentAttachmentIntegrity.validateDeletionBoundary(
                parentIDs: docIDs,
                matterID: id,
                in: db
            )
            let blobIDs = Set(try String.fetchAll(
                db,
                sql: "SELECT blob_id FROM matter_documents WHERE matter_id = ? AND blob_id IS NOT NULL",
                arguments: [id]
            ))
            for docID in docIDs {
                try db.execute(sql: "DELETE FROM document_chunk_fts WHERE document_id = ?", arguments: [docID])
            }
            // The recovery queue has a logical relation to artifact intents, not
            // a foreign key. Clear those internal queue entries transactionally
            // before the intent cascade so permanent matter deletion cannot
            // strand an unresolvable pending item. Managed export files are not
            // touched by this Store operation.
            try db.execute(
                sql: """
                DELETE FROM remediation_recovery_items
                WHERE kind = ?
                  AND related_table = ?
                  AND related_id IN (
                    SELECT id FROM draft_artifact_intents WHERE matter_id = ?
                  )
                """,
                arguments: [
                    RemediationRecoveryKind.interruptedDraftArtifact.rawValue,
                    DraftArtifactIntentRecord.databaseTableName,
                    id,
                ]
            )
            try db.execute(sql: "DELETE FROM matters WHERE id = ?", arguments: [id])

            var removedPaths: [String] = []
            for blobID in blobIDs.sorted() {
                let remaining = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM matter_documents WHERE blob_id = ?", arguments: [blobID]
                ) ?? 0
                guard remaining == 0 else { continue }
                if let path = try DocumentBlobRecord.fetchOne(db, key: blobID)?.managedRelativePath {
                    removedPaths.append(path)
                }
                try db.execute(sql: "DELETE FROM document_blobs WHERE id = ?", arguments: [blobID])
            }
            let metadataJSON = try Self.canonicalMetadataJSON([
                "schema_version": 1,
                "matter_id": id,
                "matter_name": matter.name,
                "removed_document_count": docIDs.count,
                "removed_document_ids": docIDs,
            ])
            try AuditEventRecord(
                matterID: nil,
                timestamp: timestamp,
                eventType: "matter_permanently_deleted",
                actor: normalizedActor,
                summary: "Permanently deleted matter source data.",
                relatedTable: MatterRecord.databaseTableName,
                relatedID: id,
                metadataJSON: metadataJSON
            ).insert(db)
            return removedPaths.sorted()
        }
    }

    private static func canonicalMetadataJSON(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static func insertIdentitySourceReceipt(
        _ db: Database,
        id: String,
        matterID: String,
        sourceKind: String,
        identityRevision: Int,
        courtResolutionState: String,
        resolutionReason: String,
        legacyJurisdiction: String,
        legacyCourt: String?,
        legacyPartyPerspective: String,
        legacyClientNames: String?,
        canonicalJurisdictionID: String?,
        canonicalCourtID: String?,
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
                id, matterID, sourceKind, identityRevision,
                courtResolutionState, resolutionReason, legacyJurisdiction,
                legacyCourt, legacyPartyPerspective, legacyClientNames,
                canonicalJurisdictionID, canonicalCourtID,
                canonicalCourtCatalogVersion, canonicalCourtCatalogDigestSHA256,
                createdAt,
            ]
        )
    }

    private static func validateMatterFields(
        name: String,
        jurisdiction: String,
        partyPerspective: PartyPerspective
    ) throws -> (name: String, jurisdiction: String) {
        (
            try requireNonEmpty(name, fieldName: "name"),
            try requireNonEmpty(jurisdiction, fieldName: "jurisdiction")
        )
    }

    private static func requireNonEmpty(_ value: String, fieldName: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MatterRepositoryError.requiredFieldMissing(fieldName)
        }
        return trimmed
    }

    private static func trimOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public enum MatterRepositoryError: Error, Equatable, Sendable {
    case requiredFieldMissing(String)
}
