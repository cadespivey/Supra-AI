# Protected CI policy

Protected CI should answer one question: is this exact commit safe to merge and eligible to
become a release candidate? It is not a sequence of independent review ceremonies.

## One required result

Branch protection should require one stable aggregate context, `Protected macOS CI`, for the
exact commit. The workflow may fan out internally, but change selection and aggregation belong
inside the workflow rather than in a long ruleset of per-package and smoke-test contexts.

Every change runs an Ubuntu changed-file safety check for whitespace errors, newly introduced
secrets, and prohibited artifact paths. The workflow then selects work from changed paths and
dependency impact:

- affected Swift packages and their dependents, sequentially on one macOS runner;
- one app build when app composition changed;
- focused UI/XPC checks only when their surface changed;
- migration fixtures only for schema, migration, import, or persistence changes;
- full website checks only for website changes, with narrow XML/version validation for the
  two-file appcast publication commit; and
- benchmarks only for ingestion, indexing, retrieval, or performance-sensitive changes.

Claims, entitlements, and CI-policy meta-tests run only when their inputs change. Full-tree
secret, artifact, font, entitlement, claims, and protection sweeps run weekly for drift detection.

A broad full-package, Debug/Release, UI/XPC, migration, website, and benchmark sweep is reserved
for cross-cutting changes or an explicit diagnostic run. It is not the default for every PR.

## Reuse the receipt

A green aggregate result is bound to the commit SHA and records which lanes ran or were skipped
by policy. The same receipt may authorize merge and release preflight. Do not rerun unchanged
work merely because the commit moved from a branch to `main` or because release metadata is being
published. A new receipt is required only when the source SHA or relevant validation inputs
change.

Transient infrastructure failures may rerun only the failed lane. Product failures require a
fix and a new result. Scheduled security and benchmark workflows provide drift detection; they
do not block unrelated daily work. Pages owns the one full website build for an appcast
publication.

## Ruleset migration

The workflow now emits the single aggregate result and selects internal lanes by change impact.
The historical live ruleset required 21 individual contexts; update it to require only the
aggregate `Protected macOS CI` job. Until that GitHub setting changes, the old contexts can still
block merges even though the repository automation no longer treats them as independent gates.

Third-party Actions remain pinned to reviewed full SHAs. Release signing and notarization run
only in the protected release environment, never in pull-request CI.
