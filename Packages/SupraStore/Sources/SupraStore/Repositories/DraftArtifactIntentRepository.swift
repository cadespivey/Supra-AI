import CryptoKit
import Foundation
import GRDB

public struct MotionDraftAuditComponentIdentity: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let version: String

    public init(id: String, version: String) {
        self.id = id
        self.version = version
    }
}

public enum MotionDraftAuditVerificationStatus: String, Codable, Sendable, Equatable {
    case passed
}

public enum MotionDraftAuditReceiptScope: String, Codable, Sendable, Equatable {
    case motionSelectedSourceReproductionAndStructure = "motion_selected_source_reproduction_and_structure"
}

public struct MotionDraftVerificationReceiptInput: Codable, Sendable, Equatable {
    public let status: MotionDraftAuditVerificationStatus
    public let scope: MotionDraftAuditReceiptScope
    public let supportedPropositionIDs: [String]
    public let verifierIdentity: MotionDraftAuditComponentIdentity
    public let gateIdentity: MotionDraftAuditComponentIdentity
    public let rendererIdentity: MotionDraftAuditComponentIdentity

    public init(
        status: MotionDraftAuditVerificationStatus,
        scope: MotionDraftAuditReceiptScope,
        supportedPropositionIDs: [String],
        verifierIdentity: MotionDraftAuditComponentIdentity,
        gateIdentity: MotionDraftAuditComponentIdentity,
        rendererIdentity: MotionDraftAuditComponentIdentity
    ) {
        self.status = status
        self.scope = scope
        self.supportedPropositionIDs = supportedPropositionIDs
        self.verifierIdentity = verifierIdentity
        self.gateIdentity = gateIdentity
        self.rendererIdentity = rendererIdentity
    }
}

/// Typed, content-free values supplied by the drafting layer. Store hashes the
/// canonical values itself and refuses producer or verification-scope drift.
public struct MotionDraftAuditInput: Sendable, Equatable {
    public let canonicalRequest: Data
    public let canonicalCaption: Data
    public let canonicalEffectiveStyle: Data
    public let groundContractIdentity: MotionDraftAuditComponentIdentity
    public let assemblerIdentity: MotionDraftAuditComponentIdentity
    public let verificationReceipt: MotionDraftVerificationReceiptInput

    public init(
        canonicalRequest: Data,
        canonicalCaption: Data,
        canonicalEffectiveStyle: Data,
        groundContractIdentity: MotionDraftAuditComponentIdentity,
        assemblerIdentity: MotionDraftAuditComponentIdentity,
        verificationReceipt: MotionDraftVerificationReceiptInput
    ) {
        self.canonicalRequest = canonicalRequest
        self.canonicalCaption = canonicalCaption
        self.canonicalEffectiveStyle = canonicalEffectiveStyle
        self.groundContractIdentity = groundContractIdentity
        self.assemblerIdentity = assemblerIdentity
        self.verificationReceipt = verificationReceipt
    }
}

public struct MotionDraftVerificationScope: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public static let exactSelectedBodyContract = "exact_selected_motion_body_v1"

    public let schemaVersion: Int
    public let kindID: String
    public let groundKeys: [String]
    public let factPropositionIDs: [String]
    public let authorityPropositionIDs: [String]
    public let bodyContract: String
}

/// Store-built content-free lineage. No public API accepts this envelope from a
/// caller; it is encoded only after Store validates the source snapshot,
/// producer identities, receipt scope, and actual artifact bytes.
public struct MotionDraftAuditLineage: Codable, Sendable, Equatable {
    public struct Fact: Codable, Sendable, Equatable {
        public let chunkID: String
        public let documentID: String
        public let partID: String
        public let revisionID: String
        public let nodeID: String?
        public let unitKind: String?
        public let chunkerVersion: Int
        public let charStart: Int
        public let charEnd: Int
        public let ocrConfidence: Double?
        public let boundingBoxesSHA256: String?
        public let relatedStructureEdges: [MotionDraftStructureEdgeSnapshot]
        public let revisionSHA256: String
        public let excerptSHA256: String

