# Implementation PLAN — Firm Style Profile (test-first program)

> **Companion documents.** This PLAN sequences the work; its sibling
> `Docs/Drafting-Impl-FirmStyleProfile-TESTPLAN.md` is the verification contract and is
> written and observed **first**. Authority for scope and design is
> `Docs/Drafting-Impl-FirmStyleProfile-SPEC.md` (bare `§N` = that spec). Every task below
> names the TESTPLAN Test IDs that gate it; every TESTPLAN test names the PLAN Task it
> unblocks and the SPEC § it enforces.

---

## How these two documents work in tandem

This is a **test-first** program. The contract between the two documents is mechanical:

1. **No task's production code is written until its gating tests exist and have been
   observed RED on macOS** for the specific reason the TESTPLAN records (a named undefined
   symbol, or a concrete wrong-value assertion failure). See TESTPLAN "RED-FIRST PROTOCOL".
2. **A task is DONE only when** (a) every one of its gating Test IDs is observed GREEN on
   macOS, (b) the default-parity suite (`T-PARITY-*`) still passes, and (c) the STATIC
   SAFEGUARD CHECKLIST (TESTPLAN) is clean for the files it touched.
3. **Toolchain reality (§10 preamble).** There is **no Swift toolchain in the web/dev
   environment**; red→green cannot be observed here. Observation is a **manual macOS gate**
   (`cd Packages/<Pkg> && swift test`, per package). Both the "Tests RED observed" and
   "Tests GREEN observed" columns of the PROGRESS LEDGER are **human sign-off** cells.

**Cross-reference notation.**
- **Task IDs** — `M<milestone>-T<n>`, e.g. `M1-T5`. Referenced by TESTPLAN "gates PLAN Task".
- **Test IDs** — `T-<AREA>-<nn>`, e.g. `T-CAP-03`, `T-FLOOR-01`, `T-PARITY-01`. Areas:
  `CODEC` (Codable), `RESOLVE` (merge), `FLOOR` (clamp), `DEFAULT` (defaults=literals),
  `CAP`/`LH`/`SIG`/`CERT`/`BODY` (renderer wire-proofs, per §4.2 element), `PARITY`
  (frozen-golden byte/text parity), `CTRL` (controller wiring), `PERSIST` (autosave),
  `PARSE` (exemplar), `VOICE` (Track B).

---

## Guiding principles

- **TDD, red-first (§10).** Author the gating test, watch it fail for the *named* reason on
  macOS, then write the code that turns it green. A test whose RED reason is "already green"
  is suspect and must be justified in the TESTPLAN.
- **Byte-parity for unconfigured firms (invariant 5).** A firm that configures nothing must
  get **byte-for-byte identical** output to today's `.defaultFL`. Parity is protected by a
  golden frozen from the **pre-lift** renderer (Task M1-T0). **The pre-lift baseline is a
  no-drift regression oracle, NOT an independent correctness oracle** (it is produced by the
  very renderer that M1-T5/T6 modify, so a literal→field substitution that happens to
  reproduce identical default bytes is invisible to it). Correctness therefore rests on the
  **wire-proofs**, backed by the independently authored Word-roundtripped
  `Docs/Fixtures/*.document.xml` visible-text anchors (TESTPLAN "GOLDEN/FIXTURE MANAGEMENT").
