import Foundation
import GRDB
import SupraCore

public final class StructuredOutputRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func createOutput(
        matterID: String,
        title: String,
        outputType: StructuredOutputType,
        chatID: String? = nil,
        researchSessionID: String? = nil,
        status: StructuredOutputStatus = .draft
    ) throws -> StructuredOutputRecord {
        let title = try Self.requireNonEmpty(title, fieldName: "title")
        return try writer.write { db in
            let now = Date()
            let record = StructuredOutputRecord(
                matterID: matterID,
                chatID: chatID,
                researchSessionID: researchSessionID,
                title: title,
                outputType: outputType.rawValue,
                status: status.rawValue,
                createdAt: now,
                updatedAt: now
            )
            try record.insert(db)
            return record
        }
    }

    /// Appends a version. Pass `versionIndex: nil` (the default) to let the next
    /// index be computed atomically inside the write transaction — this avoids the
    /// read-then-write race where two appends compute the same next index from a
    /// separate read. An explicit index is still honored for callers that need it.
    @discardableResult
    public func createVersion(
        structuredOutputID: String,
        versionIndex: Int? = nil,
        contentMarkdown: String,
        requiredSections: [String],
        presentSections: [String],
        missingSections: [String],
        parentVersionID: String? = nil,
        repairReason: String? = nil,
        generationSessionID: String? = nil,
        verificationStatus: OutputVerificationStatus = .legacyUnverified,
        verificationVersion: String? = nil,
        verificationResults: [PropositionSupportResult]? = nil,
        verifiedAt: Date? = nil,
        sourceSetID: String? = nil,
        promptBuilderVersion: String? = nil,
        assuranceState: OutputAssuranceState? = nil,
        outputStatus: StructuredOutputStatus? = nil,
        makeActive: Bool = true
    ) throws -> StructuredOutputVersionRecord {
        let requiredSectionsJSON = try JSONCoding.encode(requiredSections)
        let presentSectionsJSON = try JSONCoding.encode(presentSections)
        let missingSectionsJSON = try JSONCoding.encode(missingSections)
        let verificationJSON = try verificationResults.map(JSONCoding.encode)
        let normalizedVerificationVersion = verificationVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPromptBuilderVersion = promptBuilderVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAssurance = assuranceState ?? Self.defaultAssurance(for: verificationStatus)

        if verificationStatus == .allSupported {
            guard let normalizedVerificationVersion, !normalizedVerificationVersion.isEmpty else {
                throw StructuredOutputRepositoryError.verificationVersionRequired
            }
            guard let verificationResults,
                  !verificationResults.isEmpty,
                  verificationResults.allSatisfy({ $0.status == .supported })
            else {
                throw StructuredOutputRepositoryError.allSupportedResultRequired
            }
        }
        if outputStatus == .complete {
            guard verificationStatus == .allSupported else {
                throw StructuredOutputRepositoryError.completeStatusRequiresAllSupportedVerification
            }
            guard Self.supportsCompleteStatus(resolvedAssurance) else {
                throw StructuredOutputRepositoryError.completeStatusRequiresSupportedAssurance
            }
        }

        return try writer.write { db in
            let now = Date()
            let resolvedVerifiedAt = verificationStatus == .legacyUnverified ? verifiedAt : (verifiedAt ?? now)
            let resolvedIndex = try versionIndex ?? (Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(version_index), 0) + 1 FROM structured_output_versions WHERE structured_output_id = ?",
                arguments: [structuredOutputID]
            ) ?? 1)
            let record = StructuredOutputVersionRecord(
                structuredOutputID: structuredOutputID,
                versionIndex: resolvedIndex,
                parentVersionID: parentVersionID,
                contentMarkdown: contentMarkdown,
                requiredSectionsJSON: requiredSectionsJSON,
                presentSectionsJSON: presentSectionsJSON,
                missingSectionsJSON: missingSectionsJSON,
                repairReason: repairReason,
                generationSessionID: generationSessionID,
                verificationStatus: verificationStatus.rawValue,
                verificationVersion: normalizedVerificationVersion,
                verificationJSON: verificationJSON,
                verifiedAt: resolvedVerifiedAt,
                promptBuilderVersion: normalizedPromptBuilderVersion,
                assuranceState: resolvedAssurance.rawValue,
                createdAt: now,
                updatedAt: now
            )
            try record.insert(db)

            if let sourceSetID {
                try db.execute(
                    sql: """
                    UPDATE document_source_sets
                    SET structured_output_version_id = ?, status = ?
                    WHERE id = ?
                      AND structured_output_version_id IS NULL
                      AND status = ?
                      AND matter_id = (
                          SELECT matter_id FROM structured_outputs WHERE id = ?
                      )
                    """,
                    arguments: [
                        record.id,
                        DocumentSourceSetStatus.attached.rawValue,
                        sourceSetID,
                        DocumentSourceSetStatus.pending.rawValue,
                        structuredOutputID,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw StructuredOutputRepositoryError.sourceSetUnavailable(sourceSetID)
                }
                try db.execute(
                    sql: """
                    UPDATE document_output_sources
                    SET structured_output_version_id = ?
                    WHERE source_set_id = ?
                    """,
                    arguments: [record.id, sourceSetID]
                )
            }

            if makeActive {
                try db.execute(
                    sql: """
                    UPDATE structured_outputs
                    SET active_version_id = ?,
                        status = COALESCE(?, status),
                        updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [record.id, outputStatus?.rawValue, now, structuredOutputID]
                )
            }
            return record
        }
    }

    /// Creates an optional new output, its source set and source rows, and the
    /// first/next version as one database transaction. This is the strong write
    /// boundary for generated document artifacts: a version failure cannot
    /// leave a draft output or pending provenance behind.
    @discardableResult
    public func createVersionWithSourceSetAtomically(
        structuredOutputID: String,
        newOutput: StructuredOutputRecord?,
        sourceSet: DocumentSourceSetRecord,
        outputSources: [DocumentOutputSourceRecord],
        contentMarkdown: String,
        verificationStatus: OutputVerificationStatus,
        verificationVersion: String,
        verificationResults: [PropositionSupportResult],
        outputStatus: StructuredOutputStatus,
        corpusAnalysisRunID: String? = nil,
        generationSessionID: String? = nil,
        promptBuilderVersion: String? = nil,
        assuranceState: OutputAssuranceState? = nil
    ) throws -> StructuredOutputVersionRecord {
        let requiredSectionsJSON = try JSONCoding.encode([String]())
        let verificationJSON = try JSONCoding.encode(verificationResults)
        let normalizedVerificationVersion = verificationVersion
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPromptBuilderVersion = promptBuilderVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if verificationStatus == .allSupported {
            guard !normalizedVerificationVersion.isEmpty else {
                throw StructuredOutputRepositoryError.verificationVersionRequired
            }
            guard !verificationResults.isEmpty,
                  verificationResults.allSatisfy({ $0.status == .supported })
            else {
                throw StructuredOutputRepositoryError.allSupportedResultRequired
            }
        }
        if let newOutput {
            _ = try Self.requireNonEmpty(newOutput.title, fieldName: "title")
            guard newOutput.id == structuredOutputID,
                  newOutput.activeVersionID == nil,
                  newOutput.status == StructuredOutputStatus.draft.rawValue,
                  newOutput.deletedAt == nil
            else {
                throw StructuredOutputRepositoryError.outputUnavailable(structuredOutputID)
            }
        }
        guard sourceSet.structuredOutputVersionID == nil,
              sourceSet.status == DocumentSourceSetStatus.pending.rawValue,
              outputSources.allSatisfy({
                  $0.sourceSetID == sourceSet.id && $0.structuredOutputVersionID == nil
              })
        else {
            throw StructuredOutputRepositoryError.sourceSetUnavailable(sourceSet.id)
        }

        return try writer.write { db in
            let output: StructuredOutputRecord
            if let newOutput {
                try newOutput.insert(db)
                output = newOutput
            } else {
                guard let existing = try StructuredOutputRecord.fetchOne(db, key: structuredOutputID),
                      existing.deletedAt == nil
                else {
                    throw StructuredOutputRepositoryError.outputUnavailable(structuredOutputID)
                }
                output = existing
            }
            guard output.matterID == sourceSet.matterID else {
                throw StructuredOutputRepositoryError.sourceSetUnavailable(sourceSet.id)
            }
            var corpusRun: CorpusAnalysisRunRecord?
            if let corpusAnalysisRunID {
                guard let run = try CorpusAnalysisRunRecord.fetchOne(db, key: corpusAnalysisRunID),
                      run.matterID == output.matterID,
                      run.status == CorpusAnalysisRunStatus.persisted.rawValue,
                      run.structuredOutputVersionID == nil else {
                    throw StructuredOutputRepositoryError.corpusRunUnavailable(corpusAnalysisRunID)
                }
                corpusRun = run
            }
            let resolvedAssurance = assuranceState
                ?? corpusRun.flatMap { $0.assuranceState.flatMap(OutputAssuranceState.init(rawValue:)) }
                ?? Self.defaultAssurance(for: verificationStatus)
            if outputStatus == .complete {
                guard verificationStatus == .allSupported else {
                    throw StructuredOutputRepositoryError.completeStatusRequiresAllSupportedVerification
                }
                guard Self.supportsCompleteStatus(resolvedAssurance) else {
                    throw StructuredOutputRepositoryError.completeStatusRequiresSupportedAssurance
                }
            }

            try sourceSet.insert(db)
            for source in outputSources {
                try source.insert(db)
            }

            let now = Date()
            let versionIndex = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(version_index), 0) + 1 FROM structured_output_versions WHERE structured_output_id = ?",
                arguments: [structuredOutputID]
            ) ?? 1
            let parentVersionID = try String.fetchOne(
                db,
                sql: """
                SELECT id FROM structured_output_versions
                WHERE structured_output_id = ?
                ORDER BY version_index DESC LIMIT 1
                """,
                arguments: [structuredOutputID]
            )
            let version = StructuredOutputVersionRecord(
                structuredOutputID: structuredOutputID,
                versionIndex: versionIndex,
                parentVersionID: parentVersionID,
                contentMarkdown: contentMarkdown,
                requiredSectionsJSON: requiredSectionsJSON,
                presentSectionsJSON: requiredSectionsJSON,
                missingSectionsJSON: requiredSectionsJSON,
                generationSessionID: generationSessionID,
                verificationStatus: verificationStatus.rawValue,
                verificationVersion: normalizedVerificationVersion,
                verificationJSON: verificationJSON,
                verifiedAt: now,
                promptBuilderVersion: normalizedPromptBuilderVersion,
                assuranceState: resolvedAssurance.rawValue,
                createdAt: now,
                updatedAt: now
            )
            try version.insert(db)

            try db.execute(
                sql: """
                UPDATE document_source_sets
                SET structured_output_version_id = ?, status = ?
                WHERE id = ?
                  AND structured_output_version_id IS NULL
                  AND status = ?
                  AND matter_id = ?
                """,
                arguments: [
                    version.id,
                    DocumentSourceSetStatus.attached.rawValue,
                    sourceSet.id,
                    DocumentSourceSetStatus.pending.rawValue,
                    output.matterID,
                ]
            )
            guard db.changesCount == 1 else {
                throw StructuredOutputRepositoryError.sourceSetUnavailable(sourceSet.id)
            }
            try db.execute(
                sql: """
                UPDATE document_output_sources
                SET structured_output_version_id = ?
                WHERE source_set_id = ?
                """,
                arguments: [version.id, sourceSet.id]
            )
            try db.execute(
                sql: """
                UPDATE structured_outputs
                SET active_version_id = ?, status = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [version.id, outputStatus.rawValue, now, structuredOutputID]
            )
            guard db.changesCount == 1 else {
                throw StructuredOutputRepositoryError.outputUnavailable(structuredOutputID)
            }
            if let corpusAnalysisRunID {
                try db.execute(
                    sql: """
                    UPDATE corpus_analysis_runs
                    SET structured_output_version_id = ?
                    WHERE id = ?
                      AND matter_id = ?
                      AND status = ?
                      AND structured_output_version_id IS NULL
                    """,
                    arguments: [
                        version.id,
                        corpusAnalysisRunID,
                        output.matterID,
                        CorpusAnalysisRunStatus.persisted.rawValue,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw StructuredOutputRepositoryError.corpusRunUnavailable(corpusAnalysisRunID)
                }
            }
            return version
        }
    }

    public func updateStatus(outputID: String, status: StructuredOutputStatus) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE structured_outputs SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, Date(), outputID]
            )
        }
    }

    public func fetchOutputs(matterID: String) throws -> [StructuredOutputRecord] {
        try writer.read { db in
            try StructuredOutputRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM structured_outputs
                WHERE matter_id = ? AND deleted_at IS NULL
                ORDER BY updated_at DESC
                """,
                arguments: [matterID]
            )
        }
    }

    public func fetchVersions(structuredOutputID: String) throws -> [StructuredOutputVersionRecord] {
        try writer.read { db in
            try StructuredOutputVersionRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM structured_output_versions
                WHERE structured_output_id = ?
                ORDER BY version_index DESC
                """,
                arguments: [structuredOutputID]
            )
        }
    }

    public func fetchVersion(id: String) throws -> StructuredOutputVersionRecord? {
        try writer.read { db in try StructuredOutputVersionRecord.fetchOne(db, key: id) }
    }

    /// Stale is terminal for an existing version. A clean assurance state is
    /// earned by appending a newly verified/generated version, never by erasing
    /// the historical dependency failure in place.
    public func updateAssuranceState(
        versionID: String,
        assuranceState: OutputAssuranceState
    ) throws {
        try writer.write { db in
            guard let current = try StructuredOutputVersionRecord.fetchOne(db, key: versionID) else {
                throw StructuredOutputRepositoryError.versionUnavailable(versionID)
            }
            if current.assuranceState == OutputAssuranceState.stale.rawValue,
               assuranceState != .stale {
                throw StructuredOutputRepositoryError.staleVersionRequiresNewVersion(versionID)
            }
            try db.execute(
                sql: """
                UPDATE structured_output_versions
                SET assurance_state = ?, stale_reason = NULL, updated_at = ?
                WHERE id = ?
                """,
                arguments: [assuranceState.rawValue, Date(), versionID]
            )
        }
    }

    @discardableResult
    public func markStaleForSourceRevision(
        matterID: String,
        documentID: String,
        fromRevisionID: String,
        toRevisionID: String
    ) throws -> Int {
        let reason = "source_revision_changed:document=\(documentID):from=\(fromRevisionID):to=\(toRevisionID)"
        return try markStale(
            reason: reason,
            selectSQL: """
            SELECT DISTINCT source.structured_output_version_id
            FROM document_output_sources AS source
            JOIN structured_output_versions AS version
              ON version.id = source.structured_output_version_id
            JOIN structured_outputs AS output
              ON output.id = version.structured_output_id
            WHERE output.matter_id = ?
              AND source.document_id = ?
              AND source.revision_id = ?
              AND version.assurance_state IS NOT ?
            """,
            arguments: [matterID, documentID, fromRevisionID, OutputAssuranceState.stale.rawValue]
        )
    }

    @discardableResult
    public func markStaleForDocumentReprocess(
        matterID: String,
        documentID: String
    ) throws -> Int {
        try markStale(
            reason: "document_reprocessed:document=\(documentID)",
            selectSQL: """
            SELECT DISTINCT source.structured_output_version_id
            FROM document_output_sources AS source
            JOIN structured_output_versions AS version
              ON version.id = source.structured_output_version_id
            JOIN structured_outputs AS output
              ON output.id = version.structured_output_id
            WHERE output.matter_id = ?
              AND source.document_id = ?
              AND version.assurance_state IS NOT ?
            """,
            arguments: [matterID, documentID, OutputAssuranceState.stale.rawValue]
        )
    }

    @discardableResult
    public func markStaleForEmbeddingModelRevision(
        matterID: String,
        modelID: String,
        fromRevision: String,
        toRevision: String
    ) throws -> Int {
        let reason = "embedding_model_revision_changed:model=\(modelID):from=\(fromRevision):to=\(toRevision)"
        return try markStale(
            reason: reason,
            selectSQL: """
            SELECT DISTINCT set_row.structured_output_version_id
            FROM document_source_sets AS set_row
            JOIN structured_output_versions AS version
              ON version.id = set_row.structured_output_version_id
            JOIN structured_outputs AS output
              ON output.id = version.structured_output_id
            WHERE output.matter_id = ?
              AND set_row.embedding_model_id = ?
              AND set_row.embedding_model_revision = ?
              AND version.assurance_state IS NOT ?
            """,
            arguments: [matterID, modelID, fromRevision, OutputAssuranceState.stale.rawValue]
        )
    }

    @discardableResult
    public func markStaleForEmbeddingModelSelection(
        matterID: String,
        fromModelID: String,
        fromRevision: String,
        toModelID: String,
        toRevision: String
    ) throws -> Int {
        let reason = "embedding_model_changed:from=\(fromModelID)@\(fromRevision):to=\(toModelID)@\(toRevision)"
        return try markStale(
            reason: reason,
            selectSQL: """
            SELECT DISTINCT set_row.structured_output_version_id
            FROM document_source_sets AS set_row
            JOIN structured_output_versions AS version
              ON version.id = set_row.structured_output_version_id
            JOIN structured_outputs AS output
              ON output.id = version.structured_output_id
            WHERE output.matter_id = ?
              AND set_row.embedding_model_id = ?
              AND set_row.embedding_model_revision = ?
              AND version.assurance_state IS NOT ?
            """,
            arguments: [
                matterID, fromModelID, fromRevision,
                OutputAssuranceState.stale.rawValue,
            ]
        )
    }

    @discardableResult
    public func markStaleForChunkerVersion(
        matterID: String,
        fromVersion: Int,
        toVersion: Int
    ) throws -> Int {
        let reason = "chunker_version_changed:from=\(fromVersion):to=\(toVersion)"
        return try markStale(
            reason: reason,
            selectSQL: """
            SELECT DISTINCT set_row.structured_output_version_id
            FROM document_source_sets AS set_row
            JOIN structured_output_versions AS version
              ON version.id = set_row.structured_output_version_id
            JOIN structured_outputs AS output
              ON output.id = version.structured_output_id
            WHERE output.matter_id = ?
              AND set_row.chunker_version = ?
              AND version.assurance_state IS NOT ?
            """,
            arguments: [matterID, fromVersion, OutputAssuranceState.stale.rawValue]
        )
    }

    @discardableResult
    public func markStaleForPromptBuilderVersion(
        matterID: String,
        fromVersion: String,
        toVersion: String
    ) throws -> Int {
        let reason = "prompt_builder_version_changed:from=\(fromVersion):to=\(toVersion)"
        return try markStale(
            reason: reason,
            selectSQL: """
            SELECT DISTINCT version.id
            FROM structured_output_versions AS version
            JOIN structured_outputs AS output
              ON output.id = version.structured_output_id
            WHERE output.matter_id = ?
              AND version.prompt_builder_version = ?
              AND version.assurance_state IS NOT ?
            """,
            arguments: [matterID, fromVersion, OutputAssuranceState.stale.rawValue]
        )
    }

    private func markStale(
        reason: String,
        selectSQL: String,
        arguments: StatementArguments
    ) throws -> Int {
        try writer.write { db in
            let versionIDs = try String.fetchAll(db, sql: selectSQL, arguments: arguments)
            guard !versionIDs.isEmpty else { return 0 }
            let now = Date()
            try db.execute(literal: """
                UPDATE structured_output_versions
                SET assurance_state = \(OutputAssuranceState.stale.rawValue),
                    stale_reason = \(reason),
                    updated_at = \(now)
                WHERE id IN \(versionIDs)
                  AND assurance_state IS NOT \(OutputAssuranceState.stale.rawValue)
                """)
            let changedCount = db.changesCount
            try db.execute(literal: """
                UPDATE structured_outputs
                SET status = \(StructuredOutputStatus.needsReview.rawValue),
                    updated_at = \(now)
                WHERE active_version_id IN \(versionIDs)
                  AND status IS NOT \(StructuredOutputStatus.needsReview.rawValue)
                """)
            return changedCount
        }
    }

    private static func defaultAssurance(
        for verificationStatus: OutputVerificationStatus
    ) -> OutputAssuranceState {
        verificationStatus == .allSupported ? .propositionSupported : .supportNeedsReview
    }

    private static func supportsCompleteStatus(_ assuranceState: OutputAssuranceState) -> Bool {
        assuranceState == .propositionSupported || assuranceState == .corpusComplete
    }

    private static func requireNonEmpty(_ value: String, fieldName: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StructuredOutputRepositoryError.requiredFieldMissing(fieldName)
        }
        return trimmed
    }
}

public enum StructuredOutputRepositoryError: Error, Equatable, Sendable {
    case requiredFieldMissing(String)
    case verificationVersionRequired
    case allSupportedResultRequired
    case completeStatusRequiresAllSupportedVerification
    case completeStatusRequiresSupportedAssurance
    case sourceSetUnavailable(String)
    case outputUnavailable(String)
    case corpusRunUnavailable(String)
    case versionUnavailable(String)
    case staleVersionRequiresNewVersion(String)
}
