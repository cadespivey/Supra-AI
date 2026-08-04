import CryptoKit
import Foundation
import GRDB
import SupraCore

public struct MotionDraftAuthoritySelection: Codable, Equatable, Hashable, Sendable {
    public let authorityID: String
    public let groundKey: AuthorityReviewedPropositionGround
    public let expectedBindingSHA256: String

    public init(
        authorityID: String,
        groundKey: AuthorityReviewedPropositionGround,
        expectedBindingSHA256: String
    ) {
        self.authorityID = authorityID
        self.groundKey = groundKey
        self.expectedBindingSHA256 = expectedBindingSHA256
    }
}

public struct MotionDraftFactSelection: Codable, Equatable, Hashable, Sendable {
    public let chunkID: String
    public let expectedRevisionID: String
    public let expectedExcerptSHA256: String

    public init(
        chunkID: String,
        expectedRevisionID: String,
        expectedExcerptSHA256: String
    ) {
        self.chunkID = chunkID
        self.expectedRevisionID = expectedRevisionID
        self.expectedExcerptSHA256 = expectedExcerptSHA256
    }
}

public struct MotionDraftSnapshotRequest: Codable, Equatable, Sendable {
    public let matterID: String
    public let factSelections: [MotionDraftFactSelection]
    public let authoritySelections: [MotionDraftAuthoritySelection]
    public let assistantProfileSettingKey: String
    public let firmStyleProfileSettingKey: String

    public init(
        matterID: String,
        factSelections: [MotionDraftFactSelection],
        authoritySelections: [MotionDraftAuthoritySelection],
        assistantProfileSettingKey: String,
        firmStyleProfileSettingKey: String
    ) {
        self.matterID = matterID
        self.factSelections = factSelections
        self.authoritySelections = authoritySelections
        self.assistantProfileSettingKey = assistantProfileSettingKey
        self.firmStyleProfileSettingKey = firmStyleProfileSettingKey
    }

    public var factChunkIDs: [String] { factSelections.map(\.chunkID) }
}

/// Raw fact-source values captured by one Store read. Consumers can derive UI
/// blockers from these rows without combining document, part, and chunk values
/// from different database snapshots.
public struct MotionDraftFactSourceRecord: Sendable {
    public let document: MatterDocumentRecord
    public let part: DocumentPagePartRecord?
    public let chunk: DocumentChunkRecord
}

/// Raw authority metadata and its recomputed proposition state captured by one
/// Store read. The displayed citation and selected evidence binding therefore
/// always describe the same persisted authority version.
public struct MotionDraftAuthoritySourceRecord: Sendable {
    public let authority: AuthorityRecord
    public let propositionState: AuthorityReviewedPropositionState
}

public struct MotionDraftSettingSnapshot: Codable, Equatable, Sendable {
    public let key: String
    public let valueJSON: String?
    public let valueSHA256: String
}

/// Content-free identity of one persisted structure edge that supplied context
/// to a selected v2 chunk. Array order is the exact projection order.
public struct MotionDraftStructureEdgeSnapshot: Codable, Equatable, Hashable, Sendable {
    public let edgeID: String
    public let fromNodeID: String
    public let toNodeID: String
    public let kind: String
    public let projectionOrder: Int
}

public struct MotionDraftFactSnapshot: Codable, Equatable, Sendable {
    public let chunkID: String
    public let documentID: String
    public let documentName: String
    public let partID: String
    public let revisionID: String
    public let nodeID: String?
    public let unitKind: String?
    public let chunkerVersion: Int
    public let sourceKind: String
    public let pageIndex: Int?
    public let pageLabel: String?
    public let sheetName: String?
    public let cellRange: String?
    public let emailPartPath: String?
    public let charStart: Int
    public let charEnd: Int
    public let text: String
    public let ocrConfidence: Double?
    public let boundingBoxesSHA256: String?
    public let relatedStructureEdges: [MotionDraftStructureEdgeSnapshot]
    public let revisionSHA256: String
    public let excerptSHA256: String
}

public struct MotionDraftAuthoritySnapshot: Codable, Equatable, Sendable {
    public let authorityID: String
    public let caseName: String
    public let citation: String
    public let groundKey: AuthorityReviewedPropositionGround
    public let excerpt: String
    public let evidenceSchemaVersion: Int
    public let excerptByteStart: Int
    public let excerptByteLength: Int
    public let opinionSHA256: String
    public let excerptSHA256: String
    public let effectiveCitationSHA256: String
    public let courtSHA256: String
    public let bindingSHA256: String
}

/// Immutable values read from one GRDB snapshot. Raw excerpts are available to
/// the in-memory assembler/verifier; only their canonical hashes belong in audit metadata.
public struct MotionDraftStoreSnapshot: Sendable {
    public static let schemaVersion = 2

    public let request: MotionDraftSnapshotRequest
    public let matter: MatterRecord
    public let assistantProfile: MotionDraftSettingSnapshot
    public let firmStyleProfile: MotionDraftSettingSnapshot
    public let facts: [MotionDraftFactSnapshot]
    public let authorities: [MotionDraftAuthoritySnapshot]
    public let fingerprintSHA256: String

    init(
        request: MotionDraftSnapshotRequest,
        matter: MatterRecord,
        assistantProfile: MotionDraftSettingSnapshot,
        firmStyleProfile: MotionDraftSettingSnapshot,
        facts: [MotionDraftFactSnapshot],
        authorities: [MotionDraftAuthoritySnapshot],
        fingerprintSHA256: String
    ) {
        self.request = request
        self.matter = matter
        self.assistantProfile = assistantProfile
        self.firmStyleProfile = firmStyleProfile
        self.facts = facts
        self.authorities = authorities
        self.fingerprintSHA256 = fingerprintSHA256
    }
}

/// Store-owned outer contract for the schema-v2, content-free motion lineage
/// emitted by SupraSessions. Store validates the full shape before it blesses
/// the lineage and current source snapshot in one transaction.
public enum MotionDraftAuditEnvelope {
    public static let schemaVersion = 2
    public static let kindID = "motionToDismiss"
}

