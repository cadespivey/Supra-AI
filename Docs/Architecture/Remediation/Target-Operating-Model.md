# Target Operating Model

Status: **architecture and authority boundaries approved; moderated workflow baseline pending**

This model freezes ownership, terminal records, handoff context, interruption behavior, and
authority boundaries before presentation labels and navigation order become test contracts.

## Product ownership

- Supra supports one main workspace window. The app uses one `Window`, exposes no New Window
  command, and owns one coherent route/matter/workspace session. Store and runtime remain shared
  services. A future multiwindow design requires a scene-scoped session and adversarial two-window
  proof before it can ship.
- **AI Setup** owns install/select/verify for Local Assistant and Document Search. First-run
  onboarding renders those requirements; it does not create a second setup state machine.
- **Settings** owns durable preferences, provider connections, and backup policy.
- **System Status** is read-only health plus corrective links and owner-operated recovery.
  Technical IDs, paths, raw probes, and schemas are behind an explicit Advanced disclosure.
- **About / Update** remains separate from Settings and status.
- **Saved Work** is the presentation name for durable structured work products and versions.
  Notes & Time/Billing remain a separately owned matter workflow until measured attorney tasks
  support consolidation.

## Canonical typed handoff

Cross-surface actions pass a compact `WorkContext`, never global notification prose or repeated
manual entry. The context carries only applicable nonoptional identities:

```text
matterID
intent (groundedQuestion | research | draft | checkSources | addPublicRecord | savedWork | billing)
sourceScopeID/sourceSetVersionID
authorityPacketVersionID
workProductID/versionID
returnDestination
checkpointID
```

Consumers reject a missing, stale, cross-matter, or incompatible identity. There is no implicit
“current matter” fallback. Handoffs retain the exact context across navigation and relaunch, or
surface an explicit corrective/expired state with a working return action.

## Shared model-work controls

All feature-owned tasks share one process-wide physical GPU admission lane. At most one
GPU-backed operation is active across generation, embedding, reranking, model load, and prewarm;
CPU, Store, and approved network work may overlap. A feature contract may perform a fixed bounded
sequence of retrieval, sequential model calls, validation, and publication, but it does not own a
private lane or expose agents, roles, teams, handoffs, recursion, or concurrent generative workers.

Every model task declares a hard budget for sequential model calls, typed tool calls,
input/generated tokens, wall time, retries, repeated actions, egress bytes, working-set bytes,
cancellation deadline, and terminal failure class. Tool intentions declare `readLocal`,
`writeLocal`, `exportLocal`, `externalRead`, `externalWrite`, `credentialUse`, or `destructive`
before invocation. Advanced mode changes depth/visibility, not authority.

Generated facts cannot become durable matter truth without exact source binding or an explicit
owner-approved state transition. Tool success is followed by authoritative postcondition
verification; `unknown` is recovery-required, not completed.

## Canonical journeys

### 1. Matter setup → import → readiness

| Contract | Definition |
|---|---|
| Authoritative aggregate | Matter identity/parties/court plus document/import records, immutable selected revisions, index state, active model identities, and `DocumentReadinessReceipt`. |
| Entry points | New/Edit Matter; Documents → Add Documents; a typed requirement returned from a blocked task. |
| States | matter unresolved/ready; import selected/copying/extracting/indexing/failed/review-required; semantic not-ready/ready/stale. |
| Blocking/correction | Unresolved canonical court/party identity, missing Local Assistant/Document Search, failed/review-required source, incomplete active-model vectors. Open the exact matter, Documents, or AI Setup row. |
| Interruption/relaunch | Import ledger and durable target intent resume exact unfinished rows; completed rows are not repeated. Readiness recomputes from Store. |
| Terminal result | Ready matter/scope receipt bound to exact revisions, chunker/index, and active embedding artifact, or a disclosed blocker/exclusion denominator. |

### 2. Grounded question → inspect evidence → save/promote

| Contract | Definition |
|---|---|
| Authoritative aggregate | Pending/terminal chat answer aggregate; promotion creates an exact structured work-product version that reuses the source set. |
| Entry points | Matter Chat; Ask the Documents; typed source-scoped handoff. |
| States | editing/blocked/retrieving/packing/generating/verifying/needs-check/completed; promotion prepared/verified/recovery-required. |
| Blocking/correction | Missing readiness, source overflow, unsupported citation, stale source. Open exact source/readiness detail or repack; never silently fall back to ungrounded text. |
| Interruption/relaunch | Pending aggregate is idempotent by exact request identity. No partial answer publishes. A saved terminal message/version restores exact evidence selection. |
| Terminal result | Verified answer with immutable source/provenance/assurance, or an explicit refusal/blocker. Optional Save to Saved Work is atomic. |

### 3. Research → egress approval → review/accept authority → use

