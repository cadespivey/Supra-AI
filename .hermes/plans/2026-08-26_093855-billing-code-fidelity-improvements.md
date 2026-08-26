---
title: Billing code fidelity improvements
created_at: 2026-08-26T09:38:55-04:00
updated_at: 2026-08-26T09:38:55-04:00
status: active
---

# Billing Code Fidelity Improvements

## Outcome

Improve automatic task/activity-code suggestions without rebuilding the successful billing-draft pipeline. A suggested code must be a canonical code and a reasonable interpretation of the work described in the generated narrative when read together with the user’s supporting note and/or uploaded document evidence. The attorney remains the final reviewer; the system should prefer a blank, reviewable suggestion over a forced answer when the evidence does not support a reasonable choice.

## Current state verified in the repository

- `BillingDraftService` performs one local-model generation for matter, narrative, time, source IDs, and codes, followed by deterministic parsing, evidence-scope validation, code normalization, arithmetic, reconciliation, and persistence.
- `BillingDraftPrompt` asks for L1xx/A1xx codes but does not give the model the canonical code catalog or titles.
- `UTBMSCodes` already owns the canonical litigation-task and universal-activity tables and rejects invalid codes.
- `BillingFidelityHarness` exercises the real `BillingDraftService` path but currently has one fixture and scores only matter/narrative/time.
- `BillingLineItemRecord` and `BillingLineView` already carry `codeNote`; no database migration is needed to show the basis for a suggestion.
- `BillingDraftView` exposes editable code pickers but currently shows code values without their titles or `codeNote` rationale.
- The prior signed-app probe established that the installed Qwen model clears the core JSON, source, matter, narrative, and time gates but does not select codes reliably when it lacks code definitions.

## Scope

### In scope

1. Make code quality measurable with a versioned synthetic corpus and a signed-app real-model probe.
2. Improve the existing single generation by supplying canonical code choices and explicit evidence-grounded selection rules.
3. Re-run the real-model benchmark and add a narrow coding pass only if the improved single call does not clear the agreed semantic gate.
4. Make suggested-code titles and rationale visible enough for efficient attorney review.
5. Update the billing specification to describe the measured architecture and gate actually implemented.

### Non-goals

- No full segmentation → matter → narrative → time decomposition.
- No new model, remote service, dependency, or network access.
- No requirement that every defensible billing judgment match one exact “golden” code.
- No autonomous approval or export of entries without attorney review.
- No database migration unless implementation uncovers an unanticipated persistence requirement; the existing code fields, confidence, and `codeNote` should suffice.
- No learning from real client entries in this change; fixtures remain synthetic.

## Working decisions

1. **Smallest-change first.** Improve the existing single-call prompt before adding another model call because all non-code fidelity dimensions already passed.
2. **Canonical source of truth.** Prompt catalogs are rendered from `UTBMSCodes`; do not duplicate a second hand-maintained list in prompt text or tests.
3. **Evidence-grounded semantics.** The coding instruction must tell the model to derive the narrative from source evidence and then choose codes that reasonably describe that work, considering:
   - the generated narrative;
   - the exact source notes identified by `sourceEntryIDs`;
   - relevant attachment excerpt/metadata supplied with those notes or matter;
   - the matter’s billing code set, override, and client-guideline excerpts.
4. **Reasonableness, not false precision.** Golden fixtures define sets of acceptable codes plus whether blank/abstention is acceptable. They do not require one exact code where multiple choices are defensible.
5. **Fail safely.** Invalid/out-of-set codes remain deterministically dropped. Ambiguous coding may remain blank with a useful `codeNote`; a coding failure must not discard an otherwise valid billing line.
6. **Attorney review remains consequential.** Suggested codes are visibly reviewable and editable. Existing LEDES validation remains the final deterministic export guard.
7. **No prompt-repair complexity unless measured.** Do not add grammar-constrained decoding, per-line retry loops, or a full repair pipeline unless the benchmark identifies a remaining material failure.

## Three-step framework

### Step 1 — Establish a durable measurement contract

Build the benchmark that distinguishes canonical validity, semantic reasonableness, and legitimate ambiguity.

