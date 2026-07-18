# Document Ingestion Refinement

Status: implementation complete in source; protected release sign-off pending
Last reviewed: July 18, 2026

## Outcome

This program hardens the original Milestone 3 document pipeline without turning Supra AI into
a cloud service or general e-discovery platform. It preserves local processing and the existing
package boundaries while adding durable accounting, immutable evidence lineage, structured
extraction, exhaustive task coverage, independent verification dimensions, and assurance-aware
output UX.

## Delivered in source

- v059 records every selected and discovered import source, durable target-folder intent,
  resumable interruption state, and transient top-level bookmark authority.
- v060-v062 retain immutable extraction/OCR/user-edit revisions and typed, revision-bound
  DOCX, PDF, XLSX, EML, and deterministic legal-document structure.
- v063 provides structure-aware Chunker v2 behind a default-off setting and keeps legacy v1
  locators and packets readable.
- v064 adds frozen corpus snapshots, partition/attempt ledgers, bounded retry, cancellation,
  resume, exhaustive-list reconciliation, and chronology coverage accounting.
- v065-v069 add reviewed same-matter document relations, retained source-packet lineage,
  exact scoped staleness, classification lineage/abstention, and complete independent
  verification-dimension ledgers.
- Output, grounded-chat, chronology, citation-preview, and export surfaces share seven exact
  assurance states. Only proposition-supported or corpus-complete artifacts can export, and
  exports embed the assurance state. Grounded chat can be promoted atomically to Outputs while
  retaining its exact source packet; an unpromoted message has no export path.
- `SupraBench` freezes deterministic quality/safety baselines and a separate fixed 10/50/200
  performance report covering brute-force retrieval, corpus-ledger writes, structure
  persistence, import/index throughput, peak RSS, and one-document incremental work.

## Durable gates

- Protected CI tests the exact 14-package inventory, Debug and Release app/XPC builds,
  shipping migration fixtures, deterministic document baselines, and the fixed-scale rule that
  incremental work touches zero unaffected documents.
- Statistical B-PERF thresholds use the recorded fixed hardware/toolchain fingerprint. Cade
  Spivey approved the 10% latency and throughput bands, 48 MiB memory ceiling, 25% incremental
  wall-time band, and zero-unaffected-work rule on July 18, 2026.
- Product and security wording is synchronized through `Docs/Verified-Product-Claims.yml`.
  Fixtures remain synthetic and no new document-processing network path was added.

## Remaining release sign-off

The source implementation is not by itself the complete protected-tier acceptance record. A
release candidate still needs the recorded Vision/PDFKit fixtures, force-quit/relaunch bookmark
drill, Debug and Release hosted-XPC tokenizer check, chosen real local-model tasks, app/UI flows,
fixed-hardware performance comparison under the approved envelope, and any designated manual legal
fidelity review. Chunker v2 stays default-off until its separate retrieval decision gate is
approved. ANN/vector indexing is not justified by the current 200-document baseline and remains
out of scope.

## Rollback posture

Each schema work order is append-only and covered by shipping migration fixtures and the
pre-migration snapshot path. Derived structure, classifications, relations, chunks, and benchmark
gates can be rolled back independently without rewriting retained revisions or citations. A
threshold waiver can never disable deterministic matter-isolation, accounting, false-clean, or
zero-unaffected-work gates.
