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

## Audited review and downstream assurance

The Documents toolbar exposes a matter-scoped relation review queue. Each item shows the immutable proposal evidence and structural-change counts before offering the exact `Confirm`, `Reject`, and `Override` actions. Confirm and reject are one-way transitions from `proposed`. Override first rejects the original proposal, creates a distinct user-authored proposal with its own evidence, and confirms that new row through the same transition.

The repository writes the state transition and its `document_relation_reviewed` audit event in one transaction. The event records actor, time, old/new states, kind, endpoints, and the original evidence. A review also demotes any dependent structured output citing either endpoint to `needs_review`; historical output content is retained.

Only confirmed relations can add version-state metadata to retrieval sources. Draft, operative, amendment, redline, and superseded labels therefore carry the literal `(confirmed)` qualifier. Proposed relations instead produce a named warning. For version-sensitive comparison and negative-check tasks, any proposed relation whose two endpoints are in scope blocks a clean result:

- comparison assurance becomes `corpus_incomplete`;
- a negative conclusion becomes `negative_blocked`;
- the persisted reason names the relation ID, kind, and both documents.

This is an assurance boundary, not a legal conclusion. The reviewer decides whether the evidence supports a relation; the software preserves that decision and prevents an unreviewed proposal from silently selecting an operative document.

## Verification and benchmark

The test contract is split across:

- T-VER-04: stable draft/executed evidence and a cross-matter negative control;
- T-VER-05: directed, acyclic amendment/supersession chains with missing-date ambiguity;
- T-VER-06: exact changed/inserted/deleted structural units and locator round trips;
- T-VER-07: unreviewed in-scope relations block version-sensitive clean assurance while preliminary retrieval warns;
- T-VER-08: audited one-way review, distinct override proposals, confirmed-only metadata, and dependent-output invalidation;
- T-UX-08: accessible evidence/diff review flow and exact confirm/reject/override actions;
- B-VER-01: precision, recall, and F1 overall and by relation kind against `TestData/Benchmarks/document-relation-keys.json`.
- B-VER-02: reviewed operative-state accuracy plus the blocked-when-unreviewed rate for owner-designated ambiguous families in the same key file.

The checked-in key set is synthetic. B-VER-02's deterministic safety gate requires every designated ambiguous family to block a clean result. The operative-state quality band and the legal-fidelity sign-off for designated ambiguous keys remain pending owner/reviewer approval in `TestData/Benchmarks/threshold-proposals.json`; deterministic matter isolation and false-clean failures cannot be waived by that review.
