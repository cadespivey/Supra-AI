import CryptoKit
import Foundation
import GRDB
import SupraCore

extension SupraMigrator {
    static func registerMigrationV073(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v073_create_case_file_review_projects") { db in
            // The mutable attorney-work layer is intentionally separate from
            // the immutable exact corpus proof and Structured Output snapshot.
            // Frozen source identities are text; nullable live pointers support
            // preview and precise degradation after permanent source deletion.
            try db.execute(sql: """
                CREATE TABLE case_file_review_projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    matter_id TEXT NOT NULL,
                    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
                    status TEXT NOT NULL CHECK (status IN ('active', 'stale')),
                    stale_reason TEXT,
                    source_run_id TEXT NOT NULL CHECK (length(source_run_id) > 0),
                    source_output_id TEXT NOT NULL CHECK (length(source_output_id) > 0),
                    source_output_version_id TEXT NOT NULL
                        CHECK (length(source_output_version_id) > 0),
                    source_request_digest TEXT NOT NULL CHECK (
                        length(source_request_digest) = 64
                        AND source_request_digest NOT GLOB '*[^0-9a-f]*'
                    ),
                    frozen_scope_json TEXT NOT NULL CHECK (
                        json_valid(frozen_scope_json) = 1
                        AND json_type(frozen_scope_json) = 'object'
                    ),
                    frozen_corpus_snapshot_json TEXT NOT NULL CHECK (
                        json_valid(frozen_corpus_snapshot_json) = 1
                        AND json_type(frozen_corpus_snapshot_json) = 'object'
                    ),
                    frozen_reconciliation_json TEXT NOT NULL CHECK (
                        json_valid(frozen_reconciliation_json) = 1
                        AND json_type(frozen_reconciliation_json) = 'object'
                    ),
                    active_table_id TEXT,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    CHECK (
                        (status = 'active' AND stale_reason IS NULL)
                        OR (status = 'stale' AND length(stale_reason) > 0)
                    ),
                    UNIQUE (source_run_id),
                    UNIQUE (source_output_version_id),
                    FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE,
                    FOREIGN KEY (active_table_id)
                        REFERENCES case_file_review_tables(id) ON DELETE SET NULL
                )
                """)
            try db.create(
                index: "idx_case_file_review_projects_matter_updated",
                on: "case_file_review_projects",
                columns: ["matter_id", "updated_at", "id"]
            )

            try db.execute(sql: """
                CREATE TABLE case_file_review_tables (
                    id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL,
                    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
                    version_index INTEGER NOT NULL CHECK (
                        typeof(version_index) = 'integer' AND version_index >= 1
                    ),
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    UNIQUE (id, project_id),
                    UNIQUE (project_id, version_index),
                    FOREIGN KEY (project_id)
                        REFERENCES case_file_review_projects(id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                CREATE TABLE case_file_review_columns (
                    id TEXT PRIMARY KEY NOT NULL,
                    table_id TEXT NOT NULL,
                    column_key TEXT NOT NULL CHECK (
                        column_key IN ('finding', 'generated_value', 'sources', 'review')
                    ),
                    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
                    ordinal INTEGER NOT NULL CHECK (
                        typeof(ordinal) = 'integer' AND ordinal >= 0
                    ),
                    created_at DATETIME NOT NULL,
                    UNIQUE (id, table_id),
                    UNIQUE (table_id, column_key),
                    UNIQUE (table_id, ordinal),
                    FOREIGN KEY (table_id)
                        REFERENCES case_file_review_tables(id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                CREATE TABLE case_file_review_rows (
                    id TEXT PRIMARY KEY NOT NULL,
                    table_id TEXT NOT NULL,
                    row_key TEXT NOT NULL CHECK (length(row_key) > 0),
                    ordinal INTEGER NOT NULL CHECK (
                        typeof(ordinal) = 'integer' AND ordinal >= 0
                    ),
                    created_at DATETIME NOT NULL,
                    UNIQUE (id, table_id),
                    UNIQUE (table_id, row_key),
                    UNIQUE (table_id, ordinal),
                    FOREIGN KEY (table_id)
                        REFERENCES case_file_review_tables(id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                CREATE TABLE case_file_review_cells (
                    id TEXT PRIMARY KEY NOT NULL,
                    table_id TEXT NOT NULL,
                    row_id TEXT NOT NULL,
                    column_id TEXT NOT NULL,
                    current_generation_id TEXT,
                    attorney_value TEXT,
                    review_state TEXT NOT NULL CHECK (
                        review_state IN ('needs_review', 'reviewed')
                    ),
                    value_state TEXT NOT NULL CHECK (
                        value_state IN ('generated', 'edited')
                    ),
                    support_state TEXT NOT NULL CHECK (
                        support_state IN ('supported', 'unsupported', 'failed', 'stale')
                    ),
                    reviewed_by TEXT,
                    reviewed_at DATETIME,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    CHECK (
                        (review_state = 'needs_review'
                            AND reviewed_by IS NULL AND reviewed_at IS NULL)
                        OR (review_state = 'reviewed'
                            AND length(reviewed_by) > 0 AND reviewed_at IS NOT NULL)
                    ),
                    CHECK (
                        (value_state = 'generated' AND attorney_value IS NULL)
                        OR (value_state = 'edited' AND length(attorney_value) > 0)
                    ),
                    UNIQUE (row_id, column_id),
                    FOREIGN KEY (table_id)
                        REFERENCES case_file_review_tables(id) ON DELETE CASCADE,
                    FOREIGN KEY (row_id, table_id)
                        REFERENCES case_file_review_rows(id, table_id) ON DELETE CASCADE,
                    FOREIGN KEY (column_id, table_id)
                        REFERENCES case_file_review_columns(id, table_id) ON DELETE CASCADE
                )
                """)
            try db.create(
                index: "idx_case_file_review_cells_table_row",
                on: "case_file_review_cells",
                columns: ["table_id", "row_id", "column_id"]
            )

            try db.execute(sql: """
                CREATE TABLE case_file_review_cell_generations (
                    id TEXT PRIMARY KEY NOT NULL,
                    cell_id TEXT NOT NULL,
                    generation_index INTEGER NOT NULL CHECK (
                        typeof(generation_index) = 'integer' AND generation_index >= 1
                    ),
                    source_run_id TEXT NOT NULL CHECK (length(source_run_id) > 0),
                    generated_values_json TEXT NOT NULL CHECK (
                        json_valid(generated_values_json) = 1
                        AND json_type(generated_values_json) = 'array'
                        AND json_array_length(generated_values_json) > 0
                    ),
                    created_at DATETIME NOT NULL,
                    UNIQUE (cell_id, generation_index),
                    FOREIGN KEY (cell_id)
                        REFERENCES case_file_review_cells(id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                CREATE TABLE case_file_review_evidence_edges (
                    id TEXT PRIMARY KEY NOT NULL,
                    generation_id TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('supporting', 'contrary')),
                    ordinal INTEGER NOT NULL CHECK (
                        typeof(ordinal) = 'integer' AND ordinal >= 0
                    ),
                    frozen_output_source_id TEXT NOT NULL
                        CHECK (length(frozen_output_source_id) > 0),
                    frozen_document_id TEXT NOT NULL CHECK (length(frozen_document_id) > 0),
                    frozen_revision_id TEXT NOT NULL CHECK (length(frozen_revision_id) > 0),
                    frozen_document_name TEXT NOT NULL
                        CHECK (length(frozen_document_name) > 0),
                    citation_label TEXT NOT NULL CHECK (length(citation_label) > 0),
                    char_start INTEGER,
                    char_end INTEGER,
                    locator_json TEXT NOT NULL CHECK (
                        json_valid(locator_json) = 1 AND json_type(locator_json) = 'object'
                    ),
                    excerpt TEXT NOT NULL CHECK (length(excerpt) > 0),
                    excerpt_sha256 TEXT NOT NULL CHECK (
                        length(excerpt_sha256) = 64
                        AND excerpt_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    live_output_source_id TEXT,
                    live_document_id TEXT,
                    live_revision_id TEXT,
                    availability TEXT NOT NULL CHECK (
                        availability IN ('available', 'unavailable')
                    ),
                    unavailable_reason TEXT,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    CHECK (
                        (char_start IS NULL AND char_end IS NULL)
                        OR (
                            typeof(char_start) = 'integer'
                            AND typeof(char_end) = 'integer'
                            AND char_start >= 0 AND char_end > char_start
                        )
                    ),
                    CHECK (
                        (availability = 'available' AND unavailable_reason IS NULL
                            AND live_output_source_id IS NOT NULL
                            AND live_document_id IS NOT NULL
                            AND live_revision_id IS NOT NULL)
                        OR (availability = 'unavailable' AND length(unavailable_reason) > 0
                            AND live_output_source_id IS NULL
                            AND live_document_id IS NULL
                            AND live_revision_id IS NULL)
                    ),
                    UNIQUE (generation_id, kind, ordinal),
                    FOREIGN KEY (generation_id)
                        REFERENCES case_file_review_cell_generations(id) ON DELETE CASCADE,
                    FOREIGN KEY (live_output_source_id)
                        REFERENCES document_output_sources(id) ON DELETE SET NULL,
                    FOREIGN KEY (live_document_id)
                        REFERENCES matter_documents(id) ON DELETE SET NULL,
                    FOREIGN KEY (live_revision_id)
                        REFERENCES document_part_revisions(id) ON DELETE SET NULL
                )
                """)
            try db.create(
                index: "idx_case_file_review_evidence_live_document",
                on: "case_file_review_evidence_edges",
                columns: ["live_document_id", "live_revision_id"]
            )

            // Review graph parents are removed only as part of whole-matter
            // deletion. SQLite removes the owning matter row before running its
            // foreign-key cascades, so the matter-exists predicate rejects a
            // direct graph delete without blocking that audited repository path.
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_project_delete_guard
                BEFORE DELETE ON case_file_review_projects
                WHEN EXISTS (
                    SELECT 1 FROM matters WHERE id = OLD.matter_id
                )
                BEGIN SELECT RAISE(ABORT, 'review projects require whole-matter deletion'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_table_delete_guard
                BEFORE DELETE ON case_file_review_tables
                WHEN EXISTS (
                    SELECT 1
                    FROM case_file_review_projects AS project
                    JOIN matters AS matter ON matter.id = project.matter_id
                    WHERE project.id = OLD.project_id
                )
                BEGIN SELECT RAISE(ABORT, 'review tables require whole-matter deletion'); END
                """)

            let reviewTableMatterOwner = """
                EXISTS (
                    SELECT 1
                    FROM case_file_review_tables AS review_table
                    JOIN case_file_review_projects AS project
                      ON project.id = review_table.project_id
                    JOIN matters AS matter ON matter.id = project.matter_id
                    WHERE review_table.id = OLD.table_id
                )
                """
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_column_delete_guard
                BEFORE DELETE ON case_file_review_columns
                WHEN \(reviewTableMatterOwner)
                BEGIN SELECT RAISE(ABORT, 'review columns require whole-matter deletion'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_row_delete_guard
                BEFORE DELETE ON case_file_review_rows
                WHEN \(reviewTableMatterOwner)
                BEGIN SELECT RAISE(ABORT, 'review rows require whole-matter deletion'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_cell_delete_guard
                BEFORE DELETE ON case_file_review_cells
                WHEN \(reviewTableMatterOwner)
                BEGIN SELECT RAISE(ABORT, 'review cells require whole-matter deletion'); END
                """)

            // Generated payloads never change in place. Cascading project/matter
            // deletion is still permitted because the owning cell/project has
            // already left the visible graph when its child cascade executes.
            let generationOwner = """
                EXISTS (
                    SELECT 1
                    FROM case_file_review_cells AS cell
                    JOIN case_file_review_tables AS review_table
                      ON review_table.id = cell.table_id
                    JOIN case_file_review_projects AS project
                      ON project.id = review_table.project_id
                    WHERE cell.id = OLD.cell_id
                )
                """
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_generation_update_guard
                BEFORE UPDATE ON case_file_review_cell_generations
                WHEN \(generationOwner)
                BEGIN SELECT RAISE(ABORT, 'review cell generations are append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_generation_delete_guard
                BEFORE DELETE ON case_file_review_cell_generations
                WHEN \(generationOwner)
                BEGIN SELECT RAISE(ABORT, 'review cell generations are append-only'); END
                """)

            let evidenceOwner = """
                EXISTS (
                    SELECT 1
                    FROM case_file_review_cell_generations AS generation
                    JOIN case_file_review_cells AS cell ON cell.id = generation.cell_id
                    JOIN case_file_review_tables AS review_table
                      ON review_table.id = cell.table_id
                    JOIN case_file_review_projects AS project
                      ON project.id = review_table.project_id
                    WHERE generation.id = OLD.generation_id
                )
                """
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_evidence_frozen_update_guard
                BEFORE UPDATE OF generation_id, kind, ordinal, frozen_output_source_id,
                    frozen_document_id, frozen_revision_id, frozen_document_name,
                    citation_label, char_start, char_end, locator_json, excerpt,
                    excerpt_sha256, created_at
                ON case_file_review_evidence_edges
                WHEN \(evidenceOwner)
                BEGIN SELECT RAISE(ABORT, 'review evidence snapshots are append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_evidence_delete_guard
                BEFORE DELETE ON case_file_review_evidence_edges
                WHEN \(evidenceOwner)
                BEGIN SELECT RAISE(ABORT, 'review evidence snapshots are append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER case_file_review_evidence_availability_guard
                BEFORE UPDATE OF availability, unavailable_reason, live_output_source_id,
                    live_document_id, live_revision_id
                ON case_file_review_evidence_edges
                WHEN NOT (
                    OLD.availability = 'available'
                    AND NEW.availability = 'unavailable'
                    AND length(NEW.unavailable_reason) > 0
                    AND NEW.live_output_source_id IS NULL
                    AND NEW.live_document_id IS NULL
                    AND NEW.live_revision_id IS NULL
                )
                BEGIN SELECT RAISE(ABORT, 'review evidence availability only degrades'); END
                """)
        }

    }
}