        init(_ source: MotionDraftFactSnapshot) {
            chunkID = source.chunkID
            documentID = source.documentID
            partID = source.partID
            revisionID = source.revisionID
            nodeID = source.nodeID
            unitKind = source.unitKind
            chunkerVersion = source.chunkerVersion
            charStart = source.charStart
            charEnd = source.charEnd
            ocrConfidence = source.ocrConfidence
            boundingBoxesSHA256 = source.boundingBoxesSHA256
            relatedStructureEdges = source.relatedStructureEdges
            revisionSHA256 = source.revisionSHA256
            excerptSHA256 = source.excerptSHA256
        }
    }

    public struct Authority: Codable, Sendable, Equatable {
        public let authorityID: String
        public let groundKey: String
        public let evidenceSchemaVersion: Int
        public let excerptByteStart: Int
        public let excerptByteLength: Int
        public let opinionSHA256: String
        public let excerptSHA256: String
        public let effectiveCitationSHA256: String
        public let courtSHA256: String
        public let bindingSHA256: String

        init(_ source: MotionDraftAuthoritySnapshot) {
            authorityID = source.authorityID
            groundKey = source.groundKey.rawValue
            evidenceSchemaVersion = source.evidenceSchemaVersion
            excerptByteStart = source.excerptByteStart
            excerptByteLength = source.excerptByteLength
            opinionSHA256 = source.opinionSHA256
            excerptSHA256 = source.excerptSHA256
            effectiveCitationSHA256 = source.effectiveCitationSHA256
            courtSHA256 = source.courtSHA256
            bindingSHA256 = source.bindingSHA256
        }
    }

    public let schemaVersion: Int
    public let kindID: String
    public let sourceSnapshotSHA256: String
    public let facts: [Fact]
    public let authorities: [Authority]
    public let groundKeys: [String]
    public let verificationScope: MotionDraftVerificationScope
    public let requestSHA256: String
    public let captionSHA256: String
    public let assistantProfileSHA256: String
    public let effectiveStyleSHA256: String
    public let groundContractIdentity: MotionDraftAuditComponentIdentity
    public let assemblerIdentity: MotionDraftAuditComponentIdentity
    public let verifierIdentity: MotionDraftAuditComponentIdentity
    public let gateIdentity: MotionDraftAuditComponentIdentity
    public let rendererIdentity: MotionDraftAuditComponentIdentity
    public let verificationReceiptSHA256: String
    public let verificationStatus: MotionDraftAuditVerificationStatus
    public let verificationReceiptScope: MotionDraftAuditReceiptScope
    public let outputFileName: String
    public let outputSHA256: String
    public let outputByteSize: Int
}

public enum DraftArtifactIntentError: Error, Equatable, Sendable {
    case matterNotFound
    case invalidArtifactKind
    case invalidFileName
    case invalidFormat
    case invalidOutput
    case invalidMotionInput
    case fileNameReserved
    case callerOwnedAuditEnvelopeRejected
    case intentNotFound
    case invalidIntentState
    case intentIntegrityInvalid
    case sourceSnapshotStale
    case installedArtifactMismatch
}

public final class DraftArtifactIntentRepository: @unchecked Sendable {
    public static let motionGroundContractIdentity = MotionDraftAuditComponentIdentity(
        id: "supra.drafting.motion-ground-contract",
        version: "4"
    )
    public static let motionAssemblerIdentity = MotionDraftAuditComponentIdentity(
        id: "supra.drafting.motion-to-dismiss-assembler",
        version: "3"
    )
    public static let motionVerifierIdentity = MotionDraftAuditComponentIdentity(
        id: "supra.drafting.draft-verifier",
        version: "6"
    )
    public static let motionGateIdentity = MotionDraftAuditComponentIdentity(
        id: "supra.drafting.pre-file-gate",
        version: "1"
    )
    public static let motionRendererIdentity = MotionDraftAuditComponentIdentity(
        id: "supra.exports.composite-renderer",
        version: "1"
    )

    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func prepareGenericIntent(
        matterID: String,
        artifactKind: DraftArtifactIntentKind,
        format: DraftArtifactIntentFormat,
        fileName: String,
        output: Data,
        id: String = UUID().uuidString,
        createdAt: Date = Date()
    ) throws -> DraftArtifactIntentRecord {
        let expectedFormat: DraftArtifactIntentFormat
        switch artifactKind {
        case .noticeAppearance, .letterDemand:
            expectedFormat = .docx
        case .customDescription:
            expectedFormat = .markdown
        case .motionToDismiss:
            throw DraftArtifactIntentError.invalidArtifactKind
        }
        guard format == expectedFormat else { throw DraftArtifactIntentError.invalidFormat }
        try Self.validateCommon(
            artifactKind: artifactKind.rawValue,
            format: format,
            fileName: fileName,
            output: output
        )
        let metadata = GenericDraftAuditLineage(
            schemaVersion: 1,
            kindID: artifactKind.rawValue,
            format: format.rawValue,
            outputFileName: fileName,
            outputSHA256: Self.sha256(output),
            outputByteSize: output.count
        )
        let metadataJSON = try Self.jsonString(metadata)
        let record = DraftArtifactIntentRecord(
            id: id,
            matterID: matterID,
            artifactKind: artifactKind.rawValue,
            format: format,
            fileName: fileName,
            outputSHA256: metadata.outputSHA256,
            outputByteSize: metadata.outputByteSize,
            auditMetadataJSON: metadataJSON,
            auditMetadataSHA256: Self.sha256(Data(metadataJSON.utf8)),
            createdAt: createdAt
        )
        return try writer.write { db in
            try Self.requireMatter(matterID, db: db)
            try Self.reserve(fileName: fileName, matterID: matterID, db: db)
            try record.insert(db)
            return record
        }
    }