### Step 2 — Constrain the existing generation

Give the current model call the canonical code definitions and require code selection to follow the generated task description plus source evidence. Preserve the single-call architecture if it passes.

### Step 3 — Escalate narrowly only if needed

If Step 2 does not clear the semantic gate, add one batch coding pass that receives the already-generated narratives and only their validated source evidence. Do not decompose matter, narrative, or time.

## Acceptance criteria

### Existing fidelity gates that must not regress

- First-pass strict JSON: at least 95% of calls.
- Service-parser acceptance: reported separately; expected at least 95%.
- Source attribution: 100% valid `sourceEntryIDs` within `BillingEvidenceScope`.
- Matter accuracy: at least 95% overall, with tagged cases expected to remain effectively perfect.
- Narrative subject accuracy: at least 95%.
- Explicit written time: 100% exact before deterministic rounding.
- Inferred time: within fixture tolerance and supported by stated evidence.
- Arithmetic/reconciliation: zero errors by deterministic construction.

### Code-quality gates

Evaluate task and activity codes separately.

- **Canonical validity:** 100% of nonblank persisted suggestions pass `UTBMSCodes` validation for the selected matter’s code set.
- **Semantic reasonableness:** at least 80% of eligible activity suggestions and at least 80% of eligible litigation-task suggestions fall within the fixture’s independently authored acceptable set.
- **Non-litigation behavior:** 100% of transactional/advisory task codes remain blank unless the fixture supplies an explicit firm/client code and instruction that makes a task code available.
- **Abstention:** blank is a pass only when the fixture explicitly permits ambiguity/abstention or when a documented human adjudication confirms that the evidence does not support a reasonable single choice. Blanket null output cannot pass the gate.
- **Reasonable alternatives:** a code outside the pre-authored acceptable set may be adjudicated as passing only when its title reasonably describes the generated narrative and source evidence; record the rationale and update the fixture’s acceptable set only if the fixture—not the implementation—was too narrow.
- **Reviewability:** every blank, dropped, or materially ambiguous automatic code carries a concise `codeNote` suitable for attorney review.

The 80% semantic bar reflects assistive drafting: the attorney reviews the entry, but suggestions should be useful more often than not and should not create systematic miscoding. Canonical validity and non-litigation blank behavior remain strict because those are deterministic safety properties rather than judgment calls.

## Implementation tasks

### 1. Create an isolated implementation branch/worktree

- Branch from current `main` using `feat/billing-code-fidelity` or a similarly scoped name.
- Do not build on the currently dirty `chore/repository-hygiene` worktree.
- Preserve the unrelated current changes/deletions in `.hermes/plans/` and `Docs/Drafting-Catalog-SPEC.md`; do not restore, stage, or modify them as part of this work.

### 2. Extend the fidelity data contract

**Primary files**

- `Packages/SupraSessions/Sources/SupraSessions/BillingFidelityHarness.swift`
- `Packages/SupraSessions/Tests/SupraSessionsTests/BillingFidelityHarnessTests.swift`

**Changes**

- Extend each expected line with:
  - `acceptableTaskCodes: Set<String>`;
  - `acceptableActivityCodes: Set<String>`;
  - `allowsBlankTaskCode` and `allowsBlankActivityCode`;
  - a short fixture-author rationale explaining the reasonable interpretation.
- Extend actual scored lines with task code, activity code, confidence, `codeNote`, and source entry IDs.
- Add separate counters/rates for:
  - strict JSON;
  - parser acceptance;
  - source attribution;
  - matter;
  - narrative subject;
  - explicit and inferred time;
  - canonical task/activity validity;
  - semantic task/activity reasonableness;
  - justified abstention.
- Ensure a valid-but-wrong code fails semantic scoring even though it passes canonical validation.
- Match expected and actual lines by validated source IDs/matter plus narrative subject, not by array position alone.
- Emit per-line explanations so a failed code can be reviewed against the narrative and source evidence rather than appearing only as a percentage.

**Focused tests**

