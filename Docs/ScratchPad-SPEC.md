# Supra AI — ScratchPad Specification (Milestone 4 plan)
## Daily Notes → Defensible, E-Billable Time Entries

Last calibrated: June 22, 2026

This file is the self-contained ScratchPad spec and the **drift anchor** for the build.
Implementers should not rely on prior chat context. Every locked decision below was
explicitly confirmed by the product owner; changing any of them requires editing this
file first (with rationale), so drift is a visible, deliberate act rather than an accident.

---

## 0. Purpose

ScratchPad is a new top-level app section (a peer of Global Chats / Matters / Models /
Settings): a single, cross-matter **daily note** the attorney keeps as a running,
stream-of-consciousness log. On demand, a local model turns a day's notes — plus dropped
files (work product, emails, filings) used as evidence — into a reviewable, editable table
of billing entries (Client · Matter · Narrative · Time, with UTBMS codes), which the
attorney approves and exports to LEDES 1998B, CSV, or the clipboard.

The core user outcome:

```text
Over a workday the attorney jots quick notes, @-tags matters, #-tags issues, and drops in
work product / emails / filings. At day's end one action produces a defensible draft set of
billing entries — each line's time justified by cited evidence, the whole day reconciled
(total, gaps, overlaps, low-confidence flags) — that the attorney reviews, edits, and
exports. Nothing is ever billed automatically. Everything runs on-device.
```

This is not a practice-management system, an invoicing/AR system, or a time-clock. It is a
notes-to-billing-draft bridge that feeds the firm's existing billing system via LEDES/CSV.

### 0.1 Locked decisions

