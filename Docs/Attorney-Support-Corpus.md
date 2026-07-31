# Attorney support corpus

`Packages/SupraTestKit/Tests/SupraTestKitTests/Fixtures/attorney-support-corpus.json`
is the versioned, synthetic calibration corpus for proposition support. One test
runs every fixture through the legal, document, and drafting adapters. A package
may be stricter than the shared outcome, but a blocking fixture may never become
clean.

The corpus contains no client data and no production-generated expected output.
Each expected status and rationale is hand-authored independently of the
verifier. It covers direct quotation, faithful paraphrase, overbroad holdings,
dicta/holding confusion, jurisdiction mismatch, adverse authority, short source
text, OCR corruption, contradiction, reassigned critical values, and prompt
injection.

## Review state

The checked-in corpus is `attorney_reviewed`. The repository owner and attorney
approved the current fixture expectations and rationales on July 31, 2026; the
fixture metadata and tests pin the reviewer, date, and cases-only digest. See
[`Docs/Assurance-Closure.md`](Assurance-Closure.md).

Code owners must not change an expected result merely to make a verifier pass.
Any later fixture or expectation change returns the changed corpus to
`pending_attorney_review` until an attorney approves its new cases-only digest.
