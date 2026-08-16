# D-19 — Case File Review Retirement and Immutable v073 Compatibility

Status: **approved by the repo owner on 2026-08-13; retirement implemented, final release qualification pending**

## Context

Case File Review has no product purpose for the owner and is approved for complete retirement.
Its schema migration, `v073_create_case_file_review_projects`, is already an ancestor of shared
`main`. Public v2.3.4 ends at v069, and the read-only owner-profile observation ended at v072 with
no Review tables, but shared-main exposure makes deleting, renumbering, reusing, or rewriting v073
unsafe.

## Decision

Remove the named Case File Review capability end to end: Guided New Review, Review Projects,
Review Matrix/workbench, Review-only CSV/XLSX creation, matter tab, routes, controllers,
repositories, composition, fixtures, probes, smoke selectors, claims, setup/status/hardware UI,
queue submission, and runtime reservation/status/lease paths.

Preserve ordinary research-result review, reviewed authorities/propositions, document-relation
review, drafting review notes, citation review, `needsReview`, “Review a Draft,” generic corpus
analysis/exhaustive-list/chronology infrastructure, source integrity, and neutral runtime safety.

Keep migrations v001 through v073 byte-for-byte and order-identical. Keep v073 registered at its
historical position and retain only the reset/fixture compatibility needed to open a shared-main
database. Its tables remain dormant and unreachable: no shipping API may create, mutate, render,
export, queue, reserve runtime for, or advertise Review data. Any later schema change appends a new
identifier; it never repurposes v073.

Feature retirement does not authorize:

- dropping/purging Review tables or rows;
- deleting existing Review CSV/XLSX files;
- deleting model binaries;
- resetting or replacing the owner's live profile;
- removing corpus/exhaustive infrastructure used by another named consumer.

## Removal safety order

1. Add RED absence, retained-feature, job-quiescence, artifact-preservation, and migration gates.
2. Block new Review admission and prove queued/paused/running/failed/completed legacy work inert
   on isolated synthetic fixtures; preserve cancellation/quiescence until idle is confirmed.
3. Remove public UI/controller/composition/export capability.
4. Remove Store APIs while retaining immutable migration compatibility.
5. Extract neutral cancellation/quarantine/idle recovery, then remove Review runtime leasing.
6. Replace stale smoke selectors and claims with exact nonzero absence/parity gates.

## Downgrade and recovery posture

The candidate must test public-v069, owner-shape-v072, and already-main-v073 forward opening,
reopen, interruption, restore, integrity, and foreign keys. Binary downgrade is unsupported unless
an explicit fixture proves the prior binary safely opens the candidate schema. The default
emergency posture is a forward-fix release; restoring a pre-migration snapshot is an explicit
owner-operated disaster-recovery action with a disclosed post-snapshot data-loss window.

## Enforcement and gates

Required gates: `T-REVIEW-RETIRE-UI-01`, `T-REVIEW-RETIRE-JOB-01`,
`T-REVIEW-TERMS-01`, `T-REVIEW-RETIRE-ARTIFACT-01`, `T-XPC-REVIEW-REMOVE-01`,
`T-REVIEW-RETIRE-CAP-01`, `T-REVIEW-RETIRE-SCHEMA-01`,
`T-REVIEW-RETIRE-CLAIMS-01`, `T-REVIEW-RETIRE-SMOKE-01`, and `DR-CORPUS-OWNER-01`.

## Post-removal corpus-owner audit

The 2026-08-13 Release-composition audit found zero shipping consumers of
`CorpusAnalysisQueueRunner`: `AppEnvironment` constructs `DocumentProcessingQueue` without a
corpus runner, so any encountered corpus-analysis job terminates as unavailable before model
work. `ExhaustiveListTask` remains used by package tests and the synthetic `SupraBench` harness,
not by an app route. The exact-slice Store and Sessions substrate remains for compatibility and
separate owner review; this retirement does not silently broaden into its deletion.

Because there are fewer than two concrete non-Review shipping consumers, the decision is **no
coordinator extraction**. The unowned durable-queue, production-model-binding, and production
generation-audit claims are removed. Re-composing or retiring the generic substrate requires a
separate product-owner decision and new RED/GREEN gates.
