import CryptoKit
import Foundation
import GRDB
import SupraCore

extension SupraMigrator {
    static func registerMigrationV072(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v072_harden_corpus_review_integrity") { db in
            // Historical v064-v071 rows cannot be upgraded into exact requests:
            // neither their semantic request nor their presented text ranges can
            // be reconstructed safely. Nullable columns preserve that unknown
            // lineage instead of fabricating it during migration.
            try db.execute(sql: """
                ALTER TABLE corpus_analysis_runs
                ADD COLUMN request_schema_version INTEGER
                """)
            try db.execute(sql: """
                ALTER TABLE corpus_analysis_runs
                ADD COLUMN request_digest TEXT
                CHECK (
                    request_digest IS NULL OR (
                        typeof(request_digest) = 'text'
                        AND length(request_digest) = 64
                        AND request_digest NOT GLOB '*[^0-9a-f]*'
                    )
                )
                """)

            // SQLite requires the exact composite parent key to be unique before
            // it can enforce the slice's (partition_id, run_id) ownership FK.
            try db.create(
                index: "idx_corpus_analysis_partitions_id_run",
                on: "corpus_analysis_partitions",
                columns: ["id", "run_id"],
                unique: true
            )

            try db.execute(sql: """
                CREATE TABLE corpus_analysis_partition_slices (
                    id TEXT PRIMARY KEY NOT NULL,
                    run_id TEXT NOT NULL,
                    partition_id TEXT NOT NULL,
                    ordinal INTEGER NOT NULL CHECK (
                        typeof(ordinal) = 'integer' AND ordinal >= 0
                    ),
                    member_key TEXT NOT NULL CHECK (length(member_key) > 0),
                    document_id TEXT NOT NULL CHECK (length(document_id) > 0),
                    part_index INTEGER NOT NULL CHECK (
                        typeof(part_index) = 'integer' AND part_index >= 0
                    ),
                    revision_id TEXT NOT NULL CHECK (length(revision_id) > 0),
                    char_start INTEGER NOT NULL CHECK (
                        typeof(char_start) = 'integer' AND char_start >= 0
                    ),
                    char_end INTEGER NOT NULL CHECK (
                        typeof(char_end) = 'integer' AND char_end > char_start
                    ),
                    revision_char_count INTEGER NOT NULL
                        CHECK (
                            typeof(revision_char_count) = 'integer'
                            AND revision_char_count >= char_end
                        ),
                    text_sha256 TEXT NOT NULL CHECK (
                        typeof(text_sha256) = 'text'
                        AND length(text_sha256) = 64
                        AND text_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    locator_json TEXT NOT NULL CHECK (
                        json_valid(locator_json) = 1
                        AND json_type(locator_json) = 'object'
                        AND COALESCE((
                            (
                                json_type(locator_json, '$.source_kind') = 'text'
                                AND length(json_extract(locator_json, '$.source_kind')) > 0
                                AND json_type(locator_json, '$.char_start') = 'integer'
                                AND json_type(locator_json, '$.char_end') = 'integer'
                                AND json_extract(locator_json, '$.char_start') = char_start
                                AND json_extract(locator_json, '$.char_end') = char_end
                                AND json_type(locator_json, '$.sourceKind') IS NULL
                                AND json_type(locator_json, '$.pageIndex') IS NULL
                                AND json_type(locator_json, '$.pageLabel') IS NULL
                                AND json_type(locator_json, '$.sheetName') IS NULL
                                AND json_type(locator_json, '$.cellRange') IS NULL
                                AND json_type(locator_json, '$.emailPartPath') IS NULL
                                AND json_type(locator_json, '$.charStart') IS NULL
                                AND json_type(locator_json, '$.charEnd') IS NULL
                                AND json_type(locator_json, '$.boundingBoxesJSON') IS NULL
                                AND json_type(locator_json, '$.partIndex') IS NULL
                                AND (
                                    json_type(locator_json, '$.part_index') IS NULL
                                    OR (
                                        json_type(locator_json, '$.part_index') = 'integer'
                                        AND json_extract(locator_json, '$.part_index') = part_index
                                    )
                                )
                            )
                            OR (
                                json_type(locator_json, '$.sourceKind') = 'text'
                                AND length(json_extract(locator_json, '$.sourceKind')) > 0
                                AND json_type(locator_json, '$.charStart') = 'integer'
                                AND json_type(locator_json, '$.charEnd') = 'integer'
                                AND json_extract(locator_json, '$.charStart') = char_start
                                AND json_extract(locator_json, '$.charEnd') = char_end
                                AND json_type(locator_json, '$.source_kind') IS NULL
                                AND json_type(locator_json, '$.page_index') IS NULL
                                AND json_type(locator_json, '$.page_label') IS NULL
                                AND json_type(locator_json, '$.sheet_name') IS NULL
                                AND json_type(locator_json, '$.cell_range') IS NULL
                                AND json_type(locator_json, '$.email_part_path') IS NULL
                                AND json_type(locator_json, '$.char_start') IS NULL
                                AND json_type(locator_json, '$.char_end') IS NULL
                                AND json_type(locator_json, '$.bounding_boxes_json') IS NULL
                                AND json_type(locator_json, '$.part_index') IS NULL
                                AND (
                                    json_type(locator_json, '$.partIndex') IS NULL
                                    OR (
                                        json_type(locator_json, '$.partIndex') = 'integer'
                                        AND json_extract(locator_json, '$.partIndex') = part_index
                                    )
                                )
                            )
                        ), 0) = 1
                    ),
                    UNIQUE (partition_id, ordinal),
                    UNIQUE (run_id, revision_id, char_start, char_end),
                    FOREIGN KEY (run_id)
                        REFERENCES corpus_analysis_runs(id) ON DELETE CASCADE,
                    FOREIGN KEY (partition_id, run_id)
                        REFERENCES corpus_analysis_partitions(id, run_id) ON DELETE CASCADE
                )
                """)
            try db.create(
                index: "idx_corpus_analysis_slices_run_order",
                on: "corpus_analysis_partition_slices",
                columns: ["run_id", "partition_id", "ordinal", "id"]
            )

            // A v2 exact partition may become succeeded only through a durable,
            // terminal attempt. The trigger is deliberately scoped through its
            // owning run so chronology and every legacy v1 ledger keep their
            // established disposition behavior.
            let exactSucceededAttemptChecks = """
                SELECT CASE WHEN typeof(NEW.attempt_count) <> 'integer'
                        OR NEW.attempt_count < 1
                        OR typeof(NEW.attempt_history_json) <> 'text'
                        OR json_valid(NEW.attempt_history_json) <> 1
                    THEN RAISE(ABORT, 'exact success requires valid attempt history') END;
                SELECT CASE WHEN json_type(NEW.attempt_history_json) IS NOT 'array'
                        OR json_array_length(NEW.attempt_history_json) <> NEW.attempt_count
                        OR (
                            typeof(NEW.started_at) NOT IN ('integer', 'real')
                            AND (
                                typeof(NEW.started_at) <> 'text'
                                OR julianday(NEW.started_at) IS NULL
                            )
                        )
                        OR (
                            typeof(NEW.completed_at) NOT IN ('integer', 'real')
                            AND (
                                typeof(NEW.completed_at) <> 'text'
                                OR julianday(NEW.completed_at) IS NULL
                            )
                        )
                        OR (
                            typeof(NEW.started_at) IN ('integer', 'real')
                            AND typeof(NEW.completed_at) IN ('integer', 'real')
                            AND NEW.completed_at < NEW.started_at
                        )
                        OR (
                            typeof(NEW.started_at) = 'text'
                            AND typeof(NEW.completed_at) = 'text'
                            AND julianday(NEW.completed_at) < julianday(NEW.started_at)
                        )
                        OR (
                            (typeof(NEW.started_at) IN ('integer', 'real'))
                            <> (typeof(NEW.completed_at) IN ('integer', 'real'))
                        )
                    THEN RAISE(ABORT, 'exact success requires coherent attempt history') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM json_each(NEW.attempt_history_json) AS attempt
                        WHERE attempt.type IS NOT 'object'
                           OR json_type(attempt.value, '$.attempt_number') IS NOT 'integer'
                           OR json_extract(attempt.value, '$.attempt_number')
                                <> CAST(attempt.key AS INTEGER) + 1
                           OR json_type(attempt.value, '$.outcome') IS NOT 'text'
                           OR json_extract(attempt.value, '$.outcome')
                                NOT IN ('failed', 'cancelled', 'succeeded')
                           OR (
                               json_type(attempt.value, '$.retryable') IS NOT 'true'
                               AND json_type(attempt.value, '$.retryable') IS NOT 'false'
                           )
                           OR (
                               json_type(attempt.value, '$.started_at') IS NOT 'integer'
                               AND json_type(attempt.value, '$.started_at') IS NOT 'real'
                           )
                           OR (
                               json_type(attempt.value, '$.completed_at') IS NOT 'integer'
                               AND json_type(attempt.value, '$.completed_at') IS NOT 'real'
                           )
                           OR json_extract(attempt.value, '$.completed_at')
                                < json_extract(attempt.value, '$.started_at')
                           OR (
                               CAST(attempt.key AS INTEGER) < NEW.attempt_count - 1
                               AND json_extract(attempt.value, '$.outcome') = 'succeeded'
                           )
                           OR (
                               CAST(attempt.key AS INTEGER) = NEW.attempt_count - 1
                               AND (
                                   json_extract(attempt.value, '$.outcome') IS NOT 'succeeded'
                                   OR json_type(attempt.value, '$.retryable') IS NOT 'false'
                                   OR (
                                       json_type(attempt.value, '$.error_summary') IS NOT NULL
                                       AND json_type(attempt.value, '$.error_summary') IS NOT 'null'
                                   )
                               )
                           )
                    )
                    THEN RAISE(ABORT, 'exact success requires a terminal succeeded attempt') END;
                SELECT CASE WHEN typeof(NEW.findings_json) <> 'text'
                        OR json_valid(NEW.findings_json) <> 1
                    THEN RAISE(ABORT, 'exact success requires valid findings JSON') END;
                SELECT CASE WHEN json_type(NEW.findings_json) IS NOT 'array'
                    THEN RAISE(ABORT, 'exact success requires a findings array') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM json_each(NEW.findings_json) AS finding
                        WHERE finding.type IS NOT 'object'
                           OR json_type(finding.value, '$.id') IS NOT 'text'
                           OR length(json_extract(finding.value, '$.id')) = 0
                           OR json_type(finding.value, '$.value') IS NOT 'text'
                           OR json_type(finding.value, '$.evidence') IS NOT 'array'
                           OR (
                               json_type(finding.value, '$.contrary_evidence') IS NOT NULL
                               AND json_type(
                                   finding.value, '$.contrary_evidence'
                               ) IS NOT 'null'
                               AND json_type(
                                   finding.value, '$.contrary_evidence'
                               ) IS NOT 'array'
                           )
                           OR (
                               json_array_length(finding.value, '$.evidence')
                               + COALESCE(json_array_length(
                                   finding.value, '$.contrary_evidence'
                               ), 0)
                           ) < 1
                           OR EXISTS (
                               SELECT 1
                               FROM json_each(finding.value, '$.evidence') AS evidence
                               WHERE evidence.type IS NOT 'object'
                                  OR json_type(
                                      evidence.value, '$.document_id'
                                  ) IS NOT 'text'
                                  OR length(json_extract(
                                      evidence.value, '$.document_id'
                                  )) = 0
                                  OR json_type(
                                      evidence.value, '$.revision_id'
                                  ) IS NOT 'text'
                                  OR length(json_extract(
                                      evidence.value, '$.revision_id'
                                  )) = 0
                                  OR json_type(
                                      evidence.value, '$.locator_json'
                                  ) IS NOT 'text'
                                  OR length(json_extract(
                                      evidence.value, '$.locator_json'
                                  )) = 0
                                  OR (
                                      json_type(evidence.value, '$.quote') IS NOT NULL
                                      AND json_type(evidence.value, '$.quote') IS NOT 'null'
                                      AND (
                                          json_type(evidence.value, '$.quote') IS NOT 'text'
                                          OR length(json_extract(
                                              evidence.value, '$.quote'
                                          )) = 0
                                      )
                                  )
                                  OR (
                                      (
                                          json_type(
                                              evidence.value, '$.char_start'
                                          ) IS NULL
                                          OR json_type(
                                              evidence.value, '$.char_start'
                                          ) IS 'null'
                                      ) <> (
                                          json_type(
                                              evidence.value, '$.char_end'
                                          ) IS NULL
                                          OR json_type(
                                              evidence.value, '$.char_end'
                                          ) IS 'null'
                                      )
                                  )
                                  OR (
                                      json_type(
                                          evidence.value, '$.char_start'
                                      ) IS NOT NULL
                                      AND json_type(
                                          evidence.value, '$.char_start'
                                      ) IS NOT 'null'
                                      AND (
                                          json_type(
                                              evidence.value, '$.char_start'
                                          ) IS NOT 'integer'
                                          OR json_type(
                                              evidence.value, '$.char_end'
                                          ) IS NOT 'integer'
                                          OR json_extract(
                                              evidence.value, '$.char_start'
                                          ) < 0
                                          OR json_extract(
                                              evidence.value, '$.char_end'
                                          ) <= json_extract(
                                              evidence.value, '$.char_start'
                                          )
                                      )
                                  )
                                  OR NOT EXISTS (
                                      SELECT 1
                                      FROM corpus_analysis_partition_slices AS slice
                                      WHERE slice.run_id = NEW.run_id
                                        AND slice.partition_id = NEW.id
                                        AND slice.document_id = json_extract(
                                            evidence.value, '$.document_id'
                                        )
                                        AND slice.revision_id = json_extract(
                                            evidence.value, '$.revision_id'
                                        )
                                        AND slice.locator_json = json_extract(
                                            evidence.value, '$.locator_json'
                                        )
                                        AND (
                                            json_type(
                                                evidence.value, '$.char_end'
                                            ) IS NULL
                                            OR json_type(
                                                evidence.value, '$.char_end'
                                            ) IS 'null'
                                            OR json_extract(
                                                evidence.value, '$.char_end'
                                            ) <= slice.char_end - slice.char_start
                                        )
                                  )
                           )
                           OR EXISTS (
                               SELECT 1
                               FROM json_each(
                                   finding.value, '$.contrary_evidence'
                               ) AS evidence
                               WHERE evidence.type IS NOT 'object'
                                  OR json_type(
                                      evidence.value, '$.document_id'
                                  ) IS NOT 'text'
                                  OR length(json_extract(
                                      evidence.value, '$.document_id'
                                  )) = 0
                                  OR json_type(
                                      evidence.value, '$.revision_id'
                                  ) IS NOT 'text'
                                  OR length(json_extract(
                                      evidence.value, '$.revision_id'
                                  )) = 0
                                  OR json_type(
                                      evidence.value, '$.locator_json'
                                  ) IS NOT 'text'
                                  OR length(json_extract(
                                      evidence.value, '$.locator_json'
                                  )) = 0
                                  OR (
                                      json_type(evidence.value, '$.quote') IS NOT NULL
                                      AND json_type(evidence.value, '$.quote') IS NOT 'null'
                                      AND (
                                          json_type(evidence.value, '$.quote') IS NOT 'text'
                                          OR length(json_extract(
                                              evidence.value, '$.quote'
                                          )) = 0
                                      )
                                  )
                                  OR (
                                      (
                                          json_type(
                                              evidence.value, '$.char_start'
                                          ) IS NULL
                                          OR json_type(
                                              evidence.value, '$.char_start'
                                          ) IS 'null'
                                      ) <> (
                                          json_type(
                                              evidence.value, '$.char_end'
                                          ) IS NULL
                                          OR json_type(
                                              evidence.value, '$.char_end'
                                          ) IS 'null'
                                      )
                                  )
                                  OR (
                                      json_type(
                                          evidence.value, '$.char_start'
                                      ) IS NOT NULL
                                      AND json_type(
                                          evidence.value, '$.char_start'
                                      ) IS NOT 'null'
                                      AND (
                                          json_type(
                                              evidence.value, '$.char_start'
                                          ) IS NOT 'integer'
                                          OR json_type(
                                              evidence.value, '$.char_end'
                                          ) IS NOT 'integer'
                                          OR json_extract(
                                              evidence.value, '$.char_start'
                                          ) < 0
                                          OR json_extract(
                                              evidence.value, '$.char_end'
                                          ) <= json_extract(
                                              evidence.value, '$.char_start'
                                          )
                                      )
                                  )
                                  OR NOT EXISTS (
                                      SELECT 1
                                      FROM corpus_analysis_partition_slices AS slice
                                      WHERE slice.run_id = NEW.run_id
                                        AND slice.partition_id = NEW.id
                                        AND slice.document_id = json_extract(
                                            evidence.value, '$.document_id'
                                        )
                                        AND slice.revision_id = json_extract(
                                            evidence.value, '$.revision_id'
                                        )
                                        AND slice.locator_json = json_extract(
                                            evidence.value, '$.locator_json'
                                        )
                                        AND (
                                            json_type(
                                                evidence.value, '$.char_end'
                                            ) IS NULL
                                            OR json_type(
                                                evidence.value, '$.char_end'
                                            ) IS 'null'
                                            OR json_extract(
                                                evidence.value, '$.char_end'
                                            ) <= slice.char_end - slice.char_start
                                        )
                                  )
                           )
                    )
                    THEN RAISE(ABORT, 'exact success findings are not decodable') END;
                """
            let exactSucceededAttemptScope = """
                NEW.disposition = 'succeeded'
                AND EXISTS (
                    SELECT 1
                    FROM corpus_analysis_runs AS run
                    WHERE run.id = NEW.run_id
                      AND run.task_kind = 'exhaustive_list'
                      AND run.request_schema_version = 2
                      AND run.partition_strategy_version = 2
                      AND run.partition_strategy GLOB 'exact_revision_slice*'
                )
                """
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_success_insert_guard
                BEFORE INSERT ON corpus_analysis_partitions
                WHEN \(exactSucceededAttemptScope)
                BEGIN
                    \(exactSucceededAttemptChecks)
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_success_update_guard
                BEFORE UPDATE ON corpus_analysis_partitions
                WHEN \(exactSucceededAttemptScope)
                BEGIN
                    \(exactSucceededAttemptChecks)
                END
                """)

            // Preserve v064's universal corpus-complete baseline for every task,
            // and apply it to direct inserts as well as lifecycle updates.
            let corpusCompleteBaselineChecks = """
                SELECT CASE WHEN NOT EXISTS (
                        SELECT 1 FROM corpus_analysis_partitions WHERE run_id = NEW.id
                    )
                    THEN RAISE(ABORT, 'corpus_complete requires planned partitions') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1 FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition <> 'succeeded'
                    )
                    THEN RAISE(ABORT, 'corpus_complete requires all partitions succeeded') END;
                SELECT CASE WHEN COALESCE(
                        json_extract(NEW.coverage_json, '$.excluded_members_disclosed'), 0
                    ) <> 1
                    THEN RAISE(ABORT, 'corpus_complete requires disclosed exclusions') END;
                """
            try db.execute(sql: "DROP TRIGGER IF EXISTS corpus_analysis_complete_guard")
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_complete_guard
                BEFORE UPDATE OF status, assurance_state, coverage_json
                ON corpus_analysis_runs
                WHEN NEW.status = 'persisted'
                  AND NEW.assurance_state = 'corpus_complete'
                BEGIN
                    \(corpusCompleteBaselineChecks)
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_complete_insert_guard
                BEFORE INSERT ON corpus_analysis_runs
                WHEN NEW.status = 'persisted'
                  AND NEW.assurance_state = 'corpus_complete'
                BEGIN
                    \(corpusCompleteBaselineChecks)
                END
                """)

            // Case File Review's two export-eligible assurance states require a
            // complete v2 exact-slice ledger. This guard is intentionally scoped
            // by task kind, never by request version, so chronology remains on
            // its compatible v1 revision-ledger contract.
            let exhaustiveExportChecks = """
                SELECT CASE WHEN NEW.request_schema_version IS NOT 2
                    THEN RAISE(ABORT, 'exhaustive export requires v2 request lineage') END;
                SELECT CASE WHEN typeof(NEW.request_digest) <> 'text'
                        OR length(NEW.request_digest) <> 64
                        OR NEW.request_digest GLOB '*[^0-9a-f]*'
                    THEN RAISE(ABORT, 'exhaustive export requires a valid request digest') END;
                SELECT CASE WHEN NEW.partition_strategy_version IS NOT 2
                        OR NEW.partition_strategy NOT GLOB 'exact_revision_slice*'
                    THEN RAISE(ABORT, 'exhaustive export requires the exact-slice strategy') END;
                SELECT CASE WHEN typeof(NEW.corpus_snapshot_json) <> 'text'
                        OR json_valid(NEW.corpus_snapshot_json) <> 1
                    THEN RAISE(ABORT, 'exhaustive export requires a valid frozen snapshot') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        WHERE json_type(NEW.corpus_snapshot_json) IS NOT 'object'
                           OR json_type(NEW.corpus_snapshot_json, '$.schema_version') IS NOT 'integer'
                           OR json_extract(NEW.corpus_snapshot_json, '$.schema_version') <= 0
                           OR json_type(NEW.corpus_snapshot_json, '$.members') IS NOT 'array'
                    )
                    THEN RAISE(ABORT, 'exhaustive export requires a typed frozen snapshot') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                        WHERE member.type IS NOT 'object'
                           OR json_type(member.value, '$.member_key') IS NOT 'text'
                           OR length(json_extract(member.value, '$.member_key')) = 0
                           OR json_type(member.value, '$.display_name') IS NOT 'text'
                           OR length(json_extract(member.value, '$.display_name')) = 0
                           OR json_type(member.value, '$.disposition') IS NOT 'text'
                           OR json_extract(member.value, '$.disposition') NOT IN ('eligible', 'excluded')
                           OR json_type(member.value, '$.revision_ids') IS NOT 'array'
                           OR (
                               json_type(member.value, '$.document_id') IS NOT NULL
                               AND json_type(member.value, '$.document_id') IS NOT 'null'
                               AND (
                                   json_type(member.value, '$.document_id') IS NOT 'text'
                                   OR length(json_extract(member.value, '$.document_id')) = 0
                               )
                           )
                           OR (
                               json_type(member.value, '$.index_state') IS NOT NULL
                               AND json_type(member.value, '$.index_state') IS NOT 'null'
                               AND json_type(member.value, '$.index_state') IS NOT 'text'
                           )
                           OR (
                               json_type(member.value, '$.reason') IS NOT NULL
                               AND json_type(member.value, '$.reason') IS NOT 'null'
                               AND json_type(member.value, '$.reason') IS NOT 'text'
                           )
                           OR (
                               json_extract(member.value, '$.disposition') = 'eligible'
                               AND (
                                   json_type(member.value, '$.document_id') IS NOT 'text'
                                   OR length(json_extract(member.value, '$.document_id')) = 0
                                   OR json_array_length(member.value, '$.revision_ids') = 0
                               )
                          )
                    )
                    THEN RAISE(ABORT, 'eligible snapshot member is malformed') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                        JOIN json_each(member.value, '$.revision_ids') AS revision
                        WHERE revision.type IS NOT 'text' OR length(revision.value) = 0
                    )
                    THEN RAISE(ABORT, 'snapshot revision identity is malformed') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                        GROUP BY json_extract(member.value, '$.member_key')
                        HAVING COUNT(*) > 1
                    )
                    THEN RAISE(ABORT, 'snapshot member identities are not unique') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                        WHERE EXISTS (
                            SELECT 1
                            FROM json_each(member.value, '$.revision_ids') AS revision
                            GROUP BY revision.value
                            HAVING COUNT(*) > 1
                        )
                    )
                    THEN RAISE(ABORT, 'snapshot revision identities are not unique') END;
                SELECT CASE WHEN typeof(NEW.coverage_json) <> 'text'
                        OR json_valid(NEW.coverage_json) <> 1
                    THEN RAISE(ABORT, 'exhaustive export requires valid coverage') END;
                SELECT CASE WHEN json_type(NEW.coverage_json) IS NOT 'object'
                        OR json_type(NEW.coverage_json, '$.schema_version') IS NOT 'integer'
                        OR json_extract(NEW.coverage_json, '$.schema_version') <= 0
                        OR json_type(NEW.coverage_json, '$.snapshot_member_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.eligible_member_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.excluded_member_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.excluded_members_disclosed') IS NOT 'true'
                        OR json_type(NEW.coverage_json, '$.partition_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.pending_partition_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.succeeded_partition_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.failed_partition_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.cancelled_partition_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.excluded_partition_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.terminal_partition_count') IS NOT 'integer'
                        OR json_type(NEW.coverage_json, '$.balance_error_count') IS NOT 'integer'
                    THEN RAISE(ABORT, 'exhaustive export requires complete typed coverage') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1 FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition <> 'succeeded'
                    )
                    THEN RAISE(ABORT, 'exhaustive export requires all partitions succeeded') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        WHERE partition.run_id = NEW.id
                          AND (
                              typeof(partition.attempt_count) <> 'integer'
                              OR partition.attempt_count < 1
                              OR typeof(partition.attempt_history_json) <> 'text'
                              OR json_valid(partition.attempt_history_json) <> 1
                              OR (
                                  typeof(partition.started_at) NOT IN ('integer', 'real')
                                  AND (
                                      typeof(partition.started_at) <> 'text'
                                      OR julianday(partition.started_at) IS NULL
                                  )
                              )
                              OR (
                                  typeof(partition.completed_at) NOT IN ('integer', 'real')
                                  AND (
                                      typeof(partition.completed_at) <> 'text'
                                      OR julianday(partition.completed_at) IS NULL
                                  )
                              )
                              OR (
                                  typeof(partition.started_at) IN ('integer', 'real')
                                  AND typeof(partition.completed_at) IN ('integer', 'real')
                                  AND partition.completed_at < partition.started_at
                              )
                              OR (
                                  typeof(partition.started_at) = 'text'
                                  AND typeof(partition.completed_at) = 'text'
                                  AND julianday(partition.completed_at)
                                        < julianday(partition.started_at)
                              )
                              OR (
                                  (typeof(partition.started_at) IN ('integer', 'real'))
                                  <> (typeof(partition.completed_at) IN ('integer', 'real'))
                              )
                              OR typeof(partition.findings_json) <> 'text'
                              OR json_valid(partition.findings_json) <> 1
                          )
                    )
                    THEN RAISE(ABORT, 'exhaustive export requires valid checkpoints') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        WHERE partition.run_id = NEW.id
                          AND (
                              json_type(partition.attempt_history_json) IS NOT 'array'
                              OR json_array_length(partition.attempt_history_json)
                                    <> partition.attempt_count
                              OR json_type(partition.findings_json) IS NOT 'array'
                              OR EXISTS (
                                  SELECT 1
                                  FROM json_each(partition.attempt_history_json) AS attempt
                                  WHERE attempt.type IS NOT 'object'
                                     OR json_type(
                                         attempt.value, '$.attempt_number'
                                     ) IS NOT 'integer'
                                     OR json_extract(
                                         attempt.value, '$.attempt_number'
                                     ) <> CAST(attempt.key AS INTEGER) + 1
                                     OR json_type(attempt.value, '$.outcome') IS NOT 'text'
                                     OR json_extract(attempt.value, '$.outcome')
                                          NOT IN ('failed', 'cancelled', 'succeeded')
                                     OR (
                                         json_type(
                                             attempt.value, '$.retryable'
                                         ) IS NOT 'true'
                                         AND json_type(
                                             attempt.value, '$.retryable'
                                         ) IS NOT 'false'
                                     )
                                     OR (
                                         json_type(
                                             attempt.value, '$.started_at'
                                         ) IS NOT 'integer'
                                         AND json_type(
                                             attempt.value, '$.started_at'
                                         ) IS NOT 'real'
                                     )
                                     OR (
                                         json_type(
                                             attempt.value, '$.completed_at'
                                         ) IS NOT 'integer'
                                         AND json_type(
                                             attempt.value, '$.completed_at'
                                         ) IS NOT 'real'
                                     )
                                     OR json_extract(attempt.value, '$.completed_at')
                                          < json_extract(attempt.value, '$.started_at')
                                     OR (
                                         CAST(attempt.key AS INTEGER)
                                            < partition.attempt_count - 1
                                         AND json_extract(
                                             attempt.value, '$.outcome'
                                         ) = 'succeeded'
                                     )
                                     OR (
                                         CAST(attempt.key AS INTEGER)
                                            = partition.attempt_count - 1
                                         AND (
                                             json_extract(
                                                 attempt.value, '$.outcome'
                                             ) IS NOT 'succeeded'
                                             OR json_type(
                                                 attempt.value, '$.retryable'
                                             ) IS NOT 'false'
                                             OR (
                                                 json_type(
                                                     attempt.value, '$.error_summary'
                                                 ) IS NOT NULL
                                                 AND json_type(
                                                     attempt.value, '$.error_summary'
                                                 ) IS NOT 'null'
                                             )
                                         )
                                     )
                              )
                              OR EXISTS (
                                  SELECT 1
                                  FROM json_each(partition.findings_json) AS finding
                                  WHERE finding.type IS NOT 'object'
                                     OR json_type(finding.value, '$.id') IS NOT 'text'
                                     OR length(json_extract(finding.value, '$.id')) = 0
                                     OR json_type(finding.value, '$.value') IS NOT 'text'
                                     OR json_type(
                                         finding.value, '$.evidence'
                                     ) IS NOT 'array'
                                     OR (
                                         json_type(
                                             finding.value, '$.contrary_evidence'
                                         ) IS NOT NULL
                                         AND json_type(
                                             finding.value, '$.contrary_evidence'
                                         ) IS NOT 'null'
                                         AND json_type(
                                             finding.value, '$.contrary_evidence'
                                         ) IS NOT 'array'
                                     )
                                     OR EXISTS (
                                         SELECT 1
                                         FROM json_each(
                                             finding.value, '$.evidence'
                                         ) AS evidence
                                         WHERE evidence.type IS NOT 'object'
                                            OR json_type(
                                                evidence.value, '$.document_id'
                                            ) IS NOT 'text'
                                            OR length(json_extract(
                                                evidence.value, '$.document_id'
                                            )) = 0
                                            OR json_type(
                                                evidence.value, '$.revision_id'
                                            ) IS NOT 'text'
                                            OR length(json_extract(
                                                evidence.value, '$.revision_id'
                                            )) = 0
                                            OR json_type(
                                                evidence.value, '$.locator_json'
                                            ) IS NOT 'text'
                                            OR length(json_extract(
                                                evidence.value, '$.locator_json'
                                            )) = 0
                                     )
                                     OR EXISTS (
                                         SELECT 1
                                         FROM json_each(
                                             finding.value, '$.contrary_evidence'
                                         ) AS evidence
                                         WHERE evidence.type IS NOT 'object'
                                            OR json_type(
                                                evidence.value, '$.document_id'
                                            ) IS NOT 'text'
                                            OR length(json_extract(
                                                evidence.value, '$.document_id'
                                            )) = 0
                                            OR json_type(
                                                evidence.value, '$.revision_id'
                                            ) IS NOT 'text'
                                            OR length(json_extract(
                                                evidence.value, '$.revision_id'
                                            )) = 0
                                            OR json_type(
                                                evidence.value, '$.locator_json'
                                            ) IS NOT 'text'
                                            OR length(json_extract(
                                                evidence.value, '$.locator_json'
                                            )) = 0
                                     )
                              )
                          )
                    )
                    THEN RAISE(ABORT, 'exhaustive export requires decodable succeeded proof') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        JOIN json_each(partition.findings_json) AS finding
                        WHERE partition.run_id = NEW.id
                          AND (
                              (
                                  json_array_length(finding.value, '$.evidence')
                                  + COALESCE(json_array_length(
                                      finding.value, '$.contrary_evidence'
                                  ), 0)
                              ) < 1
                              OR EXISTS (
                                  SELECT 1
                                  FROM json_each(
                                      finding.value, '$.evidence'
                                  ) AS evidence
                                  WHERE NOT EXISTS (
                                      SELECT 1
                                      FROM corpus_analysis_partition_slices AS slice
                                      WHERE slice.run_id = partition.run_id
                                        AND slice.partition_id = partition.id
                                        AND slice.document_id = json_extract(
                                            evidence.value, '$.document_id'
                                        )
                                        AND slice.revision_id = json_extract(
                                            evidence.value, '$.revision_id'
                                        )
                                        AND slice.locator_json = json_extract(
                                            evidence.value, '$.locator_json'
                                        )
                                        AND (
                                            json_type(
                                                evidence.value, '$.char_end'
                                            ) IS NULL
                                            OR json_type(
                                                evidence.value, '$.char_end'
                                            ) IS 'null'
                                            OR json_extract(
                                                evidence.value, '$.char_end'
                                            ) <= slice.char_end - slice.char_start
                                        )
                                  )
                              )
                              OR EXISTS (
                                  SELECT 1
                                  FROM json_each(
                                      finding.value, '$.contrary_evidence'
                                  ) AS evidence
                                  WHERE NOT EXISTS (
                                      SELECT 1
                                      FROM corpus_analysis_partition_slices AS slice
                                      WHERE slice.run_id = partition.run_id
                                        AND slice.partition_id = partition.id
                                        AND slice.document_id = json_extract(
                                            evidence.value, '$.document_id'
                                        )
                                        AND slice.revision_id = json_extract(
                                            evidence.value, '$.revision_id'
                                        )
                                        AND slice.locator_json = json_extract(
                                            evidence.value, '$.locator_json'
                                        )
                                        AND (
                                            json_type(
                                                evidence.value, '$.char_end'
                                            ) IS NULL
                                            OR json_type(
                                                evidence.value, '$.char_end'
                                            ) IS 'null'
                                            OR json_extract(
                                                evidence.value, '$.char_end'
                                            ) <= slice.char_end - slice.char_start
                                        )
                                  )
                              )
                          )
                    )
                    THEN RAISE(ABORT, 'exhaustive export evidence is outside exact slices') END;
                SELECT CASE WHEN NOT EXISTS (
                        SELECT 1 FROM corpus_analysis_partitions WHERE run_id = NEW.id
                    )
                    THEN RAISE(ABORT, 'exhaustive export requires planned partitions') END;
                SELECT CASE WHEN NEW.structured_output_version_id IS NOT NULL
                        AND (
                            NOT EXISTS (
                                SELECT 1
                                FROM structured_output_versions AS version
                                JOIN structured_outputs AS output
                                  ON output.id = version.structured_output_id
                                WHERE version.id = NEW.structured_output_version_id
                                  AND version.assurance_state = NEW.assurance_state
                                  AND output.matter_id = NEW.matter_id
                                  AND output.output_type = 'document_exhaustive_list'
                                  AND output.deleted_at IS NULL
                            )
                            OR EXISTS (
                                SELECT 1
                                FROM corpus_analysis_runs AS other_run
                                WHERE other_run.id IS NOT NEW.id
                                  AND other_run.structured_output_version_id
                                        = NEW.structured_output_version_id
                            )
                        )
                    THEN RAISE(ABORT, 'exhaustive export attachment is incompatible') END;
                SELECT CASE WHEN json_extract(
                        NEW.coverage_json, '$.snapshot_member_count'
                    ) <> json_array_length(NEW.corpus_snapshot_json, '$.members')
                    OR json_extract(NEW.coverage_json, '$.eligible_member_count') <> (
                        SELECT COUNT(*)
                        FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                        WHERE json_extract(member.value, '$.disposition') = 'eligible'
                    )
                    OR json_extract(NEW.coverage_json, '$.excluded_member_count') <> (
                        SELECT COUNT(*)
                        FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                        WHERE json_extract(member.value, '$.disposition') = 'excluded'
                    )
                    THEN RAISE(ABORT, 'exhaustive export coverage member counts mismatch') END;
                SELECT CASE WHEN json_extract(NEW.coverage_json, '$.partition_count') <> (
                        SELECT COUNT(*) FROM corpus_analysis_partitions WHERE run_id = NEW.id
                    )
                    OR json_extract(NEW.coverage_json, '$.pending_partition_count') <> (
                        SELECT COUNT(*) FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition = 'pending'
                    )
                    OR json_extract(NEW.coverage_json, '$.succeeded_partition_count') <> (
                        SELECT COUNT(*) FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition = 'succeeded'
                    )
                    OR json_extract(NEW.coverage_json, '$.failed_partition_count') <> (
                        SELECT COUNT(*) FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition = 'failed'
                    )
                    OR json_extract(NEW.coverage_json, '$.cancelled_partition_count') <> (
                        SELECT COUNT(*) FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition = 'cancelled'
                    )
                    OR json_extract(NEW.coverage_json, '$.excluded_partition_count') <> (
                        SELECT COUNT(*) FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition = 'excluded'
                    )
                    OR json_extract(NEW.coverage_json, '$.terminal_partition_count') <> (
                        SELECT COUNT(*) FROM corpus_analysis_partitions
                        WHERE run_id = NEW.id AND disposition IN (
                            'succeeded', 'failed', 'cancelled', 'excluded'
                        )
                    )
                    OR json_extract(NEW.coverage_json, '$.balance_error_count') <> 0
                    THEN RAISE(ABORT, 'exhaustive export coverage partition counts mismatch') END;
                SELECT CASE WHEN NOT EXISTS (
                        SELECT 1 FROM corpus_analysis_partition_slices WHERE run_id = NEW.id
                    )
                    THEN RAISE(ABORT, 'exhaustive export requires exact slices') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        WHERE partition.run_id = NEW.id
                          AND NOT EXISTS (
                              SELECT 1 FROM corpus_analysis_partition_slices AS slice
                              WHERE slice.run_id = NEW.id
                                AND slice.partition_id = partition.id
                          )
                    )
                    THEN RAISE(ABORT, 'exhaustive export requires slices for every partition') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        WHERE partition.run_id = NEW.id
                          AND (
                              typeof(partition.input_revision_ids_json) <> 'text'
                              OR json_valid(partition.input_revision_ids_json) <> 1
                          )
                    )
                    THEN RAISE(ABORT, 'partition revision ledger is invalid JSON') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        WHERE partition.run_id = NEW.id
                          AND (
                              json_type(partition.input_revision_ids_json) IS NOT 'array'
                              OR json_array_length(partition.input_revision_ids_json) = 0
                          )
                    )
                    THEN RAISE(ABORT, 'partition revision ledger must be a nonempty array') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        JOIN json_each(partition.input_revision_ids_json) AS input_revision
                        WHERE partition.run_id = NEW.id
                          AND (
                              input_revision.type IS NOT 'text'
                              OR length(input_revision.value) = 0
                          )
                    )
                    THEN RAISE(ABORT, 'partition revision identity is malformed') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        WHERE partition.run_id = NEW.id
                          AND EXISTS (
                              SELECT 1
                              FROM json_each(partition.input_revision_ids_json) AS input_revision
                              GROUP BY input_revision.value
                              HAVING COUNT(*) > 1
                          )
                    )
                    THEN RAISE(ABORT, 'partition revision identities are not unique') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partition_slices AS slice
                        JOIN corpus_analysis_partitions AS partition
                          ON partition.id = slice.partition_id
                         AND partition.run_id = slice.run_id
                        WHERE slice.run_id = NEW.id
                          AND NOT EXISTS (
                              SELECT 1
                              FROM json_each(partition.input_revision_ids_json) AS input_revision
                              WHERE input_revision.value = slice.revision_id
                          )
                    )
                    THEN RAISE(ABORT, 'exhaustive export slice is outside its partition revisions') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partitions AS partition
                        JOIN json_each(partition.input_revision_ids_json) AS input_revision
                        WHERE partition.run_id = NEW.id
                          AND NOT EXISTS (
                              SELECT 1
                              FROM corpus_analysis_partition_slices AS slice
                              WHERE slice.run_id = NEW.id
                                AND slice.partition_id = partition.id
                                AND slice.revision_id = input_revision.value
                          )
                    )
                    THEN RAISE(ABORT, 'partition revision is missing exact slices') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partition_slices AS slice
                        WHERE slice.run_id = NEW.id
                          AND NOT EXISTS (
                              SELECT 1
                              FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                              WHERE json_extract(member.value, '$.disposition') = 'eligible'
                                AND json_extract(member.value, '$.member_key') = slice.member_key
                                AND json_extract(member.value, '$.document_id') = slice.document_id
                                AND EXISTS (
                                    SELECT 1
                                    FROM json_each(member.value, '$.revision_ids') AS revision
                                    WHERE revision.value = slice.revision_id
                                )
                          )
                    )
                    THEN RAISE(ABORT, 'exhaustive export contains an extraneous slice identity') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM json_each(NEW.corpus_snapshot_json, '$.members') AS member
                        JOIN json_each(member.value, '$.revision_ids') AS revision
                        WHERE json_extract(member.value, '$.disposition') = 'eligible'
                          AND NOT EXISTS (
                              SELECT 1
                              FROM corpus_analysis_partition_slices AS slice
                              WHERE slice.run_id = NEW.id
                                AND slice.member_key = json_extract(member.value, '$.member_key')
                                AND slice.document_id = json_extract(member.value, '$.document_id')
                                AND slice.revision_id = revision.value
                          )
                    )
                    THEN RAISE(ABORT, 'exhaustive export is missing an eligible revision') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partition_slices
                        WHERE run_id = NEW.id
                        GROUP BY partition_id
                        HAVING MIN(ordinal) <> 0 OR MAX(ordinal) <> COUNT(*) - 1
                    )
                    THEN RAISE(ABORT, 'exhaustive export slice ordinals are not contiguous') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partition_slices
                        WHERE run_id = NEW.id
                        GROUP BY member_key, document_id, revision_id
                        HAVING MIN(part_index) <> MAX(part_index)
                    )
                    THEN RAISE(ABORT, 'frozen revision selects multiple part indices') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partition_slices
                        WHERE run_id = NEW.id
                        GROUP BY member_key, document_id, part_index, revision_id
                        HAVING MIN(revision_char_count) <> MAX(revision_char_count)
                            OR MIN(char_start) <> 0
                            OR MAX(char_end) <> MAX(revision_char_count)
                            OR SUM(char_end - char_start) <> MAX(revision_char_count)
                    )
                    THEN RAISE(ABORT, 'exhaustive export exact ranges are incomplete') END;
                SELECT CASE WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_partition_slices AS left_slice
                        JOIN corpus_analysis_partition_slices AS right_slice
                          ON right_slice.run_id = left_slice.run_id
                         AND right_slice.member_key = left_slice.member_key
                         AND right_slice.document_id = left_slice.document_id
                         AND right_slice.part_index = left_slice.part_index
                         AND right_slice.revision_id = left_slice.revision_id
                         AND right_slice.id > left_slice.id
                         AND left_slice.char_start < right_slice.char_end
                         AND right_slice.char_start < left_slice.char_end
                        WHERE left_slice.run_id = NEW.id
                    )
                    THEN RAISE(ABORT, 'exhaustive export exact ranges overlap') END;
                """
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exhaustive_export_update_guard
                BEFORE UPDATE OF task_kind, status, assurance_state, coverage_json,
                    request_schema_version, request_digest, corpus_snapshot_json,
                    partition_strategy, partition_strategy_version
                ON corpus_analysis_runs
                WHEN NEW.task_kind = 'exhaustive_list'
                  AND NEW.status = 'persisted'
                  AND NEW.assurance_state IN ('corpus_complete', 'proposition_supported')
                BEGIN
                    \(exhaustiveExportChecks)
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exhaustive_export_insert_guard
                BEFORE INSERT ON corpus_analysis_runs
                WHEN NEW.task_kind = 'exhaustive_list'
                  AND NEW.status = 'persisted'
                  AND NEW.assurance_state IN ('corpus_complete', 'proposition_supported')
                BEGIN
                    \(exhaustiveExportChecks)
                END
                """)

            // The request digest is meaningful only while every value it binds
            // remains unchanged. A finalized v2 claim must be explicitly
            // downgraded before its frozen proof root can be replaced.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_final_proof_root_update_guard
                BEFORE UPDATE OF id, run_key, matter_id, task_kind, scope_json,
                    corpus_snapshot_json, partition_strategy,
                    partition_strategy_version, model_lineage_json,
                    request_schema_version, request_digest, created_at
                ON corpus_analysis_runs
                WHEN OLD.task_kind = 'exhaustive_list'
                  AND OLD.request_schema_version = 2
                  AND OLD.status = 'persisted'
                  AND OLD.assurance_state IN ('corpus_complete', 'proposition_supported')
                  AND (
                      NEW.id IS NOT OLD.id
                      OR NEW.run_key IS NOT OLD.run_key
                      OR NEW.matter_id IS NOT OLD.matter_id
                      OR NEW.task_kind IS NOT OLD.task_kind
                      OR NEW.scope_json IS NOT OLD.scope_json
                      OR NEW.corpus_snapshot_json IS NOT OLD.corpus_snapshot_json
                      OR NEW.partition_strategy IS NOT OLD.partition_strategy
                      OR NEW.partition_strategy_version IS NOT OLD.partition_strategy_version
                      OR NEW.model_lineage_json IS NOT OLD.model_lineage_json
                      OR NEW.request_schema_version IS NOT OLD.request_schema_version
                      OR NEW.request_digest IS NOT OLD.request_digest
                      OR NEW.created_at IS NOT OLD.created_at
                  )
                BEGIN
                    SELECT RAISE(ABORT, 'finalized exhaustive proof root is immutable');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_final_claim_state_update_guard
                BEFORE UPDATE OF status, assurance_state
                ON corpus_analysis_runs
                WHEN OLD.task_kind = 'exhaustive_list'
                  AND OLD.request_schema_version = 2
                  AND OLD.status = 'persisted'
                  AND OLD.assurance_state IN ('corpus_complete', 'proposition_supported')
                  AND NEW.assurance_state IN ('corpus_complete', 'proposition_supported')
                  AND NEW.status IS NOT 'persisted'
                BEGIN
                    SELECT RAISE(ABORT, 'finalized exhaustive claim must be downgraded explicitly');
                END
                """)

            // A structured output version has one proof owner regardless of
            // whether a second candidate is exact-v2 or a legacy task. This
            // closes the inverse ordering hole where an exact run attached
            // first and a chronology/v1 row borrowed the same version later.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_output_version_owner_insert_guard
                BEFORE INSERT ON corpus_analysis_runs
                WHEN NEW.structured_output_version_id IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM corpus_analysis_runs AS owner
                      WHERE owner.structured_output_version_id
                            = NEW.structured_output_version_id
                  )
                BEGIN
                    SELECT RAISE(ABORT, 'structured output version already has a run owner');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_output_version_owner_update_guard
                BEFORE UPDATE OF structured_output_version_id ON corpus_analysis_runs
                WHEN NEW.structured_output_version_id IS NOT NULL
                  AND NEW.structured_output_version_id
                        IS NOT OLD.structured_output_version_id
                  AND EXISTS (
                      SELECT 1
                      FROM corpus_analysis_runs AS owner
                      WHERE owner.id IS NOT NEW.id
                        AND owner.structured_output_version_id
                            = NEW.structured_output_version_id
                  )
                BEGIN
                    SELECT RAISE(ABORT, 'structured output version already has a run owner');
                END
                """)

            // Exact-run output attachment is a one-time binding. A finalized
            // run is normally persisted before its output is generated, so the
            // legitimate NULL-to-compatible transition remains available.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_attachment_guard
                BEFORE UPDATE OF structured_output_version_id
                ON corpus_analysis_runs
                WHEN NEW.structured_output_version_id IS NOT OLD.structured_output_version_id
                  AND (
                      (
                          OLD.task_kind = 'exhaustive_list'
                          AND OLD.request_schema_version = 2
                          AND OLD.partition_strategy_version = 2
                          AND OLD.partition_strategy GLOB 'exact_revision_slice*'
                      )
                      OR (
                          NEW.task_kind = 'exhaustive_list'
                          AND NEW.request_schema_version = 2
                          AND NEW.partition_strategy_version = 2
                          AND NEW.partition_strategy GLOB 'exact_revision_slice*'
                      )
                  )
                BEGIN
                    SELECT CASE WHEN OLD.structured_output_version_id IS NOT NULL
                            AND EXISTS (
                                SELECT 1
                                FROM matters
                                WHERE id = OLD.matter_id
                            )
                        THEN RAISE(ABORT, 'exact output attachment is immutable') END;
                    SELECT CASE WHEN NEW.structured_output_version_id IS NOT NULL
                            AND (
                                NEW.status IS NOT 'persisted'
                                OR NOT EXISTS (
                                    SELECT 1
                                    FROM structured_output_versions AS version
                                    JOIN structured_outputs AS output
                                      ON output.id = version.structured_output_id
                                    WHERE version.id = NEW.structured_output_version_id
                                      AND version.assurance_state = NEW.assurance_state
                                      AND output.matter_id = NEW.matter_id
                                      AND output.output_type = 'document_exhaustive_list'
                                      AND output.deleted_at IS NULL
                                )
                                OR EXISTS (
                                    SELECT 1
                                    FROM corpus_analysis_runs AS other_run
                                    WHERE other_run.id IS NOT NEW.id
                                      AND other_run.structured_output_version_id
                                            = NEW.structured_output_version_id
                                )
                            )
                        THEN RAISE(ABORT, 'exact output attachment is incompatible') END;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_attachment_insert_guard
                BEFORE INSERT ON corpus_analysis_runs
                WHEN NEW.task_kind = 'exhaustive_list'
                  AND NEW.request_schema_version = 2
                  AND NEW.partition_strategy_version = 2
                  AND NEW.partition_strategy GLOB 'exact_revision_slice*'
                  AND NEW.structured_output_version_id IS NOT NULL
                BEGIN
                    SELECT CASE WHEN NEW.status IS NOT 'persisted'
                            OR NOT EXISTS (
                                SELECT 1
                                FROM structured_output_versions AS version
                                JOIN structured_outputs AS output
                                  ON output.id = version.structured_output_id
                                WHERE version.id = NEW.structured_output_version_id
                                  AND version.assurance_state = NEW.assurance_state
                                  AND output.matter_id = NEW.matter_id
                                  AND output.output_type = 'document_exhaustive_list'
                                  AND output.deleted_at IS NULL
                            )
                            OR EXISTS (
                                SELECT 1
                                FROM corpus_analysis_runs AS other_run
                                WHERE other_run.structured_output_version_id
                                    = NEW.structured_output_version_id
                            )
                        THEN RAISE(ABORT, 'exact output attachment is incompatible') END;
                END
                """)

            // Attachment checks must also run when a pre-attached non-exact row
            // is reclassified into the v2 exact contract. Otherwise a chronology
            // row could borrow another run's version before changing identity.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_reclassification_guard
                BEFORE UPDATE OF task_kind, request_schema_version,
                    partition_strategy, partition_strategy_version, matter_id
                ON corpus_analysis_runs
                WHEN NEW.task_kind = 'exhaustive_list'
                  AND NEW.request_schema_version = 2
                  AND NEW.partition_strategy_version = 2
                  AND NEW.partition_strategy GLOB 'exact_revision_slice*'
                  AND NEW.structured_output_version_id IS NOT NULL
                  AND (
                      NEW.task_kind IS NOT OLD.task_kind
                      OR NEW.request_schema_version IS NOT OLD.request_schema_version
                      OR NEW.partition_strategy IS NOT OLD.partition_strategy
                      OR NEW.partition_strategy_version
                            IS NOT OLD.partition_strategy_version
                      OR NEW.matter_id IS NOT OLD.matter_id
                  )
                BEGIN
                    SELECT CASE WHEN NEW.status IS NOT 'persisted'
                            OR NOT EXISTS (
                                SELECT 1
                                FROM structured_output_versions AS version
                                JOIN structured_outputs AS output
                                  ON output.id = version.structured_output_id
                                WHERE version.id = NEW.structured_output_version_id
                                  AND version.assurance_state = NEW.assurance_state
                                  AND output.matter_id = NEW.matter_id
                                  AND output.output_type = 'document_exhaustive_list'
                                  AND output.deleted_at IS NULL
                            )
                            OR EXISTS (
                                SELECT 1
                                FROM corpus_analysis_runs AS other_run
                                WHERE other_run.id IS NOT NEW.id
                                  AND other_run.structured_output_version_id
                                        = NEW.structured_output_version_id
                            )
                        THEN RAISE(ABORT, 'exact output reclassification is incompatible') END;
                END
                """)

            // Once a source set is attached to an exact proof version, its
            // identity and frozen corpus lineage are append-only. The atomic
            // publisher performs its pending-to-attached transition before the
            // run is linked, so that legitimate transition remains available.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_source_set_update_guard
                BEFORE UPDATE ON document_source_sets
                WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_runs AS run
                        JOIN matters AS matter ON matter.id = run.matter_id
                        WHERE run.structured_output_version_id
                                = OLD.structured_output_version_id
                          AND run.task_kind = 'exhaustive_list'
                          AND run.request_schema_version = 2
                          AND run.partition_strategy_version = 2
                          AND run.partition_strategy GLOB 'exact_revision_slice*'
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM corpus_analysis_runs AS run
                        JOIN matters AS matter ON matter.id = run.matter_id
                        WHERE run.structured_output_version_id
                                = NEW.structured_output_version_id
                          AND run.task_kind = 'exhaustive_list'
                          AND run.request_schema_version = 2
                          AND run.partition_strategy_version = 2
                          AND run.partition_strategy GLOB 'exact_revision_slice*'
                    )
                BEGIN
                    SELECT RAISE(ABORT, 'linked exact source set is append-only');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_source_set_delete_guard
                BEFORE DELETE ON document_source_sets
                WHEN EXISTS (
                    SELECT 1
                    FROM corpus_analysis_runs AS run
                    JOIN matters AS matter ON matter.id = run.matter_id
                    WHERE run.structured_output_version_id
                            = OLD.structured_output_version_id
                      AND run.task_kind = 'exhaustive_list'
                      AND run.request_schema_version = 2
                      AND run.partition_strategy_version = 2
                      AND run.partition_strategy GLOB 'exact_revision_slice*'
                )
                BEGIN
                    SELECT RAISE(ABORT, 'linked exact source set cannot be deleted');
                END
                """)

            // A linked exact version is an append-only projection of its proof
            // root. Deletion and semantic rewrites remain available only after
            // that run is deliberately removed, or as part of whole-matter
            // deletion after the owning matter row has left the parent table.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_version_delete_guard
                BEFORE DELETE ON structured_output_versions
                WHEN EXISTS (
                    SELECT 1
                    FROM corpus_analysis_runs AS run
                    JOIN matters AS matter ON matter.id = run.matter_id
                    WHERE run.structured_output_version_id = OLD.id
                      AND run.task_kind = 'exhaustive_list'
                      AND run.request_schema_version = 2
                      AND run.partition_strategy_version = 2
                      AND run.partition_strategy GLOB 'exact_revision_slice*'
                )
                BEGIN
                    SELECT RAISE(ABORT, 'linked exact output version cannot be deleted');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_version_identity_guard
                BEFORE UPDATE OF id, structured_output_id, version_index,
                    parent_version_id, content_markdown, required_sections_json,
                    present_sections_json, missing_sections_json, repair_reason,
                    generation_session_id, verification_status,
                    verification_version, verification_json,
                    verification_dimensions_json, verified_at,
                    prompt_builder_version, created_at
                ON structured_output_versions
                WHEN EXISTS (
                        SELECT 1
                        FROM corpus_analysis_runs AS run
                        JOIN matters AS matter ON matter.id = run.matter_id
                        WHERE run.structured_output_version_id = OLD.id
                          AND run.task_kind = 'exhaustive_list'
                          AND run.request_schema_version = 2
                          AND run.partition_strategy_version = 2
                          AND run.partition_strategy GLOB 'exact_revision_slice*'
                    )
                  AND (
                      NEW.id IS NOT OLD.id
                      OR NEW.structured_output_id IS NOT OLD.structured_output_id
                      OR NEW.version_index IS NOT OLD.version_index
                      OR NEW.parent_version_id IS NOT OLD.parent_version_id
                      OR NEW.content_markdown IS NOT OLD.content_markdown
                      OR NEW.required_sections_json IS NOT OLD.required_sections_json
                      OR NEW.present_sections_json IS NOT OLD.present_sections_json
                      OR NEW.missing_sections_json IS NOT OLD.missing_sections_json
                      OR NEW.repair_reason IS NOT OLD.repair_reason
                      OR NEW.generation_session_id IS NOT OLD.generation_session_id
                      OR NEW.verification_status IS NOT OLD.verification_status
                      OR NEW.verification_version IS NOT OLD.verification_version
                      OR NEW.verification_json IS NOT OLD.verification_json
                      OR NEW.verification_dimensions_json
                            IS NOT OLD.verification_dimensions_json
                      OR NEW.verified_at IS NOT OLD.verified_at
                      OR NEW.prompt_builder_version IS NOT OLD.prompt_builder_version
                      OR NEW.created_at IS NOT OLD.created_at
                  )
                BEGIN
                    SELECT RAISE(ABORT, 'linked exact output version is append-only');
                END
                """)

            // A strong assurance value must continue to match the one exact run
            // that earned it. A downgrade remains legal, but it is normalized to
            // stale across version, run, and active parent in one transaction.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_assurance_guard
                BEFORE UPDATE OF assurance_state ON structured_output_versions
                WHEN NEW.assurance_state IS NOT OLD.assurance_state
                  AND NEW.assurance_state IN (
                      'corpus_complete', 'proposition_supported'
                  )
                  AND (
                      EXISTS (
                          SELECT 1
                          FROM corpus_analysis_runs AS run
                          WHERE run.structured_output_version_id = OLD.id
                            AND run.task_kind = 'exhaustive_list'
                            AND run.request_schema_version = 2
                            AND run.partition_strategy_version = 2
                            AND run.partition_strategy GLOB 'exact_revision_slice*'
                      )
                      OR EXISTS (
                          SELECT 1
                          FROM structured_outputs AS output
                          JOIN structured_output_versions AS governed_version
                            ON governed_version.structured_output_id = output.id
                          JOIN corpus_analysis_runs AS governed_run
                            ON governed_run.structured_output_version_id
                                = governed_version.id
                          WHERE output.active_version_id = OLD.id
                            AND output.output_type = 'document_exhaustive_list'
                            AND governed_run.task_kind = 'exhaustive_list'
                            AND governed_run.request_schema_version = 2
                            AND governed_run.partition_strategy_version = 2
                            AND governed_run.partition_strategy
                                GLOB 'exact_revision_slice*'
                      )
                  )
                BEGIN
                    SELECT CASE WHEN (
                            SELECT COUNT(*)
                            FROM corpus_analysis_runs AS run
                            WHERE run.structured_output_version_id = OLD.id
                              AND run.task_kind = 'exhaustive_list'
                              AND run.request_schema_version = 2
                              AND run.partition_strategy_version = 2
                              AND run.partition_strategy GLOB 'exact_revision_slice*'
                              AND run.status = 'persisted'
                              AND run.assurance_state = NEW.assurance_state
                        ) <> 1
                        THEN RAISE(ABORT, 'linked exact output assurance must match its proof') END;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_assurance_downgrade_stale
                AFTER UPDATE OF assurance_state ON structured_output_versions
                WHEN OLD.assurance_state IN (
                        'corpus_complete', 'proposition_supported'
                    )
                  AND (
                      NEW.assurance_state IS NULL
                      OR NEW.assurance_state NOT IN (
                          'corpus_complete', 'proposition_supported'
                      )
                  )
                  AND EXISTS (
                      SELECT 1
                      FROM corpus_analysis_runs AS run
                      WHERE run.structured_output_version_id = OLD.id
                        AND run.task_kind = 'exhaustive_list'
                        AND run.request_schema_version = 2
                        AND run.partition_strategy_version = 2
                        AND run.partition_strategy GLOB 'exact_revision_slice*'
                        AND run.status = 'persisted'
                        AND run.assurance_state = OLD.assurance_state
                  )
                BEGIN
                    UPDATE structured_output_versions
                    SET assurance_state = 'stale',
                        stale_reason = 'corpus_proof_output_downgraded'
                    WHERE id = OLD.id;
                    UPDATE corpus_analysis_runs
                    SET assurance_state = 'stale'
                    WHERE structured_output_version_id = OLD.id
                      AND task_kind = 'exhaustive_list'
                      AND request_schema_version = 2
                      AND partition_strategy_version = 2
                      AND partition_strategy GLOB 'exact_revision_slice*'
                      AND status = 'persisted'
                      AND assurance_state = OLD.assurance_state;
                    UPDATE structured_outputs
                    SET status = 'needs_review'
                    WHERE active_version_id = OLD.id;
                END
                """)

            // The parent owns the matter/type identity exposed to export. Once
            // any version is exact-proof-linked, those two semantic coordinates
            // cannot be rewritten around the durable run.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_parent_identity_guard
                BEFORE UPDATE OF id, matter_id, output_type
                ON structured_outputs
                WHEN (
                        NEW.id IS NOT OLD.id
                        OR NEW.matter_id IS NOT OLD.matter_id
                        OR NEW.output_type IS NOT OLD.output_type
                    )
                  AND EXISTS (
                      SELECT 1
                      FROM structured_output_versions AS version
                      JOIN corpus_analysis_runs AS run
                        ON run.structured_output_version_id = version.id
                      WHERE version.structured_output_id = OLD.id
                        AND run.task_kind = 'exhaustive_list'
                        AND run.request_schema_version = 2
                        AND run.partition_strategy_version = 2
                        AND run.partition_strategy GLOB 'exact_revision_slice*'
                  )
                BEGIN
                    SELECT RAISE(ABORT, 'linked exact output parent identity is immutable');
                END
                """)

            // Draft exhaustive outputs may exist before their proof. After an
            // output has entered the exact-proof graph, however, selecting a new
            // export-eligible active version requires that version's own single,
            // same-matter persisted exact proof.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_output_active_version_guard
                BEFORE UPDATE OF active_version_id ON structured_outputs
                WHEN NEW.output_type = 'document_exhaustive_list'
                  AND NEW.active_version_id IS NOT NULL
                  AND NEW.active_version_id IS NOT OLD.active_version_id
                  AND EXISTS (
                      SELECT 1
                      FROM structured_output_versions AS candidate
                      WHERE candidate.id = NEW.active_version_id
                        AND candidate.assurance_state IN (
                            'corpus_complete', 'proposition_supported'
                        )
                  )
                  AND EXISTS (
                      SELECT 1
                      FROM structured_output_versions AS prior_version
                      JOIN corpus_analysis_runs AS prior_run
                        ON prior_run.structured_output_version_id = prior_version.id
                      WHERE prior_version.structured_output_id = OLD.id
                        AND prior_run.task_kind = 'exhaustive_list'
                        AND prior_run.request_schema_version = 2
                        AND prior_run.partition_strategy_version = 2
                        AND prior_run.partition_strategy GLOB 'exact_revision_slice*'
                  )
                BEGIN
                    SELECT CASE WHEN (
                            SELECT COUNT(*)
                            FROM structured_output_versions AS version
                            JOIN corpus_analysis_runs AS run
                              ON run.structured_output_version_id = version.id
                            WHERE version.id = NEW.active_version_id
                              AND version.structured_output_id = NEW.id
                              AND version.assurance_state IN (
                                  'corpus_complete', 'proposition_supported'
                              )
                              AND run.matter_id = NEW.matter_id
                              AND run.task_kind = 'exhaustive_list'
                              AND run.request_schema_version = 2
                              AND run.partition_strategy_version = 2
                              AND run.partition_strategy
                                    GLOB 'exact_revision_slice*'
                              AND run.status = 'persisted'
                              AND run.assurance_state = version.assurance_state
                        ) <> 1
                        THEN RAISE(ABORT, 'active exhaustive version requires one exact proof') END;
                END
                """)

            // Rendering happens before the durable export/audit transaction.
            // Revalidate the exact proof at document_exports insertion time so
            // a revoked run or active-version switch cannot be recorded as a
            // successful export after the file has been installed.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_exact_export_completion_guard
                BEFORE INSERT ON document_exports
                WHEN EXISTS (
                        SELECT 1
                        FROM structured_outputs AS output
                        WHERE output.id = NEW.structured_output_id
                          AND output.output_type = 'document_exhaustive_list'
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM structured_output_versions AS version
                        JOIN structured_outputs AS output
                          ON output.id = version.structured_output_id
                        WHERE version.id = NEW.structured_output_version_id
                          AND output.output_type = 'document_exhaustive_list'
                    )
                BEGIN
                    SELECT CASE WHEN (
                            SELECT COUNT(*)
                            FROM structured_outputs AS output
                            JOIN structured_output_versions AS version
                              ON version.id = NEW.structured_output_version_id
                             AND version.structured_output_id = output.id
                            JOIN corpus_analysis_runs AS run
                              ON run.structured_output_version_id = version.id
                            WHERE output.id = NEW.structured_output_id
                              AND output.matter_id = NEW.matter_id
                              AND output.output_type = 'document_exhaustive_list'
                              AND output.deleted_at IS NULL
                              AND output.active_version_id = version.id
                              AND version.verification_status = 'all_supported'
                              AND version.assurance_state IN (
                                  'corpus_complete', 'proposition_supported'
                              )
                              AND run.matter_id = NEW.matter_id
                              AND run.task_kind = 'exhaustive_list'
                              AND run.request_schema_version = 2
                              AND run.partition_strategy_version = 2
                              AND run.partition_strategy
                                    GLOB 'exact_revision_slice*'
                              AND run.status = 'persisted'
                              AND run.assurance_state = version.assurance_state
                              AND (
                                  SELECT COUNT(*)
                                  FROM document_source_sets AS source_set
                                  WHERE source_set.structured_output_version_id
                                        = version.id
                                    AND source_set.matter_id = NEW.matter_id
                                    AND source_set.status = 'attached'
                                    AND source_set.mode = 'exhaustive'
                                    AND typeof(source_set.corpus_snapshot_hash) = 'text'
                                    AND length(source_set.corpus_snapshot_hash) = 64
                                    AND source_set.corpus_snapshot_hash
                                        NOT GLOB '*[^0-9a-f]*'
                              ) = 1
                        ) <> 1
                        THEN RAISE(ABORT, 'exhaustive export proof changed before completion') END;
                END
                """)

            // The linked output is the public/exportable projection of this
            // proof root. If the run is downgraded or removed, invalidate that
            // projection in the same statement transaction before its ledger
            // can become mutable or cascade away.
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_linked_export_downgrade_stale
                AFTER UPDATE OF status, assurance_state
                ON corpus_analysis_runs
                WHEN OLD.task_kind = 'exhaustive_list'
                  AND OLD.request_schema_version = 2
                  AND OLD.partition_strategy_version = 2
                  AND OLD.partition_strategy GLOB 'exact_revision_slice*'
                  AND OLD.status = 'persisted'
                  AND OLD.assurance_state IN ('corpus_complete', 'proposition_supported')
                  AND (
                      NEW.status IS NOT 'persisted'
                      OR NEW.assurance_state IS NULL
                      OR NEW.assurance_state NOT IN (
                          'corpus_complete', 'proposition_supported'
                      )
                  )
                  AND OLD.structured_output_version_id IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM structured_output_versions
                      WHERE id = OLD.structured_output_version_id
                        AND assurance_state IN (
                            'corpus_complete', 'proposition_supported'
                        )
                  )
                BEGIN
                    UPDATE structured_output_versions
                    SET assurance_state = 'stale',
                        stale_reason = 'corpus_proof_run_downgraded'
                    WHERE id = OLD.structured_output_version_id
                      AND assurance_state IN (
                          'corpus_complete', 'proposition_supported'
                      );
                    UPDATE structured_outputs
                    SET status = 'needs_review'
                    WHERE active_version_id = OLD.structured_output_version_id;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER corpus_analysis_linked_export_delete_stale
                AFTER DELETE ON corpus_analysis_runs
                WHEN OLD.task_kind = 'exhaustive_list'
                  AND OLD.request_schema_version = 2
                  AND OLD.partition_strategy_version = 2
                  AND OLD.partition_strategy GLOB 'exact_revision_slice*'
                  AND OLD.status = 'persisted'
                  AND OLD.assurance_state IN ('corpus_complete', 'proposition_supported')
                  AND OLD.structured_output_version_id IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM structured_output_versions
                      WHERE id = OLD.structured_output_version_id
                        AND assurance_state IN (
                            'corpus_complete', 'proposition_supported'
                        )
                  )
                BEGIN
                    UPDATE structured_output_versions
                    SET assurance_state = 'stale',
                        stale_reason = 'corpus_proof_run_deleted'
                    WHERE id = OLD.structured_output_version_id
                      AND assurance_state IN (
                          'corpus_complete', 'proposition_supported'
                      );
                    UPDATE structured_outputs
                    SET status = 'needs_review'
                    WHERE active_version_id = OLD.structured_output_version_id;
                END
                """)

            // Once an exhaustive claim is export-eligible, its proof ledger is
            // immutable until the claim itself is revoked or downgraded.
            for (name, table) in [
                ("partition", "corpus_analysis_partitions"),
                ("slice", "corpus_analysis_partition_slices"),
            ] {
                try db.execute(sql: """
                    CREATE TRIGGER corpus_analysis_final_\(name)_insert_guard
                    BEFORE INSERT ON \(table)
                    WHEN EXISTS (
                        SELECT 1 FROM corpus_analysis_runs
                        WHERE id = NEW.run_id
                          AND task_kind = 'exhaustive_list'
                          AND status = 'persisted'
                          AND assurance_state IN ('corpus_complete', 'proposition_supported')
                    )
                    BEGIN
                        SELECT RAISE(ABORT, 'finalized exhaustive ledger is immutable');
                    END
                    """)
                try db.execute(sql: """
                    CREATE TRIGGER corpus_analysis_final_\(name)_update_guard
                    BEFORE UPDATE ON \(table)
                    WHEN EXISTS (
                            SELECT 1 FROM corpus_analysis_runs
                            WHERE id = OLD.run_id
                              AND task_kind = 'exhaustive_list'
                              AND status = 'persisted'
                              AND assurance_state IN ('corpus_complete', 'proposition_supported')
                        )
                        OR EXISTS (
                            SELECT 1 FROM corpus_analysis_runs
                            WHERE id = NEW.run_id
                              AND task_kind = 'exhaustive_list'
                              AND status = 'persisted'
                              AND assurance_state IN ('corpus_complete', 'proposition_supported')
                        )
                    BEGIN
                        SELECT RAISE(ABORT, 'finalized exhaustive ledger is immutable');
                    END
                    """)
                try db.execute(sql: """
                    CREATE TRIGGER corpus_analysis_final_\(name)_delete_guard
                    BEFORE DELETE ON \(table)
                    WHEN EXISTS (
                        SELECT 1 FROM corpus_analysis_runs
                        WHERE id = OLD.run_id
                          AND task_kind = 'exhaustive_list'
                          AND status = 'persisted'
                          AND assurance_state IN ('corpus_complete', 'proposition_supported')
                    )
                    BEGIN
                        SELECT RAISE(ABORT, 'finalized exhaustive ledger is immutable');
                    END
                    """)
            }

            // Strong claims created before v072 lack reconstructible requests and
            // exact slice ledgers. Revoke publication eligibility narrowly for
            // exhaustive-list runs while preserving their historical content,
            // reconciliation, attempts, partitions, and audit records.
            let staleReason = "legacy_corpus_trust_upgrade_requires_v2_regeneration"
            try db.execute(
                sql: """
                    UPDATE structured_output_versions
                    SET assurance_state = ?, stale_reason = ?
                    WHERE assurance_state IN (?, ?)
                      AND id IN (
                        SELECT structured_output_version_id
                        FROM corpus_analysis_runs
                        WHERE task_kind = ?
                          AND request_schema_version IS NULL
                          AND structured_output_version_id IS NOT NULL
                    )
                    """,
                arguments: [
                    OutputAssuranceState.stale.rawValue,
                    staleReason,
                    OutputAssuranceState.corpusComplete.rawValue,
                    OutputAssuranceState.propositionSupported.rawValue,
                    CorpusAnalysisTaskKind.exhaustiveList.rawValue,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE structured_outputs
                    SET status = ?
                    WHERE active_version_id IN (
                        SELECT version.id
                        FROM structured_output_versions AS version
                        JOIN corpus_analysis_runs AS run
                          ON run.structured_output_version_id = version.id
                        WHERE run.task_kind = ?
                          AND run.request_schema_version IS NULL
                          AND version.assurance_state = ?
                          AND version.stale_reason = ?
                    )
                    """,
                arguments: [
                    StructuredOutputStatus.needsReview.rawValue,
                    CorpusAnalysisTaskKind.exhaustiveList.rawValue,
                    OutputAssuranceState.stale.rawValue,
                    staleReason,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE corpus_analysis_runs
                    SET assurance_state = ?
                    WHERE task_kind = ?
                      AND request_schema_version IS NULL
                      AND assurance_state IN (?, ?)
                    """,
                arguments: [
                    OutputAssuranceState.stale.rawValue,
                    CorpusAnalysisTaskKind.exhaustiveList.rawValue,
                    OutputAssuranceState.corpusComplete.rawValue,
                    OutputAssuranceState.propositionSupported.rawValue,
                ]
            )
        }

    }
}
