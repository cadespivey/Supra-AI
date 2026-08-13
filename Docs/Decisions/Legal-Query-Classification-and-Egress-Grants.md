# D-16 — Legal Query Classification and Provider-Bound Egress Grants

Status: **approved operating decision (2026-08-13); first containment slice implemented**

## Context

Local planning and retrieval may use matter-derived text. Legal-data providers are external.
A network allow-list identifies an origin but does not decide whether the exact query is safe or
authorized to leave the Mac.

## Decision

Every outbound legal query has one deterministic classification before transport:

| Classification | Automatic execution | Required authority |
|---|---|---|
| `publicCitation` | Allowed only when conclusively typed and the provider/origin/policy match | No per-query preview grant; ordinary network policy still applies. |
| `matterDerived` | Never | Exact displayed query, provider, origin, and purpose approved by the owner. |
| `unknown` | Never | Reclassify deterministically or obtain the same exact preview approval as matter-derived work. |

Classification uses typed provenance and deterministic inputs, not model prose. Ambiguity fails
closed to `unknown`.

An approval creates a single-use, short-lived `LegalQueryEgressGrant` bound to the exact provider,
origin, transmitted query bytes/digest, initiating matter/task, and expiry. Provider/origin/query
mismatch, replay, expiry, changed text, or wrong task produces zero transport. Provider tokens
remain in Keychain and are not part of the grant or audit payload.

Raw source, quick-attachment, prompt, or matter body text is never silently transformed into an
outbound query. If any such text is to be sent, the preview must show the exact transmitted bytes
and the owner must approve them.

Advanced mode, local model output, previously accepted authority, and a network allow-list do not
broaden egress authority.

## Transactional research packet

Executed query identity, grant evidence when required, provider result identity, review state,
accepted authority packet/version, exact excerpts, and provenance form the downstream research
aggregate. Packet versions are immutable. Altered use rejects; exact retry is idempotent.

## Consequences

- UI shows a provider-bound preview for matter-derived/unknown work before the first network byte.
- Idle examples and local query planning perform zero network calls.
- Logs use content-free or keyed identities unless the owner explicitly opts into raw local query
  logging; raw queries never enter external telemetry.

## Enforcement and gates

Owners: a single legal-egress policy boundary above `SupraNetworking`, with provider transport
remaining in `SupraNetworking` and normative research state in Store.

Required gates: `T-EGRESS-01...05`, `T-RESEARCH-PACKET-01/02`, and `T-NET-AUDIT-01`.
