# D-06 — Document Chunker v2 Default Flip

Status: **approved by repo owner Cade Spivey on July 18, 2026 — implementation complete; exact-Release live drill pending**
Evidence source: `932622be28ea784fb37881ce1aea5e0cbb337f15`
Benchmark artifact: `TestData/Benchmarks/chunker-v2-comparison-932622be28ea784fb37881ce1aea5e0cbb337f15.json`

## Decision

Cade Spivey explicitly approved the D-06 chunker-v2 default flip and one-time existing-matter
re-chunk on July 18, 2026. New stores now default `documents.chunkerVersion` to 2. Existing
stores run the same all-matter rebuild once during bootstrap, then persist the v2 flag and a
completion marker only after every eligible document reaches a terminal text-indexed or ready
state with zero pending documents.

The Diagnostics surface retains an explicit v1 rollback control. A rollback uses the same
complete rebuild coordinator, preserves immutable revisions and denormalized citation
locators/excerpts, and leaves the one-time promotion marker in place so a later launch cannot
silently undo the operator's rollback choice.

## Recorded comparison

The same synthetic benchmark corpus, deterministic embedding model, retrieval depth, caps,
and metric formulas were run once under each chunker version on the source SHA above.

| Metric | v1 | v2 | Delta | Gate |
|---|---:|---:|---:|---|
| B-RET-01 Recall@8 | 0.647059 | 0.647059 | 0 | pass |
| B-RET-01 Recall@12 | 0.705882 | 0.705882 | 0 | pass |
| B-RET-01 Recall@40 | 0.823529 | 0.823529 | 0 | pass |
| B-RET-02 full evidence-set recall@40 | 0.625000 | 0.625000 | 0 | pass |
| B-RET-02 typed-structure evidence recall | 0.000000 | 1.000000 | +1.000000 | **improves** |

Measured retrieval time was 0.059190 seconds for v1 and 0.190475 seconds for v2, a 3.2180×
ratio in this run. This wall-clock comparison is diagnostic decision evidence, not the
fixed-hardware B-PERF release gate. The separately approved B-PERF envelope remains the
authoritative p95 and throughput gate.

B-LST-01 precision, recall, F1, and duplicate-output rate are present in both reports. Every
higher-is-better value is noninferior and duplicate-output rate does not increase, so the
post-M6 list gate is measured and passes.

## Gate disposition

- B-RET ordinary retrieval parity: GREEN at Recall@8, Recall@12, and Recall@40.
- B-RET structure-sensitive win: GREEN; typed-structure evidence recall improves from 0 to 1.
- B-LST post-M6 comparison: GREEN; all measured list-quality values are noninferior.
- T-CHK-07 forward migration, rollback, restore, readiness, and historical citation display:
  GREEN in deterministic package tests.
- Hermetic signed-app UI flip/revert drill: GREEN (`DocumentChunkerRolloutUITests`, v2 → v1 →
  v2, 1 test and 0 failures).
- Repo-owner approval: **approved by Cade Spivey on July 18, 2026**.
- Exact signed-Release existing-store drill: pending final qualification evidence.

## Required follow-up to complete D-06

Run the exact signed-Release existing-store v2 migration and live v1 rollback/v2 restore,
confirm zero pending documents and historical citation display after each rebuild, and record
the completed drill in the private qualification evidence. The v1 implementation and operator
control remain the supported rollback path.