| Contract | Definition |
|---|---|
| Authoritative aggregate | Research query/result plus provider-bound egress evidence and immutable accepted authority-packet version. |
| Entry points | Matter Research; a typed authority need from Chat/drafting/source checking. |
| States | planning/classified/approval-required/executing/result-pending/reviewed/accepted/rejected/stale. |
| Blocking/correction | Matter-derived/unknown query requires exact preview approval; missing provider connection opens exact Settings row; unreviewed authority cannot support authority-asserting work. |
| Interruption/relaunch | Planned queries remain local. A single-use grant cannot replay. Exact executed result/review state restores from Store. |
| Terminal result | Immutable accepted packet binding exact provider, query/result, authority identities, reviewed excerpts/propositions, and provenance; or explicit no-use/rejected state. |

### 4. Draft → edit → source/citation check → version → export

| Contract | Definition |
|---|---|
| Authoritative aggregate | Structured work product and immutable active version plus matter snapshot, source set, accepted authority packet, task policy, verification ledger, publication intent, and installed-file receipt. |
| Entry points | Matter Draft; Saved Work → New Version; a typed draft handoff. |
| States | unsupported/blocked/editing/preparing/verifying/needs-check/versioned/export-prepared/exported/recovery-required. |
| Blocking/correction | Unsupported type is not interactive. Missing canonical identity/source/authority opens the exact corrective surface. Filing/applicability judgment is never claimed. |
| Interruption/relaunch | Draft input/checkpoint is preserved. Publication reconciliation authenticates exact installed bytes or preserves uncertain files for recovery. |
| Terminal result | Immutable verified version; optional unique create-only artifact bound to its exact digest and source/authority lineage. |

### 5. Check citations/sources on existing work

| Contract | Definition |
|---|---|
| Authoritative aggregate | New verification-dimension ledger/check result bound to one immutable version and exact current source/authority snapshot. |
| Entry points | Saved Work detail; citation/source status action; typed return from a blocker. |
| States | current/stale/checking/supported/needs-check/blocked. |
| Blocking/correction | Deleted/changed source, unresolved citation, altered authority packet, or absent readiness names the exact affected item and action. |
| Interruption/relaunch | Existing version remains immutable; incomplete check cannot improve assurance. Relaunch resumes or restarts explicitly against the same snapshot. |
| Terminal result | New verified version or exact check receipt; no silent retargeting of the old version. |

### 6. Source/model change → stale → relaunch/recovery → recheck

| Contract | Definition |
|---|---|
| Authoritative aggregate | Dependency identities on each work-product version plus Store-derived staleness and readiness receipts. |
| Entry points | Document edit/delete/reprocess; model/chunker switch; Saved Work status. |
| States | current/stale/reindexing/not-ready/ready/recheck-required/verified. |
| Blocking/correction | Exact changed dependency and affected versions are listed. Open Documents, AI Setup, or Check Sources with preserved context. |
| Interruption/relaunch | Immutable prior content/citations remain viewable with stale status; rebuilding never rewrites history. |
| Terminal result | Fresh readiness plus a newly verified version, or an honest permanent blocker. |

### 7. Public Records → Add to Matter → readiness/research

| Contract | Definition |
|---|---|
| Authoritative aggregate | Provider result identity; explicit Add to Matter creates an import/document identity and then the ordinary readiness aggregate. |
| Entry points | Public Records; typed legal-data search handoff. |
| States | idle/planning/approval-required/executing/result/adding/importing/not-ready/ready. |
| Blocking/correction | Idle examples make zero calls. Egress policy and provider connection apply. Results never become durable matter sources without Add to Matter. |
| Interruption/relaunch | Search/result and import have separate exact identities; Add to Matter is idempotent or visibly recoverable. |
| Terminal result | Provider result remains external research evidence, or a deliberately imported matter document reaches ordinary readiness. |

### 8. Saved Work → Notes & Time/Billing

| Contract | Definition |
|---|---|
| Authoritative aggregate | Saved work-product/version remains immutable; Notes & Time/Billing owns its own entry/draft/profile records and explicit optional link back to matter/work identity. |
| Entry points | Saved Work detail; Notes & Time; Billing. |
| States | work current/stale; time entry draft/saved; billing draft/validated/exported. |
| Blocking/correction | Missing billing profile or client/matter IDs opens the exact Settings/matter row. Legal work content is not copied into narrative without an explicit user action. |
| Interruption/relaunch | Entry/draft and exact optional link restore independently; no repeated matter identity entry when already known. |
| Terminal result | Saved note/time entry or billing draft/export with its own audit; it does not change legal assurance of the linked work product. |

## Walkthrough gate

Before presentation-order tests freeze, synthetic owner-run tasks at 880, 1100, and wide widths
record completion, wrong turns, surface switches, repeated entry, context loss, time to first
grounded result, blocker recovery, source-status comprehension, and confidence calibration.
Zero silent fallback/context loss and one working next action for every blocker are hard gates.
The initial moderated measurements and owner approval remain pending; this document freezes the
invariants and handoff/ownership contracts, not unmeasured navigation hypotheses.
