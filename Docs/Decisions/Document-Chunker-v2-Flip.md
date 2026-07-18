# D-06 — Document Chunker v2 Default Flip

Status: **quality gates passed — pending explicit repo-owner approval**
Evidence source: `932622be28ea784fb37881ce1aea5e0cbb337f15`
Benchmark artifact: `TestData/Benchmarks/chunker-v2-comparison-932622be28ea784fb37881ce1aea5e0cbb337f15.json`

## Decision

Keep `documents.chunkerVersion` at 1 until explicit repo-owner approval is recorded. The
deterministic comparison now passes the ordinary-retrieval, structure-sensitive, and
exhaustive-list quality gates; this document does not itself record the required approval.

The one-time matter re-chunk path exists and T-CHK-07 proves that it reaches a terminal text
index, preserves revision-bound locator/excerpt display for citations to deleted v1 chunks,
and does not mutate the shipping default. It must not be scheduled as a default migration
while D-06 remains pending owner approval.

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
- T-CHK-07 migration/citation recovery: GREEN in deterministic package tests.
- Default-flip live drill and rollback drill: pending approval because it changes the shipping
  default and schedules the existing one-time re-chunk path.
- Repo-owner approval: not yet recorded.

## Required follow-up to complete D-06

1. Record explicit repo-owner approval before changing the default or scheduling matter
   migrations.
2. Flip the default to v2, run the one-time re-chunk path, and execute the live flip/revert
   drill while confirming terminal readiness and old-citation display.
3. Retain the v1 rollback path and record the completed drill in the qualification evidence.
