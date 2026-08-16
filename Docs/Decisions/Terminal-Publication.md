# D-14 — Terminal Publication Aggregates

Status: **approved operating decision (2026-08-13); implementation gates pending**

## Context

Several workflows currently treat a successful service call, a generated string, or an
installed file as completion even when the authoritative Store graph, exact source identity,
or installed bytes have not been committed and read back together. That can expose a terminal
success while a legally material part of the result is partial or unverifiable.

## Decision

“Completed” is a property of one authoritative aggregate, not a controller flag or a successful
tool return. The following aggregates are canonical:

| Result | Authoritative aggregate | Terminal success requires |
|---|---|---|
| Grounded chat answer | Message plus generation session, immutable source set/rows, verification dimensions, assurance, and exact retry identity | One Store transaction commits every member; read-back matches the requested matter, model/prompt lineage, source digest, and terminal content. |
| Structured work product | Structured output plus active immutable version, source set/rows, authority packet where required, verification dimensions, assurance, task policy, model/prompt lineage, and matter-identity snapshot | The repository atomically appends/activates the version and rejects any partial, stale, cross-matter, altered-retry, or authority-incomplete graph. |
| Research result used downstream | Executed query plus provider-bound egress grant, returned result identity, review disposition, accepted authority-packet version, excerpts, and provenance | Executed, reviewed, and accepted transitions are transactional and the downstream reference binds the exact immutable packet version. |
| Installed artifact | Store-owned prepared publication intent plus immutable work-product version, intended destination identity, installed file identity/digest/format, and completion audit | Install succeeds, authoritative bytes are read back and authenticated, then Store finalization commits the exact identity and digest. |

A postcondition is typed as `verified`, `failed`, or `unknown`. Only `verified` may complete a
mutating workflow. `unknown` is nonterminal and recovery-required. Exact retry is idempotent;
an altered retry is a new request and cannot inherit the prior terminal receipt.

Operational traces, UI toasts, controller state, file existence without authenticated identity,
and model/tool success are evidence inputs only. They cannot complete or repair a legal aggregate.

## Consequences

- UI success and navigation derive from the aggregate read-back; a caught mutation error cannot
  be followed by success presentation.
- Cancellation or failure before the aggregate commits produces no terminal partial result.
- Recovery preserves uncertain installed files and asks the owner to reconcile them; compensation
  cannot overwrite a third-party replacement.
- Exports bind an exact immutable version and create a new uniquely owned artifact for later
  versions instead of replacing by timestamp/name convention.
- Timing and diagnostic receipts remain best-effort and cannot change legal completion.

## Enforcement and gates

Owners: `SupraStore` repositories for atomic records and `SupraSessions` feature use cases for
policy/orchestration; file installation is owned by the durable publication boundary.

Required gates: `T-PUB-CHAT-01/02`, `T-PUB-WORK-01`, `T-RESEARCH-PACKET-01/02`,
`T-OUTCOME-01`, and `T-ART-01/02/03` in the architecture/UX test ledger.
