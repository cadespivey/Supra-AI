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

The checked-in corpus is `pending_attorney_review`. That value is intentionally
enforced by the test until an attorney reviewer evaluates every case. Code
owners must not substitute a developer approval for that review or change an
expected result merely to make a verifier pass.

To record review, the attorney reviewer must approve the corpus version and
every rationale in the private release ledger. A follow-up reviewed commit may
then change `reviewStatus` to `attorney_reviewed` and record the reviewer, date,
and approved corpus digest in the release evidence. Any later fixture or
expectation change returns the corpus to `pending_attorney_review`.
