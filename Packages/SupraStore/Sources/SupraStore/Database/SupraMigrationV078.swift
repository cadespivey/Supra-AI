import CryptoKit
import Foundation
import GRDB
import SupraCore

extension SupraMigrator {
    static func registerMigrationV078(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v078_govern_structured_work_publication") { db in
            // A successful provider response yields only content-free receipt
            // provenance. Store registration is spent transactionally by one
            // research packet execution; query and matter bodies are never
            // retained here.
            try db.execute(sql: """
                CREATE TABLE research_packet_egress_consumptions (
                    receipt_id TEXT PRIMARY KEY NOT NULL CHECK (length(trim(receipt_id)) > 0),
                    request_digest_sha256 TEXT NOT NULL CHECK (
                        length(request_digest_sha256) = 64
                        AND request_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    provider_id TEXT NOT NULL CHECK (length(trim(provider_id)) > 0),
                    grant_version INTEGER NOT NULL CHECK (
                        typeof(grant_version) = 'integer' AND grant_version > 0
                    ),
                    origin TEXT NOT NULL CHECK (
                        origin IN ('formalResearch', 'quickResearch')
                    ),
                    matter_id TEXT,
                    research_session_id TEXT,
                    classification TEXT NOT NULL CHECK (
                        classification IN (
                            'publicCitation', 'userApprovedQuery',
                            'matterDerived', 'unknown'
                        )
                    ),
                    query_sha256 TEXT NOT NULL CHECK (
                        length(query_sha256) = 64
                        AND query_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    binding_digest_sha256 TEXT NOT NULL CHECK (
                        length(binding_digest_sha256) = 64
                        AND binding_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    registered_at DATETIME NOT NULL,
                    used_by_execution_id TEXT UNIQUE,
                    used_at DATETIME,
                    CHECK (
                        (used_by_execution_id IS NULL AND used_at IS NULL)
                        OR (length(trim(used_by_execution_id)) > 0 AND used_at IS NOT NULL)
                    ),
                    FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE,
                    FOREIGN KEY (research_session_id)
                        REFERENCES research_sessions(id) ON DELETE CASCADE,
                    FOREIGN KEY (used_by_execution_id)
                        REFERENCES research_packet_candidates(id)
                        DEFERRABLE INITIALLY DEFERRED
                )
                """)
            try db.create(
                index: "idx_research_packet_egress_consumptions_scope",
                on: "research_packet_egress_consumptions",
                columns: ["matter_id", "research_session_id", "registered_at", "receipt_id"]
            )
            try db.execute(sql: """
                CREATE TRIGGER research_packet_egress_consumption_update_guard
                BEFORE UPDATE ON research_packet_egress_consumptions
                WHEN NOT (
                    OLD.used_by_execution_id IS NULL
                    AND OLD.used_at IS NULL
                    AND length(trim(NEW.used_by_execution_id)) > 0
                    AND NEW.used_at IS NOT NULL
                    AND NEW.receipt_id = OLD.receipt_id
                    AND NEW.request_digest_sha256 = OLD.request_digest_sha256
                    AND NEW.provider_id = OLD.provider_id
                    AND NEW.grant_version = OLD.grant_version
                    AND NEW.origin = OLD.origin
                    AND NEW.matter_id IS OLD.matter_id
                    AND NEW.research_session_id IS OLD.research_session_id
                    AND NEW.classification = OLD.classification
                    AND NEW.query_sha256 = OLD.query_sha256
                    AND NEW.binding_digest_sha256 = OLD.binding_digest_sha256
                    AND NEW.registered_at = OLD.registered_at
                )
                BEGIN
                    SELECT RAISE(ABORT, 'egress consumption registration is immutable');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_egress_consumption_delete_guard
                BEFORE DELETE ON research_packet_egress_consumptions
                WHEN OLD.matter_id IS NULL OR EXISTS (
                    SELECT 1 FROM matters WHERE id = OLD.matter_id
                )
                BEGIN
                    SELECT RAISE(ABORT, 'egress consumption registration is immutable');
                END
                """)

            // One receipt terminates the complete publication aggregate: output,
            // source packet, generation, version, accepted-packet binding, audit,
            // and active selection all commit or roll back with this final row.
            try db.execute(sql: """
                CREATE TABLE structured_work_product_publications (
                    idempotency_key TEXT PRIMARY KEY NOT NULL CHECK (
                        length(trim(idempotency_key)) > 0
                    ),
                    request_digest_sha256 TEXT NOT NULL CHECK (
                        length(request_digest_sha256) = 64
                        AND request_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    publication_mode TEXT NOT NULL CHECK (
                        publication_mode IN (
                            'ordinary', 'governed_authority',
                            'provisional_issue_outline'
                        )
                    ),
                    matter_id TEXT NOT NULL,
                    structured_output_id TEXT NOT NULL,
                    structured_output_version_id TEXT NOT NULL UNIQUE,
                    version_index INTEGER NOT NULL CHECK (
                        typeof(version_index) = 'integer' AND version_index > 0
                    ),
                    source_set_id TEXT NOT NULL UNIQUE,
                    generation_session_id TEXT NOT NULL UNIQUE,
                    audit_event_id TEXT NOT NULL UNIQUE,
                    aggregate_digest_sha256 TEXT NOT NULL UNIQUE CHECK (
                        length(aggregate_digest_sha256) = 64
                        AND aggregate_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    accepted_packet_version_id TEXT,
                    accepted_packet_version_index INTEGER,
                    accepted_packet_aggregate_digest_sha256 TEXT,
                    created_at DATETIME NOT NULL,
                    CHECK (
                        (publication_mode = 'governed_authority'
                            AND length(trim(accepted_packet_version_id)) > 0
                            AND accepted_packet_version_index > 0
                            AND length(accepted_packet_aggregate_digest_sha256) = 64
                            AND accepted_packet_aggregate_digest_sha256
                                NOT GLOB '*[^0-9a-f]*')
                        OR (publication_mode <> 'governed_authority'
                            AND accepted_packet_version_id IS NULL
                            AND accepted_packet_version_index IS NULL
                            AND accepted_packet_aggregate_digest_sha256 IS NULL)
                    ),
                    FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE,
                    FOREIGN KEY (structured_output_id)
                        REFERENCES structured_outputs(id) ON DELETE CASCADE,
                    FOREIGN KEY (structured_output_version_id)
                        REFERENCES structured_output_versions(id) ON DELETE CASCADE,
                    FOREIGN KEY (source_set_id)
                        REFERENCES document_source_sets(id) ON DELETE CASCADE,
                    FOREIGN KEY (generation_session_id)
                        REFERENCES generation_sessions(id),
                    FOREIGN KEY (audit_event_id) REFERENCES audit_events(id),
                    FOREIGN KEY (accepted_packet_version_id)
                        REFERENCES accepted_research_packet_versions(id)
                )
                """)
            try db.create(
                index: "idx_structured_work_publications_matter",
                on: "structured_work_product_publications",
                columns: ["matter_id", "created_at", "idempotency_key"]
            )
            try db.execute(sql: """
                CREATE TRIGGER structured_work_product_publication_insert_guard
                BEFORE INSERT ON structured_work_product_publications
                WHEN NOT EXISTS (
                    SELECT 1
                    FROM structured_outputs AS output
                    JOIN structured_output_versions AS version
                      ON version.id = NEW.structured_output_version_id
                     AND version.structured_output_id = output.id
                    JOIN document_source_sets AS source_set
                      ON source_set.id = NEW.source_set_id
                     AND source_set.structured_output_version_id = version.id
                     AND source_set.matter_id = NEW.matter_id
                     AND source_set.status = 'attached'
                    JOIN generation_sessions AS generation
                      ON generation.id = NEW.generation_session_id
                     AND generation.id = version.generation_session_id
                     AND generation.status = 'completed'
                    JOIN audit_events AS audit
                      ON audit.id = NEW.audit_event_id
                     AND audit.event_type = 'structured_work_product_published'
                     AND audit.matter_id = NEW.matter_id
                     AND audit.related_table = 'structured_outputs'
                     AND audit.related_id = output.id
                    WHERE output.id = NEW.structured_output_id
                      AND output.matter_id = NEW.matter_id
                      AND output.deleted_at IS NULL
                      AND output.active_version_id = version.id
                      AND version.version_index = NEW.version_index
                ) OR (
                    NEW.publication_mode = 'governed_authority'
                    AND NOT EXISTS (
                        SELECT 1
                        FROM accepted_research_packet_versions AS packet
                        JOIN research_packet_work_product_bindings AS binding
                          ON binding.packet_version_id = packet.id
                         AND binding.structured_output_version_id
                            = NEW.structured_output_version_id
                        WHERE packet.id = NEW.accepted_packet_version_id
                          AND packet.version_index = NEW.accepted_packet_version_index
                          AND packet.aggregate_digest_sha256
                            = NEW.accepted_packet_aggregate_digest_sha256
                          AND binding.packet_aggregate_digest_sha256
                            = NEW.accepted_packet_aggregate_digest_sha256
                          AND packet.matter_id = NEW.matter_id
                          AND NOT EXISTS (
                              SELECT 1
                              FROM research_packet_version_dispositions AS disposition
                              WHERE disposition.packet_version_id = packet.id
                                AND disposition.kind = 'revoked'
                          )
                    )
                ) OR (
                    NEW.publication_mode <> 'governed_authority'
                    AND EXISTS (
                        SELECT 1 FROM research_packet_work_product_bindings
                        WHERE structured_output_version_id
                            = NEW.structured_output_version_id
                    )
                )
                BEGIN
                    SELECT RAISE(ABORT, 'incomplete structured work publication aggregate');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER structured_work_product_publication_update_guard
                BEFORE UPDATE ON structured_work_product_publications
                BEGIN
                    SELECT RAISE(ABORT, 'structured work publication is immutable');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER structured_work_product_publication_delete_guard
                BEFORE DELETE ON structured_work_product_publications
                WHEN EXISTS (SELECT 1 FROM matters WHERE id = OLD.matter_id)
                BEGIN
                    SELECT RAISE(ABORT, 'structured work publication is immutable');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER provisional_work_product_version_insert_guard
                BEFORE INSERT ON structured_output_versions
                WHEN EXISTS (
                    SELECT 1 FROM structured_work_product_publications
                    WHERE structured_output_id = NEW.structured_output_id
                      AND publication_mode = 'provisional_issue_outline'
                )
                BEGIN
                    SELECT RAISE(ABORT, 'provisional issue outline cannot be promoted');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER provisional_work_product_output_update_guard
                BEFORE UPDATE OF active_version_id, status ON structured_outputs
                WHEN EXISTS (
                    SELECT 1 FROM structured_work_product_publications
                    WHERE structured_output_id = OLD.id
                      AND publication_mode = 'provisional_issue_outline'
                ) AND (
                    NEW.active_version_id IS NOT OLD.active_version_id
                    OR NEW.status <> 'needs_review'
                )
                BEGIN
                    SELECT RAISE(ABORT, 'provisional issue outline cannot be promoted');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER provisional_work_product_export_insert_guard
                BEFORE INSERT ON document_exports
                WHEN EXISTS (
                    SELECT 1 FROM structured_work_product_publications
                    WHERE (
                        structured_output_id = NEW.structured_output_id
                        OR structured_output_version_id
                            = NEW.structured_output_version_id
                    )
                      AND publication_mode = 'provisional_issue_outline'
                )
                BEGIN
                    SELECT RAISE(ABORT, 'provisional issue outline cannot be exported');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER provisional_work_product_binding_insert_guard
                BEFORE INSERT ON research_packet_work_product_bindings
                WHEN EXISTS (
                    SELECT 1
                    FROM structured_work_product_publications AS publication
                    JOIN structured_output_versions AS version
                      ON version.structured_output_id = publication.structured_output_id
                    WHERE version.id = NEW.structured_output_version_id
                      AND publication.publication_mode = 'provisional_issue_outline'
                )
                BEGIN
                    SELECT RAISE(ABORT, 'provisional issue outline cannot bind authority');
                END
                """)
        }

    }
}
