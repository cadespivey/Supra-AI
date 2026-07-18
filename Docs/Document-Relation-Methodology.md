# Document relation methodology

Supra AI's relation analysis is deterministic and proposal-only. It narrows the review set; it does not decide which document is operative. Every system-created row remains in the `proposed` state until the audited review workflow confirms or rejects it.

## Isolation and inputs

`DocumentRelationProposalService` accepts one matter ID and reads only that matter's document instances, complete normalized chunk text, persisted structure nodes, display name, and optional metadata date. The repository independently verifies that both relation endpoints belong to the requested matter.

The exact/normalized pass proposes:

- `exact_duplicate` for same-matter document instances backed by one content blob;
- `normalized_duplicate` for different blobs whose complete normalized-text digest matches.

The structural pass uses a versioned `structural_relation_v1` evidence contract:

- lowercase alphanumeric tokens and three-token shingles;
- Jaccard text similarity;
- `StructuralDiff` alignment by stable natural node key, retaining revision-bound node IDs as review locators;
- structural similarity `1 - changed/maximum-unit-count`;
- combined similarity `0.75 * text + 0.25 * structure`, rounded to six decimal places.

Pairs with combined similarity at least `0.55` may receive a symmetric `near_duplicate` proposal. A shared normalized control number can establish a candidate version family even when wording changes push similarity below that threshold.

## Directional signals

Role signals come from the display name and the first 400 characters of extracted text. The deterministic precedence is amendment, redline, draft, superseded, executed/signed, then neutral.

- Draft to executed proposes `draft_of`.
- Redline to executed proposes `redline_of`.
- Executed to a named superseded version proposes `supersedes`.
- Amendments are ordered by metadata date, then explicit amendment number and stable document ID. Each amendment proposes `amendment_of` the immediately preceding executed/amendment node.

An absent metadata date never invents chronology. The edge remains proposed with `date_order = ambiguous_missing_date`, and confidence is capped at `0.69`. Directed construction is forward-only within the ordered family, preventing cycles by design.

## Evidence and review boundary

Evidence JSON is canonical key-sorted JSON and includes algorithm/schema version, relation kind, role signal, family key when present, text/structure/combined similarities, changed/inserted/deleted unit counts, endpoint roles, metadata dates when present, and the date-order classification. Repository replay requires byte-identical evidence and confidence, making proposal passes idempotent.

Confidence is descriptive only. Neither exact equality nor a score of `1.0` confirms a relation, marks a document operative, or feeds confirmed-only consumers.

## Verification and benchmark

The test contract is split across:

- T-VER-04: stable draft/executed evidence and a cross-matter negative control;
- T-VER-05: directed, acyclic amendment/supersession chains with missing-date ambiguity;
- T-VER-06: exact changed/inserted/deleted structural units and locator round trips;
- B-VER-01: precision, recall, and F1 overall and by relation kind against `TestData/Benchmarks/document-relation-keys.json`.

The checked-in key set is synthetic. Owner-approved quality bands remain governed by `TestData/Benchmarks/threshold-proposals.json` after a frozen deterministic baseline is recorded.