- One exact reasonable code passes.
- Any member of a defensible acceptable-code set passes.
- A canonical but semantically unrelated code fails.
- An invalid code fails canonical validity and is observed as dropped after the service path.
- Blank passes only when fixture-authorized.
- Transactional/advisory blank task code passes; an unsupported litigation code does not.
- Duplicate/reordered lines cannot obtain false matches.

### 3. Expand the synthetic fixture corpus

**Primary files**

- `BillingFidelityHarness.swift`, or a separate `BillingFidelityFixtures.swift` if the expanded corpus would make the harness difficult to maintain.
- Synthetic fixture resources under `TestData/` if attachment text is easier to manage as frozen resources.

**Corpus shape**

- Retain at least 20 independent model calls and approximately 30 expected lines so the 95% JSON threshold remains meaningful.
- Cover clear activities: drafting/revising, research, review/analysis, client communication, outside-counsel communication, attendance, planning, and file/data management.
- Cover litigation tasks across pleadings/motions, discovery, trial preparation, and appeal where the source evidence makes the phase apparent.
- Include cases where two task codes are both defensible and encode both in the acceptable set.
- Include at least one genuinely ambiguous case where blank plus explanation is preferred.
- Include transactional/advisory matters with blank task codes and universal A-codes.
- Include source combinations:
  - note only;
  - attachment only where attachment evidence is permitted to identify the work;
  - note plus linked attachment;
  - matter guideline controlling the code choice;
  - untagged matter inference;
  - multi-matter day;
  - `#Note` and attached canary text that must not reach either generation or coding.
- Include `autoTimestamp` on/off and explicit/inferred time fixtures so prompt changes cannot silently regress time behavior.
- Use obviously synthetic people, organizations, matter numbers, and documents; no production/client text.

### 4. Add a permanent signed-app real-model probe

**Likely files**

- New `Apps/SupraAI/SupraAI/BillingFidelityProbe.swift`.
- `Apps/SupraAI/SupraAI/SupraAIApp.swift` for a dormant launch-argument entry point.
- `Apps/SupraAI/SupraAI.xcodeproj/project.pbxproj` to include the new source file if needed by the current project structure.

**Behavior**

- Activate only with an explicit argument such as `-billingFidelityProbe`.
- Reuse the signed app’s normal `ModelLibrary`, runtime gateway, sandbox, and drafting-model route.
- Run the same `BillingDraftService` path used in production against isolated in-memory stores and synthetic fixtures.
- Accept an explicit output path and write one JSON report containing fixture version, model repository/internal IDs, exact prompts, raw responses, normalized persisted lines, per-line scores, aggregate scores, timings, and pass/fail gates.
- Keep strict-first-pass JSON distinct from service-parser acceptance.
- Exit with success only when all hard gates pass; use a nonzero result or explicit failed report status otherwise.
- Do not open or mutate the user’s production billing database.
- Avoid logging full fixture prompts to normal diagnostics outside the explicitly requested local report.

**Tests/checks**

- Unit-test argument parsing/report encoding where practical.
- Verify the probe stays dormant during normal and UI-test launches.
- Verify output is independently re-scorable from the recorded fixture, raw output, and normalized line data.

### 5. Improve the existing single-call coding prompt

**Primary files**

- `Packages/SupraSessions/Sources/SupraSessions/BillingDraftPrompt.swift`
- `Packages/SupraCore/Sources/SupraCore/UTBMSCodes.swift` only if a small reusable title lookup/renderer is needed.
- `Packages/SupraSessions/Tests/SupraSessionsTests/BillingDraftServiceTests.swift`
- Existing billing-instruction tests as affected.

**Changes**

- When auto-coding is on, render the canonical activity catalog and litigation-task catalog from `UTBMSCodes`, including code and title.
- State the decision order explicitly:
  1. derive a specific past-tense narrative from the note/document evidence;
  2. identify the activity that best describes what the attorney did;
  3. for litigation, identify the litigation phase/task that best describes what the work concerned;
  4. cross-check both choices against the source note/attachment and controlling matter guidelines;
  5. return `null` plus `codeNote` rather than forcing an unsupported choice.
