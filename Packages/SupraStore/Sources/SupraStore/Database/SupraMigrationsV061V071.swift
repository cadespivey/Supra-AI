import CryptoKit
import Foundation
import GRDB
import SupraCore

extension SupraMigrator {
    static func registerMigrationsV061ThroughV071(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v061_bind_document_output_source_revisions") { db in
            // Historical source rows deliberately stay NULL: their denormalized
            // excerpt/locator remains readable, but no exact revision can be
            // proven retroactively. New repository writes stamp the revision.
            try db.alter(table: "document_output_sources") { table in
                table.add(column: "revision_id", .text)
                    .references("document_part_revisions", onDelete: .setNull)
            }
            try db.create(
                index: "idx_document_output_sources_revision",
                on: "document_output_sources",
                columns: ["revision_id"]
            )
        }

        migrator.registerMigration("v062_create_document_structure") { db in
            // Legacy documents deliberately receive no fabricated tree. Their
            // wrapper is generated lazily on the next extraction/index pass.
            try db.create(table: "document_structure_nodes") { table in
                table.column("id", .text).primaryKey()
                table.column("document_id", .text)
                    .notNull()
                    .references("matter_documents", onDelete: .cascade)
                table.column("revision_id", .text)
                    .notNull()
                    .references("document_part_revisions", onDelete: .cascade)
                table.column("node_key", .text).notNull()
                table.column("parent_node_id", .text)
                    .references("document_structure_nodes", onDelete: .cascade)
                table.column("ordinal", .integer).notNull()
                table.column("kind", .text).notNull()
                table.column("char_start", .integer)
                table.column("char_end", .integer)
                table.column("text_content", .text)
                table.column("payload_json", .text)
                table.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_document_structure_nodes_key",
                on: "document_structure_nodes",
                columns: ["document_id", "revision_id", "node_key"],
                unique: true
            )
            try db.create(
                index: "idx_document_structure_nodes_parent",
                on: "document_structure_nodes",
                columns: ["document_id", "parent_node_id", "ordinal"]
            )

            try db.create(table: "document_structure_edges") { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text)
                    .notNull()
                    .references("matters", onDelete: .cascade)
                table.column("from_node_id", .text)
                    .notNull()
                    .references("document_structure_nodes", onDelete: .cascade)
                table.column("to_node_id", .text)
                    .notNull()
                    .references("document_structure_nodes", onDelete: .cascade)
                table.column("kind", .text).notNull()
                table.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_document_structure_edges_endpoints",
                on: "document_structure_edges",
                columns: ["from_node_id", "to_node_id", "kind"],
                unique: true
            )
            try db.create(
                index: "idx_document_structure_edges_matter",
                on: "document_structure_edges",
                columns: ["matter_id", "kind"]
            )
        }

        migrator.registerMigration("v063_add_chunk_structure_binding") { db in
            // Existing chunks are v1 by definition. The additive defaults keep
            // their bytes/text and locators untouched while v2 remains opt-in.
            try db.alter(table: "document_chunks") { table in
                table.add(column: "node_id", .text)
                    .references("document_structure_nodes", onDelete: .setNull)
                table.add(column: "unit_kind", .text)
                table.add(column: "chunker_version", .integer)
                    .notNull()
                    .defaults(to: 1)
            }
            try db.create(
                index: "idx_document_chunks_node",
                on: "document_chunks",
                columns: ["node_id", "chunk_index"]
            )
            try db.alter(table: "document_intelligence_settings") { table in
                table.add(column: "chunker_version", .integer)
                    .notNull()
                    .defaults(to: 1)
            }
        }

        migrator.registerMigration("v064_create_corpus_analysis_ledger") { db in
            try db.create(table: "corpus_analysis_runs") { table in
                table.column("id", .text).primaryKey()
                table.column("run_key", .text).notNull()
                table.column("matter_id", .text).notNull()
                    .references("matters", onDelete: .cascade)
                table.column("task_kind", .text).notNull()
                table.column("scope_json", .text).notNull()
                table.column("corpus_snapshot_json", .text).notNull()
                table.column("partition_strategy", .text).notNull()
                table.column("partition_strategy_version", .integer).notNull()
                table.column("model_lineage_json", .text)
                table.column("status", .text).notNull()
                table.column("coverage_json", .text)
                table.column("reconciliation_json", .text)
                table.column("validation_results_json", .text)
                table.column("assurance_state", .text)
                table.column("assurance_reasons_json", .text)
                table.column("structured_output_version_id", .text)
                    .references("structured_output_versions", onDelete: .setNull)
                table.column("created_at", .datetime).notNull()
                table.column("completed_at", .datetime)
            }
            try db.create(
                index: "idx_corpus_analysis_runs_matter_key",
                on: "corpus_analysis_runs",
                columns: ["matter_id", "run_key"],
                unique: true
            )
            try db.create(
                index: "idx_corpus_analysis_runs_matter_status",
                on: "corpus_analysis_runs",
                columns: ["matter_id", "status", "created_at"]
            )

            try db.create(table: "corpus_analysis_partitions") { table in
                table.column("id", .text).primaryKey()
                table.column("run_id", .text).notNull()
                    .references("corpus_analysis_runs", onDelete: .cascade)
                table.column("partition_key", .text).notNull()
                table.column("input_revision_ids_json", .text).notNull()
                table.column("attempt_count", .integer).notNull().defaults(to: 0)
                table.column("attempt_history_json", .text).notNull().defaults(to: "[]")
                table.column("disposition", .text).notNull().defaults(to: "pending")
                table.column("disposition_reason", .text)
                table.column("findings_json", .text)
                table.column("error_summary", .text)
                table.column("started_at", .datetime)
                table.column("completed_at", .datetime)
            }
            try db.create(
                index: "idx_corpus_analysis_partitions_run_key",
                on: "corpus_analysis_partitions",
                columns: ["run_id", "partition_key"],
                unique: true
            )
            try db.create(
                index: "idx_corpus_analysis_partitions_run_disposition",
                on: "corpus_analysis_partitions",
                columns: ["run_id", "disposition", "partition_key"]
            )

            // Defense in depth for INV-10: even direct SQL/repository misuse
            // cannot persist corpus_complete while work is pending/failed or
            // while snapshot exclusions are undisclosed.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_complete_guard
                BEFORE UPDATE OF status, assurance_state, coverage_json ON corpus_analysis_runs
                WHEN NEW.status = 'persisted' AND NEW.assurance_state = 'corpus_complete'
                BEGIN
                    SELECT CASE WHEN EXISTS (
                        SELECT 1 FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition <> 'succeeded'
                    ) THEN RAISE(ABORT, 'corpus_complete requires all partitions succeeded') END;
                    SELECT CASE WHEN COALESCE(
                        json_extract(NEW.coverage_json, '$.excluded_members_disclosed'), 0
                    ) <> 1 THEN RAISE(ABORT, 'corpus_complete requires disclosed exclusions') END;
                END
                """)
        }

        migrator.registerMigration("v065_create_document_relations") { db in
            try db.create(table: "document_relations") { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text).notNull()
                    .references("matters", onDelete: .cascade)
                table.column("relation_key", .text).notNull()
                table.column("from_document_id", .text).notNull()
                    .references("matter_documents", onDelete: .cascade)
                table.column("to_document_id", .text).notNull()
                    .references("matter_documents", onDelete: .cascade)
                table.column("kind", .text).notNull()
                table.column("evidence_json", .text).notNull()
                table.column("confidence", .double)
                table.column("proposed_by", .text)
                table.column("review_state", .text).notNull().defaults(to: "proposed")
                table.column("reviewed_by", .text)
                table.column("reviewed_at", .datetime)
                table.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_document_relations_matter_key_kind",
                on: "document_relations",
                columns: ["matter_id", "relation_key", "kind"],
                unique: true
            )
            try db.create(
                index: "idx_document_relations_matter_review",
                on: "document_relations",
                columns: ["matter_id", "review_state", "kind", "created_at"]
            )
            try db.create(
                index: "idx_document_relations_from",
                on: "document_relations",
                columns: ["matter_id", "from_document_id", "kind"]
            )
            try db.create(
                index: "idx_document_relations_to",
                on: "document_relations",
                columns: ["matter_id", "to_document_id", "kind"]
            )
            try backfillDocumentRelations(db)
        }

        migrator.registerMigration("v066_add_document_source_lineage") { db in
            try db.alter(table: "document_source_sets") { table in
                table.add(column: "packing_report_json", .text)
                table.add(column: "embedding_model_id", .text)
                table.add(column: "embedding_model_revision", .text)
                table.add(column: "chunker_version", .integer)
                table.add(column: "retrieval_config_json", .text)
                table.add(column: "corpus_snapshot_hash", .text)
                table.add(column: "message_id", .text)
                    .references("messages", onDelete: .setNull)
            }
            try db.create(
                index: "idx_document_source_sets_message",
                on: "document_source_sets",
                columns: ["message_id"],
                unique: true
            )
        }

        migrator.registerMigration("v067_add_output_generation_lineage") { db in
            try db.alter(table: "structured_output_versions") { table in
                table.add(column: "prompt_builder_version", .text)
                table.add(column: "assurance_state", .text)
                table.add(column: "stale_reason", .text)
            }

            // Chat sessions predate document generation and required both chat
            // and message owners. Rebuild the table so a completed document
            // generation can use the same durable audit record without minting
            // synthetic chats/messages. The stable repository/revision pair is
            // deliberately separate from the per-load runtime UUID.
            try db.create(table: "generation_sessions_v067") { table in
                table.column("id", .text).primaryKey()
                table.column("chat_id", .text)
                    .references("chats", onDelete: .cascade)
                table.column("message_id", .text)
                    .references("messages", onDelete: .cascade)
                table.column("variant_id", .text)
                table.column("model_id", .text)
                table.column("model_repository", .text)
                table.column("model_revision", .text)
                table.column("prompt_builder_version", .text)
                table.column("prompt", .text).notNull()
                table.column("system_prompt", .text)
                table.column("options_json", .text).notNull()
                table.column("status", .text).notNull()
                table.column("started_at", .datetime).notNull()
                table.column("first_token_at", .datetime)
                table.column("completed_at", .datetime)
                table.column("load_time_ms", .integer)
                table.column("first_token_latency_ms", .integer)
                table.column("tokens_per_second", .double)
                table.column("cancellation_latency_ms", .integer)
                table.column("peak_memory_mb", .integer)
                table.column("generated_token_count", .integer)
                table.column("error_summary", .text)
                table.column("interruption_reason", .text)
                table.column("diagnostic_event_id", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.execute(sql: """
                INSERT INTO generation_sessions_v067 (
                    id, chat_id, message_id, variant_id, model_id,
                    prompt, system_prompt, options_json, status, started_at,
                    first_token_at, completed_at, load_time_ms,
                    first_token_latency_ms, tokens_per_second,
                    cancellation_latency_ms, peak_memory_mb,
                    generated_token_count, error_summary, interruption_reason,
                    diagnostic_event_id, created_at, updated_at
                )
                SELECT
                    id, chat_id, message_id, variant_id, model_id,
                    prompt, system_prompt, options_json, status, started_at,
                    first_token_at, completed_at, load_time_ms,
                    first_token_latency_ms, tokens_per_second,
                    cancellation_latency_ms, peak_memory_mb,
                    generated_token_count, error_summary, interruption_reason,
                    diagnostic_event_id, created_at, updated_at
                FROM generation_sessions
                """)
            try db.drop(table: "generation_sessions")
            try db.rename(table: "generation_sessions_v067", to: "generation_sessions")
            try db.create(
                index: "idx_generation_sessions_chat_id",
                on: "generation_sessions",
                columns: ["chat_id", "started_at"]
            )
            try db.create(
                index: "idx_generation_sessions_message_id",
                on: "generation_sessions",
                columns: ["message_id"]
            )

            // Only a unique v064 run link is enough evidence to copy assurance.
            // Unrelated and ambiguously-linked historical versions stay unknown.
            try db.execute(sql: """
                UPDATE structured_output_versions
                SET assurance_state = (
                    SELECT run.assurance_state
                    FROM corpus_analysis_runs AS run
                    WHERE run.structured_output_version_id = structured_output_versions.id
                      AND run.assurance_state IS NOT NULL
                    ORDER BY run.completed_at DESC, run.id
                    LIMIT 1
                )
                WHERE assurance_state IS NULL
                  AND (
                    SELECT COUNT(*)
                    FROM corpus_analysis_runs AS run
                    WHERE run.structured_output_version_id = structured_output_versions.id
                      AND run.assurance_state IS NOT NULL
                  ) = 1
                """)
        }

        migrator.registerMigration("v068_add_document_classification_lineage") { db in
            // Legacy `matter_documents.classification_metadata_json` remains the
            // compatible latest-value projection. Historical rows are not
            // backfilled because the mutable JSON has no trustworthy input,
            // model, prompt, sampling, or evidence lineage to recover.
            try db.create(table: "document_classifications") { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text).notNull()
                    .references("matters", onDelete: .cascade)
                table.column("document_id", .text).notNull()
                    .references("matter_documents", onDelete: .cascade)
                table.column("classification_key", .text).notNull()
                table.column("input_revision_ids_json", .text).notNull()
                table.column("input_checksum", .text).notNull()
                table.column("model_repository", .text).notNull()
                table.column("model_revision", .text).notNull()
                table.column("prompt_version", .text).notNull()
                table.column("sampling_strategy", .text).notNull()
                table.column("sampling_version", .integer).notNull()
                table.column("primary_category", .text)
                table.column("secondary_categories_json", .text).notNull()
                table.column("confidence_json", .text).notNull()
                table.column("calibration_version", .text).notNull()
                table.column("abstained", .boolean).notNull()
                table.column("abstention_reason", .text)
                table.column("evidence_spans_json", .text).notNull()
                table.column("warnings_json", .text).notNull()
                table.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_document_classifications_identity",
                on: "document_classifications",
                columns: ["matter_id", "document_id", "classification_key"],
                unique: true
            )
            try db.create(
                index: "idx_document_classifications_latest",
                on: "document_classifications",
                columns: ["matter_id", "document_id", "created_at", "id"]
            )
            try db.execute(sql: """
                CREATE TRIGGER document_classifications_immutable_update
                BEFORE UPDATE ON document_classifications
                BEGIN
                    SELECT RAISE(ABORT, 'document classifications are append-only');
                END
                """)
        }

        migrator.registerMigration("v069_add_verification_dimensions") { db in
            try db.alter(table: "structured_output_versions") { table in
                table.add(column: "verification_dimensions_json", .text)
            }
        }

        migrator.registerMigration("v070_add_authority_reviewed_proposition") { db in
            // Historical authority rows have no proposition-specific human
            // review that can be reconstructed safely. Keep them unreviewed.
            try db.alter(table: "authorities") { table in
                table.add(column: "reviewed_proposition_json", .text)
            }
        }

        migrator.registerMigration("v071_create_draft_artifact_intents") { db in
            try db.create(table: "draft_artifact_intents") { table in
                table.column("id", .text).primaryKey()
                table.column("matter_id", .text).notNull()
                    .references("matters", onDelete: .cascade)
                table.column("artifact_kind", .text).notNull()
                table.column("format", .text).notNull()
                table.column("file_name", .text).notNull()
                table.column("output_sha256", .text).notNull()
                table.column("output_byte_size", .integer).notNull()
                table.column("audit_metadata_json", .text).notNull()
                table.column("audit_metadata_sha256", .text).notNull()
                table.column("motion_snapshot_request_json", .text)
                table.column("motion_snapshot_sha256", .text)
                table.column("status", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
                table.column("terminal_at", .datetime)
            }
            // Only an active operation owns a filename reservation. Terminal
            // history remains durable without poisoning future allocation.
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_draft_artifact_intents_matter_file
                ON draft_artifact_intents (matter_id, file_name)
                WHERE status = 'prepared'
                """)
            try db.create(
                index: "idx_draft_artifact_intents_status_created",
                on: "draft_artifact_intents",
                columns: ["status", "created_at", "id"]
            )
        }

    }

    private struct RelationBackfillDocument: Sendable {
        var id: String
        var matterID: String
        var blobID: String
        var createdAt: Date
    }

    private struct RelationBackfillGroupKey: Hashable {
        var matterID: String
        var value: String
    }

    /// v065 backfill is intentionally deterministic and proposal-only. It uses
    /// the same SHA-256 text key as retrieval duplicate collapse, but hashes the
    /// complete ordered chunk text for each document instance.
    private static func backfillDocumentRelations(_ db: Database) throws {
        let documents = try Row.fetchAll(
            db,
            sql: """
            SELECT id, matter_id, blob_id, created_at
            FROM matter_documents
            WHERE deleted_at IS NULL
            ORDER BY matter_id, id
            """
        ).map { row in
            RelationBackfillDocument(
                id: row["id"],
                matterID: row["matter_id"],
                blobID: row["blob_id"],
                createdAt: row["created_at"]
            )
        }
        let documentByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

        let exactGroups = Dictionary(grouping: documents) {
            RelationBackfillGroupKey(matterID: $0.matterID, value: $0.blobID)
        }
        for key in exactGroups.keys.sorted(by: backfillGroupLessThan) {
            let group = exactGroups[key, default: []].sorted { $0.id < $1.id }
            for (from, to) in relationPairs(group) {
                try insertBackfillRelation(
                    db,
                    matterID: key.matterID,
                    from: from,
                    to: to,
                    kind: .exactDuplicate,
                    evidence: [
                        "basis": "shared_blob",
                        "blob_id": key.value,
                        "schema_version": 1,
                    ]
                )
            }
        }

        let chunkRows = try Row.fetchAll(
            db,
            sql: """
            SELECT d.id AS document_id, c.normalized_text
            FROM matter_documents d
            JOIN document_chunks c ON c.document_id = d.id
            WHERE d.deleted_at IS NULL
            ORDER BY d.matter_id, d.id, c.chunk_index, c.id
            """
        )
        var chunkTextsByDocumentID: [String: [String]] = [:]
        for row in chunkRows {
            let documentID: String = row["document_id"]
            let text: String = row["normalized_text"]
            chunkTextsByDocumentID[documentID, default: []].append(text)
        }
        var normalizedGroups: [RelationBackfillGroupKey: [RelationBackfillDocument]] = [:]
        for (documentID, chunkTexts) in chunkTextsByDocumentID {
            guard let document = documentByID[documentID] else { continue }
            let fullText = chunkTexts.joined(separator: "\n\n")
            guard !fullText.isEmpty else { continue }
            let digest = SHA256.hash(data: Data(fullText.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            normalizedGroups[
                RelationBackfillGroupKey(matterID: document.matterID, value: digest),
                default: []
            ].append(document)
        }
        for key in normalizedGroups.keys.sorted(by: backfillGroupLessThan) {
            let group = normalizedGroups[key, default: []].sorted { $0.id < $1.id }
            for (from, to) in relationPairs(group) where from.blobID != to.blobID {
                try insertBackfillRelation(
                    db,
                    matterID: key.matterID,
                    from: from,
                    to: to,
                    kind: .normalizedDuplicate,
                    evidence: [
                        "basis": "normalized_text_digest",
                        "digest": key.value,
                        "schema_version": 1,
                    ]
                )
            }
        }
    }

    private static func insertBackfillRelation(
        _ db: Database,
        matterID: String,
        from: RelationBackfillDocument,
        to: RelationBackfillDocument,
        kind: DocumentRelationKind,
        evidence: [String: Any]
    ) throws {
        let ordered = [from, to].sorted { $0.id < $1.id }
        let relationKey = "\(ordered[0].id)|\(ordered[1].id)"
        let identity = "\(matterID)|\(relationKey)|\(kind.rawValue)"
        let id = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let evidenceData = try JSONSerialization.data(
            withJSONObject: evidence,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO document_relations (
                id, matter_id, relation_key, from_document_id, to_document_id,
                kind, evidence_json, confidence, proposed_by, review_state, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 1.0, 'system', 'proposed', ?)
            """,
            arguments: [
                id,
                matterID,
                relationKey,
                ordered[0].id,
                ordered[1].id,
                kind.rawValue,
                String(decoding: evidenceData, as: UTF8.self),
                max(from.createdAt, to.createdAt),
            ]
        )
    }

    private static func relationPairs<T>(_ values: [T]) -> [(T, T)] {
        guard values.count > 1 else { return [] }
        return values.indices.flatMap { firstIndex in
            values.indices.compactMap { secondIndex in
                guard secondIndex > firstIndex else { return nil }
                return (values[firstIndex], values[secondIndex])
            }
        }
    }

    private static func backfillGroupLessThan(
        _ lhs: RelationBackfillGroupKey,
        _ rhs: RelationBackfillGroupKey
    ) -> Bool {
        (lhs.matterID, lhs.value) < (rhs.matterID, rhs.value)
    }
}
