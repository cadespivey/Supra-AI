import CryptoKit
import Foundation
import GRDB
import SupraCore

extension SupraMigrator {
    static func registerMigrationV074(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v074_create_canonical_matter_identity") { db in
            // The v1 court identity contract is frozen into this migration. Store
            // does not import SupraResearch and must never apply search or fuzzy
            // matching while converting persisted legal identity.
            let catalogVersion = "jurisdiction-courts-v1"
            let catalogDigest =
                "0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3"
            let eleventhCircuitJurisdictionID =
                "federal-united-states-court-of-appeals-for-the-eleventh-circuit"
            let southernDistrictCourtID =
                "federal-florida-united-states-district-court-for-the-southern-district-of-florida"

            try db.execute(sql: """
                ALTER TABLE matters ADD COLUMN canonical_jurisdiction_id TEXT
                """)
            try db.execute(sql: """
                ALTER TABLE matters ADD COLUMN canonical_court_id TEXT
                """)
            try db.execute(sql: """
                ALTER TABLE matters ADD COLUMN court_resolution_state TEXT NOT NULL
                    DEFAULT 'unresolved'
                    CHECK (court_resolution_state IN (
                        'unresolved', 'jurisdiction_only', 'court', 'not_applicable'
                    ))
                """)
            try db.execute(sql: """
                ALTER TABLE matters ADD COLUMN canonical_catalog_version TEXT NOT NULL
                    DEFAULT 'jurisdiction-courts-v1'
                    CHECK (length(canonical_catalog_version) > 0)
                """)
            try db.execute(sql: """
                ALTER TABLE matters ADD COLUMN canonical_catalog_digest_sha256 TEXT NOT NULL
                    DEFAULT '0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3'
                    CHECK (
                        length(canonical_catalog_digest_sha256) = 64
                        AND canonical_catalog_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    )
                """)
            try db.execute(sql: """
                ALTER TABLE matters ADD COLUMN identity_revision INTEGER NOT NULL
                    DEFAULT 1
                    CHECK (typeof(identity_revision) = 'integer' AND identity_revision >= 1)
                """)

            // Structured parties are deliberately empty after migration. Legacy
            // client_names and party_perspective remain exact conversion inputs,
            // not authority to invent litigants or representation relationships.
            try db.execute(sql: """
                CREATE TABLE matter_parties (
                    id TEXT PRIMARY KEY NOT NULL,
                    matter_id TEXT NOT NULL,
                    display_name TEXT NOT NULL CHECK (length(display_name) > 0),
                    caption_name TEXT NOT NULL CHECK (length(caption_name) > 0),
                    base_role TEXT NOT NULL CHECK (base_role IN (
                        'plaintiff', 'defendant', 'petitioner', 'respondent',
                        'appellant', 'appellee', 'movant', 'third_party',
                        'nonparty', 'other'
                    )),
                    caption_order INTEGER NOT NULL CHECK (
                        typeof(caption_order) = 'integer' AND caption_order >= 0
                    ),
                    client_status TEXT NOT NULL CHECK (client_status IN (
                        'represented', 'not_represented', 'unresolved'
                    )),
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    UNIQUE (id, matter_id),
                    UNIQUE (matter_id, caption_order),
                    FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE
                )
                """)
            try db.create(
                index: "idx_matter_parties_matter_caption",
                on: "matter_parties",
                columns: ["matter_id", "caption_order"]
            )

            try db.execute(sql: """
                CREATE TABLE matter_representations (
                    id TEXT PRIMARY KEY NOT NULL,
                    matter_id TEXT NOT NULL,
                    represented_party_id TEXT NOT NULL,
                    relationship_kind TEXT NOT NULL CHECK (relationship_kind IN (
                        'counsel', 'self_represented', 'guardian', 'other'
                    )),
                    representative_name TEXT NOT NULL CHECK (length(representative_name) > 0),
                    firm_name TEXT CHECK (firm_name IS NULL OR length(firm_name) > 0),
                    service_address_json TEXT CHECK (
                        service_address_json IS NULL
                        OR (
                            json_valid(service_address_json) = 1
                            AND json_type(service_address_json) = 'object'
                        )
                    ),
                    service_emails_json TEXT NOT NULL DEFAULT '[]' CHECK (
                        json_valid(service_emails_json) = 1
                        AND json_type(service_emails_json) = 'array'
                    ),
                    service_order INTEGER CHECK (
                        service_order IS NULL
                        OR (typeof(service_order) = 'integer' AND service_order >= 0)
                    ),
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    UNIQUE (id, matter_id),
                    FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE,
                    FOREIGN KEY (represented_party_id, matter_id)
                        REFERENCES matter_parties(id, matter_id) ON DELETE CASCADE
                )
                """)
            try db.create(
                index: "idx_matter_representations_matter_party",
                on: "matter_representations",
                columns: ["matter_id", "represented_party_id"]
            )

            try db.execute(sql: """
                CREATE TABLE matter_identity_conversion_receipts (
                    id TEXT PRIMARY KEY NOT NULL,
                    matter_id TEXT NOT NULL,
                    source_kind TEXT NOT NULL CHECK (
                        source_kind IN ('migration', 'create', 'update')
                    ),
                    source_migration TEXT CHECK (
                        (source_kind = 'migration'
                            AND source_migration = 'v074_create_canonical_matter_identity'
                            AND identity_revision = 1)
                        OR (source_kind IN ('create', 'update')
                            AND source_migration IS NULL)
                    ),
                    identity_revision INTEGER NOT NULL CHECK (
                        typeof(identity_revision) = 'integer' AND identity_revision >= 1
                    ),
                    court_resolution_state TEXT NOT NULL CHECK (
                        court_resolution_state IN (
                            'unresolved', 'jurisdiction_only', 'court', 'not_applicable'
                        )
                    ),
                    resolution_reason TEXT NOT NULL CHECK (
                        resolution_reason IN (
                            'explicit_alias', 'ambiguous', 'unknown',
                            'unchanged_canonical', 'jurisdiction_only', 'not_applicable'
                        )
                    ),
                    legacy_jurisdiction TEXT NOT NULL,
                    legacy_court TEXT,
                    legacy_party_perspective TEXT NOT NULL,
                    legacy_client_names TEXT,
                    canonical_jurisdiction_id TEXT,
                    canonical_court_id TEXT,
                    canonical_catalog_version TEXT NOT NULL
                        CHECK (length(canonical_catalog_version) > 0),
                    canonical_catalog_digest_sha256 TEXT NOT NULL CHECK (
                        length(canonical_catalog_digest_sha256) = 64
                        AND canonical_catalog_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    created_at DATETIME NOT NULL,
                    UNIQUE (id, matter_id),
                    UNIQUE (matter_id, identity_revision),
                    CHECK (
                        (court_resolution_state = 'unresolved'
                            AND canonical_jurisdiction_id IS NULL
                            AND canonical_court_id IS NULL)
                        OR (court_resolution_state = 'jurisdiction_only'
                            AND length(canonical_jurisdiction_id) > 0
                            AND canonical_court_id IS NULL)
                        OR (court_resolution_state = 'court'
                            AND length(canonical_jurisdiction_id) > 0
                            AND length(canonical_court_id) > 0)
                        OR (court_resolution_state = 'not_applicable'
                            AND canonical_jurisdiction_id IS NULL
                            AND canonical_court_id IS NULL)
                    ),
                    FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE
                )
                """)

            try db.execute(sql: """
                CREATE TABLE matter_identity_decision_receipts (
                    id TEXT PRIMARY KEY NOT NULL,
                    matter_id TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('court_resolution', 'party_override')),
                    source_conversion_receipt_id TEXT,
                    prior_identity_revision INTEGER NOT NULL CHECK (
                        typeof(prior_identity_revision) = 'integer'
                        AND prior_identity_revision >= 1
                    ),
                    result_identity_revision INTEGER NOT NULL CHECK (
                        typeof(result_identity_revision) = 'integer'
                        AND result_identity_revision >= 1
                    ),
                    legacy_court TEXT,
                    canonical_jurisdiction_id TEXT CHECK (
                        canonical_jurisdiction_id IS NULL
                        OR length(canonical_jurisdiction_id) > 0
                    ),
                    canonical_court_id TEXT CHECK (
                        canonical_court_id IS NULL OR length(canonical_court_id) > 0
                    ),
                    canonical_represented_party_id TEXT,
                    requested_represented_party_id TEXT,
                    resolution_source TEXT NOT NULL CHECK (length(resolution_source) > 0),
                    actor TEXT NOT NULL CHECK (length(actor) > 0),
                    purpose TEXT NOT NULL CHECK (length(purpose) > 0),
                    canonical_catalog_version TEXT CHECK (
                        canonical_catalog_version IS NULL
                        OR length(canonical_catalog_version) > 0
                    ),
                    canonical_catalog_digest_sha256 TEXT CHECK (
                        canonical_catalog_digest_sha256 IS NULL
                        OR (
                            length(canonical_catalog_digest_sha256) = 64
                            AND canonical_catalog_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                        )
                    ),
                    request_digest_sha256 TEXT NOT NULL CHECK (
                        length(request_digest_sha256) = 64
                        AND request_digest_sha256 NOT GLOB '*[^0-9a-f]*'
                    ),
                    decided_at DATETIME NOT NULL,
                    created_at DATETIME NOT NULL,
                    UNIQUE (request_digest_sha256),
                    CHECK (
                        (kind = 'court_resolution'
                            AND source_conversion_receipt_id IS NOT NULL
                            AND result_identity_revision = prior_identity_revision + 1
                            AND canonical_jurisdiction_id IS NOT NULL
                            AND length(canonical_jurisdiction_id) > 0
                            AND canonical_court_id IS NOT NULL
                            AND length(canonical_court_id) > 0
                            AND canonical_represented_party_id IS NULL
                            AND requested_represented_party_id IS NULL
                            AND canonical_catalog_version IS NOT NULL
                            AND canonical_catalog_version = 'jurisdiction-courts-v1'
                            AND canonical_catalog_digest_sha256 IS NOT NULL
                            AND canonical_catalog_digest_sha256 =
                                '0393b9dc507ea91ebbf939e3b7620c3e6555dd01cfdbcdc00d5298d89e14adf3')
                        OR (kind = 'party_override'
                            AND source_conversion_receipt_id IS NULL
                            AND result_identity_revision = prior_identity_revision
                            AND legacy_court IS NULL
                            AND canonical_jurisdiction_id IS NULL
                            AND canonical_court_id IS NULL
                            AND canonical_represented_party_id IS NOT NULL
                            AND length(canonical_represented_party_id) > 0
                            AND requested_represented_party_id IS NOT NULL
                            AND length(requested_represented_party_id) > 0
                            AND canonical_represented_party_id <>
                                requested_represented_party_id
                            AND resolution_source = 'attorney_confirmation'
                            AND canonical_catalog_version IS NULL
                            AND canonical_catalog_digest_sha256 IS NULL)
                    ),
                    FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE,
                    FOREIGN KEY (source_conversion_receipt_id, matter_id)
                        REFERENCES matter_identity_conversion_receipts(id, matter_id)
                        ON DELETE CASCADE,
                    FOREIGN KEY (canonical_represented_party_id, matter_id)
                        REFERENCES matter_parties(id, matter_id) ON DELETE CASCADE,
                    FOREIGN KEY (requested_represented_party_id, matter_id)
                        REFERENCES matter_parties(id, matter_id) ON DELETE CASCADE
                )
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_matter_identity_court_result_revision
                ON matter_identity_decision_receipts(matter_id, result_identity_revision)
                WHERE kind = 'court_resolution'
                """)

            // One exact reviewed alias is admitted. The shorter unqualified
            // spelling is intentionally ambiguous, and every other legacy value
            // remains unresolved with its original text untouched.
            try db.execute(
                sql: """
                    UPDATE matters
                    SET canonical_jurisdiction_id = CASE court
                            WHEN 'S.D. Fla.' THEN ?
                            ELSE NULL
                        END,
                        canonical_court_id = CASE court
                            WHEN 'S.D. Fla.' THEN ?
                            ELSE NULL
                        END,
                        court_resolution_state = CASE court
                            WHEN 'S.D. Fla.' THEN 'court'
                            ELSE 'unresolved'
                        END,
                        canonical_catalog_version = ?,
                        canonical_catalog_digest_sha256 = ?,
                        identity_revision = 1
                    """,
                arguments: [
                    eleventhCircuitJurisdictionID,
                    southernDistrictCourtID,
                    catalogVersion,
                    catalogDigest,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO matter_identity_conversion_receipts (
                        id, matter_id, source_kind, source_migration, identity_revision,
                        court_resolution_state, resolution_reason,
                        legacy_jurisdiction, legacy_court,
                        legacy_party_perspective, legacy_client_names,
                        canonical_jurisdiction_id, canonical_court_id,
                        canonical_catalog_version,
                        canonical_catalog_digest_sha256, created_at
                    )
                    SELECT
                        'v074-conversion:' || id,
                        id,
                        'migration',
                        'v074_create_canonical_matter_identity',
                        1,
                        court_resolution_state,
                        CASE court
                            WHEN 'S.D. Fla.' THEN 'explicit_alias'
                            WHEN 'Southern District of Florida' THEN 'ambiguous'
                            ELSE 'unknown'
                        END,
                        jurisdiction,
                        court,
                        party_perspective,
                        client_names,
                        canonical_jurisdiction_id,
                        canonical_court_id,
                        canonical_catalog_version,
                        canonical_catalog_digest_sha256,
                        updated_at
                    FROM matters
                    ORDER BY id
                    """
            )

            try db.execute(sql: """
                CREATE TRIGGER matters_canonical_identity_insert_guard
                BEFORE INSERT ON matters
                WHEN NOT (
                    (NEW.court_resolution_state = 'unresolved'
                        AND NEW.canonical_jurisdiction_id IS NULL
                        AND NEW.canonical_court_id IS NULL)
                    OR (NEW.court_resolution_state = 'jurisdiction_only'
                        AND length(NEW.canonical_jurisdiction_id) > 0
                        AND NEW.canonical_court_id IS NULL)
                    OR (NEW.court_resolution_state = 'court'
                        AND length(NEW.canonical_jurisdiction_id) > 0
                        AND length(NEW.canonical_court_id) > 0)
                    OR (NEW.court_resolution_state = 'not_applicable'
                        AND NEW.canonical_jurisdiction_id IS NULL
                        AND NEW.canonical_court_id IS NULL)
                )
                BEGIN SELECT RAISE(ABORT, 'canonical matter identity is incoherent'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER matters_canonical_identity_update_guard
                BEFORE UPDATE OF canonical_jurisdiction_id, canonical_court_id,
                    court_resolution_state, canonical_catalog_version,
                    canonical_catalog_digest_sha256, identity_revision
                ON matters
                WHEN NOT (
                    (NEW.court_resolution_state = 'unresolved'
                        AND NEW.canonical_jurisdiction_id IS NULL
                        AND NEW.canonical_court_id IS NULL)
                    OR (NEW.court_resolution_state = 'jurisdiction_only'
                        AND length(NEW.canonical_jurisdiction_id) > 0
                        AND NEW.canonical_court_id IS NULL)
                    OR (NEW.court_resolution_state = 'court'
                        AND length(NEW.canonical_jurisdiction_id) > 0
                        AND length(NEW.canonical_court_id) > 0)
                    OR (NEW.court_resolution_state = 'not_applicable'
                        AND NEW.canonical_jurisdiction_id IS NULL
                        AND NEW.canonical_court_id IS NULL)
                )
                BEGIN SELECT RAISE(ABORT, 'canonical matter identity is incoherent'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER matters_canonical_identity_receipt_guard
                BEFORE UPDATE OF jurisdiction, party_perspective, court, client_names,
                    canonical_jurisdiction_id, canonical_court_id,
                    court_resolution_state, canonical_catalog_version,
                    canonical_catalog_digest_sha256, identity_revision
                ON matters
                WHEN (
                    OLD.jurisdiction IS NOT NEW.jurisdiction
                    OR OLD.party_perspective IS NOT NEW.party_perspective
                    OR OLD.court IS NOT NEW.court
                    OR OLD.client_names IS NOT NEW.client_names
                    OR OLD.canonical_jurisdiction_id IS NOT NEW.canonical_jurisdiction_id
                    OR OLD.canonical_court_id IS NOT NEW.canonical_court_id
                    OR OLD.court_resolution_state IS NOT NEW.court_resolution_state
                    OR OLD.canonical_catalog_version IS NOT NEW.canonical_catalog_version
                    OR OLD.canonical_catalog_digest_sha256
                        IS NOT NEW.canonical_catalog_digest_sha256
                    OR OLD.identity_revision IS NOT NEW.identity_revision
                ) AND NOT (
                    EXISTS (
                        SELECT 1
                        FROM matter_identity_conversion_receipts AS source
                        WHERE source.matter_id = NEW.id
                          AND source.identity_revision = NEW.identity_revision
                          AND source.court_resolution_state = NEW.court_resolution_state
                          AND source.legacy_jurisdiction = NEW.jurisdiction
                          AND source.legacy_court IS NEW.court
                          AND source.legacy_party_perspective = NEW.party_perspective
                          AND source.legacy_client_names IS NEW.client_names
                          AND source.canonical_jurisdiction_id
                              IS NEW.canonical_jurisdiction_id
                          AND source.canonical_court_id IS NEW.canonical_court_id
                          AND source.canonical_catalog_version
                              = NEW.canonical_catalog_version
                          AND source.canonical_catalog_digest_sha256
                              = NEW.canonical_catalog_digest_sha256
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM matter_identity_decision_receipts AS decision
                        WHERE decision.matter_id = NEW.id
                          AND decision.kind = 'court_resolution'
                          AND decision.result_identity_revision = NEW.identity_revision
                          AND NEW.court_resolution_state = 'court'
                          AND decision.canonical_jurisdiction_id
                              = NEW.canonical_jurisdiction_id
                          AND decision.canonical_court_id = NEW.canonical_court_id
                          AND decision.canonical_catalog_version
                              = NEW.canonical_catalog_version
                          AND decision.canonical_catalog_digest_sha256
                              = NEW.canonical_catalog_digest_sha256
                    )
                )
                BEGIN
                    SELECT RAISE(ABORT, 'canonical matter identity transition lacks receipt');
                END
                """)

            // Receipts are immutable while their owning matter exists. A whole-
            // matter delete remains possible because SQLite removes the parent
            // before running the child cascades.
            try db.execute(sql: """
                CREATE TRIGGER matter_identity_conversion_update_guard
                BEFORE UPDATE ON matter_identity_conversion_receipts
                WHEN EXISTS (SELECT 1 FROM matters WHERE id = OLD.matter_id)
                BEGIN SELECT RAISE(ABORT, 'matter identity conversions are append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER matter_identity_conversion_delete_guard
                BEFORE DELETE ON matter_identity_conversion_receipts
                WHEN EXISTS (SELECT 1 FROM matters WHERE id = OLD.matter_id)
                BEGIN SELECT RAISE(ABORT, 'matter identity conversions are append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER matter_identity_decision_update_guard
                BEFORE UPDATE ON matter_identity_decision_receipts
                WHEN EXISTS (SELECT 1 FROM matters WHERE id = OLD.matter_id)
                BEGIN SELECT RAISE(ABORT, 'matter identity decisions are append-only'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER matter_identity_decision_delete_guard
                BEFORE DELETE ON matter_identity_decision_receipts
                WHEN EXISTS (SELECT 1 FROM matters WHERE id = OLD.matter_id)
                BEGIN SELECT RAISE(ABORT, 'matter identity decisions are append-only'); END
                """)

            // Kept deliberately late and non-idempotent within the migration so
            // the shipping closure's transaction rollback can be fault-injected.
            try db.execute(sql: """
                CREATE INDEX idx_matter_identity_decisions_matter
                ON matter_identity_decision_receipts(matter_id, decided_at)
                """)
        }

    }
}