    @discardableResult
    public func prepareMotionIntent(
        snapshot: MotionDraftStoreSnapshot,
        fileName: String,
        output: Data,
        auditInput: MotionDraftAuditInput,
        id: String = UUID().uuidString,
        createdAt: Date = Date()
    ) throws -> DraftArtifactIntentRecord {
        try Self.validateCommon(
            artifactKind: MotionDraftAuditEnvelope.kindID,
            format: .docx,
            fileName: fileName,
            output: output
        )
        guard !auditInput.canonicalRequest.isEmpty,
              !auditInput.canonicalCaption.isEmpty,
              !auditInput.canonicalEffectiveStyle.isEmpty,
              auditInput.groundContractIdentity == Self.motionGroundContractIdentity,
              auditInput.assemblerIdentity == Self.motionAssemblerIdentity,
              auditInput.verificationReceipt.status == .passed,
              auditInput.verificationReceipt.scope == .motionSelectedSourceReproductionAndStructure,
              auditInput.verificationReceipt.verifierIdentity == Self.motionVerifierIdentity,
              auditInput.verificationReceipt.gateIdentity == Self.motionGateIdentity,
              auditInput.verificationReceipt.rendererIdentity == Self.motionRendererIdentity else {
            throw DraftArtifactIntentError.invalidMotionInput
        }

        return try writer.write { db in
            let current: MotionDraftStoreSnapshot
            do {
                current = try DraftingSourceRepository.capture(snapshot.request, db: db)
            } catch {
                throw DraftArtifactIntentError.sourceSnapshotStale
            }
            guard current.fingerprintSHA256 == snapshot.fingerprintSHA256 else {
                throw DraftArtifactIntentError.sourceSnapshotStale
            }

            let factPropositionIDs = current.facts.map { "motion.fact.\($0.chunkID)" }
            let authorityPropositionIDs = current.authorities.map { "motion.authority.\($0.authorityID)" }
            guard auditInput.verificationReceipt.supportedPropositionIDs
                    == factPropositionIDs + authorityPropositionIDs else {
                throw DraftArtifactIntentError.invalidMotionInput
            }
            var groundKeys: [String] = []
            for source in current.authorities where !groundKeys.contains(source.groundKey.rawValue) {
                groundKeys.append(source.groundKey.rawValue)
            }
            let scope = MotionDraftVerificationScope(
                schemaVersion: MotionDraftVerificationScope.schemaVersion,
                kindID: MotionDraftAuditEnvelope.kindID,
                groundKeys: groundKeys,
                factPropositionIDs: factPropositionIDs,
                authorityPropositionIDs: authorityPropositionIDs,
                bodyContract: MotionDraftVerificationScope.exactSelectedBodyContract
            )
            let lineage = MotionDraftAuditLineage(
                schemaVersion: MotionDraftAuditEnvelope.schemaVersion,
                kindID: MotionDraftAuditEnvelope.kindID,
                sourceSnapshotSHA256: current.fingerprintSHA256,
                facts: current.facts.map(MotionDraftAuditLineage.Fact.init),
                authorities: current.authorities.map(MotionDraftAuditLineage.Authority.init),
                groundKeys: groundKeys,
                verificationScope: scope,
                requestSHA256: Self.sha256(auditInput.canonicalRequest),
                captionSHA256: Self.sha256(auditInput.canonicalCaption),
                assistantProfileSHA256: current.assistantProfile.valueSHA256,
                effectiveStyleSHA256: Self.sha256(auditInput.canonicalEffectiveStyle),
                groundContractIdentity: auditInput.groundContractIdentity,
                assemblerIdentity: auditInput.assemblerIdentity,
                verifierIdentity: auditInput.verificationReceipt.verifierIdentity,
                gateIdentity: auditInput.verificationReceipt.gateIdentity,
                rendererIdentity: auditInput.verificationReceipt.rendererIdentity,
                verificationReceiptSHA256: Self.sha256(try Self.jsonData(auditInput.verificationReceipt)),
                verificationStatus: auditInput.verificationReceipt.status,
                verificationReceiptScope: auditInput.verificationReceipt.scope,
                outputFileName: fileName,
                outputSHA256: Self.sha256(output),
                outputByteSize: output.count
            )
            let requestJSON = try Self.jsonString(current.request)
            let metadataJSON = try Self.jsonString(lineage)
            let record = DraftArtifactIntentRecord(
                id: id,
                matterID: current.request.matterID,
                artifactKind: MotionDraftAuditEnvelope.kindID,
                format: .docx,
                fileName: fileName,
                outputSHA256: lineage.outputSHA256,
                outputByteSize: lineage.outputByteSize,
                auditMetadataJSON: metadataJSON,
                auditMetadataSHA256: Self.sha256(Data(metadataJSON.utf8)),
                motionSnapshotRequestJSON: requestJSON,
                motionSnapshotSHA256: current.fingerprintSHA256,
                createdAt: createdAt
            )
            try Self.reserve(fileName: fileName, matterID: current.request.matterID, db: db)
            try record.insert(db)
            return record
        }
    }

