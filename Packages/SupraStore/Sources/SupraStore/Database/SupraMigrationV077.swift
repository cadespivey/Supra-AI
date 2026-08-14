import CryptoKit
import Foundation
import GRDB
import SupraCore

extension SupraMigrator {
    static func registerMigrationV077(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v077_create_accepted_research_packets") { db in
            // Provider execution is evidence, not accepted legal authority.
            // This candidate ledger makes the executed -> reviewed -> accepted
            // transition explicit and preserves the exact content-free egress
            // identity used for the provider call.
            try db.execute(sql: """
                CREATE TABLE research_packet_candidates (
                    id TEXT PRIMARY KEY NOT NULL CHECK (length(trim(id)) > 0),
                    packet_id TEXT NOT NULL CHECK (length(trim(packet_id)) > 0),
                    matter_id TEXT NOT NULL,
                    research_session_id TEXT NOT NULL,
                    research_query_id TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (
                        state IN ('executed', 'reviewed', 'accepted', 'cancelled')
                    ),
                    provider_id TEXT NOT NULL CHECK (length(trim(provider_id)) > 0),
                    egress_authority_kind TEXT NOT NULL CHECK (
                        egress_authority_kind = 'approved_grant'
                    ),
                    egress_grant_id TEXT NOT NULL CHECK (
                        length(trim(egress_grant_id)) > 0
                    ),
                    egress_grant_version INTEGER NOT NULL CHECK (
                        typeof(egress_grant_version) = 'integer'
                        AND egress_grant_version > 0
                    ),
                    exact_query_sha256 TEXT NOT NULL CHECK (
                        length(exact_query_sha256) = 64
                        AND exact_query_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    execution_digest_sha256 TEXT NOT NULL UNIQUE CHECK (
                        length(execution_digest_sha256) = 64
                        AND execution_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    source_digest_sha256 TEXT CHECK (
                        source_digest_sha256 IS NULL OR (
                            length(source_digest_sha256) = 64
                            AND source_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    review_digest_sha256 TEXT CHECK (
                        review_digest_sha256 IS NULL OR (
                            length(review_digest_sha256) = 64
                            AND review_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    reviewer_id TEXT,
                    reviewer_action TEXT CHECK (
                        reviewer_action IS NULL
                        OR reviewer_action = 'approved_for_authority_use'
                    ),
                    reviewed_at DATETIME,
                    cancelled_by TEXT,
                    cancelled_at DATETIME,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    CHECK (
                        (state = 'executed'
                            AND source_digest_sha256 IS NULL
                            AND review_digest_sha256 IS NULL
                            AND reviewer_id IS NULL
                            AND reviewer_action IS NULL
                            AND reviewed_at IS NULL
                            AND cancelled_by IS NULL
                            AND cancelled_at IS NULL)
                        OR (state IN ('reviewed', 'accepted')
                            AND source_digest_sha256 IS NOT NULL
                            AND review_digest_sha256 IS NOT NULL
                            AND length(trim(reviewer_id)) > 0
                            AND reviewer_action = 'approved_for_authority_use'
                            AND reviewed_at IS NOT NULL
                            AND cancelled_by IS NULL
                            AND cancelled_at IS NULL)
                        OR (state = 'cancelled'
                            AND length(trim(cancelled_by)) > 0
                            AND cancelled_at IS NOT NULL
                            AND (
                                (source_digest_sha256 IS NULL
                                    AND review_digest_sha256 IS NULL
                                    AND reviewer_id IS NULL
                                    AND reviewer_action IS NULL
                                    AND reviewed_at IS NULL)
                                OR (source_digest_sha256 IS NOT NULL
                                    AND review_digest_sha256 IS NOT NULL
                                    AND length(trim(reviewer_id)) > 0
                                    AND reviewer_action = 'approved_for_authority_use'
                                    AND reviewed_at IS NOT NULL)
                            ))
                    ),
                    FOREIGN KEY (matter_id)
                        REFERENCES matters(id) ON DELETE CASCADE,
                    FOREIGN KEY (research_session_id)
                        REFERENCES research_sessions(id) ON DELETE CASCADE,
                    FOREIGN KEY (research_query_id)
                        REFERENCES research_queries(id) ON DELETE CASCADE
                )
                """)
            try db.create(
                index: "idx_research_packet_candidates_packet",
                on: "research_packet_candidates",
                columns: ["packet_id", "created_at", "id"]
            )
            try db.create(
                index: "idx_research_packet_candidates_matter",
                on: "research_packet_candidates",
                columns: ["matter_id", "updated_at", "id"]
            )

            try db.execute(sql: """
                CREATE TABLE research_packet_candidate_sources (
                    execution_id TEXT NOT NULL,
                    source_index INTEGER NOT NULL CHECK (
                        typeof(source_index) = 'integer' AND source_index >= 0
                    ),
                    research_result_id TEXT NOT NULL CHECK (
                        length(trim(research_result_id)) > 0
                    ),
                    provider_result_id TEXT NOT NULL CHECK (
                        length(trim(provider_result_id)) > 0
                    ),
                    authority_id TEXT,
                    ground_key TEXT,
                    reviewed_proposition_binding_sha256 TEXT CHECK (
                        reviewed_proposition_binding_sha256 IS NULL OR (
                            length(reviewed_proposition_binding_sha256) = 64
                            AND reviewed_proposition_binding_sha256
                                NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    excerpt TEXT,
                    excerpt_sha256 TEXT CHECK (
                        excerpt_sha256 IS NULL OR (
                            length(excerpt_sha256) = 64
                            AND excerpt_sha256 NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    PRIMARY KEY (execution_id, source_index),
                    UNIQUE (execution_id, research_result_id),
                    UNIQUE (execution_id, provider_result_id),
                    CHECK (
                        (authority_id IS NULL
                            AND ground_key IS NULL
                            AND reviewed_proposition_binding_sha256 IS NULL
                            AND excerpt IS NULL
                            AND excerpt_sha256 IS NULL)
                        OR (length(trim(authority_id)) > 0
                            AND length(trim(ground_key)) > 0
                            AND reviewed_proposition_binding_sha256 IS NOT NULL
                            AND length(excerpt) > 0
                            AND excerpt_sha256 IS NOT NULL)
                    ),
                    FOREIGN KEY (execution_id)
                        REFERENCES research_packet_candidates(id) ON DELETE CASCADE
                )
                """)

            // Accepted versions and their ordered frozen sources are an
            // immutable projection. Live authority/result rows remain useful
            // for revalidation but are deliberately not cascade parents here.
            try db.execute(sql: """
                CREATE TABLE accepted_research_packet_versions (
                    id TEXT PRIMARY KEY NOT NULL CHECK (length(trim(id)) > 0),
                    packet_id TEXT NOT NULL CHECK (length(trim(packet_id)) > 0),
                    execution_id TEXT NOT NULL UNIQUE,
                    version_index INTEGER NOT NULL CHECK (
                        typeof(version_index) = 'integer' AND version_index > 0
                    ),
                    state TEXT NOT NULL CHECK (state = 'accepted'),
                    matter_id TEXT NOT NULL,
                    research_session_id TEXT NOT NULL,
                    research_query_id TEXT NOT NULL,
                    provider_id TEXT NOT NULL CHECK (length(trim(provider_id)) > 0),
                    egress_grant_id TEXT NOT NULL CHECK (
                        length(trim(egress_grant_id)) > 0
                    ),
                    egress_grant_version INTEGER NOT NULL CHECK (
                        typeof(egress_grant_version) = 'integer'
                        AND egress_grant_version > 0
                    ),
                    exact_query_sha256 TEXT NOT NULL CHECK (
                        length(exact_query_sha256) = 64
                        AND exact_query_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    source_digest_sha256 TEXT NOT NULL CHECK (
                        length(source_digest_sha256) = 64
                        AND source_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    review_digest_sha256 TEXT NOT NULL CHECK (
                        length(review_digest_sha256) = 64
                        AND review_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    reviewer_id TEXT NOT NULL CHECK (length(trim(reviewer_id)) > 0),
                    reviewer_action TEXT NOT NULL CHECK (
                        reviewer_action = 'approved_for_authority_use'
                    ),
                    aggregate_digest_sha256 TEXT NOT NULL UNIQUE CHECK (
                        length(aggregate_digest_sha256) = 64
                        AND aggregate_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    audit_event_id TEXT NOT NULL UNIQUE,
                    accepted_at DATETIME NOT NULL,
                    UNIQUE (packet_id, version_index),
                    FOREIGN KEY (execution_id)
                        REFERENCES research_packet_candidates(id) ON DELETE CASCADE,
                    FOREIGN KEY (matter_id)
                        REFERENCES matters(id) ON DELETE CASCADE,
                    FOREIGN KEY (research_session_id)
                        REFERENCES research_sessions(id) ON DELETE CASCADE,
                    FOREIGN KEY (research_query_id)
                        REFERENCES research_queries(id) ON DELETE CASCADE,
                    FOREIGN KEY (audit_event_id) REFERENCES audit_events(id)
                )
                """)
            try db.create(
                index: "idx_accepted_research_packets_matter",
                on: "accepted_research_packet_versions",
                columns: ["matter_id", "accepted_at", "id"]
            )

            try db.execute(sql: """
                CREATE TABLE accepted_research_packet_sources (
                    packet_version_id TEXT NOT NULL,
                    source_index INTEGER NOT NULL CHECK (
                        typeof(source_index) = 'integer' AND source_index >= 0
                    ),
                    research_result_id TEXT NOT NULL CHECK (
                        length(trim(research_result_id)) > 0
                    ),
                    provider_result_id TEXT NOT NULL CHECK (
                        length(trim(provider_result_id)) > 0
                    ),
                    authority_id TEXT NOT NULL CHECK (length(trim(authority_id)) > 0),
                    ground_key TEXT NOT NULL CHECK (length(trim(ground_key)) > 0),
                    excerpt TEXT NOT NULL CHECK (length(excerpt) > 0),
                    excerpt_sha256 TEXT NOT NULL CHECK (
                        length(excerpt_sha256) = 64
                        AND excerpt_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    reviewed_proposition_binding_sha256 TEXT NOT NULL CHECK (
                        length(reviewed_proposition_binding_sha256) = 64
                        AND reviewed_proposition_binding_sha256
                            NOT GLOB '*[^0-9a-f]*'
                    ),
                    PRIMARY KEY (packet_version_id, source_index),
                    UNIQUE (packet_version_id, research_result_id),
                    UNIQUE (packet_version_id, authority_id),
                    FOREIGN KEY (packet_version_id)
                        REFERENCES accepted_research_packet_versions(id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                CREATE TABLE research_packet_acceptance_receipts (
                    idempotency_key TEXT PRIMARY KEY NOT NULL CHECK (
                        length(trim(idempotency_key)) > 0
                    ),
                    request_digest_sha256 TEXT NOT NULL CHECK (
                        length(request_digest_sha256) = 64
                        AND request_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    accepted_version_id TEXT NOT NULL UNIQUE,
                    created_at DATETIME NOT NULL,
                    FOREIGN KEY (accepted_version_id)
                        REFERENCES accepted_research_packet_versions(id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                CREATE TABLE research_packet_version_dispositions (
                    idempotency_key TEXT PRIMARY KEY NOT NULL CHECK (
                        length(trim(idempotency_key)) > 0
                    ),
                    request_digest_sha256 TEXT NOT NULL CHECK (
                        length(request_digest_sha256) = 64
                        AND request_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    packet_version_id TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('superseded', 'revoked')),
                    replacement_packet_version_id TEXT,
                    actor TEXT NOT NULL CHECK (length(trim(actor)) > 0),
                    reason TEXT NOT NULL CHECK (length(trim(reason)) > 0),
                    occurred_at DATETIME NOT NULL,
                    audit_event_id TEXT NOT NULL UNIQUE,
                    CHECK (
                        (kind = 'superseded'
                            AND length(trim(replacement_packet_version_id)) > 0
                            AND replacement_packet_version_id <> packet_version_id)
                        OR (kind = 'revoked'
                            AND replacement_packet_version_id IS NULL)
                    ),
                    FOREIGN KEY (packet_version_id)
                        REFERENCES accepted_research_packet_versions(id) ON DELETE CASCADE,
                    FOREIGN KEY (audit_event_id) REFERENCES audit_events(id)
                )
                """)
            try db.create(
                index: "idx_research_packet_dispositions_version",
                on: "research_packet_version_dispositions",
                columns: ["packet_version_id", "occurred_at", "idempotency_key"]
            )

            try db.execute(sql: """
                CREATE TABLE research_packet_work_product_bindings (
                    structured_output_version_id TEXT PRIMARY KEY NOT NULL,
                    idempotency_key TEXT NOT NULL UNIQUE CHECK (
                        length(trim(idempotency_key)) > 0
                    ),
                    request_digest_sha256 TEXT NOT NULL CHECK (
                        length(request_digest_sha256) = 64
                        AND request_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    packet_version_id TEXT NOT NULL,
                    packet_aggregate_digest_sha256 TEXT NOT NULL CHECK (
                        length(packet_aggregate_digest_sha256) = 64
                        AND packet_aggregate_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    created_at DATETIME NOT NULL,
                    audit_event_id TEXT NOT NULL UNIQUE,
                    FOREIGN KEY (structured_output_version_id)
                        REFERENCES structured_output_versions(id) ON DELETE CASCADE,
                    FOREIGN KEY (packet_version_id)
                        REFERENCES accepted_research_packet_versions(id) ON DELETE CASCADE,
                    FOREIGN KEY (audit_event_id) REFERENCES audit_events(id)
                )
                """)

            // Candidate identities are immutable from execution onward. Only
            // review evidence may be attached while executed, followed by one
            // legal state edge. Terminal candidates are append-only.
            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_identity_update_guard
                BEFORE UPDATE OF packet_id, matter_id, research_session_id,
                    research_query_id, provider_id, egress_authority_kind,
                    egress_grant_id, egress_grant_version, exact_query_sha256,
                    execution_digest_sha256, created_at
                ON research_packet_candidates
                BEGIN SELECT RAISE(ABORT, 'research packet execution is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_review_update_guard
                BEFORE UPDATE OF source_digest_sha256, review_digest_sha256,
                    reviewer_id, reviewer_action, reviewed_at
                ON research_packet_candidates
                WHEN OLD.state <> 'executed'
                BEGIN SELECT RAISE(ABORT, 'research packet review is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_transition_guard
                BEFORE UPDATE OF state ON research_packet_candidates
                WHEN NOT (
                    (OLD.state = 'executed' AND NEW.state IN ('reviewed', 'cancelled'))
                    OR (OLD.state = 'reviewed' AND NEW.state IN ('accepted', 'cancelled'))
                )
                BEGIN SELECT RAISE(ABORT, 'invalid research packet transition'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_review_completion_guard
                BEFORE UPDATE OF state ON research_packet_candidates
                WHEN NEW.state = 'reviewed' AND (
                    NOT EXISTS (
                        SELECT 1 FROM research_packet_candidate_sources
                        WHERE execution_id = OLD.id
                    )
                    OR EXISTS (
                        SELECT 1 FROM research_packet_candidate_sources
                        WHERE execution_id = OLD.id
                          AND (authority_id IS NULL
                            OR ground_key IS NULL
                            OR reviewed_proposition_binding_sha256 IS NULL
                            OR excerpt IS NULL
                            OR excerpt_sha256 IS NULL)
                    )
                )
                BEGIN SELECT RAISE(ABORT, 'research packet review is incomplete'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_acceptance_completion_guard
                BEFORE UPDATE OF state ON research_packet_candidates
                WHEN NEW.state = 'accepted' AND NOT EXISTS (
                    SELECT 1
                    FROM accepted_research_packet_versions AS version
                    JOIN research_packet_acceptance_receipts AS receipt
                      ON receipt.accepted_version_id = version.id
                    WHERE version.execution_id = OLD.id
                )
                BEGIN SELECT RAISE(ABORT, 'research packet acceptance is incomplete'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_terminal_update_guard
                BEFORE UPDATE ON research_packet_candidates
                WHEN OLD.state IN ('accepted', 'cancelled')
                BEGIN SELECT RAISE(ABORT, 'terminal research packet is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_delete_guard
                BEFORE DELETE ON research_packet_candidates
                WHEN EXISTS (SELECT 1 FROM matters WHERE id = OLD.matter_id)
                BEGIN SELECT RAISE(ABORT, 'research packet history is append-only'); END
                """)

            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_source_insert_guard
                BEFORE INSERT ON research_packet_candidate_sources
                WHEN NOT EXISTS (
                    SELECT 1 FROM research_packet_candidates
                    WHERE id = NEW.execution_id AND state = 'executed'
                )
                BEGIN SELECT RAISE(ABORT, 'candidate sources require executed packet'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_source_update_guard
                BEFORE UPDATE ON research_packet_candidate_sources
                WHEN OLD.execution_id IS NOT NEW.execution_id
                  OR OLD.source_index IS NOT NEW.source_index
                  OR OLD.research_result_id IS NOT NEW.research_result_id
                  OR OLD.provider_result_id IS NOT NEW.provider_result_id
                  OR NOT EXISTS (
                    SELECT 1 FROM research_packet_candidates
                    WHERE id = OLD.execution_id AND state = 'executed'
                  )
                BEGIN SELECT RAISE(ABORT, 'candidate source identity is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_candidate_source_delete_guard
                BEFORE DELETE ON research_packet_candidate_sources
                WHEN EXISTS (
                    SELECT 1 FROM research_packet_candidates WHERE id = OLD.execution_id
                )
                BEGIN SELECT RAISE(ABORT, 'candidate sources are append-only'); END
                """)

            try db.execute(sql: """
                CREATE TRIGGER accepted_research_packet_version_insert_guard
                BEFORE INSERT ON accepted_research_packet_versions
                WHEN NOT EXISTS (
                    SELECT 1
                    FROM research_packet_candidates AS candidate
                    WHERE candidate.id = NEW.execution_id
                      AND candidate.state = 'reviewed'
                      AND candidate.packet_id = NEW.packet_id
                      AND candidate.matter_id = NEW.matter_id
                      AND candidate.research_session_id = NEW.research_session_id
                      AND candidate.research_query_id = NEW.research_query_id
                      AND candidate.provider_id = NEW.provider_id
                      AND candidate.egress_grant_id = NEW.egress_grant_id
                      AND candidate.egress_grant_version = NEW.egress_grant_version
                      AND candidate.exact_query_sha256 = NEW.exact_query_sha256
                      AND candidate.source_digest_sha256 = NEW.source_digest_sha256
                      AND candidate.review_digest_sha256 = NEW.review_digest_sha256
                      AND candidate.reviewer_id = NEW.reviewer_id
                      AND candidate.reviewer_action = NEW.reviewer_action
                )
                BEGIN SELECT RAISE(ABORT, 'accepted packet does not match review'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER accepted_research_packet_source_insert_guard
                BEFORE INSERT ON accepted_research_packet_sources
                WHEN NOT EXISTS (
                    SELECT 1
                    FROM accepted_research_packet_versions AS version
                    JOIN research_packet_candidate_sources AS source
                      ON source.execution_id = version.execution_id
                     AND source.source_index = NEW.source_index
                    WHERE version.id = NEW.packet_version_id
                      AND source.research_result_id = NEW.research_result_id
                      AND source.provider_result_id = NEW.provider_result_id
                      AND source.authority_id = NEW.authority_id
                      AND source.ground_key = NEW.ground_key
                      AND source.excerpt = NEW.excerpt
                      AND source.excerpt_sha256 = NEW.excerpt_sha256
                      AND source.reviewed_proposition_binding_sha256
                          = NEW.reviewed_proposition_binding_sha256
                )
                BEGIN SELECT RAISE(ABORT, 'accepted packet source does not match review'); END
                """)

            for (name, table) in [
                ("version", "accepted_research_packet_versions"),
                ("source", "accepted_research_packet_sources"),
                ("receipt", "research_packet_acceptance_receipts"),
                ("disposition", "research_packet_version_dispositions"),
                ("work_product_binding", "research_packet_work_product_bindings"),
            ] {
                try db.execute(sql: """
                    CREATE TRIGGER accepted_research_packet_\(name)_update_guard
                    BEFORE UPDATE ON \(table)
                    BEGIN SELECT RAISE(ABORT, 'accepted research packet ledger is immutable'); END
                    """)
            }
            try db.execute(sql: """
                CREATE TRIGGER accepted_research_packet_version_delete_guard
                BEFORE DELETE ON accepted_research_packet_versions
                WHEN EXISTS (SELECT 1 FROM matters WHERE id = OLD.matter_id)
                BEGIN SELECT RAISE(ABORT, 'accepted research packet is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER accepted_research_packet_source_delete_guard
                BEFORE DELETE ON accepted_research_packet_sources
                WHEN EXISTS (
                    SELECT 1 FROM accepted_research_packet_versions
                    WHERE id = OLD.packet_version_id
                )
                BEGIN SELECT RAISE(ABORT, 'accepted research source is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER accepted_research_packet_receipt_delete_guard
                BEFORE DELETE ON research_packet_acceptance_receipts
                WHEN EXISTS (
                    SELECT 1 FROM accepted_research_packet_versions
                    WHERE id = OLD.accepted_version_id
                )
                BEGIN SELECT RAISE(ABORT, 'research packet receipt is immutable'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_disposition_insert_guard
                BEFORE INSERT ON research_packet_version_dispositions
                WHEN NEW.kind = 'superseded' AND NOT EXISTS (
                    SELECT 1
                    FROM accepted_research_packet_versions AS prior
                    JOIN accepted_research_packet_versions AS replacement
                      ON replacement.id = NEW.replacement_packet_version_id
                    WHERE prior.id = NEW.packet_version_id
                      AND replacement.packet_id = prior.packet_id
                )
                BEGIN SELECT RAISE(ABORT, 'packet supersession must remain in packet'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_disposition_delete_guard
                BEFORE DELETE ON research_packet_version_dispositions
                WHEN EXISTS (
                    SELECT 1 FROM accepted_research_packet_versions
                    WHERE id = OLD.packet_version_id
                )
                BEGIN SELECT RAISE(ABORT, 'research packet disposition is append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_work_product_insert_guard
                BEFORE INSERT ON research_packet_work_product_bindings
                WHEN NOT EXISTS (
                    SELECT 1
                    FROM accepted_research_packet_versions AS packet
                    JOIN structured_output_versions AS output_version
                      ON output_version.id = NEW.structured_output_version_id
                    JOIN structured_outputs AS output
                      ON output.id = output_version.structured_output_id
                    WHERE packet.id = NEW.packet_version_id
                      AND packet.aggregate_digest_sha256
                          = NEW.packet_aggregate_digest_sha256
                      AND output.matter_id = packet.matter_id
                      AND output.deleted_at IS NULL
                )
                BEGIN SELECT RAISE(ABORT, 'invalid accepted packet work-product binding'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER research_packet_work_product_delete_guard
                BEFORE DELETE ON research_packet_work_product_bindings
                WHEN EXISTS (
                    SELECT 1 FROM accepted_research_packet_versions
                    WHERE id = OLD.packet_version_id
                )
                BEGIN SELECT RAISE(ABORT, 'research packet binding is immutable'); END
                """)
        }

    }
}
