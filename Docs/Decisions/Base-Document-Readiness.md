# D-18 — Canonical Base Document Readiness

Status: **approved operating decision (2026-08-13); implementation gates pending**

## Context

Import/extraction completion, a generic `ready` string, and semantic search readiness are different
facts. Controllers and synthetic demo data currently project them differently, which can enable
grounded work without complete active-model evidence or report a false ready count.

## Decision

One Store-derived `DocumentReadinessReceipt` is authoritative for every Documents, Ask,
Chronology, drafting, Chat, and Saved Work consumer. A document is ready for grounded semantic
work only when all applicable conditions are satisfied for its current immutable revisions:

1. the document is live and in the requested matter/scope;
2. ingestion/extraction is terminal and has no failed or review-required part that the task hides;
3. current selected part revisions and structural index state are coherent;
4. current chunker/index version is complete for those revisions;
5. the active embedding artifact is selected, verified, and exactly identified;
6. every required current chunk has one valid vector for that exact artifact/dimension;
7. no relevant source/model/chunker/toolchain change has marked the receipt stale;
8. exclusions and blockers are explicit in the denominator and visible to the caller.

Readiness is task/scope aware. Text-only viewing may be available when semantic grounded work is
blocked, but the UI must name that narrower capability. Switching from embedding model A to B
makes B not-ready until B coverage is complete; vectors for A do not satisfy B.

Consumers may cache a receipt only with exact matter/scope, source-snapshot, revision, chunker,
index, and embedding identities and must revalidate before use. Controller-local booleans and
synthetic counts cannot override the receipt.

## Consequences

- Demo/UITest fixtures must build real synthetic readiness records. “Exactly three ready” is
  asserted through every consumer from the same Store state.
- Blocking UI states name the missing requirement and deep-link to the exact corrective AI Setup
  or Documents row while preserving return context.
- Failed/review-required/excluded documents remain visible in coverage receipts and negative-result
  reasoning.

## Enforcement and gates

Owners: `SupraStore` for the canonical derivation and `SupraSessions` for typed projection only.

Required gates: `T-DATA-READY-01/02/03`, `T-UX-SETUP-01`, `T-RAG-CACHE-01`, and the readiness
portions of `T-RAG-SCAN-01`.