- Clarify that activity code and task code answer different questions: activity is the kind of work performed; task is the litigation phase/topic.
- Explicitly warn that `A110 Manage data/files` is only for file/data management—not a generic fallback for drafting, research, review, or communication.
- Require codes to be copied exactly from the supplied catalog.
- For transactional/advisory matters, keep task code blank unless controlling guidelines provide a supported firm-specific code; continue selecting a universal activity code.
- When auto-coding is off, omit the catalogs and require both codes to be null.
- Preserve current model settings, matter evidence scope, attachment filtering, hours handling, and deterministic validators.

**Focused tests**

- Catalog text is derived from and contains every `UTBMSCodes` value/title exactly once.
- Catalog is present only when auto-coding is enabled.
- Prompt explicitly binds code selection to generated narrative plus source note/attachment and matter rules.
- `#Note` text and linked attachment canaries remain absent.
- Invalid/out-of-set model codes still become nil.
- Existing parse, matter, work-date, hours, evidence-scope, and persistence tests remain green.

### 6. Improve attorney review without changing persistence

**Primary files**

- `Packages/SupraSessions/Sources/SupraSessions/UIProjectionModels.swift` only if additional derived display information is required; `codeNote` is already projected.
- `Apps/SupraAI/SupraAI/ScratchPad/BillingDraftView.swift`
- Focused controller/view contract tests if an existing stable seam is available.

**Changes**

- Show code titles via chip label expansion, help text, or an accessible description so the attorney need not memorize code numbers.
- Surface `codeNote` for blank, ambiguous, or auto-selected codes without cluttering every row; a secondary line or tooltip/details affordance is sufficient.
- Make the language clear that codes are suggestions requiring review, while preserving “Nothing is billed automatically.”
- Keep existing edit pickers and LEDES blockers unchanged.
- Do not add a separate approval workflow or require an extra click for every routine line.

### 7. Run the controlled single-call benchmark and apply the stop/go gate

- First run the permanent probe against the unchanged production prompt to produce a reproducible baseline report.
- Run it again after the prompt/review changes with the same model, fixtures, generation settings, and fixture version.
- Compare all dimensions, not just code scores; reject a code improvement that materially regresses matter, narrative, time, source attribution, or JSON fidelity.
- If all acceptance criteria pass, stop. Do not add a second model call.
- If task or activity semantic reasonableness remains below 80%, inspect the per-line failures before escalating. Widen an acceptable fixture set only when the generated code is genuinely defensible from the narrative and source evidence.

### 8. Conditional: add one narrow batch coding pass only if Step 7 fails

This task is conditional and must not be implemented if the constrained single call passes.

**Likely files**

- New `Packages/SupraSessions/Sources/SupraSessions/BillingCodeSelectionPrompt.swift`.
- New `Packages/SupraSessions/Sources/SupraSessions/BillingCodeSelectionService.swift`, or a small internal helper in `BillingDraftService.swift` if that remains clearer.
- `BillingDraftService.swift` and focused tests.

**Contract**

- Keep the first generation responsible for line segmentation, matter, narrative, time, confidence, evidence, and source IDs.
- Validate matter and source IDs before constructing coding input.
- Send all unresolved lines in one batch call, keyed by stable line index/source IDs, to avoid one model call per line.
- For each line, provide only:
  - generated narrative;
  - selected matter and code set;
  - exact validated source note text;
  - attachments linked to those source entries or otherwise valid for the selected matter under existing evidence scope;
  - applicable matter override/client-guideline excerpt;
  - canonical eligible code catalogs.
- Return only keyed task code, activity code, and `codeNote`.
- Deterministically merge by stable key; reject duplicates, unknown keys, invalid enums, and matter/code-set conflicts.
- If the coding pass is unavailable or malformed, persist the otherwise valid billing lines with blank codes and a review note. Do not fail or lose the draft.
- Skip the coding call entirely when auto-coding is off.
- Preserve manual code edits across regeneration through the existing `userEdited` path.

**Focused tests**