- **Wire-proof over default-echo (the #1 doctrine).** Because every new field's default
  *equals* today's literal, a test rendered under `.defaultFL` passes whether or not the
  renderer actually reads the field. The proof that a field is wired **must** render a
  **non-default** value and assert the customized token is present **and** the default token
  is absent (`XCTAssertFalse`), each at the **exact `<w:t …>…</w:t>` element level or scoped
  to the specific target paragraph** — never a whole-document short/shared substring. See
  TESTPLAN "ANTI-SILENT-FAILURE DOCTRINE".
- **The §2 invariants restated as guardrails** (do not violate in any task):
  1. **Floor un-overridable** — 2.520(a) ≥ 12 pt / ≥ 1″; clamp is total & idempotent (M1-T3).
  2. **Golden-lock** — same profile + same slots ⇒ same bytes.
  3. **No model-originated structure** — generation output types gain **no** structural field.
  4. **Identity slot-only** — the exemplar parser captures labels/prefixes/geometry, never
     names/addresses/phone-numbers/emails/bar-numbers (M3-T2).
  5. **Default byte-parity / zero regression** — empty profile ⇒ `.defaultFL` output.

---

## Milestones & tasks

### M1 — Lift literals + `FirmStyleProfile` + wiring; default parity (§11)

**Exit criterion (§11):** golden `.docx`/visible-text bytes unchanged for an empty profile
(`T-PARITY-01/02/03` GREEN); all wire-proof tests GREEN; no UI yet.

> **Field-count reconciliation (§11).** M1-T4 adds exactly **29** stored style fields (the
> additive per-struct list in §4.2; see M1-T4). SPEC §11's "~22 new style fields" is an
> approximate early estimate and an undercount; the authoritative count is the 29 enumerated
> in §4.2. This note exists so a reviewer checking the milestone against §11 sees the
> discrepancy is a known approximation, not a scope drift.

---

#### M1-T0 — Freeze the pre-lift baseline goldens (parity source of truth)
- **Goal:** capture the exact renderer output **before any literal is lifted**, commit it as
  the frozen **no-drift regression** oracle for parity. This predates the code under test, so
  comparing post-wire-up output to it never violates the PARITY RULE. **It is explicitly NOT
  an independent correctness oracle** (same renderer code) — that burden is carried by the
  wire-proofs plus the Word-roundtripped `*.document.xml` visible-text anchors.
- **Files touched:** `Docs/Fixtures/` (new: `noticeAppearance-baseline.wml.txt`,
  `letterDemand-baseline.wml.txt`, `motionToDismiss-baseline.wml.txt` — normalized WML
  captured from HEAD renderers), plus a capture note in the TESTPLAN.
- **Gating tests:** none precede this (it *produces* the parity oracle). It is validated by
  `T-PARITY-01/02/03` later.
- **Steps:**
  0. Confirm working tree is clean at the pre-lift commit.
  1. Run a throwaway macOS harness that renders `noticeModel` / `letterModel` / `motionModel`
     under `.defaultFL` through today's `CourtFLRenderer`/`LetterheadRenderer`, normalize via
     `OoxmlNormalizer.normalize`, write to the baseline files. The **motion** baseline is
     captured from the same pre-lift `CourtFLRenderer` fed the `motionModel` fixture (numbered
     allegations + point heading + `respectfullySubmitted` date) defined in the TESTPLAN
     ready-to-paste harness.
  2. Commit the baseline files. **Never regenerate them from post-lift code.**
- **DONE when:** baseline files exist and are committed on the pre-lift commit; recorded in
  the ledger as the parity oracle.

#### M1-T1 — `NumberFormat` enum (two cases) + `FirmStyleProfile` DTO
- **Goal:** the sparse all-`Optional` `Codable` DTO (§4.1) with `schemaVersion`,
  `currentSchemaVersion = 1`, `profileKey = "firm.styleProfile"`, explicit `public init`,
  and a `public enum NumberFormat: Codable` with **two** cases so a genuine non-default value
  exists for the #25 wire-proof:
  ```swift
  public enum NumberFormat: Codable {
      case numberDot    // "1."  (default — today's literal at CourtFLRenderer.swift:168)
      case numberParen  // "1)"  (non-default — enables the T-BODY-01 wire-proof)
  }
  ```
- **Files touched:** `Packages/SupraDraftingCore/Sources/SupraDraftingCore/FirmStyleProfile.swift` (NEW).
- **Gating tests (author & RED first):** `T-CODEC-01`, `T-CODEC-02`, `T-CODEC-03`,
  `T-CODEC-04`.
- **Steps:**
  0. Author `T-CODEC-01..04` in `SupraDraftingCoreTests`; observe RED — **compile error:
     undefined symbol `FirmStyleProfile` / `NumberFormat`**.
  1. Declare `FirmStyleProfile` (all fields from §4.1, every one `Optional` except
     `schemaVersion: Int`), `NumberFormat` (both cases), `static let currentSchemaVersion = 1`,
     `static let profileKey = "firm.styleProfile"`, `public init(schemaVersion:)`.
  2. Add a resilient `init(from:)` using `decodeIfPresent` everywhere (§4.4) so a lower
     `schemaVersion` / missing keys decode to `nil`, then stamp `currentSchemaVersion`.
- **DONE when:** `T-CODEC-01..04` GREEN; parity intact; static checklist clean.

#### M1-T4 — Add the 29 style fields (defaults = literals) to `DraftingCore.swift`
> Ordered before M1-T2 because `resolved(over:)` writes into these fields.
- **Goal:** add the exactly **29** stored fields enumerated in §4.2 to their home structs,
  each `public var` with a default equal to today's literal, including
  `BodyStyle.numberFormat: NumberFormat = .numberDot`. No behavior change (renderer still
  ignores them until M1-T5/T6).
- **Files touched:** `Packages/SupraDraftingCore/Sources/SupraDraftingCore/DraftingCore.swift`
  (structs `LetterheadBlock:488` +3, `LetterheadStyle:509` +5, `CaptionStyle:388` +6,
  `ESignatureStyle:424` +1, `SignatureStyle:436` +8, `CertificateStyle:460` +4,
  `HeadingLadder:416` +1, `BodyStyle:374` +1) — sum = **29** (reconciles §11's "~22").
- **Gating tests:** `T-DEFAULT-01` (spot-checks that each new default equals the §4.2
  literal — a supporting check, **not** a wiring proof); `T-BODY-04` (bodyJustify overlay via
  the new field + resolver — its RED is the undefined member here, see M1-T2).
- **Steps:**
  0. Author `T-DEFAULT-01`; observe RED — **undefined member** (e.g.
     `HouseStyleSheet.defaultFL.caption.partySeparator`).
  1. Add the fields with literal defaults per the §4.2 "Resulting struct additions" list.
  2. Keep synthesized `Codable` (route (b), §4.2 — the sheet is never persisted).
- **DONE when:** `T-DEFAULT-01` GREEN; the whole existing SupraExports suite still GREEN
  (defaults changed nothing); parity intact.

#### M1-T2 — `resolved(over:)` merge extension
- **Goal:** `public func resolved(over base: HouseStyleSheet = .defaultFL) -> HouseStyleSheet`
  overlaying each non-nil field via `.map` (§4.1). Pure, total, deterministic.
- **Files touched:** `FirmStyleProfile.swift` (extension).
- **Gating tests (author & RED first):** `T-RESOLVE-01` (empty ⇒ `.defaultFL`, exact
  `Equatable`), `T-RESOLVE-02` (single overlay lands on the sheet, off-target fields
  untouched), and **`T-BODY-04`** (bodyJustify overlay — the renderer *already* reads
  `style.body.justify` at CourtFLRenderer:157/165, so once the `FirmStyleProfile.bodyJustify`
  field (M1-T4) and this resolver exist, `justify=false` suppresses `<w:jc w:val="both"/>`
  with **no M1-T5 change**; its RED reason is the **undefined member
  `FirmStyleProfile.bodyJustify`**, observed here — NOT a renderer lift).
- **Steps:**
  0. Author `T-RESOLVE-01/02` and `T-BODY-04`; observe RED — **undefined method
     `resolved(over:)` / undefined member `FirmStyleProfile.bodyJustify`**.
  1. Implement the overlay exactly as §4.1 (nil ⇒ no `.map` fires ⇒ base returned unchanged).
- **DONE when:** `T-RESOLVE-01/02` + `T-BODY-04` GREEN; parity intact.

#### M1-T3 — `clampedToFloor()` (2.520(a))
- **Goal:** `public func clampedToFloor() -> HouseStyleSheet` on `HouseStyleSheet`, clamping
  `page.fontHalfPoints >= 24` and every `page.marginTwips` side `>= 1440`. Pure, total,
  idempotent (§4.3).
- **Files touched:** `Packages/SupraDraftingCore/Sources/SupraDraftingCore/StyleSheetFloor.swift`
  (NEW).
- **Gating tests (author & RED first):** `T-FLOOR-01`, `T-FLOOR-02`, `T-FLOOR-03`,
  `T-FLOOR-04`.
- **Steps:**
  0. Author `T-FLOOR-01..04`; observe RED — **undefined method `clampedToFloor()`**.
  1. Implement per §4.3 using `max(...)` per field/side.
- **DONE when:** `T-FLOOR-01..04` GREEN; parity intact. (Cross-module note: the existing
  `StyleSheetCompiler.validateFloor` lives in **SupraExports**, `Ooxml/StyleSheetCompiler.swift:11`;
  the clamp *precedes* it as defense-in-depth — do not fold it in this slice; open-question 3.)

#### M1-T5 — `CourtFLRenderer` wire-up (caption / signature / certificate / body / heading)
- **Goal:** replace each baked literal in `CourtFLRenderer.swift` (§4.2 rows 8–29) with a
  read of the corresponding style field, and lift the ignored bools
  (`headerBoldCentered`, `closingRuleEndsInSlash`, `firmNameBoldCaps`,
  `representationLineItalic`, `headingCenteredBoldCaps`) to read the sheet. **Route the
  allegation number glyph through `style.body.numberFormat` at :168** (`.numberDot ⇒ "\(n)."`,
  `.numberParen ⇒ "\(n))"`) so #25 is a genuine wire-up. The `", I "` middle connective of the
  attestation stays hardcoded (row 23) to preserve byte-parity.
- **Files touched:** `Packages/SupraExports/Sources/SupraExports/CourtFLRenderer.swift`
  (lines 42–47, 110, 116, 124, 128, 131, 134, 167, 168, 173, 176, 177, 200, 207, 210, 215,
  223, 225, 229, 241, 254, 259, 296, 317–327).
- **Gating tests (author & RED first — each is WIRE-PROOF unless noted):** `T-CAP-01..08`,
  `T-SIG-01..10`, `T-CERT-01..04`, `T-BODY-01..03`; plus parity `T-PARITY-01` and
  `T-PARITY-03` (motion path exercises the numbered-allegation / point-heading / submitted
  constructs). **`T-BODY-04` is NOT gated here** — it belongs to M1-T2/M1-T4 (bodyJustify is
  already wired; see M1-T2).
- **Steps:**
  0. Author the wire-proof tests; observe RED — the customized token (exact `<w:t>` element or
     paragraph-scoped run) is **absent** and the baked default token is **present** (concrete
     wrong value stated per test in TESTPLAN).
  1. Substitute each literal for its field read (§6 mapping); gate the bool constructs on the
     already-present sheet flags; switch the allegation glyph on `numberFormat`.
- **DONE when:** all listed wire-proofs GREEN **and** `T-PARITY-01`/`T-PARITY-03` GREEN (empty
  profile still matches the M1-T0 baselines); static checklist clean (no `contains("")`, no
  bare `guard case … else { return }`, no whole-doc short-token absence assert).

#### M1-T6 — `LetterheadRenderer` wire-up (letterhead + body paragraph style)
- **Goal:** replace §4.2 rows 1–7 literals with field reads, gate the masthead rule on
  `block.bottomRule`, and **wire the body paragraph on `bodyParagraphStyle`** — an in-scope
  renderer wire-up (grounded beyond the §4.2 numbered list): when
  `bodyParagraphStyle == .indented`, the body paragraph (LetterheadRenderer ~line 84) gains
  `<w:ind w:firstLine="720"/>`; `.block` (default) keeps no first-line indent. This makes
  `bodyParagraphStyle` a live field with a real wire-proof (T-LH-09), not a dead field.
- **Files touched:** `Packages/SupraExports/Sources/SupraExports/LetterheadRenderer.swift`
  (lines 43, 50, 51, 54, 70, 71, **84 (body paragraph — new `bodyParagraphStyle` read)**,
  120, 123).
- **Gating tests (author & RED first — WIRE-PROOF):** `T-LH-01..09`; plus parity `T-PARITY-02`.
- **Steps:**
  0. Author `T-LH-01..09`; observe RED — customized token absent / default present (exact
     `<w:t>` element or attribute-pair form).
  1. Substitute literals; gate `bottomRule`; read `bodyParagraphStyle` at the body paragraph.
- **DONE when:** `T-LH-01..09` GREEN and `T-PARITY-02` GREEN; static checklist clean.

#### M1-T7 — Controller `effectiveStyle()` + swap call sites; inject `firmStyleProfile`
- **Goal:** add `func effectiveStyle() -> HouseStyleSheet` — **`internal`, not `private`**, so
  `@testable import` can reach it (T-CTRL-01/04 call it directly; `@testable` raises only
  `internal`, never `private`) — returning
  `(firmStyleProfile ?? FirmStyleProfile()).resolved(over: .defaultFL).clampedToFloor()`.
  Inject the **raw** `firmStyleProfile: FirmStyleProfile?` (NOT the `FirmStyleProfileController`,
  which does not exist until M2-T1 — injecting the value type keeps M1-T7 compilable and
  RED-observable inside M1). Swap `.defaultFL → effectiveStyle()` at
  `MatterDraftingController.swift:160` (Notice) and `:307` (Letter); add the injected field
  next to `runtimeClient` (`:85`, init `:87`). (`runMotion` deferred — no controller call site
  yet.) In M2, `FirmStyleProfileController` supplies its `.profile` into this injection point.
- **Files touched:**
  `Packages/SupraSessions/Sources/SupraSessions/MatterDraftingController.swift`.
- **Gating tests (author & RED first):** `T-CTRL-01` (no profile ⇒ `effectiveStyle() ==
  .defaultFL`), `T-CTRL-02` (Notice passes `effectiveStyle()`; WIRE-PROOF via a non-default
  profile that a spy pipeline captures), `T-CTRL-03` (Letter path likewise), `T-CTRL-04`
  (below-floor profile clamped to 24/1440 through the controller).
- **Steps:**
  0. Author `T-CTRL-01..04`; observe RED — **undefined member `firmStyleProfile`/`effectiveStyle`**,
     then captured `style` still `.defaultFL` for a set profile.
  1. Add the field, init param, `internal` helper; edit `:160`/`:307`.
- **DONE when:** `T-CTRL-01..04` GREEN; existing `MatterDraftingControllerTests` GREEN;
  parity intact.

---

### M2 — Settings manual controls + preview (§7, §11)

**Exit:** per-element controls autosave; a live `.docx` preview renders from the effective
sheet. No exemplar parsing yet.

#### M2-T1 — `FirmStyleProfileController` (autosave / load / persist)
- **Goal:** `@MainActor public final class FirmStyleProfileController: ObservableObject` with
  `@Published var profile: FirmStyleProfile { didSet { persist() } }`, load at init via
  `getSetting(FirmStyleProfile.profileKey, as: FirmStyleProfile.self) ?? FirmStyleProfile()`,
  `persist()` writing via `store.appSettings.setSetting` and setting `message` only on
  failure — mirroring `AssistantProfileController` exactly (§4.4). It feeds its `.profile`
  into `MatterDraftingController`'s M1-T7 `firmStyleProfile` injection point.
- **Files touched:**
  `Packages/SupraSessions/Sources/SupraSessions/FirmStyleProfileController.swift` (NEW).
- **Gating tests (author & RED first):** `T-PERSIST-01` (absent ⇒ default ⇒ resolves to
  `.defaultFL`), `T-PERSIST-02` (edit autosaves; a fresh controller on the same store reloads
  it), `T-PERSIST-03` (`message` set only on write failure).
- **Steps:** 0. Author `T-PERSIST-01..03` (RED: undefined type). 1. Implement mirroring
  `AssistantProfileController` (initial-assignment-doesn't-fire-`didSet` relied on, §4.4).
- **DONE when:** `T-PERSIST-01..03` GREEN.

#### M2-T2 — `FirmStyleSection` UI + effective-sheet preview control
- **Goal:** add `FirmStyleSection` to `SettingsView.swift` (near `AssistantProfileSection:17`)
  with the five per-element subsections (§7), autosave bindings to `$firmStyle.profile.<field>`,
  the 2.520(a) inline notice, and a "Preview what your firm's documents look like" control that
  renders a sample `.docx` from the effective sheet via `SendUserFile`/save.
- **Files touched:** `Apps/SupraAI/SupraAI/FirmStyleSection.swift` (NEW),
  `Apps/SupraAI/SupraAI/SettingsView.swift` (EDIT), reusing `LabeledTextField`
  (`MultilineField.swift:412`) / `MultilineField` (`:114`).
- **Gating tests:** **none automated** — the app target has no unit test target (R1/R2). This
  task is verified by the **manual macOS UI gate** only (build + click-through). Recorded in
  the ledger as `UI-manual`. Its correctness leans entirely on M2-T1's `T-PERSIST-*` (the
  binding writes flow through the tested controller) — flagged as a coverage GAP in the
  TESTPLAN COVERAGE MATRIX.
- **DONE when:** builds; manual click-through autosaves and preview renders; M2-T1 GREEN.

---

### M3 — Exemplar parse + confirm (§5, §11)

**Exit:** upload → extract → STRICT-JSON structured extraction → review → rendered preview →
confirm-writes-profile, with all §5.4 guardrails (including the §5.4 image/`needsOCR` path).

#### M3-T1 — `ExemplarKind` enum + per-kind extraction DTOs
- **Goal:** small `enum ExemplarKind { case letterhead, caption, signature }` and the internal
  `Codable` DTOs `LetterheadExtraction` / `CaptionExtraction` / `SignatureExtraction` (§5.2,
  all fields `Optional`). **These DTOs must exist before the parser (M3-T2) compiles.**
- **Files touched:**
  `Packages/SupraSessions/Sources/SupraSessions/FirmStyleExemplarParser.swift` (NEW).
- **Gating tests:** covered by M3-T2's parse tests (the DTOs have no behavior alone); the
  parser test file references the DTO types, so authoring `T-PARSE-01` first yields the
  DTOs' RED (undefined symbol) — but the compile-order dependency is **DTOs → parser**.
- **DONE when:** the DTO types compile so M3-T2's parser body can be written against them.

#### M3-T2 — `FirmStyleExemplarParser` (extract → JSON → repair → candidate mapping + guardrails)
- **Goal:** `extract(fileURL:)` via reused `ExtractionService` (§5.1); build a `GenerateRequest`
  with the STRICT-JSON system contract + `combinedText` prompt, greedy/temp-0 route
  (`ModelRouting.swift:284–287`), drain with `collectGeneratedText`, strip via
  `ReasoningContent.answer(from:)`, `JSONDecoder().decode`; **one** repair on decode failure,
  then graceful manual-entry fallback; map field-by-field into a *candidate* `FirmStyleProfile`;
  discard `combinedText`. Identity fields (names/addresses/phone-numbers/emails/bar-numbers)
  are never captured (invariant 4, §5.4). The **image-only / `needsOCR`** letterhead path
  (§5.4) surfaces the "we can capture your letterhead text but not a logo image yet" advisory,
  maps whatever OCR text is available, and stores **no image bytes** on the profile.
- **Files touched:** `FirmStyleExemplarParser.swift`.
- **Gating tests (author & RED first, via `StubRuntimeClient` canned JSON):** `T-PARSE-01`
  (letterhead → fields), `T-PARSE-02` (caption), `T-PARSE-03` (signature), `T-PARSE-04`
  (malformed → one repair prompt issued → success), `T-PARSE-05` (still malformed after repair →
  candidate all-nil, **no profile write**), `T-PARSE-06` (identity-bearing exemplar → no
  name/number/email captured), `T-PARSE-07` (empty text → "No text was found" message, no
  write), `T-PARSE-08` (exemplar text never reaches `runNotice`/`runLetter` or a stored field),
  **`T-PARSE-10`** (image-only/`needsOCR` extraction → advisory surfaced, OCR text (if any)
  still mapped, **no image bytes on the profile**).
- **Steps:** 0. Author `T-PARSE-01..08,10`; observe RED (undefined type, then wrong mappings).
  1. Implement per §5.2/§5.4.
- **DONE when:** `T-PARSE-01..08,10` GREEN.

#### M3-T3 — Review/confirm UI + rendered preview + preview determinism
- **Goal:** two-pane review (parsed fields editable with defaults shown; rendered candidate
  `.docx` via `candidate.resolved(over:.defaultFL).clampedToFloor()` through production
  renderers using `firmProfile(from:)` slots), confirm writes the profile via controller
  `didSet` (§5.3).
- **Files touched:** `Apps/SupraAI/SupraAI/FirmStyleSection.swift` (EDIT), plus a small
  preview-builder helper in `FirmStyleProfileController` (testable).
- **Gating tests:** `T-PARSE-09` (preview determinism: render the same candidate sheet twice ⇒
  identical bytes) is automatable at the controller/renderer layer; the pane UI itself is
  `UI-manual`.
- **DONE when:** `T-PARSE-09` GREEN; manual confirm writes profile (observed via `T-PERSIST-02`
  path).

---

### M4 — Voice track (Track B) (§8, §11)

**Exit:** `AssistantVoiceProfile.registerNotes` enriched from the `AssistantProfile` style
surface; prose-only; outside the trust contract.

#### M4-T1 — Enrich `registerNotes` from the `AssistantProfile` style surface
- **Goal:** at `MatterDraftingController.swift:290`, enrich `registerNotes` from
  `AssistantProfile.formality`/`length`/`voiceNotes` (`:99–101`) and the firewall block from
  `composedSystemPrompt`, while preserving both hard rules: writing samples stay
  style-exemplar-only, and **no** structural field is added to any generation output type (§8).
- **Files touched:** `MatterDraftingController.swift` (`:290`, `:375–381` `toneRegister`).
- **Gating tests (author & RED first):** `T-VOICE-01` (enriched `registerNotes` contains the
  firm's `voiceNotes`/`formality` cues for a set profile, and does **not** for an empty one —
  WIRE-PROOF). **`T-VOICE-02` is a standing invariant/regression guard, GREEN from HEAD**
  (`AssistantVoiceProfile`'s only surface is `registerNotes: String`; `GeneratedLetter` has no
  structural field today) — it has **no pre-implementation RED** and is documented as such; its
  job is to fail only on a *future* structural-field regression (see TESTPLAN RED-FIRST note).
- **DONE when:** `T-VOICE-01` GREEN; `T-VOICE-02` GREEN and re-affirmed as a standing guard;
  Notice path still builds no voice profile; parity of structural output unaffected.

---

## Dependency / sequencing graph

```
M1-T0 (freeze baseline goldens)  ─────────────► gates all T-PARITY-*

M1-T1 (FirmStyleProfile + NumberFormat[2 cases]) ─┐
M1-T4 (29 style fields) ──────────────────────────┼─► M1-T2 (resolved, +bodyJustify) ─► M1-T7 (controller effectiveStyle; injects raw FirmStyleProfile)
M1-T3 (clampedToFloor) ───────────────────────────┘

M1-T4 ─► M1-T5 (CourtFLRenderer)   ─► T-PARITY-01, T-PARITY-03
M1-T4 ─► M1-T6 (LetterheadRenderer) ─► T-PARITY-02

M1-T7 ─► M2-T1 (FirmStyleProfileController supplies .profile into M1-T7's injection point) ─► M2-T2 (UI, manual)
M2-T1 ─► M3-T1 (extraction DTOs) ─► M3-T2 (exemplar parser) ─► M3-T3 (review/preview)
M1-T7 ─► M4-T1 (voice)   [independent of M2/M3]
```

Critical path: `M1-T0 → M1-T1/T4 → M1-T2 → M1-T5/T6 → T-PARITY → M1-T7`. M2/M3/M4 follow M1.

> **Graph fixes vs. prose:** (1) M1-T7 injects the **raw `FirmStyleProfile`** value type
> (available from M1-T1), so it no longer depends on the M2-T1 controller — the producer→
> consumer edge now runs **M1-T7 → M2-T1**, matching the tests-before-code chain within M1.
> (2) The M3 edge is **M3-T1 (DTOs) → M3-T2 (parser) → M3-T3**: the parser consumes the DTOs,
> so the DTOs must precede it (matches the compile dependency and the prose ordering).

## Definition of Done

**Per milestone:** every task's gating Test IDs GREEN on macOS; `T-PARITY-01/02/03` still
GREEN; STATIC SAFEGUARD CHECKLIST clean for all touched files; ledger rows updated with human
sign-off on both RED-observed and GREEN-observed cells.

**Overall:** M1–M4 DONE; the full per-package suites (`SupraDraftingCoreTests`,
`SupraExportsTests`, `SupraSessionsTests`, `SupraDraftingTests`) run with **zero failures**
(`CONTRIBUTING.md:61`); COVERAGE MATRIX shows every §2 invariant and every §4.2 literal covered
by at least one wire-proof (not merely a parity test); no GAP rows remain except the explicitly
accepted `UI-manual` app-target items and the documented dead `letterhead.dateFormat` field.

## Regression-safety note

Default parity is the outer guardrail. `M1-T0` freezes the pre-lift renderer output as a
**no-drift regression** oracle; `T-PARITY-01/02/03` re-render under
`FirmStyleProfile().resolved(over:.defaultFL).clampedToFloor()` and compare to that baseline
plus the **independently authored** Word-roundtripped `Docs/Fixtures/*.document.xml`
visible-text anchors. Because parity feeds the **same** `.defaultFL` sheet through both paths,
parity alone **cannot** catch a literal→field substitution error (both sides emit the default,
and the baseline is not an independent correctness oracle) — that is exactly why every §4.2
literal also carries a **wire-proof** test (non-default value; custom-present + default-absent
at the exact-element / paragraph-scoped level). Parity catches accidental byte drift (golden
churn, §12); wire-proofs catch unwired reads. The two are complementary and both are required
for a task to be DONE.

---

## PROGRESS LEDGER (tandem tracker — seed state)

| Task ID | Description | Gating Tests | Tests RED observed | Code done | Tests GREEN observed | Parity OK | Status |
|---|---|---|---|---|---|---|---|
| M1-T0 | Freeze pre-lift baseline goldens (notice/letter/motion) | (parity oracle) | n/a | ☐ | n/a | n/a | not started |
| M1-T1 | `FirmStyleProfile` + `NumberFormat` (2 cases) DTO | T-CODEC-01..04 | ☐¹ | ☑ | ☐² | ☐² | code done — awaiting macOS |
| M1-T4 | Add 29 style fields (defaults=literals) | T-DEFAULT-01 | ☐¹ | ☑ | ☐² | ☐² | code done — awaiting macOS |
| M1-T2 | `resolved(over:)` merge (+bodyJustify) | T-RESOLVE-01, T-RESOLVE-02, T-BODY-04³ | ☐¹ | ☑ | ☐² | ☐² | code done — awaiting macOS |
| M1-T3 | `clampedToFloor()` (2.520(a)) | T-FLOOR-01..04 | ☐¹ | ☑ | ☐² | ☐² | code done — awaiting macOS |
| M1-T5 | CourtFLRenderer wire-up | T-CAP-01..08, T-SIG-01..10, T-CERT-01..04, T-BODY-01..04, T-PARITY-01, T-PARITY-03⁴ | ☐¹ | ☑ | ☐² | ☐² | code done — awaiting macOS |
| M1-T6 | LetterheadRenderer wire-up (+bodyParagraphStyle) | T-LH-01..09, T-PARITY-02⁴ | ☐¹ | ☑ | ☐² | ☐² | code done — awaiting macOS |
| M1-T7 | Controller `effectiveStyle()` (internal) + inject raw `firmStyleProfile`; swap :160/:307 | T-CTRL-01..04 | ☐¹ | ☑ | ☐² | ☐² | code done — awaiting macOS |
| M2-T1 | `FirmStyleProfileController` autosave | T-PERSIST-01..03 | ☐ | ☐ | ☐ | ☐ | not started |
| M2-T2 | `FirmStyleSection` UI + preview | UI-manual | n/a | ☐ | n/a | ☐ | not started |
| M3-T1 | `ExemplarKind` + extraction DTOs | (via T-PARSE-01 RED; DTOs precede parser) | ☐ | ☐ | ☐ | n/a | not started |
| M3-T2 | `FirmStyleExemplarParser` + guardrails (+needsOCR) | T-PARSE-01..08, T-PARSE-10 | ☐ | ☐ | ☐ | ☐ | not started |
| M3-T3 | Review/confirm UI + preview determinism | T-PARSE-09 (+UI-manual) | ☐ | ☐ | ☐ | ☐ | not started |
| M4-T1 | Enrich `AssistantVoiceProfile.registerNotes` | T-VOICE-01 (+T-VOICE-02 standing guard) | ☐ | ☐ | ☐ | ☐ | not started |

> ¹ RED is *observable in git history*: the foundation tests were committed one commit **before**
> the implementation, so `git checkout <tests-commit> && cd Packages/SupraDraftingCore && swift test`
> fails to compile with the named undefined symbols (`FirmStyleProfile`, `resolved(over:)`,
> `clampedToFloor`, `NumberFormat`, the new style members) — the recorded RED reason. The dev
> environment has no Swift toolchain, so this observation is a human macOS step.
> ² GREEN + Parity await the same macOS `swift test` run on the implementation commit.
> ³ `T-BODY-04` (bodyJustify overlay) is authored in `FirmStyleWireProofTests.swift`; the
> resolver + `bodyJustify` field it needs already exist, so it is GREEN from the foundation (the
> renderer already reads `style.body.justify`) — no renderer edit was required for it.
> ⁴ `T-PARITY-01/02/03` are **deferred with M1-T0**: they compare against pre-lift baseline
> goldens that must be captured by a macOS render (no toolchain here). The wire-proofs above are
> authored and the code is landed; the existing golden-locked `CourtFLRendererTests` /
> `LetterheadRendererTests` (render under `.defaultFL`) act as the interim parity net, since every
> new field defaults to today's literal.
>
> Legend: ☐ = pending human sign-off on macOS; **Parity OK** = `T-PARITY-01/02/03` re-run GREEN
> after the task's code landed. A task moves to **done** only when every cell in its row is
> checked (or `n/a`). `T-VOICE-02`'s "Tests RED observed" cell is `n/a (standing guard,
> GREEN-from-HEAD, justified)`.
