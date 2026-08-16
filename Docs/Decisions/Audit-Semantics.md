# D-15 — Normative and Operational Audit Semantics

Status: **approved operating decision (2026-08-13); implementation gates pending**

## Context

Supra needs durable evidence for legally material state transitions, but it also records probes,
timings, and resource observations that may fail without changing the legal result. Treating both
classes alike either weakens the legal record or lets a diagnostic outage block ordinary work.

## Decision

Audit evidence is divided by effect, not by logger or screen.

### Normative evidence

Normative evidence is part of the authoritative Store transaction when it proves or changes:

- legal artifact state or active immutable version;
- exact matter, source-set, source revision, authority, accepted packet, or citation identity;
- owner authorization or provider-bound egress grant;
- destructive action, review/acceptance decision, identity correction, restoration, or
  publication intent/completion;
- exact installed artifact identity and digest;
- assurance/staleness state whose value controls reliance or export.

If a required normative row cannot commit, the state transition fails. A later best-effort log
cannot reconstruct or authorize it.

### Operational evidence

Operational evidence includes timings, queue and resource measurements, health probes,
performance counters, content-minimized retrieval receipts, cache outcomes, and developer
diagnostics. It is bounded, redacted, rotating where appropriate, and best-effort. Failure to
write it never changes a legal terminal aggregate.

Operational evidence cannot establish readiness, provenance, source support, authority,
authorization, egress permission, publication, or review state. Advanced Diagnostics changes
visibility only; it does not change authority or semantic weight.

### Failure boundaries

- A pre-send audit/policy failure for an external request produces zero transport.
- The external-response policy must name whether the legal-data result and normative response
  evidence commit together or the result remains unavailable; it may not silently downgrade to
  an operational log.
- Diagnostics and support reports exclude raw query/source/prompt/answer/credential/client-file
  canaries by default.

## Consequences

`SupraNetworking` should expose content-free request evidence to a Store-owned or injected audit
capability rather than depending broadly on Store. Feature repositories own normative legal
transitions. `SupraDiagnostics` owns operational receipt presentation and redacted export.

## Enforcement and gates

Required gates: `T-OUTCOME-01`, `T-RAG-TRACE-01/02`, `T-NET-AUDIT-01`,
`T-RESEARCH-PACKET-01`, `T-ART-03`, and `T-TOOL-AUTH-01`.