| # | Decision | Locked answer |
|---|----------|---------------|
| 1 | Tagging / matter association | `@matter` (resolves a real `MatterRecord` → client + LEDES IDs) **and** `#tag` (free/app-maintained issue or task label). Untagged prose is matter-inferred from context; tags are strong hints, not requirements. |
| 2 | Time capture | Hybrid: free-form prose, each entry silently timestamped. Auto-timestamp is a Settings toggle, **on by default**; when off, the engine degrades to written cues + task-type defaults and ignores stamp gaps as evidence. |
| 3 | Generation flow | On-demand "Generate billing draft" → editable Client·Matter·Narrative·Time table; re-generable, human-approved, nothing auto-billed. Day-level **file attachments** feed the model as time + narrative evidence. |
| 4 | Attachments | Auto-classify + local text-extract as evidence (reuse the 1.3.2 `DocumentClassificationService` + `ExtractionService`); auto-assignment is correctable. `.msg` is unsupported by the extractor → surface "export as .eml". |
| 5 | Time engine | User-set **sensitivity slider** (precise ↔ generous; high may infer implied workflow, e.g. research before substantive drafting). Guardrails ride at every setting: cite evidence per duration, reconcile the day, exclude apparent non-billable gaps, never fabricate time without a basis. |
| 6 | Instructions | **Global** billing instructions (Settings) + **per-matter overrides** (free text **plus** uploaded client billing-guideline documents, whose extracted text is composed into that matter's controlling rules — verbatim budgeted excerpts as built in 1.5.0; see §5.3 note). |
| 7 | Export | **LEDES 1998B + CSV + clipboard** (fee lines only). Makes UTBMS task/activity codes, timekeeper, rate, units, client ID, matter ID first-class on the entry model. |

### 0.2 §L defaults (locked)

```text
a. Generation model: reuse the existing drafting/critique-class local MLX model with a
   deterministic low-temperature preset. No new model is added.
b. UTBMS auto-coding: the model proposes task/activity codes; always editable; a Settings
   toggle can disable auto-proposal (blank for manual entry).
c. Attachment storage: imported into the matter's real document library (MatterDocumentRecord),
   NOT a ScratchPad-only silo, so files are reusable elsewhere.
d. Lock semantics: a day lock is per-day and reversible (reopen with a confirm), not permanent.
```

### 0.3 Non-goals (v1, by design — named so they do not silently creep)

```text
- .msg parsing (the extractor does not support it; guide the user to export as .eml)
- expense (E) lines / LEDES 1998BI / LEDES XML 2.x  (fee lines, 1998B only)
- multi-timekeeper / per-date rate variation  (single configured timekeeper profile)
- de-duplication against an existing time ledger (the app has no prior-time store yet)
- direct push into practice-management APIs (clipboard/CSV/LEDES bridge that gap)
- cloud sync, remote extraction, remote model calls, telemetry (consistent with M1–M3)
```

---

## 1. Architecture

Follows the established package split (views in the app target; logic in SupraSessions;
storage in SupraStore; contracts/templates in SupraResearch; pure types in SupraCore).

```text
SupraCore         new pure types: BillingLineItem, TimeEvidence, TimekeeperProfile,
                  BillingSensitivity, UTBMS code tables, LEDES field enum. New IDs.
SupraStore        new records + migrations + repositories (ScratchPadRepository, BillingRepository);
                  LEDES fields added to the matters table.
SupraDocuments    reuse ExtractionService / DocumentClassificationService / DocumentChunker as-is.
SupraSessions     ScratchPadController (@MainActor ObservableObject), BillingDraftService
                  (the decomposed engine), ScratchPadAttachmentService, TagResolutionService,
                  LEDESExporter / CSVExporter.
SupraResearch     billing prompt templates + the JSON billing schema/contract.
Apps/SupraAI      ScratchPad/ views (editor + day nav, review table, NSTextView editor),
                  Settings section, per-matter "Billing" tab. Wire into AppEnvironment + AppRoute.
SupraDesignSystem new reusable UI primitives (see §10) consumed by ScratchPad.
```

Key boundary call: **billing entries are tabular structured data, not a prose memo.**
`BillingDraftService` therefore reuses the runtime, `PromptBudget`, prompt composition, and
the guard/repair *patterns*, but emits **validated JSON line items** (the proven approach in
`DocumentClassificationService` — `extractJSONObject` + decode + best-effort repair), rather
than the markdown-heading `StructuredOutputType` contract used for memos/chronologies.

---

## 2. Data model

New GRDB records (all `Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable`;
snake_case columns via `CodingKeys`; `created_at/updated_at`; soft-delete via `deleted_at`
where applicable). Register migrations after the newest existing migration — M3 used
v022–v037 and matter enrichment added ~v038; **confirm the highest applied `vNNN` at
implementation time and append after it.** Update the DEBUG `deleteAllTables(_:)` drop order.

```text
scratch_pad_days        id, day (YYYY-MM-DD, unique), locked_at, timestamps. One per date.
scratch_pad_entries     id, day_id (FK cascade), seq, text, created_at (silent stamp),
                        edited_at, mentions_json (@matter→matterID list), tags_json (#tags).
scratch_pad_attachments id, day_id (FK), matter_document_id (FK MatterDocumentRecord), matter_id,
                        evidence_kind (email|work_product|filing|other),
                        evidence_signals_json (page/word counts, email headers/dates, file-stamp,
                        classifier output), created_at.
billing_drafts          id, day_id (FK), version, model_id, sensitivity, status
                        (draft|reviewed|exported), reconciliation_json (total, gaps, overlaps,
                        flags, non-billable excluded), created_at. Versioned — re-generation
                        never destroys a prior draft.
billing_line_items      id, draft_id (FK), seq (stable line id), client_id, matter_id, narrative,
                        hours, work_date, utbms_task_code, utbms_activity_code, timekeeper_id, rate,
                        confidence (high|medium|low), evidence_json, code_note, user_edited (bool —
                        the drift-preservation flag), source_entry_ids_json.
matter_billing_profiles id, matter_id (FK, unique), override_instructions (free text),
                        billing_code_set (litigation|transactional|advisory|none — drives UTBMS
                        applicability), and links to guideline docs stored as MatterDocumentRecords
                        tagged "billing guideline".
```

Additions to the `matters` table (LEDES): `client_id` (LEDES `CLIENT_ID`), `client_matter_id`
(LEDES `CLIENT_MATTER_ID`). `internalMatterID` already exists → `LAW_FIRM_MATTER_ID`;
`clientNames` already exists for display. There is no separate Client entity; client is
denormalized on the matter.

The firm `LAW_FIRM_ID` and the `TimekeeperProfile` (`TIMEKEEPER_ID` / `NAME` /
`CLASSIFICATION` + default `rate`) live in Settings (DB-backed via `AppSettingsRepository`).

---

## 3. Editor & tagging engine

The only piece with no existing infrastructure (the app today has plain `TextField`/`TextEditor`
only — no rich text, no mention autocomplete).

```text
- ScratchPadEditor: an NSViewRepresentable wrapping NSTextView with a completion popover.
- '@' triggers TagResolutionService.matters(prefix:) (backed by MattersRepository.fetchMatters());
  selection inserts a styled token bound to a matterID.
- '#' triggers the tag registry (distinct #tags across days + any app-maintained list); free entry
  creates the tag.
- Typing '@newname' with no match offers an inline "Create matter '…'" (writes a MatterRecord) so
  the pad never dead-ends.
- Underlying store stays plain text + mentions_json/tags_json per entry (diff-able, exportable).
- Auto-timestamp: each entry boundary stamps created_at; edits update edited_at. Subtle inline time
  gutter, controlled by the Settings toggle. When off, stamps are still recorded but flagged
  "not evidence" so the engine ignores gaps.
- Risk mitigation: an MVP fallback (plain TextEditor + an "Insert @/#" menu + manual newline
  stamping) is acceptable for an early Phase-2 cut; the comprehensive target is the custom editor.
```

---

## 4. Attachments & evidence

Drop a file on the day (or an entry) → `ScratchPadAttachmentService`:

```text
1. ExtractionService.extract(fileURL:) — local; pdf/docx/rtf/html/xml/xlsx/images-OCR/eml. .msg
   is unsupported by the extractor: surface the existing "export as .eml" guidance, do not crash.
2. DocumentClassificationService.classifyDocument → DocumentClassification (primaryTag,
   isCourtFiledLikely, detectedDocumentDate, detectedPartiesOrEntities, …), mapped to evidence_kind.
3. Matter resolution: classifier-detected parties + the day's @-mentions → suggested matter,
   attorney-correctable.
4. Evidence signals for the time engine: page/word counts (drafting effort), email headers + sent/
   received timestamps (communication time), filing file-stamp date (review time) → evidence_signals_json.
5. The file is imported as a real MatterDocumentRecord (existing import path) so it lives in the
   matter's library too — no separate silo (§0.2c).
```

---

## 5. Billing-generation engine — `BillingDraftService` (decomposed)

The single most important fidelity decision: **the model never does the whole job in one shot,
and never does arithmetic.** The work is decomposed into narrow, constrained, individually
verifiable calls; all numeric work is deterministic code.

### 5.1 Decomposed pipeline (per day)

```text
a. Segment       — split the day into discrete work events. Mostly deterministic (split on
                   entries/timestamps); the model only merges/splits ambiguous spans.
b. Resolve matter— per segment, constrained classification over the day's known matters, with
                   @-tags as strong priors. Tagged segments resolve by lookup (≈100%).
c. Draft narrative— per segment, a focused rewrite into a past-tense billing narrative that obeys
                   the merged instruction stack. (Small models do this reliably.)
d. Pick UTBMS code— per segment, a constrained pick from a PROVIDED shortlist filtered by the
                   matter's billing_code_set (litigation L-codes vs transactional/advisory set vs
                   none). Open generation becomes multiple-choice.
e. Bill / adjust — per segment, decide bill vs non-billable and any write-down, given the timestamp
                   gap and attachment signals supplied AS PRE-COMPUTED NUMBERS. The model decides
                   judgment, not arithmetic.
```

Each call is small, cacheable, retryable, and independently checkable.

### 5.2 Determinism (code, never the model)

```text
- Totals, units × rate, day reconciliation (gaps/overlaps/totals), rounding to the increment, and
  LEDES field assembly are deterministic post-processing. Whole classes of error (e.g. a wrong day
  total, a malformed LEDES row) cannot originate in the model.
```

### 5.3 Instruction stack & prompt

```text
- Instruction stack = global billing instructions ⊕ per-matter override text ⊕ client guideline
  doc excerpts (for matters appearing that day), composed by BillingInstructions.composedStack.
- Budgeted with PromptBudget.promptTokenBudget; honor GenerationStreamCollector refusals
  (contextOverflowed / truncatedReasoning).
- Deterministic low-temp preset (à la .legalVerify / .legalCritique).
```

> **Implementation note (1.5.0 — drift-control §14).** Guideline docs reach the prompt as
> **verbatim, budgeted excerpts** of their extracted text (`BillingInstructions.guidelineCharBudget`,
> truncated at a whitespace boundary with a `…` marker), **not** a model-generated summary. Rationale:
> (a) the composition stays fully deterministic, so the golden-fixture fidelity gate (§6.1, §12) holds;
> (b) verbatim client rules avoid summarization loss/hallucination in a billing-compliance context.
> Model summarization with a cached per-matter rule digest remains a possible future enhancement (it
> would need its own fidelity gate). This does not weaken the guarantee that the matter's controlling
> guideline rules reach the draft prompt.

### 5.4 Constrained decoding & repair

```text
- JSON-extract + per-field validation with retry: UTBMS code must be in the provided enum or it is
  rejected and re-asked; hours must be a 0.1 multiple bounded by the segment's timestamp gap; matter
  must be one of the day's matters or null. Use grammar-constrained sampling where MLX supports it.
- A repair pass (the commitOnlyIfImproved discipline) fixes malformed/missing fields without
  discarding good rows.
```

### 5.5 Sensitivity & guardrails

```text
- The sensitivity slider sets how freely the model fills inferred time and how readily it abstains.
  Low: explicit/strong-evidence time only. High: may infer implied workflow (research before drafting,
  review before a conference) and estimate from gaps + attachment evidence.
- Guardrails at every setting: cite the evidence per duration; never fabricate without a basis;
  exclude apparent non-billable gaps; prefer abstention (leave blank + flag low-confidence) over a
  guess. Rounding increment default 0.1h, overridable by the instructions.
```

---

## 6. Fidelity strategy & acceptance bar

The exemplar quality must be *typical, not aspirational*. The path is: take the hard/whole task
away from the model (§5), verify deterministically, repair only what is flagged, learn from the
attorney's own approved work, and measure against golden fixtures.

```text
- Built-in verification (the in-app analog of an adversarial review): cheap deterministic validators
  (arithmetic, code-in-enum, past-tense, one-task-per-line, narrative length) catch most issues for
  free; only flagged lines get a model repair pass.
- Calibrated confidence + abstention tied to concrete signals (explicit written time = high; gap +
  attachment = medium; bare gap = low/flag). The sensitivity slider sets the abstention threshold.
- Learning loop (approved): few-shot anchored on verified exemplars AND, over time, the attorney's
  OWN past approved narratives for similar work, retrieved as the style/coding anchor — so fidelity
  improves with use and converges on the firm's voice and coding habits.
- Stronger model for the reasoning-heavy steps: the narrative/coding steps may route to the
  higher-precision (6/8-bit) role variants; mechanical steps may use a cheaper model.
```

### 6.1 Phase-4 fidelity gate (run against the REAL local model, not Opus)

```text
- Matter accuracy            ≥ 95%   (tagged ≈100%; the bar governs untagged inference)
- Narrative subject matter   ≥ 95%   (topic correctness)
- Full narrative wording     flexible — scored and reported, NOT a hard gate
- Time                       near-perfect:
                               * 0 arithmetic errors (by construction — code does the math)
                               * explicit written times reproduced exactly (100%)
                               * inferred durations within ±0.1h of expected on the golden set
                               * every inferred/adjusted time flagged + attorney-confirmed before export
- JSON validity              ≥ 95% first pass (repair recovers the remainder)
```

Phase 4 does not pass until the real local model clears these against the golden-fixture corpus.

---

## 7. Review table UI — `BillingDraftView`

```text
- Editable grid: Client · Matter · Narrative · Time · Task · Activity · Confidence, grouped by matter
  with per-matter subtotals and a day footer (reconciliation banner: total, gaps, overlaps, flags).
- Row ops via a per-line menu: edit, merge (combine entries, sum time), split, delete, set/override
  UTBMS code (picker over the SupraCore UTBMS tables). A dashed "set code" chip marks transactional/
  advisory lines whose firm code set must be supplied before LEDES export.
- Re-generation preserves manual edits: each line carries a stable key (source_entry_ids + matter);
  on re-run, user_edited rows are retained and the model fills only the rest.
- Lock/finalize: a day can be locked after export (locked_at); locked days are read-only unless
  explicitly reopened (§0.2d).
- "Nothing billed automatically" is always visible.
```

---

## 8. Export — `LEDESExporter` / `CSVExporter`

LEDES 1998B layout: line 1 `LEDES1998B[]`; line 2 the 24-field header terminated with `[]`; then one
`[]`-terminated record per fee line, grouped into one invoice per client-matter (distinct
`INVOICE_NUMBER`; `LINE_ITEM_NUMBER` restarts per invoice; `INVOICE_TOTAL` = sum of that invoice's
line totals). The 24 fields, in order:

```text
INVOICE_DATE | INVOICE_NUMBER | CLIENT_ID | LAW_FIRM_MATTER_ID | INVOICE_TOTAL | BILLING_START_DATE |
BILLING_END_DATE | INVOICE_DESCRIPTION | LINE_ITEM_NUMBER | EXP/FEE/INV_ADJ_TYPE |
LINE_ITEM_NUMBER_OF_UNITS | LINE_ITEM_ADJUSTMENT_AMOUNT | LINE_ITEM_TOTAL | LINE_ITEM_DATE |
LINE_ITEM_TASK_CODE | LINE_ITEM_EXPENSE_CODE | LINE_ITEM_ACTIVITY_CODE | TIMEKEEPER_ID |
LINE_ITEM_DESCRIPTION | LAW_FIRM_ID | LINE_ITEM_UNIT_COST | TIMEKEEPER_NAME |
TIMEKEEPER_CLASSIFICATION | CLIENT_MATTER_ID
```

```text
Mapping: dates YYYYMMDD; EXP/FEE/INV_ADJ_TYPE="F"; UNITS=hours; UNIT_COST=rate; TOTAL=units×rate;
ADJUSTMENT_AMOUNT=0.00; EXPENSE_CODE blank for fees; TASK_CODE blank where the matter's code set has
none; ACTIVITY_CODE = UTBMS A1xx; TIMEKEEPER_* + LAW_FIRM_ID from Settings; CLIENT_ID / CLIENT_MATTER_ID
/ LAW_FIRM_MATTER_ID from the matter.
- CSV: human-friendly Date,Client,Matter,Timekeeper,Task Code,Activity Code,Narrative,Hours,Rate,Amount
  (+ total row).
- Clipboard: tab-separated, paste-into-practice-management formatted.
- A pre-export validator blocks LEDES export on missing required fields (timekeeper rate, client ID,
  unresolved transactional task code) with a clear message.
```

---

## 9. Settings & instructions

```text
- New "ScratchPad / Billing" Settings section (DB-backed via SettingsController didSet→persist,
  stored under scratchpad.* keys): global billing instructions; auto-timestamp toggle (default on);
  time-sensitivity slider; rounding increment (default 0.1h); UTBMS auto-coding toggle; timekeeper
  profile (ID/name/classification/default rate) + firm LAW_FIRM_ID.
- Per-matter "Billing" tab in the matter workspace: override text + upload client guideline docs +
  billing_code_set selection. Merged on top of global at generation time.
```

---

## 10. Design-system componentization charter

The new UI primitives are built **inside `SupraDesignSystem`** (clean reusable APIs), not inline in
ScratchPad views, so they are battle-tested in a real feature first:

```text
ConfidencePill, UTBMSCodeChip (+ dashed "set code" variant), MetricRow / StatCard,
ReconciliationBanner (extending the existing SupraWarningBanner), GroupedReviewTable (with subtotals),
SegmentedControl, RowActionMenu (per-row kebab).
```

App-wide **adoption** of these across Authorities / Outputs / Matters / Research / Settings is a
**separate, downstream initiative** (its own plan), sequenced after the components stabilize
(~Phase 5), with per-screen audit gates and visual regression. It is deliberately NOT folded into
ScratchPad: ScratchPad is additive (new section, new tables), whereas a UI rollout modifies every
existing screen — a different risk profile that must not enlarge this feature's blast radius.

---

## 11. Security / privacy / auditability

```text
- Fully on-device. Extraction, classification, and all generation run locally via MLX. No notes or
  attachment content ever leave the machine. Zero network egress in any ScratchPad path (asserted in
  the Phase-8 audit).
- Privilege/confidentiality awareness: the classifier's isPrivilegedLikely / isConfidentialLikely
  flags surface on attachments; this changes nothing about the on-device guarantee.
- Auditability: every suggested time cites its evidence; drafts are versioned; a locked day exports
  reproducibly. Audit major actions only (draft generated/exported, day locked/reopened), consistent
  with the M3 audit philosophy.
```

---

## 12. Validation suite & fidelity gate

```text
- Deterministic layer (SwiftPM): data round-trips & migration; tag resolution; attachment
  extract/classify/associate (incl. .msg graceful rejection); LEDES byte-level golden file;
  reconciliation math; edit-preservation on re-generation; export validators.
- Golden-fixture layer (run against the loaded local chat model): representative days → expected
  line items, scored against the §6.1 bar (matter accuracy, narrative subject, time tolerance, JSON
  validity). This is what turns "typical, not aspirational" into a measured number.
- Fixtures contain no real client data; deterministic text; known matters/dates/amounts; at least one
  transactional (blank-task-code) matter and one untagged-inferred segment.
```

---

## 13. Phased plan & audit gates

Each phase ends with an **audit gate**: run the phase's tests, re-read this spec and confirm no
locked decision was violated or quietly re-scoped, and a written checkpoint for sign-off before the
next phase begins. Toolchain: `DEVELOPER_DIR=/Applications/Xcode-beta.app/...`; package tests via
`swift test --package-path`; app via the xcodebuild workspace command.

```text
Phase 0 — Spec lock & scaffolding. This file committed; .scratchpad added to AppRoute + routeView
          behind a feature flag; empty ScratchPadController + AppEnvironment wiring; stub packages.
          GATE: builds + launches; empty section appears; spec signed off.
Phase 1 — Data layer. All records + migration + LEDES matter fields + repositories; register in
          SupraStore; DEBUG drop order. GATE: migration applies on a populated DB; CRUD/cascade/
          soft-delete round-trip tests green; no change to existing migrations.
Phase 2 — Editor & tagging. ScratchPadEditor (NSTextView + @/# popover) or MVP fallback;
          TagResolutionService; entry persistence + auto-timestamp; inline "create matter"; day nav.
          GATE: @ resolves real matters & binds matterID; # creates/reuses tags; entries persist/reload;
          toggle honored. Checkpoint: editor UX.
Phase 3 — Attachments & evidence. ScratchPadAttachmentService (extract→classify→resolve→signals);
          import as MatterDocumentRecord; attachment tray. GATE: docx/pdf/eml end-to-end; .msg guidance;
          evidence signals populated. 
Phase 4 — Billing engine. Decomposed pipeline; deterministic math/reconciliation; constrained decode +
          repair; instruction-stack merge; UTBMS tables. GATE: golden-fixture FIDELITY BAR (§6.1) met
          against the real local model; guardrail tests (no fabricated time at low sensitivity;
          implied-workflow at high). Checkpoint: sample outputs.
Phase 5 — Review table. BillingDraftView: editable grid, merge/split/delete, code picker, flags banner,
          regenerate-preserves-edits, lock/finalize. GATE: edit round-trip; re-gen keeps user_edited rows;
          lock/reopen; reconciliation renders. New primitives land in SupraDesignSystem (§10).
Phase 6 — Export. LEDESExporter (24-field 1998B), CSVExporter, clipboard; pre-export validator;
          timekeeper/firm Settings. GATE: LEDES byte-level golden; CSV correctness; validator blocks on
          missing fields.
Phase 7 — Settings & instructions. Global instructions; toggles; sensitivity; rounding; timekeeper;
          per-matter Billing tab (override text + guideline upload + code set). GATE: persistence;
          per-matter override + guideline reach the prompt (assert merged stack).
Phase 8 — Integration, security & release. End-to-end (type→attach→generate→edit→export→lock); remove
          flag; CHANGELOG/version bump; notarized release. GATE: full e2e; SECURITY audit (zero network
          egress, content stays local, privilege flags surface); full test suite green; Release/
          hardened-runtime build; final spec-conformance review.
```

---

## 14. Drift control

```text
- This spec is the contract. Each phase's audit gate re-checks against it. Any deviation edits this
  file first, with rationale, before code changes.
- The §0.3 non-goals are the scope fence; re-opening one is a deliberate spec edit, not a quiet add.
- The data-side drift guard is billing_line_items.user_edited (manual edits survive re-generation);
  the quality-side drift guard is the §6.1 golden-fixture gate (fidelity is a number, not a vibe).
```