    public func intent(id: String) throws -> DraftArtifactIntentRecord? {
        try writer.read { db in
            try DraftArtifactIntentRecord.fetchOne(db, key: id)
        }
    }

    public func pendingIntents(limit: Int = 500) throws -> [DraftArtifactIntentRecord] {
        let bounded = min(max(limit, 1), 2_000)
        return try writer.read { db in
            try DraftArtifactIntentRecord.fetchAll(
                db,
                sql: "SELECT * FROM draft_artifact_intents WHERE status = ? ORDER BY created_at, id LIMIT ?",
                arguments: [DraftArtifactIntentStatus.prepared.rawValue, bounded]
            )
        }
    }

    public func auditEventPreview(intentID: String) throws -> AuditEventRecord {
        try writer.read { db in
            guard let record = try DraftArtifactIntentRecord.fetchOne(db, key: intentID) else {
                throw DraftArtifactIntentError.intentNotFound
            }
            guard record.status == DraftArtifactIntentStatus.prepared.rawValue else {
                throw DraftArtifactIntentError.invalidIntentState
            }
            _ = try Self.validateStoredRecord(record)
            return Self.auditEvent(for: record)
        }
    }

    /// Appends the fixed Store-built audit row and transitions the intent in one
    /// SQLite transaction. Motion source revalidation shares that transaction.
    public func finalizeIntent(id: String, installedOutput: Data) throws {
        try writer.write { db in
            guard let record = try DraftArtifactIntentRecord.fetchOne(db, key: id) else {
                throw DraftArtifactIntentError.intentNotFound
            }
            let isCompleted = record.status == DraftArtifactIntentStatus.completed.rawValue
            guard isCompleted || record.status == DraftArtifactIntentStatus.prepared.rawValue else {
                throw DraftArtifactIntentError.invalidIntentState
            }
            let storedLineage = try Self.validateStoredRecord(record)
            guard installedOutput.count == record.outputByteSize,
                  Self.sha256(installedOutput) == record.outputSHA256 else {
                throw DraftArtifactIntentError.installedArtifactMismatch
            }
            let event = Self.auditEvent(for: record)
            if isCompleted {
                guard let existing = try AuditEventRecord.fetchOne(db, key: event.id),
                      Self.auditEvent(existing, exactlyMatches: event) else {
                    throw DraftArtifactIntentError.intentIntegrityInvalid
                }
                // Completion already atomically bound this event and output.
                // Do not revalidate mutable motion sources on an idempotent retry;
                // they may legitimately change after publication.
                return
            }
            if case let .motion(lineage) = storedLineage {
                guard let requestJSON = record.motionSnapshotRequestJSON else {
                    throw DraftArtifactIntentError.intentIntegrityInvalid
                }
                guard let expected = record.motionSnapshotSHA256,
                      let data = requestJSON.data(using: .utf8),
                      let request = try? JSONDecoder().decode(MotionDraftSnapshotRequest.self, from: data),
                      (try? Self.jsonString(request)) == requestJSON,
                      request.matterID == record.matterID else {
                    throw DraftArtifactIntentError.intentIntegrityInvalid
                }
                let current: MotionDraftStoreSnapshot
                do {
                    current = try DraftingSourceRepository.capture(request, db: db)
                } catch {
                    throw DraftArtifactIntentError.sourceSnapshotStale
                }
                guard current.fingerprintSHA256 == expected else {
                    throw DraftArtifactIntentError.sourceSnapshotStale
                }
                try Self.validateMotionLineage(
                    lineage,
                    record: record,
                    current: current
                )
            }
            // A prepared intent cannot legitimately have crossed this atomic
            // insert/transition boundary already. Any occupant of the
            // deterministic ID is a collision, even if its fields happen to
            // match the preview, and must fail closed.
            guard try AuditEventRecord.fetchOne(db, key: event.id) == nil else {
                throw DraftArtifactIntentError.intentIntegrityInvalid
            }
            try event.insert(db)
            let now = Date()
            try db.execute(
                sql: "UPDATE draft_artifact_intents SET status = ?, updated_at = ?, terminal_at = ? WHERE id = ?",
                arguments: [DraftArtifactIntentStatus.completed.rawValue, now, now, id]
            )
        }
    }

