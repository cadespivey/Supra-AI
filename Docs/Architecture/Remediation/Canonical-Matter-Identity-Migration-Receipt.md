# Canonical Matter Identity Migration Receipt

**Captured:** 2026-08-13 (America/New_York)  
**Validated source commit:** `a8f8f479c8ba858c9fcde557db5dbbc0db6cb52e`  
**v074 implementation commit:** `9b8c19e6`  
**Branch:** `codex/architecture-ux-r0`  
**Scope:** WP-1.1 owner-profile copy drill and canonical-identity migration acceptance  
**Master-plan SHA-256:**
`5582d4da708d0dfb8ab7ba182da7f6130b35f9b8a10c2d89376ab172c9301bc5`

This receipt records the non-destructive live-profile-copy acceptance required before the
canonical matter-identity conversion can be treated as migration-safe. It is evidence about
this Mac's observed owner-shape v072 profile and the separately committed synthetic migration
fixtures. It is not permission to reset, replace, or otherwise mutate the ordinary profile.

## 1. Test-first implementation history

| Commit | Evidence or implementation |
|---|---|
| `b373e643` | RED canonical migration, unresolved queue, and resolution-receipt contracts |
| `54839a67` | Refined RED coherent court-resolution-state contract |
| `689061b6` | Refined RED exact party and representation schema contract |
| `631d526b` | RED durable party-confirmation receipt schema contract |
| `cdeadb07` | RED Store-owned party-confirmation receipt repository contract |
| `e8eb8fde` | RED matter identity lifecycle contracts |
| `ce4460b9` | Refined RED missing-court lifecycle contract |
| `152e76a6` | RED receipt-backed identity-transition guard |
| `9b8c19e6` | GREEN v074 schema, migration, Store lifecycle, and durable receipts |
| `4730f92c` | GREEN court presentation and coherent party-default derivation |

The committed automated gates preserve the exact v072 and v073 migration bodies, exercise a
rich synthetic v073 graph through v074, prove late-migration rollback and deterministic
recovery, retain legacy strings and related document/work-product/corpus/audit identities,
create no inferred parties, and verify idempotent reopen behavior.

## 2. Ordinary profile precondition

The ordinary database was inspected read-only before the drill:

| Item | Observation |
|---|---|
| Database | `/Users/cadespivey/Library/Application Support/ai.supra.SupraAI/SupraAI.sqlite` |
| SHA-256 | `8dfa556e0768a3ab8711b3c517982bb64c11e0fd03e19ee3e417487f22081b76` |
| Size | 1,019,904 bytes |
| Latest migration | `v072_harden_corpus_review_integrity` |
| SQLite integrity | `ok` |
| Foreign-key violations | 0 |
| Adjacent WAL/SHM | none |

No production migrator opened the ordinary database. The SHA-256 remained identical after the
drill.

## 3. Disposable-copy drill

An exact byte copy was made at
`/private/tmp/supra-owner-v074-drill.SRc0CJ/SupraAI.sqlite`. Its pre-migration SHA-256 matched
the ordinary database. Only that disposable copy was opened through `SupraStore`.

The copy was opened and closed through the shipping migrator three times. The acceptance
harness captured all 60 pre-existing non-migration table counts plus the exact `app_settings`
and `document_intelligence_settings` rows before the first open, then compared them after every
open.

| Postcondition | Observation |
|---|---|
| Final migration | `v074_create_canonical_matter_identity` |
| Registered/applied migrations | 74, contiguous v001 through v074 |
| SQLite integrity after each open | `ok` |
| Foreign-key violations after each open | 0 |
| Pre-existing table-count mismatches | 0 |
| Settings-row mismatches | 0 |
| Dormant v073 Review rows across seven compatibility tables | 0 |
| v074 conversion, decision, party, or representation rows | 0 |
| Migrated copy SHA-256 | `c7dd9a6428f3da071862fe699c06481f1263e571792d78436c93d03e6c99874f` |

The migration created one pre-upgrade snapshot at
`/private/tmp/supra-owner-v074-drill.SRc0CJ/PreMigrationSnapshots/SupraAI-premigration-20260813-231944-788.sqlite`.
Its SHA-256 is
`29cbf8e1323aa7c3db2d55a2a19574eb41a456d4db29b092e02e3f9346602cee`; it remains healthy,
has zero foreign-key violations, and ends at exact v072.

## 4. Scope and limitation

The observed owner profile contains no matter, document, output, audit, managed-document, or
canonical-identity business rows. This drill therefore proves owner-shape migration,
snapshotting, settings preservation, schema compatibility, and deterministic reopen. It does
not substitute for the committed rich synthetic preservation/rollback fixture, and it does not
claim that the public v069 shipping fixture contains business data. Those limitations remain
explicit so empty-row success cannot be mistaken for a rich restore proof.

No database, snapshot, export, model, backup, or managed document was deleted. The disposable
copy and its snapshot are evidence artifacts only; the ordinary owner profile remains at v072.
