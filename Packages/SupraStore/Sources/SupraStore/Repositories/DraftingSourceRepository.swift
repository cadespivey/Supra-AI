import CryptoKit
import Foundation
import GRDB
import SupraCore

public struct MotionDraftAuthoritySelection: Codable, Equatable, Hashable, Sendable {
    public let authorityID: String
    public let groundKey: AuthorityReviewedPropositionGround

    public init(authorityID: String, groundKey: AuthorityReviewedPropositionGround) {
        self.authorityID = authorityID
        self.groundKey = groundKey
    }
}

public struct MotionDraftSnapshotRequest: Codable, Equatable, Sendable {
    public let matterID: String
    public let factChunkIDs: [String]
    public let authoritySelections: [MotionDraftAuthoritySelection]
    public let assistantProfileSettingKey: String
    public let firmStyleProfileSettingKey: String

    public init(
        matterID: String,
        factChunkIDs: [String],
        authoritySelections: [MotionDraftAuthoritySelection],
        assistantProfileSettingKey: String,
        firmStyleProfileSettingKey: String
    ) {
        self.matterID = matterID
        self.factChunkIDs = factChunkIDs
        self.authoritySelections = authoritySelections
        self.assistantProfileSettingKey = assistantProfileSettingKey
        self.firmStyleProfileSettingKey = firmStyleProfileSettingKey
    }
}

public struct MotionDraftSettingSnapshot: Codable, Equatable, Sendable {
    public let key: String
    public let valueJSON: String?
    public let valueSHA256: String
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
    public static let schemaVersion = 1

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
    case authorityNotFound(String)
    case authorityOutsideMatter(String)
    case authorityPropositionUnavailable(authorityID: String, reason: String)
    case auditMatterMismatch
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
        let facts = try request.factChunkIDs.map {
            try fact(chunkID: $0, matterID: request.matterID, db: db)
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
        guard !request.factChunkIDs.isEmpty else {
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
        for id in request.factChunkIDs {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MotionDraftSnapshotError.factNotFound(id)
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
        chunkID: String,
        matterID: String,
        db: Database
    ) throws -> MotionDraftFactSnapshot {
        guard let chunk = try DocumentChunkRecord.fetchOne(db, key: chunkID) else {
            throw MotionDraftSnapshotError.factNotFound(chunkID)
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
              let revision = try DocumentPartRevisionRecord.fetchOne(db, key: revisionID),
              revision.documentID == document.id,
              revision.partIndex == part.partIndex else {
            throw MotionDraftSnapshotError.factBindingInvalid(chunkID)
        }

        do {
            if let nodeID = nonblank(chunk.nodeID) {
                guard let node = try DocumentStructureNodeRecord.fetchOne(db, key: nodeID),
                      chunk.chunkerVersion == 2,
                      node.documentID == document.id,
                      node.revisionID == revision.id,
                      chunk.unitKind == node.kind,
                      (node.charStart ?? 0) == start,
                      (node.charEnd ?? node.textContent?.count ?? 0) == end else {
                    throw MotionDraftSnapshotError.factBindingInvalid(chunkID)
                }
                let nodes = try DocumentStructureNodeRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM document_structure_nodes WHERE document_id = ? AND revision_id = ?",
                    arguments: [document.id, revision.id]
                )
                var resolvedByID: [String: String] = [:]
                for candidate in nodes {
                    if let text = try StructureRepository.resolvedText(
                        node: candidate,
                        revisionText: revision.text
                    ), !text.isEmpty {
                        resolvedByID[candidate.id] = text
                    }
                }
                let nodeIDs = Set(nodes.map(\.id))
                let edges = try DocumentStructureEdgeRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM document_structure_edges WHERE matter_id = ?",
                    arguments: [matterID]
                ).filter {
                    nodeIDs.contains($0.fromNodeID) && nodeIDs.contains($0.toNodeID)
                }
                let allowedTexts = try allowedStructuredChunkTexts(
                    primary: node,
                    resolvedByID: resolvedByID,
                    edges: edges
                )
                guard allowedTexts.contains(chunk.normalizedText) else {
                    throw MotionDraftSnapshotError.factBindingInvalid(chunkID)
                }
            } else {
                guard exactCharacterSlice(revision.text, start: start, end: end) == chunk.normalizedText else {
                    throw MotionDraftSnapshotError.factBindingInvalid(chunkID)
                }
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
            sourceKind: chunk.sourceKind,
            pageIndex: chunk.pageIndex,
            pageLabel: chunk.pageLabel,
            sheetName: chunk.sheetName,
            cellRange: chunk.cellRange,
            emailPartPath: chunk.emailPartPath,
            charStart: start,
            charEnd: end,
            text: chunk.normalizedText,
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

    /// Mirrors the v2 chunker's edge priority and ordering using only immutable
    /// revision-bound structure rows. The chunker's configured maximum is not
    /// persisted, but it is clamped to at least 200 characters: a short
    /// request/response pair must therefore be combined, while a longer pair may
    /// legitimately be either split or combined under an injected configuration.
    private static func allowedStructuredChunkTexts(
        primary: DocumentStructureNodeRecord,
        resolvedByID: [String: String],
        edges: [DocumentStructureEdgeRecord]
    ) throws -> Set<String> {
        guard let primaryText = resolvedByID[primary.id] else {
            throw StructureRepositoryError.invalidTextContract(primary.id)
        }
        let ordered = edges.sorted {
            if $0.fromNodeID != $1.fromNodeID { return $0.fromNodeID < $1.fromNodeID }
            return $0.toNodeID < $1.toNodeID
        }

        if let responseEdge = ordered.first(where: {
            $0.kind == "responds_to" && $0.toNodeID == primary.id
        }), let responseText = resolvedByID[responseEdge.fromNodeID] {
            let combined = primaryText + "\n" + responseText
            return combined.count <= 200 ? [combined] : [primaryText, combined]
        }

        if let referenceEdge = ordered.first(where: {
            $0.kind == "references" && $0.toNodeID == primary.id
        }), let useText = resolvedByID[referenceEdge.fromNodeID] {
            return [primaryText + "\n" + useText]
        }

        let headers = ordered.filter {
            $0.kind == "header_for" && $0.fromNodeID == primary.id
        }.compactMap { resolvedByID[$0.toNodeID] }
        if !headers.isEmpty {
            return [headers.joined(separator: "\n") + "\n" + primaryText]
        }
        return [primaryText]
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