    public func abortIntent(id: String) throws {
        try transitionPreparedIntent(id: id, to: .aborted)
    }

    public func markRecoveryRequired(id: String) throws {
        try writer.write { db in
            guard let record = try DraftArtifactIntentRecord.fetchOne(db, key: id) else {
                throw DraftArtifactIntentError.intentNotFound
            }
            guard record.status == DraftArtifactIntentStatus.prepared.rawValue else { return }
            let now = Date()
            try db.execute(
                sql: "UPDATE draft_artifact_intents SET status = ?, updated_at = ?, terminal_at = ? WHERE id = ?",
                arguments: [DraftArtifactIntentStatus.recoveryRequired.rawValue, now, now, id]
            )
            if try RemediationRecoveryItemRecord.fetchOne(
                db,
                sql: "SELECT * FROM remediation_recovery_items WHERE kind = ? AND related_table = ? AND related_id = ?",
                arguments: [
                    RemediationRecoveryKind.interruptedDraftArtifact.rawValue,
                    DraftArtifactIntentRecord.databaseTableName,
                    record.id,
                ]
            ) == nil {
                let item = RemediationRecoveryItemRecord(
                    kind: .interruptedDraftArtifact,
                    matterID: record.matterID,
                    relatedTable: DraftArtifactIntentRecord.databaseTableName,
                    relatedID: record.id,
                    createdAt: now
                )
                try item.insert(db)
            }
        }
    }

    private func transitionPreparedIntent(id: String, to status: DraftArtifactIntentStatus) throws {
        try writer.write { db in
            guard let record = try DraftArtifactIntentRecord.fetchOne(db, key: id) else {
                throw DraftArtifactIntentError.intentNotFound
            }
            guard record.status == DraftArtifactIntentStatus.prepared.rawValue else { return }
            let now = Date()
            try db.execute(
                sql: "UPDATE draft_artifact_intents SET status = ?, updated_at = ?, terminal_at = ? WHERE id = ?",
                arguments: [status.rawValue, now, now, id]
            )
        }
    }

