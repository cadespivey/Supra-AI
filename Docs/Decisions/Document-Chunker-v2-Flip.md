# D-06 — Document Chunker v2 Default Flip

Status: **blocked — keep shipping default at v1**  
Evidence source: `02337f3d2aacbbec0c8e4d61e97c56b474b6a3c5`  
Benchmark artifact: `TestData/Benchmarks/chunker-v2-comparison-02337f3d2aacbbec0c8e4d61e97c56b474b6a3c5.json`

## Decision

Do not flip `documents.chunkerVersion` from 1 to 2. The deterministic comparison fails the
B-RET-01 noninferiority proposal at Recall@8. Explicit repo-owner approval is still required
after the quality gate is repaired; this document does not record that approval.

The one-time matter re-chunk path exists and T-CHK-07 proves that it reaches a terminal text
index, preserves revision-bound locator/excerpt display for citations to deleted v1 chunks,
and does not mutate the shipping default. It must not be scheduled as a default migration
while D-06 is blocked.

## Recorded comparison

The same synthetic benchmark corpus, deterministic embedding model, retrieval depth, caps,
and metric formulas were run once under each chunker version on the source SHA above.

| Metric | v1 | v2 | Delta | Gate |
|---|---:|---:|---:|---|
| B-RET-01 Recall@8 | 0.647059 | 0.294118 | -0.352941 | **fail** |
| B-RET-01 Recall@12 | 0.705882 | 0.764706 | +0.058824 | pass |
| B-RET-01 Recall@40 | 0.823529 | 0.823529 | 0 | pass |
| B-RET-02 full evidence-set recall@40 | 0.625000 | 0.625000 | 0 | pass, no improvement |

Measured retrieval time was 0.052476 seconds for v1 and 0.183050 seconds for v2, a 3.4883×
ratio in this run. This is decision evidence, not a fixed-hardware B-PERF release threshold;
repeat measurements are required after the Recall@8 defect is corrected.

B-LST-01 is explicitly deferred until M6 because the exhaustive list engine does not yet
exist. No list-quality value is inferred or fabricated for this decision.

## Gate disposition

- B-RET ordinary retrieval parity: blocked by Recall@8 regression.
- Structure-sensitive win: insufficient to approve; the aggregate Recall@12 improvement does
  not discharge the Recall@8 failure or the deferred B-LST gate.
- T-CHK-07 migration/citation recovery: GREEN in deterministic package tests.
- Default-flip live drill and rollback drill: not run while the gate is blocked.
- Repo-owner approval: not granted.

## Required follow-up before reconsideration

1. Diagnose and correct the v2 top-eight ranking regression without changing v1 bytes or
   silently relaxing retrieval caps/floors.
2. Re-run the deterministic v1/v2 report and record noninferiority at Recall@8, Recall@12,
   Recall@40, and full evidence-set recall.
3. Re-run latency measurements after the ranking correction.
4. After M6, add the real B-LST-01 comparison.
5. Record explicit repo-owner approval before changing the default or scheduling matter
   migrations; then execute the live flip/revert drill.
