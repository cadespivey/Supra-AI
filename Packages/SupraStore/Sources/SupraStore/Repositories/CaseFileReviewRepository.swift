import CryptoKit
import Foundation
import GRDB
import SupraCore

public enum CaseFileReviewRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case invalidField(String)
    case matterUnavailable(String)
    case exactRunUnavailable(String)
    case invalidReconciliation(String)
    case evidenceUnavailable(String)
    case projectScopeMismatch(String)
    case cellScopeMismatch(String)
    case corruptGraph(String)

    public var errorDescription: String? {
        switch self {
        case .invalidField(let field):
            "Case File Review requires a non-empty \(field)."
        case .matterUnavailable:
            "The selected matter is unavailable."
        case .exactRunUnavailable:
            "The selected output no longer has one eligible exact corpus proof."
        case .invalidReconciliation:
            "The exhaustive result cannot be reconstructed safely for review."
        case .evidenceUnavailable:
            "The exact retained evidence cannot be bound to an available source revision."
        case .projectScopeMismatch:
            "The Review Project does not belong to the selected matter."
        case .cellScopeMismatch:
            "The Review cell does not belong to the selected project."
        case .corruptGraph:
            "The persisted Review Project graph is incomplete."
        }
    }
}

public final class CaseFileReviewRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Creates the first immutable generation for each reconciled finding in one
    /// transaction. The fixed four-column Matrix is Store-owned so caller and UI
    /// labels cannot drift. Exact retries return the already-persisted graph.
    @discardableResult
    public func createOrFetchProject(
        matterID: String,
        sourceRunID: String,
        title: String,
        actor: String,
        at timestamp: Date = Date()
    ) throws -> CaseFileReviewProjectGraph {
        let normalizedMatterID = try Self.requireNonEmpty(matterID, field: "matterID")
        let normalizedRunID = try Self.requireNonEmpty(sourceRunID, field: "sourceRunID")
        let normalizedTitle = try Self.requireNonEmpty(title, field: "title")
        let normalizedActor = try Self.requireNonEmpty(actor, field: "actor")

        return try writer.write { db in
            if let existing = try CaseFileReviewProjectRecord.fetchOne(
                db,
                sql: """
                    SELECT * FROM case_file_review_projects
                    WHERE source_run_id = ?
                    """,
                arguments: [normalizedRunID]
            ) {
                guard existing.matterID == normalizedMatterID else {
                    throw CaseFileReviewRepositoryError.projectScopeMismatch(existing.id)
                }
                return try Self.fetchGraph(db, project: existing)
            }

            let proof = try Self.eligibleProof(
                db,
                matterID: normalizedMatterID,
                runID: normalizedRunID
            )
            guard let frozenReconciliationJSON = proof.run.reconciliationJSON else {
                throw CaseFileReviewRepositoryError.invalidReconciliation("missing")
            }
            let reconciliation = try Self.decodeReconciliation(frozenReconciliationJSON)
            let frozenNames = try Self.frozenDocumentNames(proof.run.corpusSnapshotJSON)
            let slices = try CorpusAnalysisPartitionSliceRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM corpus_analysis_partition_slices
                    WHERE run_id = ? ORDER BY partition_id, ordinal, id
                    """,
                arguments: [proof.run.id]
            )
            let sourceRows = try DocumentOutputSourceRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM document_output_sources
                    WHERE source_set_id = ? AND structured_output_version_id = ?
                    ORDER BY rank, id
                    """,
                arguments: [proof.sourceSet.id, proof.version.id]
            )

            let project = CaseFileReviewProjectRecord(
                matterID: normalizedMatterID,
                title: normalizedTitle,
                sourceRunID: proof.run.id,
                sourceOutputID: proof.output.id,
                sourceOutputVersionID: proof.version.id,
                sourceRequestDigest: try Self.requireDigest(proof.run.requestDigest),
                frozenScopeJSON: proof.run.scopeJSON,
                frozenCorpusSnapshotJSON: proof.run.corpusSnapshotJSON,
                frozenReconciliationJSON: frozenReconciliationJSON,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            try project.insert(db)

            let table = CaseFileReviewTableRecord(
                projectID: project.id,
                title: "Review Matrix",
                createdAt: timestamp,
                updatedAt: timestamp
            )
            try table.insert(db)
            let columnSpecs = [
                ("finding", "Finding"),
                ("generated_value", "Generated value"),
                ("sources", "Sources"),
                ("review", "Review"),
            ]
            var columns: [CaseFileReviewColumnRecord] = []
            for (ordinal, spec) in columnSpecs.enumerated() {
                let column = CaseFileReviewColumnRecord(
                    tableID: table.id,
                    columnKey: spec.0,
                    title: spec.1,
                    ordinal: ordinal,
                    createdAt: timestamp
                )
                try column.insert(db)
                columns.append(column)
            }
            guard let generatedColumn = columns.first(where: { $0.columnKey == "generated_value" }) else {
                throw CaseFileReviewRepositoryError.corruptGraph(project.id)
            }

            var rows: [CaseFileReviewRowRecord] = []
            var cells: [CaseFileReviewCellRecord] = []
            var generations: [CaseFileReviewCellGenerationRecord] = []
            for (ordinal, item) in reconciliation.items.enumerated() {
                let row = CaseFileReviewRowRecord(
                    tableID: table.id,
                    rowKey: item.itemKey,
                    ordinal: ordinal,
                    createdAt: timestamp
                )
                try row.insert(db)

                let cellID = UUID().uuidString
                let generationID = UUID().uuidString
                let cell = CaseFileReviewCellRecord(
                    id: cellID,
                    tableID: table.id,
                    rowID: row.id,
                    columnID: generatedColumn.id,
                    currentGenerationID: generationID,
                    supportState: item.evidence.isEmpty ? "unsupported" : "supported",
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
                try cell.insert(db)
                let generation = CaseFileReviewCellGenerationRecord(
                    id: generationID,
                    cellID: cellID,
                    sourceRunID: proof.run.id,
                    generatedValuesJSON: try Self.canonicalJSON(item.values),
                    createdAt: timestamp
                )
                try generation.insert(db)

                for (evidenceOrdinal, reference) in item.evidence.enumerated() {
                    let edge = try Self.makeEvidenceEdge(
                        reference,
                        kind: "supporting",
                        ordinal: evidenceOrdinal,
                        generationID: generationID,
                        runID: proof.run.id,
                        matterID: proof.run.matterID,
                        sourceRows: sourceRows,
                        slices: slices,
                        frozenNames: frozenNames,
                        db: db,
                        timestamp: timestamp
                    )
                    try edge.insert(db)
                }
                for (evidenceOrdinal, reference) in item.contraryEvidence.enumerated() {
                    let edge = try Self.makeEvidenceEdge(
                        reference,
                        kind: "contrary",
                        ordinal: evidenceOrdinal,
                        generationID: generationID,
                        runID: proof.run.id,
                        matterID: proof.run.matterID,
                        sourceRows: sourceRows,
                        slices: slices,
                        frozenNames: frozenNames,
                        db: db,
                        timestamp: timestamp
                    )
                    try edge.insert(db)
                }
                rows.append(row)
                cells.append(cell)
                generations.append(generation)
            }

            try db.execute(
                sql: """
                    UPDATE case_file_review_projects
                    SET active_table_id = ?, updated_at = ?
                    WHERE id = ? AND active_table_id IS NULL
                    """,
                arguments: [table.id, timestamp, project.id]
            )
            guard db.changesCount == 1 else {
                throw CaseFileReviewRepositoryError.corruptGraph(project.id)
            }
            guard let createdProject = try CaseFileReviewProjectRecord.fetchOne(
                db,
                key: project.id
            ) else {
                throw CaseFileReviewRepositoryError.corruptGraph(project.id)
            }
            try AuditEventRecord(
                matterID: normalizedMatterID,
                timestamp: timestamp,
                eventType: "case_file_review_project_created",
                actor: normalizedActor,
                summary: "Created a Case File Review project from an exact exhaustive result.",
                relatedTable: CaseFileReviewProjectRecord.databaseTableName,
                relatedID: project.id,
                metadataJSON: try Self.auditMetadata([
                    "schema_version": 1,
                    "source_run_id": proof.run.id,
                    "source_output_id": proof.output.id,
                    "source_output_version_id": proof.version.id,
                    "row_count": rows.count,
                ])
            ).insert(db)
            return CaseFileReviewProjectGraph(
                project: createdProject,
                table: table,
                columns: columns,
                rows: rows,
                cells: cells,
                generations: generations
            )
        }
    }

    public func fetchProjects(matterID: String) throws -> [CaseFileReviewProjectRecord] {
        try writer.read { db in
            try CaseFileReviewProjectRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM case_file_review_projects
                    WHERE matter_id = ?
                    ORDER BY updated_at DESC, created_at DESC, id
                    """,
                arguments: [matterID]
            )
        }
    }

    public func fetchProjectGraph(
        matterID: String,
        projectID: String
    ) throws -> CaseFileReviewProjectGraph? {
        try writer.read { db in
            guard let project = try CaseFileReviewProjectRecord.fetchOne(db, key: projectID) else {
                return nil
            }
            guard project.matterID == matterID else {
                throw CaseFileReviewRepositoryError.projectScopeMismatch(projectID)
            }
            return try Self.fetchGraph(db, project: project)
        }
    }

    /// Captures every current row, generation, and evidence edge for one live
    /// Review Project in a single read transaction. Export callers must use this
    /// boundary rather than joining a cached UI projection to per-cell reads.
    public func fetchSnapshot(
        matterID: String,
        projectID: String
    ) throws -> CaseFileReviewSnapshot {
        let normalizedMatterID = try Self.requireNonEmpty(matterID, field: "matterID")
        let normalizedProjectID = try Self.requireNonEmpty(projectID, field: "projectID")
        return try writer.read { db in
            try Self.fetchSnapshot(
                db,
                matterID: normalizedMatterID,
                projectID: normalizedProjectID
            )
        }
    }

    public func fetchCurrentEvidence(
        matterID: String,
        projectID: String,
        cellID: String
    ) throws -> [CaseFileReviewEvidenceEdgeRecord] {
        try writer.read { db in
            guard let cell = try Self.scopedCell(
                db,
                matterID: matterID,
                projectID: projectID,
                cellID: cellID
            ), let generationID = cell.currentGenerationID,
                  let generation = try CaseFileReviewCellGenerationRecord.fetchOne(
                      db,
                      key: generationID
                  ), generation.cellID == cell.id else {
                throw CaseFileReviewRepositoryError.cellScopeMismatch(cellID)
            }
            return try CaseFileReviewEvidenceEdgeRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM case_file_review_evidence_edges
                    WHERE generation_id = ?
                    ORDER BY CASE kind WHEN 'supporting' THEN 0 ELSE 1 END,
                             ordinal, id
                    """,
                arguments: [generationID]
            )
        }
    }

    /// Records only a validated Review snapshot artifact. The managed export
    /// remains deliberately unlinked from Structured Output IDs so a Review
    /// Project that retains contrary evidence never enters or weakens the
    /// stricter Structured Output export authorization path.
    @discardableResult
    public func recordSnapshotExportCompletion(
        matterID: String,
        projectID: String,
        exportID: String,
        managedRelativePath: String,
        artifactSHA256: String,
        snapshotUpdatedAt: Date,
        rowCount: Int,
        actor: String,
        at timestamp: Date = Date()
    ) throws -> DocumentExportRecord {
        let normalizedMatterID = try Self.requireNonEmpty(matterID, field: "matterID")
        let normalizedProjectID = try Self.requireNonEmpty(projectID, field: "projectID")
        let normalizedExportID = try Self.requireNonEmpty(exportID, field: "exportID")
        let normalizedPath = try Self.requireManagedReviewCSVPath(
            managedRelativePath,
            matterID: normalizedMatterID
        )
        let normalizedDigest = try Self.requireSHA256(
            artifactSHA256,
            field: "artifactSHA256"
        )
        let normalizedActor = try Self.requireNonEmpty(actor, field: "actor")
        guard rowCount >= 0 else {
            throw CaseFileReviewRepositoryError.invalidField("rowCount")
        }
        guard snapshotUpdatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw CaseFileReviewRepositoryError.invalidField("snapshotUpdatedAt")
        }
        guard timestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw CaseFileReviewRepositoryError.invalidField("timestamp")
        }

        return try writer.write { db in
            let snapshot = try Self.fetchSnapshot(
                db,
                matterID: normalizedMatterID,
                projectID: normalizedProjectID
            )
            guard snapshot.project.updatedAt == snapshotUpdatedAt else {
                throw CaseFileReviewRepositoryError.invalidField("snapshotUpdatedAt")
            }
            guard snapshot.rows.count == rowCount else {
                throw CaseFileReviewRepositoryError.invalidField("rowCount")
            }

            let export = DocumentExportRecord(
                id: normalizedExportID,
                structuredOutputID: nil,
                structuredOutputVersionID: nil,
                matterID: normalizedMatterID,
                format: "review_csv",
                managedRelativePath: normalizedPath,
                createdAt: timestamp
            )
            try export.insert(db)
            try AuditEventRecord(
                matterID: normalizedMatterID,
                timestamp: timestamp,
                eventType: "case_file_review_snapshot_exported",
                actor: normalizedActor,
                summary: "Exported a Case File Review snapshot as CSV.",
                relatedTable: CaseFileReviewProjectRecord.databaseTableName,
                relatedID: normalizedProjectID,
                metadataJSON: try Self.auditMetadata([
                    "schema_version": 1,
                    "export_id": export.id,
                    "project_id": snapshot.project.id,
                    "source_run_id": snapshot.project.sourceRunID,
                    "source_output_id": snapshot.project.sourceOutputID,
                    "source_output_version_id": snapshot.project.sourceOutputVersionID,
                    "format": export.format,
                    "managed_relative_path": export.managedRelativePath,
                    "artifact_sha256": normalizedDigest,
                    "snapshot_project_updated_at": snapshotUpdatedAt.timeIntervalSince1970,
                    "row_count": snapshot.rows.count,
                ])
            ).insert(db)
            return export
        }
    }

    @discardableResult
    public func markCellReviewed(
        matterID: String,
        projectID: String,
        cellID: String,
        reviewedBy: String,
        reviewedAt: Date = Date()
    ) throws -> CaseFileReviewCellRecord {
        let normalizedMatterID = try Self.requireNonEmpty(matterID, field: "matterID")
        let normalizedProjectID = try Self.requireNonEmpty(projectID, field: "projectID")
        let normalizedCellID = try Self.requireNonEmpty(cellID, field: "cellID")
        let normalizedReviewer = try Self.requireNonEmpty(reviewedBy, field: "reviewedBy")
        return try writer.write { db in
            var cell = try Self.scopedGeneratedValueCell(
                db,
                matterID: normalizedMatterID,
                projectID: normalizedProjectID,
                cellID: normalizedCellID
            ).cell
            if cell.reviewState == "reviewed" {
                return cell
            }
            cell.reviewState = "reviewed"
            cell.reviewedBy = normalizedReviewer
            cell.reviewedAt = reviewedAt
            cell.updatedAt = reviewedAt
            try cell.update(db)
            try db.execute(
                sql: "UPDATE case_file_review_projects SET updated_at = ? WHERE id = ?",
                arguments: [reviewedAt, normalizedProjectID]
            )
            try AuditEventRecord(
                matterID: normalizedMatterID,
                timestamp: reviewedAt,
                eventType: "case_file_review_cell_reviewed",
                actor: normalizedReviewer,
                summary: "Marked one \(cell.valueState) Review value as reviewed.",
                relatedTable: CaseFileReviewCellRecord.databaseTableName,
                relatedID: cell.id,
                metadataJSON: try Self.auditMetadata([
                    "schema_version": 1,
                    "project_id": normalizedProjectID,
                    "cell_id": cell.id,
                    "value_state": cell.valueState,
                ])
            ).insert(db)
            return cell
        }
    }

    /// Replaces the value displayed for one scoped generated-value cell without
    /// mutating its immutable generation or evidence. Exact retries are no-ops,
    /// including when the existing edited value has already been reviewed.
    @discardableResult
    public func editCellValue(
        matterID: String,
        projectID: String,
        cellID: String,
        attorneyValue: String,
        editedBy: String,
        editedAt: Date = Date()
    ) throws -> CaseFileReviewCellRecord {
        let normalizedMatterID = try Self.requireNonEmpty(matterID, field: "matterID")
        let normalizedProjectID = try Self.requireNonEmpty(projectID, field: "projectID")
        let normalizedCellID = try Self.requireNonEmpty(cellID, field: "cellID")
        let normalizedValue = try Self.requireNonEmpty(attorneyValue, field: "attorneyValue")
        let normalizedActor = try Self.requireNonEmpty(editedBy, field: "editedBy")
        return try transitionCellValue(
            matterID: normalizedMatterID,
            projectID: normalizedProjectID,
            cellID: normalizedCellID,
            newValueState: "edited",
            newAttorneyValue: normalizedValue,
            actor: normalizedActor,
            timestamp: editedAt,
            eventType: "case_file_review_cell_value_edited",
            summary: "Edited one Review value."
        )
    }

    /// Removes one attorney override and returns the displayed value to the
    /// cell's existing immutable generation. An already-generated cell is an
    /// exact no-op and does not disturb a Reviewed attestation.
    @discardableResult
    public func restoreGeneratedCellValue(
        matterID: String,
        projectID: String,
        cellID: String,
        actor: String,
        at timestamp: Date = Date()
    ) throws -> CaseFileReviewCellRecord {
        let normalizedMatterID = try Self.requireNonEmpty(matterID, field: "matterID")
        let normalizedProjectID = try Self.requireNonEmpty(projectID, field: "projectID")
        let normalizedCellID = try Self.requireNonEmpty(cellID, field: "cellID")
        let normalizedActor = try Self.requireNonEmpty(actor, field: "actor")
        return try transitionCellValue(
            matterID: normalizedMatterID,
            projectID: normalizedProjectID,
            cellID: normalizedCellID,
            newValueState: "generated",
            newAttorneyValue: nil,
            actor: normalizedActor,
            timestamp: timestamp,
            eventType: "case_file_review_cell_value_restored",
            summary: "Restored one Review value to its generated result."
        )
    }

    private func transitionCellValue(
        matterID: String,
        projectID: String,
        cellID: String,
        newValueState: String,
        newAttorneyValue: String?,
        actor: String,
        timestamp: Date,
        eventType: String,
        summary: String
    ) throws -> CaseFileReviewCellRecord {
        try writer.write { db in
            let scoped = try Self.scopedGeneratedValueCell(
                db,
                matterID: matterID,
                projectID: projectID,
                cellID: cellID
            )
            var cell = scoped.cell
            guard cell.valueState != newValueState || cell.attorneyValue != newAttorneyValue else {
                return cell
            }

            let priorValueState = cell.valueState
            let priorAttorneyValue = cell.attorneyValue
            let reviewAttestationCleared = cell.reviewState == "reviewed"
            cell.attorneyValue = newAttorneyValue
            cell.valueState = newValueState
            cell.reviewState = "needs_review"
            cell.reviewedBy = nil
            cell.reviewedAt = nil
            cell.updatedAt = timestamp
            try cell.update(db)

            try db.execute(
                sql: "UPDATE case_file_review_projects SET updated_at = ? WHERE id = ?",
                arguments: [timestamp, projectID]
            )
            try AuditEventRecord(
                matterID: matterID,
                timestamp: timestamp,
                eventType: eventType,
                actor: actor,
                summary: summary,
                relatedTable: CaseFileReviewCellRecord.databaseTableName,
                relatedID: cell.id,
                metadataJSON: try Self.auditMetadata([
                    "schema_version": 1,
                    "project_id": projectID,
                    "cell_id": cell.id,
                    "current_generation_id": scoped.generationID,
                    "prior_value_state": priorValueState,
                    "new_value_state": newValueState,
                    "prior_attorney_value": priorAttorneyValue ?? NSNull(),
                    "new_attorney_value": newAttorneyValue ?? NSNull(),
                    "review_attestation_cleared": reviewAttestationCleared,
                ])
            ).insert(db)
            return cell
        }
    }

    /// Transaction-local deletion hook. It changes only mutable availability and
    /// staleness projections; every frozen evidence byte remains untouched.
    static func degradeForPermanentSourceDeletion(
        matterID: String,
        documentIDs: [String],
        revisionIDs: [String],
        actor: String,
        at timestamp: Date,
        db: Database
    ) throws -> [String] {
        guard !documentIDs.isEmpty else { return [] }
        var predicates = [
            "edge.live_document_id IN (\(databaseQuestionMarks(count: documentIDs.count)))"
        ]
        var arguments: [DatabaseValueConvertible] = documentIDs
        if !revisionIDs.isEmpty {
            predicates.append(
                "edge.live_revision_id IN (\(databaseQuestionMarks(count: revisionIDs.count)))"
            )
            arguments.append(contentsOf: revisionIDs)
        }
        let impacted = try Row.fetchAll(
            db,
            sql: """
                SELECT DISTINCT edge.id AS edge_id, cell.id AS cell_id,
                                project.id AS project_id
                FROM case_file_review_evidence_edges AS edge
                JOIN case_file_review_cell_generations AS generation
                  ON generation.id = edge.generation_id
                JOIN case_file_review_cells AS cell ON cell.id = generation.cell_id
                JOIN case_file_review_tables AS review_table ON review_table.id = cell.table_id
                JOIN case_file_review_projects AS project ON project.id = review_table.project_id
                WHERE project.matter_id = ? AND (\(predicates.joined(separator: " OR ")))
                ORDER BY project.id, cell.id, edge.id
                """,
            arguments: StatementArguments([matterID] + arguments)
        )
        guard !impacted.isEmpty else { return [] }
        let edgeIDs = Array(Set(impacted.map { $0["edge_id"] as String })).sorted()
        let cellIDs = Array(Set(impacted.map { $0["cell_id"] as String })).sorted()
        let projectIDs = Array(Set(impacted.map { $0["project_id"] as String })).sorted()
        let reason = "source_permanently_deleted"

        var edgeArguments: [DatabaseValueConvertible] = [reason, timestamp]
        edgeArguments.append(contentsOf: edgeIDs)
        try db.execute(
            sql: """
                UPDATE case_file_review_evidence_edges
                SET availability = 'unavailable', unavailable_reason = ?,
                    live_output_source_id = NULL, live_document_id = NULL,
                    live_revision_id = NULL, updated_at = ?
                WHERE id IN (\(databaseQuestionMarks(count: edgeIDs.count)))
                """,
            arguments: StatementArguments(edgeArguments)
        )
        var cellArguments: [DatabaseValueConvertible] = [timestamp]
        cellArguments.append(contentsOf: cellIDs)
        try db.execute(
            sql: """
                UPDATE case_file_review_cells
                SET support_state = 'stale', updated_at = ?
                WHERE id IN (\(databaseQuestionMarks(count: cellIDs.count)))
                """,
            arguments: StatementArguments(cellArguments)
        )
        var projectArguments: [DatabaseValueConvertible] = [reason, timestamp]
        projectArguments.append(contentsOf: projectIDs)
        try db.execute(
            sql: """
                UPDATE case_file_review_projects
                SET status = 'stale', stale_reason = ?, updated_at = ?
                WHERE id IN (\(databaseQuestionMarks(count: projectIDs.count)))
                """,
            arguments: StatementArguments(projectArguments)
        )
        for projectID in projectIDs {
            try AuditEventRecord(
                matterID: matterID,
                timestamp: timestamp,
                eventType: "case_file_review_source_unavailable",
                actor: actor,
                summary: "Marked Review evidence unavailable after permanent source deletion.",
                relatedTable: CaseFileReviewProjectRecord.databaseTableName,
                relatedID: projectID,
                metadataJSON: try auditMetadata([
                    "schema_version": 1,
                    "project_id": projectID,
                    "unavailable_edge_ids": impacted.compactMap {
                        ($0["project_id"] as String) == projectID
                            ? ($0["edge_id"] as String) : nil
                    }.sorted(),
                ])
            ).insert(db)
        }
        return projectIDs
    }

    private static func eligibleProof(
        _ db: Database,
        matterID: String,
        runID: String
    ) throws -> EligibleProof {
        guard try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM matters WHERE id = ? AND deleted_at IS NULL",
            arguments: [matterID]
        ) == 1,
        let candidate = try CorpusAnalysisRunRecord.fetchOne(db, key: runID),
        candidate.matterID == matterID,
        let versionID = candidate.structuredOutputVersionID else {
            throw CaseFileReviewRepositoryError.exactRunUnavailable(runID)
        }
        guard let run = try CorpusAnalysisRepository.fetchExactReviewRun(
            in: db,
            matterID: matterID,
            structuredOutputVersionID: versionID
        ),
        run.id == runID,
        let version = try StructuredOutputVersionRecord.fetchOne(db, key: versionID),
        version.assuranceState == run.assuranceState,
        let output = try StructuredOutputRecord.fetchOne(db, key: version.structuredOutputID),
        output.matterID == matterID,
        output.outputType == StructuredOutputType.documentExhaustiveList.rawValue,
        output.deletedAt == nil,
        output.activeVersionID == version.id else {
            throw CaseFileReviewRepositoryError.exactRunUnavailable(runID)
        }
        let sourceSets = try DocumentSourceSetRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM document_source_sets
                WHERE structured_output_version_id = ?
                ORDER BY id
                """,
            arguments: [version.id]
        )
        guard sourceSets.count == 1,
              sourceSets[0].status == DocumentSourceSetStatus.attached.rawValue,
              try CorpusAnalysisProofIdentity.sourceSetMatchesFrozenCorpus(
                  sourceSets[0], run: run, db: db
              ) else {
            throw CaseFileReviewRepositoryError.exactRunUnavailable(runID)
        }
        return EligibleProof(run: run, output: output, version: version, sourceSet: sourceSets[0])
    }

    private static func decodeReconciliation(_ json: String?) throws -> ReviewReconciliation {
        guard let json,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ReviewReconciliation.self, from: data),
              decoded.schemaVersion == 1 else {
            throw CaseFileReviewRepositoryError.invalidReconciliation("schema")
        }
        let keys = decoded.items.map(\.itemKey)
        guard keys.allSatisfy({ !$0.isEmpty }),
              Set(keys).count == keys.count,
              decoded.items.allSatisfy({ item in
                  !item.values.isEmpty
                      && item.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
              }) else {
            throw CaseFileReviewRepositoryError.invalidReconciliation("items")
        }
        return decoded
    }

    private static func makeEvidenceEdge(
        _ reference: ReviewEvidenceReference,
        kind: String,
        ordinal: Int,
        generationID: String,
        runID: String,
        matterID: String,
        sourceRows: [DocumentOutputSourceRecord],
        slices: [CorpusAnalysisPartitionSliceRecord],
        frozenNames: [String: String],
        db: Database,
        timestamp: Date
    ) throws -> CaseFileReviewEvidenceEdgeRecord {
        guard let relativeStart = reference.charStart,
              let relativeEnd = reference.charEnd,
              relativeStart >= 0,
              relativeEnd > relativeStart,
              let quote = reference.quote?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quote.isEmpty else {
            throw CaseFileReviewRepositoryError.evidenceUnavailable(reference.revisionID)
        }
        let matchingSlices = slices.filter {
            $0.runID == runID
                && $0.documentID == reference.documentID
                && $0.revisionID == reference.revisionID
                && $0.locatorJSON == reference.locatorJSON
                && relativeEnd <= $0.charEnd - $0.charStart
        }
        guard matchingSlices.count == 1, let slice = matchingSlices.first else {
            throw CaseFileReviewRepositoryError.evidenceUnavailable(reference.revisionID)
        }
        let absoluteStart = slice.charStart + relativeStart
        let absoluteEnd = slice.charStart + relativeEnd
        guard let referenceLocator = ReviewLocator.decode(reference.locatorJSON) else {
            throw CaseFileReviewRepositoryError.evidenceUnavailable(reference.revisionID)
        }
        let matchingSources = sourceRows.filter { source in
            guard source.documentID == reference.documentID,
                  source.revisionID == reference.revisionID,
                  normalizedText(source.excerpt) == normalizedText(quote),
                  let sourceLocator = ReviewLocator.decode(source.locatorJSON) else {
                return false
            }
            return sourceLocator.matchesDimensions(of: referenceLocator)
                && sourceLocator.charStart == absoluteStart
                && sourceLocator.charEnd == absoluteEnd
        }
        guard matchingSources.count == 1, let source = matchingSources.first,
              let document = try MatterDocumentRecord.fetchOne(db, key: reference.documentID),
              document.deletedAt == nil,
              document.matterID == matterID,
              let revision = try DocumentPartRevisionRecord.fetchOne(db, key: reference.revisionID),
              revision.documentID == document.id,
              revision.partIndex == slice.partIndex,
              revision.text.count == slice.revisionCharCount,
              sha256(substring(
                  revision.text,
                  start: slice.charStart,
                  end: slice.charEnd
              ) ?? "") == slice.textSHA256,
              absoluteEnd <= revision.text.count,
              substring(revision.text, start: absoluteStart, end: absoluteEnd) == reference.quote,
              let frozenName = frozenNames[reference.documentID],
              !frozenName.isEmpty else {
            throw CaseFileReviewRepositoryError.evidenceUnavailable(reference.revisionID)
        }
        return CaseFileReviewEvidenceEdgeRecord(
            generationID: generationID,
            kind: kind,
            ordinal: ordinal,
            frozenOutputSourceID: source.id,
            frozenDocumentID: document.id,
            frozenRevisionID: revision.id,
            frozenDocumentName: frozenName,
            citationLabel: source.citationLabel,
            charStart: absoluteStart,
            charEnd: absoluteEnd,
            locatorJSON: source.locatorJSON,
            excerpt: source.excerpt,
            excerptSHA256: sha256(source.excerpt),
            liveOutputSourceID: source.id,
            liveDocumentID: document.id,
            liveRevisionID: revision.id,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private static func frozenDocumentNames(_ snapshotJSON: String) throws -> [String: String] {
        guard let data = snapshotJSON.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(CorpusAnalysisSnapshot.self, from: data) else {
            throw CaseFileReviewRepositoryError.invalidReconciliation("snapshot")
        }
        let pairs = snapshot.members.compactMap { member in
            member.documentID.map { ($0, member.displayName) }
        }
        guard Set(pairs.map(\.0)).count == pairs.count else {
            throw CaseFileReviewRepositoryError.invalidReconciliation("snapshot")
        }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    private static func fetchGraph(
        _ db: Database,
        project: CaseFileReviewProjectRecord
    ) throws -> CaseFileReviewProjectGraph {
        guard let tableID = project.activeTableID,
              let table = try CaseFileReviewTableRecord.fetchOne(db, key: tableID),
              table.projectID == project.id else {
            throw CaseFileReviewRepositoryError.corruptGraph(project.id)
        }
        let columns = try CaseFileReviewColumnRecord.fetchAll(
            db,
            sql: "SELECT * FROM case_file_review_columns WHERE table_id = ? ORDER BY ordinal, id",
            arguments: [table.id]
        )
        let rows = try CaseFileReviewRowRecord.fetchAll(
            db,
            sql: "SELECT * FROM case_file_review_rows WHERE table_id = ? ORDER BY ordinal, id",
            arguments: [table.id]
        )
        let cells = try CaseFileReviewCellRecord.fetchAll(
            db,
            sql: """
                SELECT cell.* FROM case_file_review_cells AS cell
                JOIN case_file_review_rows AS row ON row.id = cell.row_id
                WHERE cell.table_id = ? ORDER BY row.ordinal, cell.id
                """,
            arguments: [table.id]
        )
        let generations: [CaseFileReviewCellGenerationRecord]
        if cells.isEmpty {
            generations = []
        } else {
            generations = try CaseFileReviewCellGenerationRecord.fetchAll(
                db,
                sql: """
                    SELECT generation.*
                    FROM case_file_review_cell_generations AS generation
                    JOIN case_file_review_cells AS cell ON cell.id = generation.cell_id
                    JOIN case_file_review_rows AS row ON row.id = cell.row_id
                    WHERE cell.table_id = ?
                    ORDER BY row.ordinal, generation.generation_index, generation.id
                    """,
                arguments: [table.id]
            )
        }
        let expectedColumns = [
            (key: "finding", title: "Finding"),
            (key: "generated_value", title: "Generated value"),
            (key: "sources", title: "Sources"),
            (key: "review", title: "Review"),
        ]
        let generatedValueColumnID = columns.first {
            $0.columnKey == "generated_value"
        }?.id
        let generationByID = Dictionary(
            uniqueKeysWithValues: generations.map { ($0.id, $0) }
        )
        guard columns.count == expectedColumns.count,
              zip(columns, expectedColumns).allSatisfy({ column, expected in
                  column.columnKey == expected.key && column.title == expected.title
              }),
              let generatedValueColumnID,
              cells.count == rows.count,
              Set(cells.map(\.rowID)) == Set(rows.map(\.id)),
              cells.allSatisfy({ $0.columnID == generatedValueColumnID }),
              generations.count == cells.count,
              cells.allSatisfy({ cell in
                  guard let currentGenerationID = cell.currentGenerationID,
                        let generation = generationByID[currentGenerationID] else {
                      return false
                  }
                  return generation.cellID == cell.id
              }) else {
            throw CaseFileReviewRepositoryError.corruptGraph(project.id)
        }
        return CaseFileReviewProjectGraph(
            project: project,
            table: table,
            columns: columns,
            rows: rows,
            cells: cells,
            generations: generations
        )
    }

    private static func fetchSnapshot(
        _ db: Database,
        matterID: String,
        projectID: String
    ) throws -> CaseFileReviewSnapshot {
        guard try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM matters WHERE id = ? AND deleted_at IS NULL",
            arguments: [matterID]
        ) == 1 else {
            throw CaseFileReviewRepositoryError.matterUnavailable(matterID)
        }
        guard let project = try CaseFileReviewProjectRecord.fetchOne(db, key: projectID),
              project.matterID == matterID else {
            throw CaseFileReviewRepositoryError.projectScopeMismatch(projectID)
        }

        let graph = try fetchGraph(db, project: project)
        let evidence = try CaseFileReviewEvidenceEdgeRecord.fetchAll(
            db,
            sql: """
                SELECT edge.*
                FROM case_file_review_evidence_edges AS edge
                JOIN case_file_review_cell_generations AS generation
                  ON generation.id = edge.generation_id
                JOIN case_file_review_cells AS cell
                  ON cell.id = generation.cell_id
                 AND cell.current_generation_id = generation.id
                JOIN case_file_review_rows AS row
                  ON row.id = cell.row_id AND row.table_id = cell.table_id
                WHERE cell.table_id = ?
                ORDER BY row.ordinal, row.id,
                         CASE edge.kind WHEN 'supporting' THEN 0 ELSE 1 END,
                         edge.ordinal, edge.id
                """,
            arguments: [graph.table.id]
        )

        var cellsByRowID: [String: CaseFileReviewCellRecord] = [:]
        for cell in graph.cells {
            guard cellsByRowID.updateValue(cell, forKey: cell.rowID) == nil else {
                throw CaseFileReviewRepositoryError.corruptGraph(projectID)
            }
        }
        var generationsByID: [String: CaseFileReviewCellGenerationRecord] = [:]
        for generation in graph.generations {
            guard generationsByID.updateValue(generation, forKey: generation.id) == nil else {
                throw CaseFileReviewRepositoryError.corruptGraph(projectID)
            }
        }
        var evidenceByGenerationID: [String: [CaseFileReviewEvidenceEdgeRecord]] = [:]
        for edge in evidence {
            evidenceByGenerationID[edge.generationID, default: []].append(edge)
        }

        var snapshotRows: [CaseFileReviewSnapshotRow] = []
        snapshotRows.reserveCapacity(graph.rows.count)
        var capturedEvidenceCount = 0
        for row in graph.rows {
            guard let cell = cellsByRowID.removeValue(forKey: row.id),
                  cell.tableID == graph.table.id,
                  let generationID = cell.currentGenerationID,
                  let generation = generationsByID.removeValue(forKey: generationID),
                  generation.cellID == cell.id,
                  generation.sourceRunID == project.sourceRunID,
                  let generatedValuesData = generation.generatedValuesJSON.data(using: .utf8),
                  let generatedValues = try? JSONDecoder().decode(
                      [String].self,
                      from: generatedValuesData
                  ),
                  !generatedValues.isEmpty,
                  generatedValues.allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else {
                throw CaseFileReviewRepositoryError.corruptGraph(projectID)
            }

            let rowEvidence = evidenceByGenerationID.removeValue(forKey: generationID) ?? []
            guard rowEvidence.allSatisfy({ edge in
                edge.generationID == generationID
                    && edge.excerptSHA256 == sha256(edge.excerpt)
            }) else {
                throw CaseFileReviewRepositoryError.corruptGraph(projectID)
            }
            for kind in ["supporting", "contrary"] {
                let kindEvidence = rowEvidence.filter { $0.kind == kind }
                guard kindEvidence.map(\.ordinal) == Array(0..<kindEvidence.count) else {
                    throw CaseFileReviewRepositoryError.corruptGraph(projectID)
                }
            }
            guard rowEvidence.allSatisfy({ $0.kind == "supporting" || $0.kind == "contrary" }) else {
                throw CaseFileReviewRepositoryError.corruptGraph(projectID)
            }

            capturedEvidenceCount += rowEvidence.count
            snapshotRows.append(CaseFileReviewSnapshotRow(
                row: row,
                cell: cell,
                generation: generation,
                evidence: rowEvidence
            ))
        }
        guard cellsByRowID.isEmpty,
              generationsByID.isEmpty,
              evidenceByGenerationID.isEmpty,
              capturedEvidenceCount == evidence.count else {
            throw CaseFileReviewRepositoryError.corruptGraph(projectID)
        }

        return CaseFileReviewSnapshot(
            project: graph.project,
            table: graph.table,
            columns: graph.columns,
            rows: snapshotRows
        )
    }

    private static func scopedCell(
        _ db: Database,
        matterID: String,
        projectID: String,
        cellID: String
    ) throws -> CaseFileReviewCellRecord? {
        try CaseFileReviewCellRecord.fetchOne(
            db,
            sql: """
                SELECT cell.*
                FROM case_file_review_cells AS cell
                JOIN case_file_review_tables AS review_table ON review_table.id = cell.table_id
                JOIN case_file_review_projects AS project ON project.id = review_table.project_id
                WHERE cell.id = ? AND project.id = ? AND project.matter_id = ?
                """,
            arguments: [cellID, projectID, matterID]
        )
    }

    private static func scopedGeneratedValueCell(
        _ db: Database,
        matterID: String,
        projectID: String,
        cellID: String
    ) throws -> (cell: CaseFileReviewCellRecord, generationID: String) {
        guard try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM matters WHERE id = ? AND deleted_at IS NULL",
            arguments: [matterID]
        ) == 1 else {
            throw CaseFileReviewRepositoryError.matterUnavailable(matterID)
        }
        guard let cell = try CaseFileReviewCellRecord.fetchOne(
            db,
            sql: """
                SELECT cell.*
                FROM case_file_review_cells AS cell
                JOIN case_file_review_columns AS column ON column.id = cell.column_id
                JOIN case_file_review_tables AS review_table ON review_table.id = cell.table_id
                JOIN case_file_review_projects AS project ON project.id = review_table.project_id
                WHERE cell.id = ? AND project.id = ? AND project.matter_id = ?
                  AND project.active_table_id = cell.table_id
                  AND column.table_id = cell.table_id
                  AND column.column_key = 'generated_value'
                """,
            arguments: [cellID, projectID, matterID]
        ) else {
            throw CaseFileReviewRepositoryError.cellScopeMismatch(cellID)
        }
        guard let generationID = cell.currentGenerationID,
              let generation = try CaseFileReviewCellGenerationRecord.fetchOne(
                  db,
                  key: generationID
              ),
              generation.cellID == cell.id else {
            throw CaseFileReviewRepositoryError.corruptGraph(projectID)
        }
        return (cell, generationID)
    }

    private static func requireNonEmpty(_ value: String, field: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CaseFileReviewRepositoryError.invalidField(field)
        }
        return normalized
    }

    private static func requireManagedReviewCSVPath(
        _ value: String,
        matterID: String
    ) throws -> String {
        let normalized = try requireNonEmpty(value, field: "managedRelativePath")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard normalized == value,
              !normalized.hasPrefix("/"),
              !normalized.contains("\\"),
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              components.count == 3,
              components[0] == "exports",
              components[1] == Substring(matterID),
              !components[2].isEmpty,
              components[2] != ".",
              components[2] != "..",
              components[2].hasSuffix(".csv") else {
            throw CaseFileReviewRepositoryError.invalidField("managedRelativePath")
        }
        return normalized
    }

    private static func requireSHA256(_ value: String, field: String) throws -> String {
        let normalized = try requireNonEmpty(value, field: field)
        guard normalized == value,
              normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw CaseFileReviewRepositoryError.invalidField(field)
        }
        return normalized
    }

    private static func requireDigest(_ value: String?) throws -> String {
        guard let value, value.count == 64,
              value.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else {
            throw CaseFileReviewRepositoryError.exactRunUnavailable("request_digest")
        }
        return value
    }

    private static func normalizedText(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func substring(_ value: String, start: Int, end: Int) -> String? {
        guard start >= 0, end > start, end <= value.count else { return nil }
        let lower = value.index(value.startIndex, offsetBy: start)
        let upper = value.index(value.startIndex, offsetBy: end)
        return String(value[lower..<upper])
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func auditMetadata(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}

private struct EligibleProof {
    let run: CorpusAnalysisRunRecord
    let output: StructuredOutputRecord
    let version: StructuredOutputVersionRecord
    let sourceSet: DocumentSourceSetRecord
}

private struct ReviewReconciliation: Codable {
    var schemaVersion: Int
    var items: [ReviewReconciliationItem]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case items
    }
}

private struct ReviewReconciliationItem: Codable {
    var itemKey: String
    var values: [String]
    var evidence: [ReviewEvidenceReference]
    var contraryEvidence: [ReviewEvidenceReference]

    private enum CodingKeys: String, CodingKey {
        case itemKey = "item_key"
        case values, evidence
        case contraryEvidence = "contrary_evidence"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemKey = try container.decode(String.self, forKey: .itemKey)
        values = try container.decode([String].self, forKey: .values)
        evidence = try container.decodeIfPresent([ReviewEvidenceReference].self, forKey: .evidence) ?? []
        contraryEvidence = try container.decodeIfPresent(
            [ReviewEvidenceReference].self,
            forKey: .contraryEvidence
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(itemKey, forKey: .itemKey)
        try container.encode(values, forKey: .values)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(contraryEvidence, forKey: .contraryEvidence)
    }
}

private struct ReviewEvidenceReference: Codable, Hashable {
    var documentID: String
    var revisionID: String
    var locatorJSON: String
    var quote: String?
    var charStart: Int?
    var charEnd: Int?

    private enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case revisionID = "revision_id"
        case locatorJSON = "locator_json"
        case quote
        case charStart = "char_start"
        case charEnd = "char_end"
    }
}

private struct ReviewLocator {
    var sourceKind: String
    var pageIndex: Int?
    var pageLabel: String?
    var sheetName: String?
    var cellRange: String?
    var emailPartPath: String?
    var charStart: Int?
    var charEnd: Int?
    var boundingBoxesJSON: String?

    static func decode(_ json: String) -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let locator = object as? [String: Any] else { return nil }
        let camel = locator["sourceKind"] != nil
        let snake = locator["source_kind"] != nil
        guard camel != snake else { return nil }
        func value<T>(_ camelKey: String, _ snakeKey: String) -> T? {
            locator[camel ? camelKey : snakeKey] as? T
        }
        guard let sourceKind: String = value("sourceKind", "source_kind") else { return nil }
        return Self(
            sourceKind: sourceKind,
            pageIndex: value("pageIndex", "page_index"),
            pageLabel: value("pageLabel", "page_label"),
            sheetName: value("sheetName", "sheet_name"),
            cellRange: value("cellRange", "cell_range"),
            emailPartPath: value("emailPartPath", "email_part_path"),
            charStart: value("charStart", "char_start"),
            charEnd: value("charEnd", "char_end"),
            boundingBoxesJSON: value("boundingBoxesJSON", "bounding_boxes_json")
        )
    }

    func matchesDimensions(of other: Self) -> Bool {
        sourceKind == other.sourceKind
            && pageIndex == other.pageIndex
            && pageLabel == other.pageLabel
            && sheetName == other.sheetName
            && cellRange == other.cellRange
            && emailPartPath == other.emailPartPath
            && boundingBoxesJSON == other.boundingBoxesJSON
    }
}