    private static func validateCommon(
        artifactKind: String,
        format: DraftArtifactIntentFormat,
        fileName: String,
        output: Data
    ) throws {
        let kind = artifactKind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty, kind.utf8.count <= 100 else {
            throw DraftArtifactIntentError.invalidArtifactKind
        }
        guard !fileName.isEmpty,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              !fileName.contains("/"),
              !fileName.contains("\\"),
              !fileName.hasPrefix("."),
              fileName.utf8.count <= 255 else {
            throw DraftArtifactIntentError.invalidFileName
        }
        let expectedExtension = format == .docx ? "docx" : "md"
        guard URL(fileURLWithPath: fileName).pathExtension.lowercased() == expectedExtension else {
            throw DraftArtifactIntentError.invalidFormat
        }
        guard !output.isEmpty else { throw DraftArtifactIntentError.invalidOutput }
    }

    private static func requireMatter(_ matterID: String, db: Database) throws {
        guard let matter = try MatterRecord.fetchOne(db, key: matterID), matter.deletedAt == nil else {
            throw DraftArtifactIntentError.matterNotFound
        }
    }

    private static func reserve(fileName: String, matterID: String, db: Database) throws {
        let existing = try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM draft_artifact_intents WHERE matter_id = ? AND file_name = ? AND status = ? LIMIT 1",
            arguments: [matterID, fileName, DraftArtifactIntentStatus.prepared.rawValue]
        )
        guard existing == nil else { throw DraftArtifactIntentError.fileNameReserved }
    }

    private enum StoredLineage {
        case generic(GenericDraftAuditLineage)
        case motion(MotionDraftAuditLineage)
    }

    private static func validateStoredRecord(
        _ record: DraftArtifactIntentRecord
    ) throws -> StoredLineage {
        guard let format = DraftArtifactIntentFormat(rawValue: record.format),
              record.outputByteSize > 0,
              isSHA256(record.outputSHA256),
              isSHA256(record.auditMetadataSHA256),
              sha256(Data(record.auditMetadataJSON.utf8)) == record.auditMetadataSHA256,
              record.motionSnapshotRequestJSON == nil
                ? record.motionSnapshotSHA256 == nil
                : record.motionSnapshotSHA256.map(isSHA256) == true else {
            throw DraftArtifactIntentError.intentIntegrityInvalid
        }
        try validateCommon(
            artifactKind: record.artifactKind,
            format: format,
            fileName: record.fileName,
            output: Data(repeating: 0, count: 1)
        )
        let data = Data(record.auditMetadataJSON.utf8)
        if record.motionSnapshotRequestJSON != nil {
            guard record.artifactKind == DraftArtifactIntentKind.motionToDismiss.rawValue,
                  format == .docx,
                  let lineage = try? JSONDecoder().decode(MotionDraftAuditLineage.self, from: data),
                  (try? jsonString(lineage)) == record.auditMetadataJSON,
                  lineage.schemaVersion == MotionDraftAuditEnvelope.schemaVersion,
                  lineage.kindID == DraftArtifactIntentKind.motionToDismiss.rawValue,
                  lineage.sourceSnapshotSHA256 == record.motionSnapshotSHA256,
                  lineage.groundContractIdentity == motionGroundContractIdentity,
                  lineage.assemblerIdentity == motionAssemblerIdentity,
                  lineage.verifierIdentity == motionVerifierIdentity,
                  lineage.gateIdentity == motionGateIdentity,
                  lineage.rendererIdentity == motionRendererIdentity,
                  lineage.verificationStatus == .passed,
                  lineage.verificationReceiptScope == .motionSelectedSourceReproductionAndStructure,
                  lineage.outputFileName == record.fileName,
                  lineage.outputSHA256 == record.outputSHA256,
                  lineage.outputByteSize == record.outputByteSize,
                  [
                      lineage.sourceSnapshotSHA256,
                      lineage.requestSHA256,
                      lineage.captionSHA256,
                      lineage.assistantProfileSHA256,
                      lineage.effectiveStyleSHA256,
                      lineage.verificationReceiptSHA256,
                      lineage.outputSHA256,
                  ].allSatisfy(isSHA256) else {
                throw DraftArtifactIntentError.intentIntegrityInvalid
            }
            return .motion(lineage)
        }

        guard let kind = DraftArtifactIntentKind(rawValue: record.artifactKind),
              kind != .motionToDismiss,
              ((kind == .customDescription && format == .markdown)
                || ([DraftArtifactIntentKind.noticeAppearance, .letterDemand].contains(kind) && format == .docx)),
              let lineage = try? JSONDecoder().decode(GenericDraftAuditLineage.self, from: data),
              (try? jsonString(lineage)) == record.auditMetadataJSON,
              lineage.schemaVersion == 1,
              lineage.kindID == record.artifactKind,
              lineage.format == record.format,
              lineage.outputFileName == record.fileName,
              lineage.outputSHA256 == record.outputSHA256,
              lineage.outputByteSize == record.outputByteSize else {
            throw DraftArtifactIntentError.intentIntegrityInvalid
        }
        return .generic(lineage)
    }

    private static func validateMotionLineage(
        _ lineage: MotionDraftAuditLineage,
        record: DraftArtifactIntentRecord,
        current: MotionDraftStoreSnapshot
    ) throws {
        var groundKeys: [String] = []
        for source in current.authorities where !groundKeys.contains(source.groundKey.rawValue) {
            groundKeys.append(source.groundKey.rawValue)
        }
        let factPropositionIDs = current.facts.map { "motion.fact.\($0.chunkID)" }
        let authorityPropositionIDs = current.authorities.map { "motion.authority.\($0.authorityID)" }
        let expectedReceipt = MotionDraftVerificationReceiptInput(
            status: lineage.verificationStatus,
            scope: lineage.verificationReceiptScope,
            supportedPropositionIDs: factPropositionIDs + authorityPropositionIDs,
            verifierIdentity: lineage.verifierIdentity,
            gateIdentity: lineage.gateIdentity,
            rendererIdentity: lineage.rendererIdentity
        )
        let expectedReceiptSHA256 = sha256(try jsonData(expectedReceipt))
        guard lineage.sourceSnapshotSHA256 == current.fingerprintSHA256,
              lineage.sourceSnapshotSHA256 == record.motionSnapshotSHA256,
              lineage.facts == current.facts.map(MotionDraftAuditLineage.Fact.init),
              lineage.authorities == current.authorities.map(MotionDraftAuditLineage.Authority.init),
              lineage.groundKeys == groundKeys,
              lineage.assistantProfileSHA256 == current.assistantProfile.valueSHA256,
              lineage.verificationScope.schemaVersion == MotionDraftVerificationScope.schemaVersion,
              lineage.verificationScope.kindID == MotionDraftAuditEnvelope.kindID,
              lineage.verificationScope.groundKeys == groundKeys,
              lineage.verificationScope.factPropositionIDs == factPropositionIDs,
              lineage.verificationScope.authorityPropositionIDs == authorityPropositionIDs,
              lineage.verificationScope.bodyContract == MotionDraftVerificationScope.exactSelectedBodyContract,
              lineage.verificationReceiptSHA256 == expectedReceiptSHA256 else {
            throw DraftArtifactIntentError.intentIntegrityInvalid
        }
    }

    private static func auditEvent(for record: DraftArtifactIntentRecord) -> AuditEventRecord {
        AuditEventRecord(
            id: "draft-artifact-\(record.id)",
            matterID: record.matterID,
            timestamp: record.createdAt,
            eventType: "draft_generated",
            actor: "user",
            summary: "Generated \(record.artifactKind) draft (\(record.fileName))",
            relatedTable: MatterRecord.databaseTableName,
            relatedID: record.matterID,
            metadataJSON: record.auditMetadataJSON
        )
    }

    private static func auditEvent(
        _ lhs: AuditEventRecord,
        exactlyMatches rhs: AuditEventRecord
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.matterID == rhs.matterID
            && lhs.timestamp == rhs.timestamp
            && lhs.eventType == rhs.eventType
            && lhs.actor == rhs.actor
            && lhs.summary == rhs.summary
            && lhs.relatedTable == rhs.relatedTable
            && lhs.relatedID == rhs.relatedID
            && lhs.metadataJSON == rhs.metadataJSON
    }

    private static func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try jsonData(value), as: UTF8.self)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private struct GenericDraftAuditLineage: Codable {
        let schemaVersion: Int
        let kindID: String
        let format: String
        let outputFileName: String
        let outputSHA256: String
        let outputByteSize: Int
    }
}