- Coding input contains generated narrative and only its validated note/attachment evidence.
- Unrelated matter/source text does not reach the coding prompt.
- Reordered/duplicate/unknown selector outputs cannot attach a code to the wrong line.
- Valid selector output merges and persists.
- Invalid semantic-format output is dropped and flagged.
- Selector failure yields reviewable blank codes without losing narratives/hours.
- Auto-coding off makes exactly one generation call and persists blank codes.
- Regeneration retains attorney-edited codes.

Re-run the identical signed-app benchmark after this conditional stage. Do not proceed to full pipeline decomposition unless a new benchmark shows failures outside coding.

### 9. Synchronize durable documentation

**Primary files**

- `Docs/ScratchPad-SPEC.md` §§5.4, 6.1, and 12.
- `Docs/Verified-Product-Claims.yml` only if the changed behavior alters covered public/product wording.

**Changes**

- Replace the stale “not yet measured” implementation note with the measured result and final architecture selected by the stop/go gate.
- Add the code-fidelity metric and explain acceptable-set scoring/attorney review.
- State whether the shipping path remains one constrained generation or now uses one additional coding pass.
- Keep full decomposition explicitly deferred unless future measured evidence requires it.

## Verification plan

Use the smallest loop while changing code, then one final impact-appropriate pass after the code and fixtures stop changing.

1. **SupraCore tests** if `UTBMSCodes` changes:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
   ```

   Run from `Packages/SupraCore`.

2. **SupraSessions tests** for prompt, service, scorer, evidence scope, and persistence:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
   ```

   Run from `Packages/SupraSessions`.

3. **Relevant app build** because the signed probe and review UI touch app composition:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
     xcodebuild -workspace SupraAI.xcworkspace -scheme SupraAI \
     -destination 'platform=macOS' build
   ```

4. **Repository/product-claim checks** if documentation or project composition changes require them:

   ```bash
   bash Scripts/verify-repo-facts.sh
   bash Scripts/verify-product-claims.sh
   ```

5. **Signed real-model run:** execute the built signed app with the fidelity-probe arguments, verify report creation, independently inspect failed lines, and record the actual aggregate gate results. Use the same installed model and fixture version for baseline and candidate runs.

6. **Final diff review:** verify no client data, prompt/report artifacts, credentials, unrelated current-branch changes, generated build output, or temporary worktrees are included.

## Risks and mitigations

- **Prompt growth could regress other tasks.** The UTBMS catalogs are small, rendered only when auto-coding is on, and all existing fidelity dimensions are re-measured.
- **Golden answers can encode one reviewer’s preference as false certainty.** Use acceptable sets, rationale, and explicit ambiguity; adjudicate only from narrative plus source evidence.
- **All-null output could game a permissive scorer.** Blank is accepted only when fixture-authorized, and coverage is reported.
- **A valid code can still be wrong.** Score canonical validity and semantic reasonableness separately; keep attorney editing and code rationale visible.
- **A second model call adds latency/failure modes.** Add it only after the single-call gate fails, batch all lines, and fail soft to blank reviewable codes.
- **Attachment context could cross line/matter boundaries.** Reuse validated `sourceEntryIDs` and `BillingEvidenceScope`; never feed unrelated day evidence into a coding pass.
- **Benchmark access depends on app sandbox/model installation.** Run through the signed app and record model identity and raw outputs in the local report.
- **Current worktree contains unrelated changes.** Implement in a fresh branch/worktree and keep this plan’s diff isolated.

## Definition of done

- The permanent synthetic benchmark and signed-app probe produce an independently reviewable report.
- The shipping prompt receives canonical code definitions from `UTBMSCodes` and explicitly grounds code selection in generated narrative plus validated note/document evidence.
- Non-code fidelity gates remain green.
- Canonical validity is 100%; activity and litigation-task semantic reasonableness each reach at least 80%; non-litigation blank-task behavior is correct.
- Ambiguous/blank suggestions carry a useful review note, and the attorney can see code meaning/rationale and edit the result.
- The implementation stops at the single call if it passes; otherwise only the narrow batch coding stage is added and verified.
- Focused package tests, relevant app build, required repository/product checks, and the final real-model benchmark complete successfully.
- Documentation accurately states the final measured architecture and no real client data or transient benchmark/build artifacts enter the repository.