public enum MotionDraftSnapshotError: Error, Equatable, Sendable {
    case blankMatterID
    case emptyFactSelection
    case emptyAuthoritySelection
    case blankSettingKey
    case duplicateFactChunkID(String)
    case duplicateAuthorityID(String)
    case matterNotFound(String)
    case factNotFound(String)
    case factOutsideMatter(String)
    case factNotReady(String)
    case factBindingInvalid(String)
    case factSelectionStale(String)
    case authorityNotFound(String)
    case authorityOutsideMatter(String)
    case authorityProvenanceInvalid(String)
    case authoritySelectionStale(String)
    case authorityPropositionUnavailable(authorityID: String, reason: String)
    case auditMatterMismatch
    case auditEnvelopeInvalid
    case sourceSnapshotStale
}

/// Owns the one coherent source boundary used by motion drafting. Existing
/// repositories intentionally remain independent; composing their public reads
/// would create a different SQLite snapshot for each source.
public final class DraftingSourceRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func captureMotionSnapshot(
        _ request: MotionDraftSnapshotRequest
    ) throws -> MotionDraftStoreSnapshot {
        try writer.read { db in
            try Self.capture(request, db: db)
        }
    }

    public func fetchMotionFactSources(
        matterID: String
    ) throws -> [MotionDraftFactSourceRecord] {
        try writer.read { db in
            let documents = try MatterDocumentRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM matter_documents
                    WHERE matter_id = ? AND deleted_at IS NULL
                    ORDER BY display_name COLLATE NOCASE ASC
                    """,
                arguments: [matterID]
            )
            var sources: [MotionDraftFactSourceRecord] = []
            for document in documents {
                let partsByID = Dictionary(
                    uniqueKeysWithValues: try DocumentPagePartRecord.fetchAll(
                        db,
                        sql: "SELECT * FROM document_pages_parts WHERE document_id = ? ORDER BY part_index ASC",
                        arguments: [document.id]
                    ).map { ($0.id, $0) }
                )
                let chunks = try DocumentChunkRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM document_chunks WHERE document_id = ? ORDER BY chunk_index ASC",
                    arguments: [document.id]
                )
                sources.append(contentsOf: chunks.map { chunk in
                    MotionDraftFactSourceRecord(
                        document: document,
                        part: chunk.pagePartID.flatMap { partsByID[$0] },
                        chunk: chunk
                    )
                })
            }
            return sources
        }
    }

    public func fetchMotionAuthoritySources(
        matterID: String,
        groundKey: AuthorityReviewedPropositionGround
    ) throws -> [MotionDraftAuthoritySourceRecord] {
        try writer.read { db in
            let authorities = try AuthorityRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM authorities
                    WHERE matter_id = ? AND deleted_at IS NULL
                    ORDER BY updated_at DESC
                    """,
                arguments: [matterID]
            )
            return authorities.map { authority in
                let state: AuthorityReviewedPropositionState
                do {
                    try AuthorityRepository.validateResearchProvenance(authority: authority, db: db)
                    state = AuthorityRepository.reviewedPropositionState(
                        authority: authority,
                        groundKey: groundKey
                    )
                } catch {
                    state = .blocked(.authorityProvenanceInvalid)
                }
                return MotionDraftAuthoritySourceRecord(
                    authority: authority,
                    propositionState: state
                )
            }
        }
    }

    /// Revalidates every dependency and appends the audit event in the same
    /// writer transaction. A change during async verification therefore cannot
    /// be blessed by an audit row for a different source state.
    public func recordMotionAudit(
        _ event: AuditEventRecord,
        requiring snapshot: MotionDraftStoreSnapshot
    ) throws {
        guard event.matterID == snapshot.request.matterID else {
            throw MotionDraftSnapshotError.auditMatterMismatch
        }
        guard event.eventType == "draft_generated",
              event.relatedTable == MatterRecord.databaseTableName,
              event.relatedID == snapshot.request.matterID,
              let metadataJSON = event.metadataJSON,
              Self.validAuditEnvelope(metadataJSON, requiring: snapshot) else {
            throw MotionDraftSnapshotError.auditEnvelopeInvalid
        }
        try writer.write { db in
            let current: MotionDraftStoreSnapshot
            do {
                current = try Self.capture(snapshot.request, db: db)
            } catch is MotionDraftSnapshotError {
                throw MotionDraftSnapshotError.sourceSnapshotStale
            }
            guard current.fingerprintSHA256 == snapshot.fingerprintSHA256 else {
                throw MotionDraftSnapshotError.sourceSnapshotStale
            }
            try event.insert(db)
        }
    }

    private static func capture(
        _ request: MotionDraftSnapshotRequest,
        db: Database
    ) throws -> MotionDraftStoreSnapshot {
        try validate(request)
        guard let matter = try MatterRecord.fetchOne(db, key: request.matterID),
              matter.deletedAt == nil else {
            throw MotionDraftSnapshotError.matterNotFound(request.matterID)
        }

        let assistant = try setting(key: request.assistantProfileSettingKey, db: db)
        let style = try setting(key: request.firmStyleProfileSettingKey, db: db)
        let facts = try request.factSelections.map {
            try fact(selection: $0, matterID: request.matterID, db: db)
        }
        let authorities = try request.authoritySelections.map {
            try authority(selection: $0, matterID: request.matterID, db: db)
        }
        let fingerprint = try fingerprint(
            matter: matter,
            assistant: assistant,
            style: style,
            facts: facts,
            authorities: authorities
        )
        return MotionDraftStoreSnapshot(
            request: request,
            matter: matter,
            assistantProfile: assistant,
            firmStyleProfile: style,
            facts: facts,
            authorities: authorities,
            fingerprintSHA256: fingerprint
        )
    }

    private static func validate(_ request: MotionDraftSnapshotRequest) throws {
        guard !request.matterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MotionDraftSnapshotError.blankMatterID
        }
        guard !request.factSelections.isEmpty else {
            throw MotionDraftSnapshotError.emptyFactSelection
        }
        guard !request.authoritySelections.isEmpty else {
            throw MotionDraftSnapshotError.emptyAuthoritySelection
        }
        guard !request.assistantProfileSettingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.firmStyleProfileSettingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MotionDraftSnapshotError.blankSettingKey
        }
        var factIDs = Set<String>()
        for selection in request.factSelections {
            let id = selection.chunkID
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MotionDraftSnapshotError.factNotFound(id)
            }
            guard !selection.expectedRevisionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  isSHA256(selection.expectedExcerptSHA256) else {
                throw MotionDraftSnapshotError.factSelectionStale(id)
            }
            guard factIDs.insert(id).inserted else {
                throw MotionDraftSnapshotError.duplicateFactChunkID(id)
            }
        }
        var authorityIDs = Set<String>()
        for selection in request.authoritySelections {
            let id = selection.authorityID
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MotionDraftSnapshotError.authorityNotFound(id)
            }
            guard isSHA256(selection.expectedBindingSHA256) else {
                throw MotionDraftSnapshotError.authoritySelectionStale(id)
            }
            guard authorityIDs.insert(id).inserted else {
                throw MotionDraftSnapshotError.duplicateAuthorityID(id)
            }
        }
    }

    private static func setting(key: String, db: Database) throws -> MotionDraftSettingSnapshot {
        let value = try AppSettingRecord.fetchOne(db, key: key)?.valueJSON
        let digestInput = value.map { Data($0.utf8) } ?? Data("missing\u{0}\(key)".utf8)
        return MotionDraftSettingSnapshot(
            key: key,
            valueJSON: value,
            valueSHA256: sha256(digestInput)
        )
    }

    private static func fact(
        selection: MotionDraftFactSelection,
        matterID: String,
        db: Database
    ) throws -> MotionDraftFactSnapshot {
        let chunkID = selection.chunkID
        guard let chunk = try DocumentChunkRecord.fetchOne(db, key: chunkID) else {
            throw MotionDraftSnapshotError.factNotFound(chunkID)
        }
        guard nonblank(chunk.revisionID) == selection.expectedRevisionID,
              sha256(Data(chunk.normalizedText.utf8)) == selection.expectedExcerptSHA256 else {
            throw MotionDraftSnapshotError.factSelectionStale(chunkID)
        }
        guard let document = try MatterDocumentRecord.fetchOne(db, key: chunk.documentID) else {
            throw MotionDraftSnapshotError.factNotFound(chunkID)
        }
        guard document.matterID == matterID else {
            throw MotionDraftSnapshotError.factOutsideMatter(chunkID)
        }
        let extractionReady = [
            DocumentExtractionStatus.extracted.rawValue,
            DocumentExtractionStatus.ocrComplete.rawValue,
            DocumentExtractionStatus.edited.rawValue,
        ].contains(document.extractionStatus)
        let indexReady = [
            DocumentIndexStatus.textIndexed.rawValue,
            DocumentIndexStatus.ready.rawValue,
        ].contains(document.indexStatus)
        guard document.deletedAt == nil,
              document.status == MatterDocumentStatus.ready.rawValue,
              extractionReady,
              indexReady else {
            throw MotionDraftSnapshotError.factNotReady(chunkID)
        }
        guard chunk.chunkerVersion == 1 || chunk.chunkerVersion == 2,
              let partID = nonblank(chunk.pagePartID),
              let revisionID = nonblank(chunk.revisionID),
              let start = chunk.charStart,
              let end = chunk.charEnd,
              !chunk.normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let part = try DocumentPagePartRecord.fetchOne(db, key: partID),
              part.documentID == document.id,
              part.currentRevisionID == revisionID,
              part.sourceKind == chunk.sourceKind,
              part.pageIndex == chunk.pageIndex,
              part.pageLabel == chunk.pageLabel,
              part.sheetName == chunk.sheetName,
              part.cellRange == chunk.cellRange,
              part.emailPartPath == chunk.emailPartPath,
              part.ocrConfidence == chunk.ocrConfidence,
              part.boundingBoxesJSON == chunk.boundingBoxesJSON,
              let revision = try DocumentPartRevisionRecord.fetchOne(db, key: revisionID),
              revision.documentID == document.id,
              revision.partIndex == part.partIndex,
              part.normalizedText == revision.text,
              part.charCount == revision.charCount,
              revision.charCount == revision.text.count,
              part.ocrConfidence == revision.ocrConfidence,
              part.boundingBoxesJSON == revision.boundingBoxesJSON else {
            throw MotionDraftSnapshotError.factBindingInvalid(chunkID)
        }

        let relatedStructureEdges: [MotionDraftStructureEdgeSnapshot]
        do {
            if chunk.chunkerVersion == 2 {
                let expectedChunks = try shippingV2Chunks(
                    documentID: document.id,
                    matterID: matterID,
                    db: db
                )
                guard let matched = expectedChunks.first(where: {
                    $0.chunkIndex == chunk.chunkIndex
                        && $0.partID == part.id
                        && $0.revisionID == revision.id
                        && $0.nodeID == chunk.nodeID
                        && $0.unitKind == chunk.unitKind
                        && $0.charStart == start
                        && $0.charEnd == end
                        && $0.text == chunk.normalizedText
                }) else {
                    throw MotionDraftSnapshotError.factBindingInvalid(chunkID)
                }
                relatedStructureEdges = matched.relatedStructureEdges
            } else {
                guard chunk.nodeID == nil,
                      chunk.unitKind == nil else {
                    throw MotionDraftSnapshotError.factBindingInvalid(chunkID)
                }
                guard exactCharacterSlice(revision.text, start: start, end: end) == chunk.normalizedText else {
                    throw MotionDraftSnapshotError.factBindingInvalid(chunkID)
                }
                relatedStructureEdges = []
            }
        } catch is MotionDraftSnapshotError {
            throw MotionDraftSnapshotError.factBindingInvalid(chunkID)
        } catch {
            throw MotionDraftSnapshotError.factBindingInvalid(chunkID)
        }

        if chunk.chunkerVersion == 2 {
            let identity = [
                "chunk-v2", document.id, revision.id, part.id, chunk.nodeID ?? "",
                String(chunk.chunkIndex), String(start), String(end), chunk.normalizedText,
            ].joined(separator: "\u{001f}")
            guard chunk.id == "chunk-v2-\(sha256(Data(identity.utf8)))" else {
                throw MotionDraftSnapshotError.factBindingInvalid(chunkID)
            }
        }

        return MotionDraftFactSnapshot(
            chunkID: chunk.id,
            documentID: document.id,
            documentName: document.displayName,
            partID: part.id,
            revisionID: revision.id,
            nodeID: chunk.nodeID,
            unitKind: chunk.unitKind,
            chunkerVersion: chunk.chunkerVersion,
            sourceKind: part.sourceKind,
            pageIndex: part.pageIndex,
            pageLabel: part.pageLabel,
            sheetName: part.sheetName,
            cellRange: part.cellRange,
            emailPartPath: part.emailPartPath,
            charStart: start,
            charEnd: end,
            text: chunk.normalizedText,
            ocrConfidence: part.ocrConfidence,
            boundingBoxesSHA256: part.boundingBoxesJSON.map { sha256(Data($0.utf8)) },
            relatedStructureEdges: relatedStructureEdges,
            revisionSHA256: sha256(Data(revision.text.utf8)),
            excerptSHA256: sha256(Data(chunk.normalizedText.utf8))
        )
    }

    private static func authority(
        selection: MotionDraftAuthoritySelection,
        matterID: String,
        db: Database
    ) throws -> MotionDraftAuthoritySnapshot {
        guard let authority = try AuthorityRecord.fetchOne(db, key: selection.authorityID) else {
            throw MotionDraftSnapshotError.authorityNotFound(selection.authorityID)
        }
        guard authority.matterID == matterID else {
            throw MotionDraftSnapshotError.authorityOutsideMatter(selection.authorityID)
        }
        do {
            try AuthorityRepository.validateResearchProvenance(authority: authority, db: db)
        } catch {
            throw MotionDraftSnapshotError.authorityProvenanceInvalid(selection.authorityID)
        }
        let state = AuthorityRepository.reviewedPropositionState(
            authority: authority,
            groundKey: selection.groundKey
        )
        let reviewed: AuthorityReviewedProposition
        switch state {
        case let .ready(value):
            reviewed = value
        case .notReviewed:
            throw MotionDraftSnapshotError.authorityPropositionUnavailable(
                authorityID: authority.id,
                reason: "not_reviewed"
            )
        case let .blocked(reason):
            throw MotionDraftSnapshotError.authorityPropositionUnavailable(
                authorityID: authority.id,
                reason: reason.rawValue
            )
        }
        guard reviewed.bindingSHA256 == selection.expectedBindingSHA256 else {
            throw MotionDraftSnapshotError.authoritySelectionStale(authority.id)
        }
        guard let citation = AuthorityRepository.effectiveCitation(authority) else {
            throw MotionDraftSnapshotError.authorityPropositionUnavailable(
                authorityID: authority.id,
                reason: AuthorityReviewedPropositionBlockReason.staleEvidence.rawValue
            )
        }
        return MotionDraftAuthoritySnapshot(
            authorityID: authority.id,
            caseName: authority.caseName,
            citation: citation,
            groundKey: selection.groundKey,
            excerpt: reviewed.excerpt,
            evidenceSchemaVersion: reviewed.schemaVersion,
            excerptByteStart: reviewed.excerptByteStart,
            excerptByteLength: reviewed.excerptByteLength,
            opinionSHA256: reviewed.opinionSHA256,
            excerptSHA256: reviewed.excerptSHA256,
            effectiveCitationSHA256: reviewed.effectiveCitationSHA256,
            courtSHA256: reviewed.courtSHA256,
            bindingSHA256: reviewed.bindingSHA256
        )
    }

    private struct CanonicalMatter: Encodable {
        let id: String
        let jurisdiction: String
        let partyPerspective: String
        let court: String?
        let judge: String?
        let docketNumber: String?
    }

    private struct CanonicalSetting: Encodable {
        let key: String
        let present: Bool
        let valueSHA256: String
    }

    private struct CanonicalFact: Encodable {
        let chunkID: String
        let documentID: String
        let documentNameSHA256: String
        let partID: String
        let revisionID: String
        let nodeID: String?
        let unitKind: String?
        let chunkerVersion: Int
        let sourceKind: String
        let pageIndex: Int?
        let pageLabel: String?
        let sheetName: String?
        let cellRange: String?
        let emailPartPath: String?
        let charStart: Int
        let charEnd: Int
        let ocrConfidence: Double?
        let boundingBoxesSHA256: String?
        let relatedStructureEdges: [MotionDraftStructureEdgeSnapshot]
        let revisionSHA256: String
        let excerptSHA256: String
    }

    private struct CanonicalAuthority: Encodable {
        let authorityID: String
        let caseNameSHA256: String
        let groundKey: String
        let evidenceSchemaVersion: Int
        let excerptByteStart: Int
        let excerptByteLength: Int
        let opinionSHA256: String
        let excerptSHA256: String
        let effectiveCitationSHA256: String
        let courtSHA256: String
        let bindingSHA256: String
    }

    private struct CanonicalSnapshot: Encodable {
        let schemaVersion: Int
        let hashAlgorithm: String
        let canonicalization: String
        let matter: CanonicalMatter
        let settings: [CanonicalSetting]
        let facts: [CanonicalFact]
        let authorities: [CanonicalAuthority]
    }

    private static func fingerprint(
        matter: MatterRecord,
        assistant: MotionDraftSettingSnapshot,
        style: MotionDraftSettingSnapshot,
        facts: [MotionDraftFactSnapshot],
        authorities: [MotionDraftAuthoritySnapshot]
    ) throws -> String {
        let payload = CanonicalSnapshot(
            schemaVersion: MotionDraftStoreSnapshot.schemaVersion,
            hashAlgorithm: "sha256",
            canonicalization: "json-sorted-keys-v1",
            matter: CanonicalMatter(
                id: matter.id,
                jurisdiction: matter.jurisdiction,
                partyPerspective: matter.partyPerspective,
                court: matter.court,
                judge: matter.judge,
                docketNumber: matter.docketNumber
            ),
            settings: [assistant, style].map {
                CanonicalSetting(
                    key: $0.key,
                    present: $0.valueJSON != nil,
                    valueSHA256: $0.valueSHA256
                )
            },
            facts: facts.map {
                CanonicalFact(
                    chunkID: $0.chunkID,
                    documentID: $0.documentID,
                    documentNameSHA256: sha256(Data($0.documentName.utf8)),
                    partID: $0.partID,
                    revisionID: $0.revisionID,
                    nodeID: $0.nodeID,
                    unitKind: $0.unitKind,
                    chunkerVersion: $0.chunkerVersion,
                    sourceKind: $0.sourceKind,
                    pageIndex: $0.pageIndex,
                    pageLabel: $0.pageLabel,
                    sheetName: $0.sheetName,
                    cellRange: $0.cellRange,
                    emailPartPath: $0.emailPartPath,
                    charStart: $0.charStart,
                    charEnd: $0.charEnd,
                    ocrConfidence: $0.ocrConfidence,
                    boundingBoxesSHA256: $0.boundingBoxesSHA256,
                    relatedStructureEdges: $0.relatedStructureEdges,
                    revisionSHA256: $0.revisionSHA256,
                    excerptSHA256: $0.excerptSHA256
                )
            },
            authorities: authorities.map {
                CanonicalAuthority(
                    authorityID: $0.authorityID,
                    caseNameSHA256: sha256(Data($0.caseName.utf8)),
                    groundKey: $0.groundKey.rawValue,
                    evidenceSchemaVersion: $0.evidenceSchemaVersion,
                    excerptByteStart: $0.excerptByteStart,
                    excerptByteLength: $0.excerptByteLength,
                    opinionSHA256: $0.opinionSHA256,
                    excerptSHA256: $0.excerptSHA256,
                    effectiveCitationSHA256: $0.effectiveCitationSHA256,
                    courtSHA256: $0.courtSHA256,
                    bindingSHA256: $0.bindingSHA256
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(payload))
    }

    private struct DecodedMotionAuditEnvelope: Decodable {
        struct Fact: Decodable {
            let chunkID: String
            let documentID: String
            let partID: String
            let revisionID: String
            let nodeID: String?
            let unitKind: String?
            let chunkerVersion: Int
            let charStart: Int
            let charEnd: Int
            let ocrConfidence: Double?
            let boundingBoxesSHA256: String?
            let relatedStructureEdges: [MotionDraftStructureEdgeSnapshot]
            let revisionSHA256: String
            let excerptSHA256: String
        }

        struct Authority: Decodable {
            let authorityID: String
            let groundKey: String
            let evidenceSchemaVersion: Int
            let excerptByteStart: Int
            let excerptByteLength: Int
            let opinionSHA256: String
            let excerptSHA256: String
            let effectiveCitationSHA256: String
            let courtSHA256: String
            let bindingSHA256: String
        }

        struct ComponentIdentity: Decodable {
            let id: String
            let version: String
        }

        let schemaVersion: Int
        let kindID: String
        let sourceSnapshotSHA256: String
        let facts: [Fact]
        let authorities: [Authority]
        let groundKeys: [String]
        let requestSHA256: String
        let captionSHA256: String
        let assistantProfileSHA256: String
        let effectiveStyleSHA256: String
        let groundContractIdentity: ComponentIdentity
        let assemblerIdentity: ComponentIdentity
        let verifierIdentity: ComponentIdentity
        let gateIdentity: ComponentIdentity
        let rendererIdentity: ComponentIdentity
        let verificationReceiptSHA256: String
        let verificationStatus: String
        let outputFileName: String
        let outputSHA256: String
        let outputByteSize: Int
    }

    private static func validAuditEnvelope(
        _ metadataJSON: String,
        requiring snapshot: MotionDraftStoreSnapshot
    ) -> Bool {
        let data = Data(metadataJSON.utf8)
        guard hasContentFreeAuditSchema(data),
              let envelope = try? JSONDecoder().decode(DecodedMotionAuditEnvelope.self, from: data),
              envelope.schemaVersion == MotionDraftAuditEnvelope.schemaVersion,
              envelope.kindID == MotionDraftAuditEnvelope.kindID,
              envelope.sourceSnapshotSHA256 == snapshot.fingerprintSHA256,
              isSHA256(envelope.sourceSnapshotSHA256),
              envelope.assistantProfileSHA256 == snapshot.assistantProfile.valueSHA256,
              envelope.verificationStatus == "passed",
              envelope.outputByteSize > 0,
              !envelope.outputFileName.isEmpty,
              !envelope.outputFileName.contains("/"),
              !envelope.outputFileName.contains("\\"),
              !envelope.facts.isEmpty,
              !envelope.authorities.isEmpty,
              !envelope.groundKeys.isEmpty,
              envelope.facts.count == snapshot.facts.count,
              envelope.authorities.count == snapshot.authorities.count else {
            return false
        }

        let envelopeHashes = [
            envelope.requestSHA256,
            envelope.captionSHA256,
            envelope.assistantProfileSHA256,
            envelope.effectiveStyleSHA256,
            envelope.verificationReceiptSHA256,
            envelope.outputSHA256,
        ]
        guard envelopeHashes.allSatisfy({ isSHA256($0) }),
              [
                  envelope.groundContractIdentity,
                  envelope.assemblerIdentity,
                  envelope.verifierIdentity,
                  envelope.gateIdentity,
                  envelope.rendererIdentity,
              ].allSatisfy({ nonblank($0.id) != nil && nonblank($0.version) != nil }) else {
            return false
        }

        var expectedGroundKeys: [String] = []
        for authority in snapshot.authorities where !expectedGroundKeys.contains(authority.groundKey.rawValue) {
            expectedGroundKeys.append(authority.groundKey.rawValue)
        }
        guard envelope.groundKeys == expectedGroundKeys else { return false }

        for (fact, source) in zip(envelope.facts, snapshot.facts) {
            guard fact.chunkID == source.chunkID,
                  fact.documentID == source.documentID,
                  fact.partID == source.partID,
                  fact.revisionID == source.revisionID,
                  fact.nodeID == source.nodeID,
                  fact.unitKind == source.unitKind,
                  fact.chunkerVersion == source.chunkerVersion,
                  fact.charStart == source.charStart,
                  fact.charEnd == source.charEnd,
                  fact.ocrConfidence == source.ocrConfidence,
                  fact.boundingBoxesSHA256 == source.boundingBoxesSHA256,
                  fact.relatedStructureEdges == source.relatedStructureEdges,
                  fact.revisionSHA256 == source.revisionSHA256,
                  fact.excerptSHA256 == source.excerptSHA256,
                  isSHA256(fact.revisionSHA256),
                  isSHA256(fact.excerptSHA256),
                  fact.boundingBoxesSHA256.map({ isSHA256($0) }) ?? true,
                  fact.relatedStructureEdges.enumerated().allSatisfy({ index, edge in
                      edge.projectionOrder == index
                          && ["responds_to", "references", "header_for"].contains(edge.kind)
                          && nonblank(edge.edgeID) != nil
                          && nonblank(edge.fromNodeID) != nil
                          && nonblank(edge.toNodeID) != nil
                  }) else {
                return false
            }
        }

        for (authority, source) in zip(envelope.authorities, snapshot.authorities) {
            guard authority.authorityID == source.authorityID,
                  authority.groundKey == source.groundKey.rawValue,
                  authority.evidenceSchemaVersion == source.evidenceSchemaVersion,
                  authority.excerptByteStart == source.excerptByteStart,
                  authority.excerptByteLength == source.excerptByteLength,
                  authority.opinionSHA256 == source.opinionSHA256,
                  authority.excerptSHA256 == source.excerptSHA256,
                  authority.effectiveCitationSHA256 == source.effectiveCitationSHA256,
                  authority.courtSHA256 == source.courtSHA256,
                  authority.bindingSHA256 == source.bindingSHA256,
                  [
                      authority.opinionSHA256,
                      authority.excerptSHA256,
                      authority.effectiveCitationSHA256,
                      authority.courtSHA256,
                      authority.bindingSHA256,
                  ].allSatisfy({ isSHA256($0) }) else {
                return false
            }
        }
        return true
    }

    /// Rejects unknown keys at every content-bearing level. Synthesized
    /// Decodable conformance intentionally ignores unknown keys, so this schema
    /// check is what prevents raw source/profile fields from hitchhiking beside
    /// the approved identifier/hash-only lineage.
    private static func hasContentFreeAuditSchema(_ data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        let rootKeys: Set<String> = [
            "schemaVersion", "kindID", "sourceSnapshotSHA256", "facts", "authorities",
            "groundKeys", "requestSHA256", "captionSHA256", "assistantProfileSHA256",
            "effectiveStyleSHA256", "groundContractIdentity", "assemblerIdentity",
            "verifierIdentity", "gateIdentity", "rendererIdentity",
            "verificationReceiptSHA256", "verificationStatus", "outputFileName",
            "outputSHA256", "outputByteSize",
        ]
        guard Set(root.keys) == rootKeys else { return false }

        let factRequiredKeys: Set<String> = [
            "chunkID", "documentID", "partID", "revisionID", "chunkerVersion",
            "charStart", "charEnd", "relatedStructureEdges", "revisionSHA256",
            "excerptSHA256",
        ]
        let factAllowedKeys = factRequiredKeys.union([
            "nodeID", "unitKind", "ocrConfidence", "boundingBoxesSHA256",
        ])
        let edgeKeys: Set<String> = [
            "edgeID", "fromNodeID", "toNodeID", "kind", "projectionOrder",
        ]
        guard let facts = root["facts"] as? [[String: Any]],
              facts.allSatisfy({ fact in
                  let keys = Set(fact.keys)
                  guard factRequiredKeys.isSubset(of: keys), keys.isSubset(of: factAllowedKeys),
                        let edges = fact["relatedStructureEdges"] as? [[String: Any]] else {
                      return false
                  }
                  return edges.allSatisfy { Set($0.keys) == edgeKeys }
              }) else {
            return false
        }

        let authorityKeys: Set<String> = [
            "authorityID", "groundKey", "evidenceSchemaVersion", "excerptByteStart",
            "excerptByteLength", "opinionSHA256", "excerptSHA256",
            "effectiveCitationSHA256", "courtSHA256", "bindingSHA256",
        ]
        guard let authorities = root["authorities"] as? [[String: Any]],
              authorities.allSatisfy({ Set($0.keys) == authorityKeys }) else {
            return false
        }

        let identityKeys: Set<String> = ["id", "version"]
        for key in [
            "groundContractIdentity", "assemblerIdentity", "verifierIdentity",
            "gateIdentity", "rendererIdentity",
        ] {
            guard let identity = root[key] as? [String: Any],
                  Set(identity.keys) == identityKeys else {
                return false
            }
        }
        return true
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func exactCharacterSlice(
        _ text: String,
        start: Int,
        end: Int
    ) -> String? {
        guard start >= 0, end > start, end <= text.count else { return nil }
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(text.startIndex, offsetBy: end)
        return String(text[lower..<upper])
    }

    private struct StructuredChunkProjection {
        let chunkIndex: Int
        let partID: String
        let revisionID: String?
        let nodeID: String?
        let unitKind: String?
        let charStart: Int
        let charEnd: Int
        let text: String
        let relatedStructureEdges: [MotionDraftStructureEdgeSnapshot]
    }

    private static let shippingV2MaxChars = 1_200
    private static let shippingV2OverlapChars = 200

    /// Mirrors the shipping v2 producer's candidate ordering, edge priority,
    /// consumption, global chunk indices, and node-less fallback boundaries
    /// without making the persistence package depend on SupraDocuments.
    private static func shippingV2Chunks(
        documentID: String,
        matterID: String,
        db: Database
    ) throws -> [StructuredChunkProjection] {
        let parts = try DocumentPagePartRecord.fetchAll(
            db,
            sql: "SELECT * FROM document_pages_parts WHERE document_id = ? ORDER BY part_index ASC",
            arguments: [documentID]
        )
        let partsByID = Dictionary(uniqueKeysWithValues: parts.map { ($0.id, $0) })
        let partOrder = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($0.element.id, $0.offset) })
        let revisionIDsByPartID = Dictionary(uniqueKeysWithValues: parts.compactMap { part in
            part.currentRevisionID.map { (part.id, $0) }
        })
        var partIDsByRevisionID: [String: String] = [:]
        for (partID, revisionID) in revisionIDsByPartID {
            guard partIDsByRevisionID.updateValue(partID, forKey: revisionID) == nil else {
                throw MotionDraftSnapshotError.factBindingInvalid(documentID)
            }
        }

        let recognizedKinds: Set<String> = [
            "document", "section", "heading", "paragraph", "list", "list_item",
            "table", "table_row", "table_cell", "footnote", "endnote", "comment",
            "header", "footer", "tracked_insertion", "tracked_deletion", "page",
            "region", "sheet", "cell_range", "email_message", "email_body",
            "email_quote", "attachment_ref", "discovery_request", "discovery_response",
            "objection", "deposition_question", "deposition_answer", "exhibit_ref",
        ]
        let legalKinds: Set<String> = [
            "discovery_request", "discovery_response", "objection",
            "deposition_question", "deposition_answer",
        ]
        let genericKinds: Set<String> = ["paragraph", "list_item", "region", "email_body"]
        let producerNodes = try DocumentStructureNodeRecord.fetchAll(
            db,
            sql: "SELECT * FROM document_structure_nodes WHERE document_id = ?",
            arguments: [documentID]
        ).filter {
            recognizedKinds.contains($0.kind) && partIDsByRevisionID[$0.revisionID] != nil
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: producerNodes.map { ($0.id, $0) })
        let legalRangesByPart = Dictionary(grouping: producerNodes.filter {
            legalKinds.contains($0.kind) && $0.charStart != nil && $0.charEnd != nil
        }) { node in
            partIDsByRevisionID[node.revisionID] ?? ""
        }
        let candidates = producerNodes.filter { node in
            guard let partID = partIDsByRevisionID[node.revisionID],
                  partsByID[partID] != nil else {
                return false
            }
            let hasRange = node.charStart != nil && node.charEnd != nil
            let hasText = nonblank(node.textContent) != nil
            guard hasRange || hasText,
                  node.kind != "tracked_insertion",
                  node.kind != "tracked_deletion" else {
                return false
            }
            if genericKinds.contains(node.kind),
               let start = node.charStart,
               let end = node.charEnd,
               legalRangesByPart[partID]?.contains(where: {
                   guard let legalStart = $0.charStart, let legalEnd = $0.charEnd else {
                       return false
                   }
                   return start < legalEnd && legalStart < end
               }) == true {
                return false
            }
            return true
        }.sorted { lhs, rhs in
            let lhsPart = partOrder[partIDsByRevisionID[lhs.revisionID] ?? ""] ?? .max
            let rhsPart = partOrder[partIDsByRevisionID[rhs.revisionID] ?? ""] ?? .max
            if lhsPart != rhsPart { return lhsPart < rhsPart }
            if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
            if lhs.charStart != rhs.charStart {
                return (lhs.charStart ?? .max) < (rhs.charStart ?? .max)
            }
            return lhs.id < rhs.id
        }
        guard !candidates.isEmpty else {
            return shippingV1FallbackChunks(parts: parts)
        }

        let orderedEdges = try DocumentStructureEdgeRecord.fetchAll(
            db,
            sql: "SELECT * FROM document_structure_edges WHERE matter_id = ?",
            arguments: [matterID]
        ).filter { edge in
            guard let from = nodesByID[edge.fromNodeID],
                  let to = nodesByID[edge.toNodeID],
                  let fromPartID = partIDsByRevisionID[from.revisionID],
                  let toPartID = partIDsByRevisionID[to.revisionID] else {
                return false
            }
            return fromPartID == toPartID && from.revisionID == to.revisionID
        }.sorted {
            if $0.fromNodeID != $1.fromNodeID { return $0.fromNodeID < $1.fromNodeID }
            return $0.toNodeID < $1.toNodeID
        }

        var result: [StructuredChunkProjection] = []
        var consumed = Set<String>()
        for node in candidates where !consumed.contains(node.id) {
            guard let partID = partIDsByRevisionID[node.revisionID],
                  let part = partsByID[partID],
                  let primaryText = shippingNodeText(node, partText: part.normalizedText) else {
                continue
            }

            if let responseEdge = orderedEdges.first(where: {
                $0.kind == "responds_to" && $0.toNodeID == node.id
            }), let response = nodesByID[responseEdge.fromNodeID],
               let responsePartID = partIDsByRevisionID[response.revisionID],
               let responsePart = partsByID[responsePartID],
               let responseText = shippingNodeText(response, partText: responsePart.normalizedText) {
                let combined = primaryText + "\n" + responseText
                if combined.count <= shippingV2MaxChars {
                    result.append(structuredProjection(
                        index: result.count,
                        node: node,
                        partID: partID,
                        text: combined,
                        relatedEdges: [responseEdge]
                    ))
                } else {
                    result.append(structuredProjection(
                        index: result.count,
                        node: node,
                        partID: partID,
                        text: primaryText,
                        relatedEdges: [responseEdge]
                    ))
                    result.append(structuredProjection(
                        index: result.count,
                        node: response,
                        partID: responsePartID,
                        text: responseText,
                        relatedEdges: [responseEdge]
                    ))
                }
                consumed.formUnion([node.id, response.id])
                continue
            }

            if let referenceEdge = orderedEdges.first(where: {
                $0.kind == "references" && $0.toNodeID == node.id
            }), let use = nodesByID[referenceEdge.fromNodeID],
               let usePartID = partIDsByRevisionID[use.revisionID],
               let usePart = partsByID[usePartID],
               let useText = shippingNodeText(use, partText: usePart.normalizedText) {
                result.append(structuredProjection(
                    index: result.count,
                    node: node,
                    partID: partID,
                    text: primaryText + "\n" + useText,
                    relatedEdges: [referenceEdge]
                ))
                consumed.insert(node.id)
                continue
            }

            let headerEdges = orderedEdges.filter {
                $0.kind == "header_for" && $0.fromNodeID == node.id
            }.filter { edge in
                guard let header = nodesByID[edge.toNodeID],
                      let headerPartID = partIDsByRevisionID[header.revisionID],
                      let headerPart = partsByID[headerPartID] else {
                    return false
                }
                return shippingNodeText(header, partText: headerPart.normalizedText) != nil
            }
            let headers = headerEdges.compactMap { edge -> String? in
                guard let header = nodesByID[edge.toNodeID],
                      let headerPartID = partIDsByRevisionID[header.revisionID],
                      let headerPart = partsByID[headerPartID] else {
                    return nil
                }
                return shippingNodeText(header, partText: headerPart.normalizedText)
            }
            if !headers.isEmpty {
                result.append(structuredProjection(
                    index: result.count,
                    node: node,
                    partID: partID,
                    text: headers.joined(separator: "\n") + "\n" + primaryText,
                    relatedEdges: headerEdges
                ))
                consumed.insert(node.id)
                continue
            }

            result.append(structuredProjection(
                index: result.count,
                node: node,
                partID: partID,
                text: primaryText,
                relatedEdges: []
            ))
            consumed.insert(node.id)
        }
        return result
    }

    private static func structuredProjection(
        index: Int,
        node: DocumentStructureNodeRecord,
        partID: String,
        text: String,
        relatedEdges: [DocumentStructureEdgeRecord]
    ) -> StructuredChunkProjection {
        StructuredChunkProjection(
            chunkIndex: index,
            partID: partID,
            revisionID: node.revisionID,
            nodeID: node.id,
            unitKind: node.kind,
            charStart: node.charStart ?? 0,
            charEnd: node.charEnd ?? node.textContent?.count ?? 0,
            text: text,
            relatedStructureEdges: relatedEdges.enumerated().map { index, edge in
                MotionDraftStructureEdgeSnapshot(
                    edgeID: edge.id,
                    fromNodeID: edge.fromNodeID,
                    toNodeID: edge.toNodeID,
                    kind: edge.kind,
                    projectionOrder: index
                )
            }
        )
    }

    private static func shippingNodeText(
        _ node: DocumentStructureNodeRecord,
        partText: String
    ) -> String? {
        if let start = node.charStart, let end = node.charEnd {
            return exactCharacterSlice(partText, start: start, end: end).flatMap { value in
                nonblank(value) == nil ? nil : value
            }
        }
        return nonblank(node.textContent)
    }

    private static func shippingV1FallbackChunks(
        parts: [DocumentPagePartRecord]
    ) -> [StructuredChunkProjection] {
        var result: [StructuredChunkProjection] = []
        for part in parts {
            for range in shippingV1Ranges(part.normalizedText) {
                result.append(StructuredChunkProjection(
                    chunkIndex: result.count,
                    partID: part.id,
                    revisionID: part.currentRevisionID,
                    nodeID: nil,
                    unitKind: nil,
                    charStart: range.start,
                    charEnd: range.end,
                    text: range.text,
                    relatedStructureEdges: []
                ))
            }
        }
        return result
    }

    private struct ShippingTextRange {
        let start: Int
        let end: Int
        let text: String
    }

    private static func shippingV1Ranges(_ text: String) -> [ShippingTextRange] {
        let characters = Array(text)
        guard characters.contains(where: { !$0.isWhitespace }) else { return [] }
        var offsets: [(Int, Int)] = []
        var start = 0
        while start < characters.count {
            let hardEnd = min(start + shippingV2MaxChars, characters.count)
            var end = hardEnd
            if hardEnd < characters.count {
                let windowStart = max(hardEnd - shippingV2OverlapChars - 1, start + 1)
                end = preferredShippingBreak(
                    in: characters,
                    from: windowStart,
                    to: hardEnd
                ) ?? hardEnd
            }
            offsets.append((start, end))
            if end >= characters.count { break }
            start = max(end - shippingV2OverlapChars, start + 1)
        }
        return offsets.compactMap { start, end in
            let value = String(characters[start..<end])
            guard nonblank(value) != nil else { return nil }
            return ShippingTextRange(start: start, end: end, text: value)
        }
    }

    private static func preferredShippingBreak(
        in characters: [Character],
        from lower: Int,
        to upper: Int
    ) -> Int? {
        var lastParagraph: Int?
        var lastSpace: Int?
        var lastSentence: Int?
        var index = lower
        while index < upper {
            let character = characters[index]
            if character == "\n" {
                if index + 1 < upper, characters[index + 1] == "\n" {
                    lastParagraph = index + 2
                }
                lastSentence = index + 1
            } else if character == "." || character == "!" || character == "?" {
                if index + 1 < upper, characters[index + 1] == " " {
                    lastSentence = index + 1
                }
            } else if character == " " {
                lastSpace = index + 1
            }
            index += 1
        }
        return lastParagraph ?? lastSentence ?? lastSpace
    }

    private static func nonblank(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
