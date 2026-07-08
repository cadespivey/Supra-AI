# Verification TESTPLAN — Firm Style Profile (written & run FIRST)

> **Companion documents.** This TESTPLAN is the verification contract for
> `Docs/Drafting-Impl-FirmStyleProfile-PLAN.md`; it is authored and observed **RED before**
> any production code is written. Authority for behavior is
> `Docs/Drafting-Impl-FirmStyleProfile-SPEC.md` (bare `§N` = that spec). Every test names the
> PLAN Task it gates and the SPEC § it enforces; every PLAN task names the Test IDs that gate
> it.

---

## ANTI-SILENT-FAILURE DOCTRINE (governing rules — enforced in every test)

These rules override convenience. A test that violates any of them is invalid and must be
rewritten before it may gate a task.

1. **WIRE-PROOF RULE.** Every new style field / lifted literal is proven wired by a test that
   renders a **NON-DEFAULT** `FirmStyleProfile` value and asserts **both**: (a) the customized
   token **IS present** (`XCTAssertTrue`), **and** (b) the original default token **IS absent**
   (`XCTAssertFalse`). A test that only checks the default value is **FORBIDDEN** as the wiring
   proof — under `.defaultFL` it passes whether or not the renderer reads the field.
   **Absence/presence assertions MUST target the exact `<w:t …>…</w:t>` element (or a specific
   target-paragraph fragment), never a whole-document short/shared substring** (`<w:b/>`,
   `<w:i/>`, `<w:caps/>`, `<w:jc …>`, a bare `/`, `v.`, `Re:`, an empty string). Every wire-proof
   must also render against a fixture whose **model shape actually emits the target element**
   (a judge in the caption, a `.numberedAllegation`/`.pointHeading` in the body, a
   `respectfullySubmitted` date for the submitted line, etc.), or the "custom present" half can
   never fire.
2. **PARITY RULE.** Default-parity tests compare new-code output to a **FROZEN** golden authored
   **once** from an independent source of truth. Two oracles exist and their roles are distinct:
   the pre-lift `*-baseline.wml.txt` (PLAN M1-T0) is a **no-drift regression** oracle (produced
   by the very renderer under change, so it is **NOT** an independent correctness oracle); the
   Word-roundtripped `Docs/Fixtures/*.document.xml` is the **independent** oracle, used for
   `visibleText` containment. Goldens are **NEVER** regenerated from the code under test; no test
   may write-then-read a golden it also produced.
3. **RED-FIRST RULE.** Every test records its expected pre-implementation failure — a compile
   error (**named** undefined symbol) or a specific assertion failure stating the **concrete
   wrong value** that will be observed. A RED reason of "already green / n/a" is suspect and
   must be **explicitly justified** (the two justified standing guards are `T-VOICE-02` and the
   `T-FLOOR-02` idempotence check — see their rows).
4. **NO-SILENT-SKIP RULE.** No `guard let … else { return }` in tests (use `XCTUnwrap`); async
   tests **must** `await`/`try await` the call under test; no `try` without a following
   assertion; no assertion buried in a closure/completion handler that may never fire; every test
   method is `test`-prefixed and lives in a SwiftPM-discovered `Tests/<Target>` file. Any
   `guard case … else` in a test puts `XCTFail(...)` **before** `return`.
5. **TAUTOLOGY BAN.** No assertion true regardless of the code under test — no asserting a
   constant the test itself defined, no `contains("")`, no comparing a value to itself, no
   `golden.contains(<constant known to be in the golden>)` as the load-bearing half. Parity
   anchors are **extracted from the independent golden's `visibleText`**, not written inline as
   constants that duplicate the renderer's own literals.
6. **TOOLCHAIN REALITY.** This repo has **no Swift toolchain** in the web/dev environment;
   red→green cannot be observed here. Observation is the **MANUAL macOS GATE** below. Both
   "observed RED for the stated reason" and "observed GREEN" are explicit human sign-off steps
   (PLAN PROGRESS LEDGER), and the STATIC SAFEGUARD CHECKLIST must be run to catch silent-pass
   patterns even before a Mac run.

---

## RED-FIRST PROTOCOL

For each task, in order:
1. **Author** the gating tests in the correct `Tests/<Target>` file (see per-package layout).
2. **Observe RED on macOS** — run the package suite and confirm the failure matches the test's
   recorded **expected RED reason** (a named undefined symbol, or the concrete wrong value). If
   it fails for a *different* reason, the test is wrong — fix the test, not the code.
3. **Sign off** the "Tests RED observed" ledger cell.
4. Only then write the production code (PLAN task steps).
5. **Observe GREEN on macOS**; re-run `T-PARITY-01/02/03`; run the STATIC SAFEGUARD CHECKLIST;
   sign off "Tests GREEN observed" + "Parity OK".

**Justified standing guards (no pre-impl RED — RED-FIRST RULE exception, documented):**
- **`T-VOICE-02`** — `AssistantVoiceProfile.registerNotes` is the only surface and
  `GeneratedLetter` has no structural field **at HEAD**, so this test is GREEN from the start.
  It is a regression guard that fails only if a *future* structural field is added (invariant 3);
  it carries **no** pre-implementation RED reason and must not be treated as one.
- **`T-FLOOR-02`** (idempotence) — cannot, alone, prove the clamp does anything (a no-op
  `clampedToFloor(){ return self }` also passes). It is meaningful only because siblings
  `T-FLOOR-01/03/04` raise below-floor values and would catch a no-op. It is seeded with a
  **slightly-above-floor** value and asserts unchanged, so idempotence is tested independently of
  the raise tests; its RED is only the undefined-symbol compile error. This dependency is stated
  so `T-FLOOR-02` is never treated as a standalone clamp proof.

## MANUAL macOS OBSERVATION GATE (exact commands)

No root `Package.swift` exists (R1); each package is standalone (`CONTRIBUTING.md:49–50`).

```bash
# Foundation (DTO, resolver, floor, defaults):
cd Packages/SupraDraftingCore && swift test

# Renderer wire-proofs + parity:
cd Packages/SupraExports && swift test

# Controller, persistence, exemplar parse:
cd Packages/SupraSessions && swift test

# Voice (Track B) type surface:
cd Packages/SupraDrafting && swift test
```

Beta toolchain variant (`CONTRIBUTING.md:58`):
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test`. The whole suite must
run with **zero failures across all packages** (`CONTRIBUTING.md:61`). No GitHub Actions runs
`swift test` (R1) — enforcement is local/reviewer.

## STATIC SAFEGUARD CHECKLIST (run before every Mac run)

Concrete greps that mechanically catch each silent-pass footgun this plan is exposed to
(short-token absence contamination, fixture-shape mismatch, impossible non-default enum) — before
a toolchain is even available:

| # | Footgun | Detection grep / lint | Expected clean result |
|---|---|---|---|
| 1 | Lifted-literal under `.defaultFL` with no non-default proof | For each field in the §4.2 table run `rg -n "\$0\.<field> *=" Packages/SupraExports/Tests` — every field name must return ≥1 assignment site (a wire-proof that sets a non-default). Maintain the per-field list from §4.2 and diff it against the grep hits. | every §4.2 field has ≥1 `$0.<field> =` wire-proof site |
| 2 | Whole-doc **absence** assert on a short/shared token | `rg -n 'XCTAssertFalse\(.*contains\("[^"]{1,6}"' Packages/SupraExports/Tests` — any hit means an absence-assert on a ≤6-char token (e.g. `v.`, `/`, `Re:`, `<w:b/>`). Rewrite to the exact `<w:t xml:space="preserve">…</w:t>` element or a paragraph-scoped fragment. | no hits (all absence-asserts use exact `<w:t>` elements or scoped fragments) |
| 3 | Wire-proof run against a fixture lacking the emitting block | Review the **Wire-proof → required model block** table below; every wire-proof Test ID must name a fixture whose model contains the block that emits its token. | table has no "fixture lacks block" row |
| 4 | Non-default value that does not exist (single-case enum) | `rg -n 'enum NumberFormat' -A6 Packages/SupraDraftingCore/Sources` must show **≥2 cases** whenever a `numberFormat` wire-proof (T-BODY-01) exists. | `NumberFormat` has ≥2 cases |
| 5 | `guard case … else { return }` without `XCTFail` | `rg -n 'guard (case\|let).*else \{ *return *\}' Packages/*/Tests` | no hits |
| 6 | Unawaited async result | `rg -n '= *await ' Packages/SupraSessions/Tests` cross-checked that the result is asserted (not `_ =`) | no `_ = await controller.draft` |
| 7 | `try` without assert | `rg -n 'let .* = try .*documentXML' Packages/*/Tests` and verify a following `XCTAssert` | every render has an assertion |
| 8 | Golden regenerated from code under test | `rg -n 'write\|Data\(.*\).write' Packages/*/Tests Docs/Fixtures` | no test writes into `Docs/Fixtures` |
| 9 | Tautological golden assertion | `rg -n 'golden.contains' Packages/SupraExports/Tests` — the load-bearing half must be `renderText.contains(anchorExtractedFromGolden)`; the golden's own literal must not be duplicated inline | golden-only / inline-constant asserts flagged |
| 10 | `contains("")` / self-comparison | `rg -n 'contains\(""\)\|XCTAssertEqual\((\w+), \1\)' Packages/*/Tests` | no hits |
| 11 | Non-`test`-prefixed method | `rg -n 'func [a-z].*\(\) (async )?throws' Packages/*/Tests | rg -v 'func test'` (exclude helpers) | only helpers, no orphan cases |

**Wire-proof → required model block (checklist #3 reference table).** Each wire-proof must run on
a fixture whose model contains the emitting block; otherwise the "custom present" half can never
fire:

| Wire-proof | Required model block | Fixture in this plan |
|---|---|---|
| T-CAP-01/02/03/04/06/07/08 | caption table (always present) | `noticeModel` |
| T-CAP-05 (judgeLabel) | non-nil `caption.judge` | `judgeCaptionModel` |
| T-SIG-03 (submittedLabel) | non-nil `respectfullySubmitted` | `motionModel` |
| T-SIG-08 primary-only branch | signature with **empty** `emails.secondary` | `noSecondaryEmailModel` |
| T-BODY-01 (numberFormat) | `.numberedAllegation` | `motionModel` |
| T-BODY-02 (baseIndent) | `.numberedAllegation` + `.pointHeading` | `motionModel` |
| T-BODY-03 (spaceAfter) | `.pointHeading` | `motionModel` |
| T-LH-09 (bodyParagraphStyle) | letter body paragraph (always present) | `letterModel` |

---

## Test taxonomy

- **(i) default-PARITY** (`T-PARITY-*`) — empty profile ⇒ frozen baseline (no-drift) **and**
  independent Word-golden `visibleText` containment; catches byte drift.
- **(ii) WIRE-PROOF** (`T-CAP/LH/SIG/CERT/BODY/CTRL/VOICE-*`) — non-default value; assert custom
  present **AND** default absent, at exact-`<w:t>`-element or paragraph scope. The primary
  defense against the #1 footgun.
- **(iii) INVARIANT** — `T-FLOOR-*` (floor un-overridable), `T-CODEC-*` (round-trip + missing-key
  migration), `T-PARSE-06` (identity slot-only), `T-PARSE-08` (exemplar-never-in-prompt),
  `T-VOICE-02` (no model-originated structure — standing guard).
- **(iv) exemplar-PARSE** (`T-PARSE-01..05,07,09,10`) — extraction → structured fields → review;
  malformed/partial fallback; image/`needsOCR` path.
- **(v) CONTROLLER-wiring** (`T-CTRL-*`, `T-PERSIST-*`) — effective sheet reaches
  `runNotice`/`runLetter`; autosave.
- **(vi) Track-B VOICE** (`T-VOICE-*`).

---

## TEST CATALOG

Legend: **WP?** = wire-proof (non-default value used). Assertions cite real WML anchors from the
existing suites (`CourtFLRendererTests`, `LetterheadRendererTests`) where known. Every renderer
`<w:t>` run is emitted with `xml:space="preserve"` (`Ooxml/OoxmlWriter.swift:79`,
**unconditional**), which is why exact-element assertions take the form
`<w:t xml:space="preserve">…</w:t>`.

### M1 — Foundation (SupraDraftingCoreTests, plain `import SupraDraftingCore`)

| Test ID | Method | Target | Fixture | Assertion(s) | Expected value | WP? | Expected RED reason | Gates | SPEC § |
|---|---|---|---|---|---|---|---|---|---|
| T-CODEC-01 | `testEmptyProfileCodableRoundTrips` | `FirmStyleProfile` | empty profile | encode→decode→`==` | equal | N | undefined symbol `FirmStyleProfile` | M1-T1 | §4.1, §10 |
| T-CODEC-02 | `testPopulatedProfileCodableRoundTrips` | `FirmStyleProfile` | all fields set | encode→decode→`==` | equal | N | undefined symbol | M1-T1 | §4.4, §10 |
| T-CODEC-03 | `testLowerSchemaVersionMissingKeysDecodeToDefaults` | `init(from:)` | JSON `{"schemaVersion":0}` | `decode` does **not** throw; new keys `nil`; `schemaVersion` stamped to 1 | nil fields, v1 | N | decode throws / undefined | M1-T1 | §4.4 |
| T-CODEC-04 | `testClauseTextMapRoundTrips` | `certificateClauseText` | `[.flEPortal:"X"]` | encode→decode→`==`; key is enum rawValue | equal | N | undefined member | M1-T1 | §4.1, §10 |
| T-RESOLVE-01 | `testEmptyProfileResolvesToDefaultFL` | `resolved(over:)` | empty profile | `FirmStyleProfile().resolved(over:.defaultFL) == HouseStyleSheet.defaultFL` | equal | N | undefined method `resolved` | M1-T2 | §4.1, §10 (inv. 5) |
| T-RESOLVE-02 | `testSingleOverlayLandsAndLeavesOthers` | `resolved(over:)` | `captionPartySeparator="vs."` | resolved `.caption.partySeparator=="vs."`; `.caption.caseNumberLabel` unchanged | `vs.` / `CASE NO.: ` | Y (`vs.`) | undefined member | M1-T2 | §4.1 |
| T-DEFAULT-01 | `testNewFieldDefaultsEqualTodaysLiterals` | `HouseStyleSheet.defaultFL` | — | spot: `.caption.partySeparator=="v."`, `.signature.eSignature.mark=="/s/ "`, `.certificate.heading=="CERTIFICATE OF SERVICE"`, `.letterhead?.headerBlock.tagline=="Attorneys at Law"`, `.body.numberFormat==.numberDot` | literals | N | undefined member | M1-T4 | §4.2 |
| T-FLOOR-01 | `testClampRaisesFontAndMargins` | `clampedToFloor()` | 20 half-pt, 1080 twips all sides | after clamp: `fontHalfPoints==24`; every margin `==1440` | 24 / 1440 | Y (20/1080) | undefined method `clampedToFloor` | M1-T3 | §4.3 |
| T-FLOOR-02 | `testClampIsIdempotentSlightlyAboveFloor` | `clampedToFloor()` | 26 half-pt / 1500 twips (**above** floor) | clamp once == clamp twice == input (unchanged) | unchanged | N | undefined method | M1-T3 | §4.3 (inv. 1) |
| T-FLOOR-03 | `testClampIsPerSide` | `clampedToFloor()` | mixed `EdgeInsets` (top 1440, leading 720) | leading→1440, top stays 1440 | per-side | Y (720) | undefined method | M1-T3 | §4.3 |
| T-FLOOR-04 | `testBelowFloorProfileCannotOverrideFloor` | resolve+clamp | `pageFontHalfPoints=20, pageMarginTwips=720` | `profile.resolved().clampedToFloor().page.fontHalfPoints==24` and margins `==1440`; `!=20` | 24 / 1440 | Y (20/720) | assertion: font==20 (unclamped) | M1-T3 | §4.3 (inv. 1) |

### M1 — CourtFLRenderer wire-proofs (SupraExportsTests, `@testable import SupraExports`)

Each test builds `let style = { var p = FirmStyleProfile(); p.<field> = <non-default>; return p }().resolved(over:.defaultFL)`
and asserts at **exact-`<w:t>`-element** or **target-paragraph** scope. Fixtures are named per
row (per checklist #3): `noticeModel` (caption/signature/cert; judge nil; single-paragraph body),
`judgeCaptionModel` (caption with judge), `motionModel` (numbered allegations + point heading +
`respectfullySubmitted` date), `noSecondaryEmailModel` (signature with empty `emails.secondary`).
All are defined in the ready-to-paste harness below.

| Test ID | Method | Field (§4.2 #) | Fixture | Non-default | Assert present (exact) | Assert absent (exact) | WP? | Expected RED reason | Gates | SPEC § |
|---|---|---|---|---|---|---|---|---|---|---|
| T-CAP-01 | `testPartySeparatorIsWired` | partySeparator (#8) | noticeModel | `"vs."` | `<w:t xml:space="preserve">vs.</w:t>` | `<w:t xml:space="preserve">v.</w:t>` | Y | exact `>v.<` run present | M1-T5 | §4.2 |
| T-CAP-02 | `testClosingRuleGlyphIsWired` | closingRuleGlyph (#9) | noticeModel | `"§"` | `<w:t xml:space="preserve">§</w:t>` | `<w:t xml:space="preserve">/</w:t>` (glyph run) | Y | exact `>/<` glyph run present | M1-T5 | §4.2 |
| T-CAP-03 | `testCaseNumberLabelIsWired` | caseNumberLabel (#10) | noticeModel | `"CASE NUMBER: "` | `"CASE NUMBER: 2026-CA-001847"` | `<w:t xml:space="preserve">CASE NO.: 2026-CA-001847</w:t>` | Y | `CASE NO.:` run present | M1-T5 | §4.2 |
| T-CAP-04 | `testDivisionLabelIsWired` | divisionLabel (#11) | noticeModel | `"DIV: "` | `<w:t xml:space="preserve">DIV: CV-G</w:t>` | `<w:t xml:space="preserve">DIVISION: CV-G</w:t>` | Y | `DIVISION:` run present | M1-T5 | §4.2 |
| T-CAP-05 | `testJudgeLabelIsWired` | judgeLabel (#12) | **judgeCaptionModel** (judge="Hon. Jane Roe") | `"J.: "` | `<w:t xml:space="preserve">J.: Hon. Jane Roe</w:t>` | `<w:t xml:space="preserve">JUDGE: Hon. Jane Roe</w:t>` | Y | `JUDGE:` run present | M1-T5 | §4.2 |
| T-CAP-06 | `testDesignationIndentIsWired` | designationIndentTwips (#13) | noticeModel (caption-only; **no** level-1 point heading) | `1000` | designation paragraph fragment has `w:left="1000"` | same paragraph `w:left="720"` | Y | 720 on designation para present | M1-T5 | §4.2 |
| T-CAP-07 | `testHeaderBoldCenteredToggleIsWired` | headerBoldCentered (wire-up) | noticeModel | `false` | court-header paragraph fragment (contains `"IN THE CIRCUIT COURT"`) has **no** `<w:b/>` and **no** `<w:jc w:val="center"/>` | those runs present in that paragraph | Y | header paragraph still `<w:b/>`+center | M1-T5 | §4.2 |
| T-CAP-08 | `testClosingRuleEndsInSlashToggleIsWired` | closingRuleEndsInSlash (wire-up) | noticeModel | `false` | caption still present (`CASE NO.: 2026-CA-001847`) | closing-rule glyph run `<w:t xml:space="preserve">/</w:t>` absent | Y | `>/<` glyph run present | M1-T5 | §4.2 |
| T-SIG-01 | `testESignatureMarkIsWired` | mark (#14) | noticeModel | `"s/ "` | `<w:t xml:space="preserve">s/ Harvey Specter</w:t>` | `<w:t xml:space="preserve">/s/ Harvey Specter</w:t>` | Y | `/s/ …` run present | M1-T5 | §4.2 |
| T-SIG-02 | `testByPrefixIsWired` | byPrefix (#15) | noticeModel | `"BY: "` | `<w:t xml:space="preserve">BY: </w:t>` | `<w:t xml:space="preserve">By: </w:t>` | Y | `By: ` run present | M1-T5 | §4.2 |
| T-SIG-03 | `testSubmittedLabelIsWired` | submittedLabel (#16) | **motionModel** (`respectfullySubmitted` set) | `"Respectfully yours: "` | `<w:t xml:space="preserve">Respectfully yours: June 25, 2026</w:t>` | `<w:t xml:space="preserve">Respectfully submitted: June 25, 2026</w:t>` | Y | old submitted run present | M1-T5 | §4.2 |
| T-SIG-04 | `testRepresentationPrefixIsWired` | representationPrefix (#17) | noticeModel | `"Counsel for "` | `<w:t xml:space="preserve">Counsel for Defendant</w:t>` | `<w:t xml:space="preserve">Attorneys for Defendant</w:t>` | Y | `Attorneys for Defendant` present | M1-T5 | §4.2 |
| T-SIG-05 | `testBarNumberLabelAppliesOnlyToBareNumbers` (revised per PR #50 review) | barNumberLabel (#18) | noticeModel (pre-labeled) + bare-number variant (`barNumber: "100847"`) | `"Fla. Bar No. "` | bare: `<w:t xml:space="preserve">Fla. Bar No. 100847</w:t>`; pre-labeled: `<w:t xml:space="preserve">Florida Bar No. 100847</w:t>` unchanged | pre-labeled: `Fla. Bar No. Florida Bar No.` (no double prefix); bare: `<w:t xml:space="preserve">100847</w:t>` | Y | pre-labeled render carries the duplicated prefix | M1-T5 | §4.2 |
| T-SIG-06 | `testSignaturePhoneLabelIsWired` | phoneLabel (#19) | noticeModel | `"Tel: "` | `<w:t xml:space="preserve">Tel: (904) 555-0142</w:t>` | `<w:t xml:space="preserve">Telephone: (904) 555-0142</w:t>` | Y | `Telephone:` run present | M1-T5 | §4.2 |
| T-SIG-07 | `testSignatureFaxLabelIsWired` | faxLabel (#20) | noticeModel | `"Fax: "` | `<w:t xml:space="preserve">Fax: (904) 555-0143</w:t>` | `<w:t xml:space="preserve">Facsimile: (904) 555-0143</w:t>` | Y | `Facsimile:` run present | M1-T5 | §4.2 |
| T-SIG-08 | `testEmailLabelsAreWired` | emailLabel/WithSecondary (#21) | **two renders:** noticeModel (secondary present) + noSecondaryEmailModel (primary-only) | `"E1/E2: "` / `"E: "` | render1 `<w:t xml:space="preserve">E1/E2: </w:t>`; render2 `<w:t xml:space="preserve">E: </w:t>` | render1 `Primary and Secondary E-Mail: `; render2 `Primary E-Mail: ` | Y | old email labels present (each branch) | M1-T5 | §4.2 |
| T-SIG-09 | `testFirmNameBoldCapsToggleIsWired` | firmNameBoldCaps (wire-up) | noticeModel | `false` | firm-name paragraph fragment (first paragraph containing `"Pearson Specter Litt"`) has **no** `<w:b/>` and **no** `<w:caps/>` | those runs present in that paragraph | Y | firm-name para still bold-caps | M1-T5 | §4.2 |
| T-SIG-10 | `testRepresentationLineItalicToggleIsWired` | representationLineItalic (wire-up) | noticeModel | `false` | representation-line paragraph (contains `"Attorneys for Defendant"`) has **no** `<w:i/>` | `<w:i/>` present in that paragraph | Y | rep-line para still italic | M1-T5 | §4.2 |
| T-CERT-01 | `testCertificateHeadingIsWired` | heading (#22) | noticeModel | `"CERTIFICATE OF SVC"` | `<w:t xml:space="preserve">CERTIFICATE OF SVC</w:t>` | `<w:t xml:space="preserve">CERTIFICATE OF SERVICE</w:t>` | Y | old heading run present | M1-T5 | §4.2 |
| T-CERT-02 | `testAttestationPrefixSuffixWiredMiddleConnectivePreserved` | attestationPrefix/Suffix (#23) | noticeModel | prefix `"I CERTIFY on "`, suffix `" upon:"` | run contains `"I CERTIFY on June 25, 2026, I "` … `" upon:"` (middle `, I ` preserved) | `"I HEREBY CERTIFY that on "` | Y | old prefix present / middle dropped | M1-T5 | §4.2 |
| T-CERT-03 | `testClauseTextOverrideIsWired` | clauseText (#24) | noticeModel | `[.flEPortal:"CUSTOM CLAUSE"]` | `"CUSTOM CLAUSE"` | built-in e-portal sentence (`"electronically filed the foregoing with the Clerk of Court using the Florida Courts E-Filing Portal"`) | Y | boilerplate present | M1-T5 | §4.2 |
| T-CERT-04 | `testCertificateHeadingBoldCapsToggleIsWired` | headingCenteredBoldCaps (wire-up) | noticeModel | `false` | certificate-heading paragraph (contains `"CERTIFICATE OF SERVICE"`) has **no** `<w:b/>`, `<w:caps/>`, `<w:jc w:val="center"/>` | those runs present in that paragraph | Y | heading para still bold-caps-center | M1-T5 | §4.2 |
| T-BODY-01 | `testNumberFormatIsWired` | numberFormat (#25) | **motionModel** (`.numberedAllegation`) | `.numberParen` | `<w:t xml:space="preserve">1)</w:t>` | `<w:t xml:space="preserve">1.</w:t>` | Y | `1.` run present | M1-T5 | §4.2 |
| T-BODY-02 | `testHeadingBaseIndentIsWired` | baseIndentTwips (#26–28) | **motionModel** (`.numberedAllegation`+`.pointHeading`) | `1000` | point-heading paragraph fragment has `w:left="1000"` / `w:pos="1000"` | `w:left="720"` / `w:pos="720"` at those sites | Y | 720 at heading sites present | M1-T5 | §4.2 |
| T-BODY-03 | `testHeadingSpaceAfterIsWired` | spaceAfterTwips (#29) | **motionModel** (`.pointHeading`) | `360` | point-heading paragraph fragment has `w:after="360"` | `w:after="240"` in that paragraph | Y | 240 present | M1-T5 | §4.2 |
| T-BODY-04 | `testBodyJustifyOverlaySuppressesJustification` | bodyJustify (existing overlay) | noticeModel | `false` | body paragraph (contains the body text) has **no** `<w:jc w:val="both"/>` | `<w:jc w:val="both"/>` in that paragraph | Y | **compile: undefined `FirmStyleProfile.bodyJustify`** | **M1-T2/M1-T4** | §4.2 |

> **T-BODY-04 note (RED-FIRST RULE).** The renderer **already** reads `style.body.justify`
> (`CourtFLRenderer.swift:157` and `:165`) — `justify` is not a lifted literal (it is the
> "existing bodyJustify overlay", not a §4.2 numbered row). Once the `FirmStyleProfile.bodyJustify`
> field (M1-T4) and `resolved(over:)` (M1-T2) exist, setting `justify=false` suppresses
> `<w:jc w:val="both"/>` with **no CourtFLRenderer change**. Its true RED is therefore the
> **undefined member `FirmStyleProfile.bodyJustify`** observed at M1-T2/M1-T4 — **not** a renderer
> lift and **not** "still justified" at M1-T5. It is removed from M1-T5's gating set and gates
> M1-T2/M1-T4 instead.

> **T-SIG-05 note (revised per PR #50 review).** `barNumber` arrives at the renderer ALREADY
> labeled: `NoticeAppearance.assemble` composes `"\(profile.barLabel) \(profile.barNumber)"` into
> the slot (`"Florida Bar No. 100847"`). An unconditional style prefix would therefore duplicate
> the jurisdiction label (`"Fla. Bar No. Florida Bar No. 100847"`). The renderer applies
> `barNumberLabel` **only when the slot is a bare number** (first character is a digit), so the
> wire-proof uses a bare-number fixture; the pre-labeled fixture doubles as the no-double-prefix
> regression guard. Default parity is unaffected (`barNumberLabel` defaults to `""`).

### M1 — LetterheadRenderer wire-proofs (SupraExportsTests, `@testable`)

Fixture `letterModel` = the shared `LetterheadRendererTests` fixture (tagline `Attorneys at Law`,
`RE:`, `Enclosure: `, `cc:  `). Style built from a non-default `FirmStyleProfile` via
`resolved(over:.defaultFL)`.

| Test ID | Method | Field (§4.2 #) | Non-default | Assert present (exact) | Assert absent (exact) | WP? | Expected RED reason | Gates | SPEC § |
|---|---|---|---|---|---|---|---|---|---|
| T-LH-01 | `testTaglineIsWired` | tagline (#1) | `"Counselors at Law"` | `<w:t xml:space="preserve">Counselors at Law</w:t>` | `<w:t xml:space="preserve">Attorneys at Law</w:t>` | Y | `Attorneys at Law` present | M1-T6 | §4.2 |
| T-LH-02 | `testLetterheadPhoneLabelIsWired` | phoneLabel (#2) | `"Tel: "` | masthead run contains `"Tel: (904) 555-0142"` | `"Telephone: (904) 555-0142"` masthead run | Y | `Telephone:` present | M1-T6 | §4.2 |
| T-LH-03 | `testLetterheadFaxLabelIsWired` | faxLabel (#3) | `"Fax: "` | masthead run contains `"Fax: (904) 555-0143"` | `"Facsimile: (904) 555-0143"` masthead run | Y | `Facsimile:` present | M1-T6 | §4.2 |
| T-LH-04 | `testRELabelIsWired` | reLabel (#4) | `"Re:"` | `<w:t xml:space="preserve">Re:</w:t>` | `<w:t xml:space="preserve">RE:</w:t>` (i.e. `>RE:<`) | Y | `RE:` run present | M1-T6 | §4.2 |
| T-LH-05 | `testREIndentHangingWired` | reIndent/Hanging (#5) | `1000/300` | contiguous pair `w:left="1000" w:hanging="300"` | contiguous pair `w:left="1440" w:hanging="720"` | Y | 1440/720 pair present | M1-T6 | §4.2 |
| T-LH-06 | `testEnclosurePrefixIsWired` | enclosurePrefix (#6) | `"Encl: "` | `<w:t xml:space="preserve">Encl: Statement of Unpaid Invoices</w:t>` | `<w:t xml:space="preserve">Enclosure: Statement of Unpaid Invoices</w:t>` | Y | `Enclosure:` run present | M1-T6 | §4.2 |
| T-LH-07 | `testCCPrefixIsWired` | ccPrefix (#7) | `"copy to: "` | `<w:t xml:space="preserve">copy to: McKernon Motors</w:t>` | `<w:t xml:space="preserve">cc:  McKernon Motors</w:t>` | Y | `cc:  ` run present | M1-T6 | §4.2 |
| T-LH-08 | `testBottomRuleToggleIsWired` | bottomRule (wire-up) | `false` | date paragraph still present | masthead-rule paragraph `<w:pBdr><w:bottom w:val="single"` absent | Y | rule paragraph present | M1-T6 | §4.2 |
| T-LH-09 | `testLetterheadParagraphStyleIsWired` | bodyParagraphStyle (wire-up) | `.indented` | body paragraph fragment (contains `"This firm represents McKernon Motors."`) has `<w:ind w:firstLine="720"/>` | no `w:firstLine` in that body paragraph (block form) | Y | body paragraph has no first-line indent | M1-T6 | §4.2, §4.1 (bodyParagraphStyle wire-up, PLAN M1-T6) |

> **T-LH-09 note.** `bodyParagraphStyle` is an **in-scope renderer wire-up** grounded in PLAN
> M1-T6 (LetterheadRenderer body paragraph, ~line 84): `.indented` ⇒ `<w:ind w:firstLine="720"/>`,
> `.block` (default) ⇒ none. M1-T6's touched-line list includes line 84 for this read, so the
> test gates work the edit list covers. `bodyParagraphStyle` is therefore a **live** field, not a
> dead one; only `letterhead.dateFormat` remains the documented dead field.

> **T-LH-05 note.** `w:left="1440"` alone is contaminated — the letter signature block also
> indents (`signatureIndentTwips`) — so the absence assert must target the **contiguous
> attribute pair** `w:left="1440" w:hanging="720"`, which only the RE paragraph carries (it is the
> sole element with a hanging indent). Verify `ParaProps` emits `w:left` then `w:hanging`
> contiguously in that order.

### M1 — Parity (SupraExportsTests)

Parity uses **both** oracles: the pre-lift `*-baseline.wml.txt` for byte no-drift, **and** the
independent Word-roundtripped `*-golden.document.xml` for `visibleText` containment. Anchors are
**extracted from the golden's `visibleText`** (not written inline), so the independent golden is
load-bearing (TAUTOLOGY BAN).

| Test ID | Method | Fixture | Assertion | Expected | WP? | Expected RED reason | Gates | SPEC § |
|---|---|---|---|---|---|---|---|---|
| T-PARITY-01 | `testNoticeEmptyProfileMatchesFrozenBaseline` | `noticeModel`, `noticeAppearance-baseline.wml.txt` + `noticeAppearance-golden.document.xml` | render under `FirmStyleProfile().resolved(over:.defaultFL).clampedToFloor()`; normalized WML `==` M1-T0 baseline; **and** every non-empty line of `visibleText(golden)` is contained in `visibleText(render)` (anchors extracted from the golden, covering each lifted string literal, not three inline constants) | equal / all golden lines present | N | undefined `resolved`/`clampedToFloor` | M1-T5 | §10 (inv. 5) |
| T-PARITY-02 | `testLetterEmptyProfileMatchesFrozenBaseline` | `letterModel`, `letterDemand-baseline.wml.txt` + `letterDemand-golden.document.xml` | normalized WML `==` baseline; **and** `visibleText(render)` contains every non-empty line of `visibleText(letterDemand-golden.document.xml)` | equal / all golden lines present | N | undefined method | M1-T6 | §10 |
| T-PARITY-03 | `testMotionEmptyProfileMatchesFrozenBaseline` | `motionModel`, `motionToDismiss-baseline.wml.txt` + `motionToDismiss-golden.document.xml` (wires the currently-unused fixtures, R1 §4.5) | normalized WML `==` baseline; **and** `visibleText(render)` contains every non-empty line of `visibleText(motionToDismiss-golden.document.xml)` | equal / all golden lines present | N | undefined method | M1-T5 | §10 |

### M1 — Controller wiring (SupraSessionsTests, `@testable import SupraSessions`; `@MainActor async throws`)

Setup mirrors `MatterDraftingControllerTests` (R1 §2): UUID-temp `SupraStore` + `DocumentStorage`,
`completeProfile()`, a **spy** pipeline capturing the `style:` argument. M1-T7 injects the **raw**
`firmStyleProfile: FirmStyleProfile?` and `effectiveStyle()` is `internal` (reachable via
`@testable`).

| Test ID | Method | Target | Assertion | Expected | WP? | Expected RED reason | Gates | SPEC § |
|---|---|---|---|---|---|---|---|---|
| T-CTRL-01 | `testEffectiveStyleWithoutProfileIsDefaultFL` | `effectiveStyle()` | no `firmStyleProfile` injected ⇒ `effectiveStyle() == HouseStyleSheet.defaultFL` | equal | N | undefined member `effectiveStyle`/`firmStyleProfile` | M1-T7 | §6 (inv. 5) |
| T-CTRL-02 | `testNoticePassesEffectiveStyleToRunNotice` | `draftNoticeOfAppearance` | inject profile w/ `captionCaseNumberLabel="CASE NUMBER: "`; `await` draft; spy-captured `style.caption.caseNumberLabel=="CASE NUMBER: "` **and** `!= "CASE NO.: "` | custom / not default | Y | captured style still `.defaultFL` | M1-T7 | §6 |
| T-CTRL-03 | `testLetterPassesEffectiveStyleToRunLetter` | `draftLetterDemand` | inject profile w/ `letterheadTagline="Counselors at Law"`; `await`; spy `style.letterhead?.headerBlock.tagline=="Counselors at Law"` and `!= "Attorneys at Law"` | custom / not default | Y | captured tagline default | M1-T7 | §6 |
| T-CTRL-04 | `testBelowFloorProfileClampedThroughController` | `effectiveStyle()` | profile `pageFontHalfPoints=20` ⇒ `effectiveStyle().page.fontHalfPoints==24` (called directly on the controller — `internal` reachable via `@testable`) | 24 | Y (20) | captured font==20 | M1-T7 | §4.3 (inv. 1) |

### M2 — Persistence (SupraSessionsTests, `@testable`; `@MainActor`)

| Test ID | Method | Target | Assertion | Expected | WP? | Expected RED reason | Gates | SPEC § |
|---|---|---|---|---|---|---|---|---|
| T-PERSIST-01 | `testAbsentProfileLoadsDefaultResolvingToDefaultFL` | `FirmStyleProfileController(store:)` | fresh store ⇒ `controller.profile == FirmStyleProfile()`; `resolved()==.defaultFL` | default | N | undefined type | M2-T1 | §4.4 |
| T-PERSIST-02 | `testEditAutosavesAndReloads` | `@Published profile.didSet` | set `profile.captionJudgeLabel="J: "`; new controller on **same** store reloads it | persisted | Y (`J: `) | value not persisted | M2-T1 | §4.4 |
| T-PERSIST-03 | `testMessageSetOnlyOnWriteFailure` | `persist()` | inject failing store ⇒ `message != nil`; success ⇒ `message == nil` | conditional | N | undefined member | M2-T1 | §4.4 |

### M3 — Exemplar parse (SupraSessionsTests, `@testable`; `StubRuntimeClient` canned JSON)

| Test ID | Method | Fixture | Assertion | Expected | WP? | Expected RED reason | Gates | SPEC § |
|---|---|---|---|---|---|---|---|---|
| T-PARSE-01 | `testLetterheadExemplarMapsToCandidate` | canned `LetterheadExtraction` JSON (`tagline`,`reLabel`,`ccPrefix`) | candidate `.letterheadTagline`/`.letterheadRELabel`/`.letterheadCCPrefix` set; untouched fields `nil` | mapped | Y | undefined `FirmStyleExemplarParser` | M3-T2 | §5.2 |
| T-PARSE-02 | `testCaptionExemplarMapsToCandidate` | canned `CaptionExtraction` JSON | `.captionPartySeparator` etc. set | mapped | Y | undefined type | M3-T2 | §5.2 |
| T-PARSE-03 | `testSignatureExemplarMapsToCandidate` | canned `SignatureExtraction` JSON | `.signatureByPrefix` etc. set | mapped | Y | undefined type | M3-T2 | §5.2 |
| T-PARSE-04 | `testMalformedJSONTriggersSingleRepairThenSucceeds` | first answer non-JSON, repair answer valid | assert repair prompt **was** sent (spy on `StubRuntimeClient` prompt contains `"STRICT JSON only"`); candidate populated | repaired | N | undefined / repair not sent | M3-T2 | §5.2, §5.4 |
| T-PARSE-05 | `testUnparseableAfterRepairFallsBackToManualEntry` | both answers non-JSON | candidate all-`nil`; **no** profile write (store unchanged) | manual fallback | N | profile mutated on bad parse | M3-T2 | §5.4 |
| T-PARSE-06 | `testIdentityContentIsNeverCaptured` | exemplar text `"Telephone: (305) 555-1212, John Q. Esq., FBN 12345"` | candidate captures `"Telephone: "` label; **no** `"555-1212"`, `"John Q"`, `"12345"` on any field | labels only | Y | number/name captured | M3-T2 | §5.4 (inv. 4) |
| T-PARSE-07 | `testEmptyExtractionShowsNoTextMessageNoWrite` | extractor returns empty `combinedText` | parser returns "No text was found…" message; store unchanged | no write | N | undefined / writes anyway | M3-T2 | §5.4 |
| T-PARSE-08 | `testExemplarTextNeverEntersDraftingPrompt` | run parse then `draftLetterDemand` via spy runtime | spy-captured drafting `request.prompt` does **not** contain the exemplar `combinedText`; profile has no field holding raw exemplar text | absent | N | exemplar text found in prompt | M3-T2 | §2, §5.2 (inv. 3) |
| T-PARSE-09 | `testPreviewIsDeterministic` | candidate sheet | render sample twice ⇒ identical bytes (`Array(data.prefix(2))==[0x50,0x4B]` + full `==`) | equal | N | undefined preview builder | M3-T3 | §5.3, §10 |
| T-PARSE-10 | `testImageOnlyLetterheadSurfacesAdvisoryNoImageBytes` | extraction flagged `needsOCR` / image-only, OCR text `"Attorneys at Law"` (if any) | parser surfaces advisory containing `"letterhead text but not a logo image"`; OCR text (if present) mapped to `.letterheadTagline`; **no image bytes stored on the candidate profile** (no `Data`/image field populated) | advisory + text-only, no bytes | N | undefined / image bytes stored or advisory missing | M3-T2 | §5.4 |

### M4 — Track B voice (SupraSessionsTests `@testable` + SupraDraftingTests plain)

| Test ID | Method | Target | Assertion | Expected | WP? | Expected RED reason | Gates | SPEC § |
|---|---|---|---|---|---|---|---|---|
| T-VOICE-01 | `testRegisterNotesEnrichedFromAssistantProfile` | `toneRegister`/voice build (`:290`) | set `AssistantProfile.voiceNotes="terse, aggressive"`; built `AssistantVoiceProfile.registerNotes` **contains** `"terse"`; for an empty profile it does **not** | enriched / not | Y (`terse`) | registerNotes lacks voiceNotes | M4-T1 | §8 |
| T-VOICE-02 | `testVoiceCarriesNoStructure` | `AssistantVoiceProfile`, `GeneratedLetter` | reflect/enumerate: `AssistantVoiceProfile` surface is only `registerNotes: String`; `GeneratedLetter` fields are `paragraphs`/`assertedFacts`/`citesUsed` only | no structural field | N | **standing guard, GREEN-from-HEAD (justified)** — fails only on a future structural-field regression | M4-T1 | §1, §8 (inv. 3) |

> **T-VOICE-02 note (RED-FIRST RULE exception).** `AssistantVoiceProfile.registerNotes` is the
> sole surface (`Generation.swift:25–27`) and `GeneratedLetter` has only
> `paragraphs`/`assertedFacts`/`citesUsed` (`DraftingCore.swift:769`) **at HEAD**, so this test is
> GREEN from the start; M4-T1 adds **no** structural field. It is therefore a **standing
> invariant/regression guard**, not a pre-implementation RED test — it carries no observable RED
> reason and exists to fail only if a future change adds a structural field. Its "Tests RED
> observed" ledger cell is `n/a (justified)`.

---

## Ready-to-paste M1 FOUNDATION + WIRE-PROOF harness

> These compile **only once the M1 types exist** — that is their RED-first state. Author them
> now; the recorded RED reason for each is a **named undefined symbol** (`FirmStyleProfile`,
> `resolved(over:)`, `clampedToFloor`, `NumberFormat.numberParen`) or the concrete wrong value
> noted inline.

### `Packages/SupraDraftingCore/Tests/SupraDraftingCoreTests/FirmStyleProfileTests.swift`

```swift
import Foundation
import SupraDraftingCore
import XCTest

/// FOUNDATION — Codable round-trip, resolver identity/overlay, floor clamp, default parity.
/// RED-first: every method below fails to COMPILE until FirmStyleProfile / NumberFormat /
/// resolved(over:) / clampedToFloor() exist (SPEC §4.1, §4.3, §10).
final class FirmStyleProfileTests: XCTestCase {

    // T-CODEC-01 — empty profile round-trips. RED: undefined symbol `FirmStyleProfile`.
    func testEmptyProfileCodableRoundTrips() throws {
        let p = FirmStyleProfile()
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(FirmStyleProfile.self, from: data)
        XCTAssertEqual(p, back)
    }

    // T-CODEC-02 — fully-populated profile round-trips.
    func testPopulatedProfileCodableRoundTrips() throws {
        var p = FirmStyleProfile()
        p.captionPartySeparator = "vs."
        p.letterheadTagline = "Counselors at Law"
        p.signatureRepresentationPrefix = "Counsel for "
        p.bodyNumberFormat = .numberParen
        p.pageFontHalfPoints = 26
        p.pageMarginTwips = EdgeInsets(top: 1500, leading: 1500, bottom: 1500, trailing: 1500)
        p.certificateClauseText = [.flEPortal: "CUSTOM CLAUSE"]
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(FirmStyleProfile.self, from: data)
        XCTAssertEqual(p, back)
    }

    // T-CODEC-03 — lower schemaVersion + missing keys decode to nil/defaults, do NOT throw.
    // RED: decode throws (no resilient init(from:)) OR undefined symbol.
    func testLowerSchemaVersionMissingKeysDecodeToDefaults() throws {
        let json = Data(#"{"schemaVersion":0}"#.utf8)
        let p = try JSONDecoder().decode(FirmStyleProfile.self, from: json)
        XCTAssertNil(p.captionPartySeparator)
        XCTAssertNil(p.letterheadTagline)
        XCTAssertEqual(p.schemaVersion, FirmStyleProfile.currentSchemaVersion) // stamped to 1
    }

    // T-CODEC-04 — [ServiceMethodClause:String] map round-trips on enum rawValue keys.
    func testClauseTextMapRoundTrips() throws {
        var p = FirmStyleProfile()
        p.certificateClauseText = [.flEPortal: "X"]
        let back = try JSONDecoder().decode(
            FirmStyleProfile.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(back.certificateClauseText?[.flEPortal], "X")
    }

    // T-RESOLVE-01 — empty profile resolves to .defaultFL EXACTLY (invariant 5, SPEC §4.1).
    // RED: undefined method `resolved(over:)`.
    func testEmptyProfileResolvesToDefaultFL() {
        XCTAssertEqual(FirmStyleProfile().resolved(over: .defaultFL), HouseStyleSheet.defaultFL)
    }

    // T-RESOLVE-02 — single overlay lands; off-target field untouched. WIRE-PROOF at merge layer.
    func testSingleOverlayLandsAndLeavesOthers() {
        var p = FirmStyleProfile()
        p.captionPartySeparator = "vs."
        let s = p.resolved(over: .defaultFL)
        XCTAssertEqual(s.caption.partySeparator, "vs.")                 // custom present
        XCTAssertNotEqual(s.caption.partySeparator, "v.")               // default absent
        XCTAssertEqual(s.caption.caseNumberLabel, "CASE NO.: ")         // off-target untouched
    }

    // T-DEFAULT-01 — new field defaults equal today's literals (§4.2). Supporting, NOT a wiring proof.
    func testNewFieldDefaultsEqualTodaysLiterals() {
        let d = HouseStyleSheet.defaultFL
        XCTAssertEqual(d.caption.partySeparator, "v.")
        XCTAssertEqual(d.signature.eSignature.mark, "/s/ ")
        XCTAssertEqual(d.certificate.heading, "CERTIFICATE OF SERVICE")
        XCTAssertEqual(d.letterhead?.headerBlock.tagline, "Attorneys at Law")
        XCTAssertEqual(d.body.numberFormat, .numberDot)
    }

    // T-FLOOR-01 — clamp raises 20→24 half-pt and 1080→1440 twips per side (SPEC §4.3). WIRE-PROOF.
    // RED: undefined method `clampedToFloor()`.
    func testClampRaisesFontAndMargins() {
        var s = HouseStyleSheet.defaultFL
        s.page.fontHalfPoints = 20
        s.page.marginTwips = EdgeInsets(top: 1080, leading: 1080, bottom: 1080, trailing: 1080)
        let c = s.clampedToFloor()
        XCTAssertEqual(c.page.fontHalfPoints, 24)
        XCTAssertNotEqual(c.page.fontHalfPoints, 20)
        XCTAssertEqual(c.page.marginTwips.top, 1440)
        XCTAssertEqual(c.page.marginTwips.leading, 1440)
        XCTAssertEqual(c.page.marginTwips.bottom, 1440)
        XCTAssertEqual(c.page.marginTwips.trailing, 1440)
    }

    // T-FLOOR-02 — idempotent when seeded ABOVE the floor, so idempotence is meaningful
    // independent of the raise tests (a no-op impl also passes this — see RED-FIRST note; the
    // clamp's DO-something proof lives in T-FLOOR-01/03/04). RED: undefined method.
    func testClampIsIdempotentSlightlyAboveFloor() {
        var s = HouseStyleSheet.defaultFL
        s.page.fontHalfPoints = 26                                            // 13 pt, above floor
        s.page.marginTwips = EdgeInsets(top: 1500, leading: 1500, bottom: 1500, trailing: 1500)
        XCTAssertEqual(s.clampedToFloor(), s)                                 // unchanged
        XCTAssertEqual(s.clampedToFloor().clampedToFloor(), s.clampedToFloor())
    }

    // T-FLOOR-03 — per-side clamp. WIRE-PROOF (leading below floor).
    func testClampIsPerSide() {
        var s = HouseStyleSheet.defaultFL
        s.page.marginTwips = EdgeInsets(top: 1440, leading: 720, bottom: 1440, trailing: 1440)
        let c = s.clampedToFloor()
        XCTAssertEqual(c.page.marginTwips.leading, 1440)  // raised
        XCTAssertNotEqual(c.page.marginTwips.leading, 720)
        XCTAssertEqual(c.page.marginTwips.top, 1440)      // untouched
    }

    // T-FLOOR-04 — a below-floor PROFILE cannot override the floor (invariant 1). WIRE-PROOF.
    func testBelowFloorProfileCannotOverrideFloor() {
        var p = FirmStyleProfile()
        p.pageFontHalfPoints = 20                                            // 10 pt
        p.pageMarginTwips = EdgeInsets(top: 720, leading: 720, bottom: 720, trailing: 720) // 0.5"
        let s = p.resolved(over: .defaultFL).clampedToFloor()
        XCTAssertEqual(s.page.fontHalfPoints, 24)   // custom-below-floor was clamped up
        XCTAssertNotEqual(s.page.fontHalfPoints, 20)
        XCTAssertEqual(s.page.marginTwips.leading, 1440)
    }
}
```

### `Packages/SupraExports/Tests/SupraExportsTests/FirmStyleWireProofTests.swift`

```swift
import Foundation
import SupraDraftingCore
@testable import SupraExports
import XCTest

/// WIRE-PROOF — each renders a NON-DEFAULT FirmStyleProfile value and asserts the customized
/// token IS present AND the default token IS absent, at EXACT-`<w:t>`-ELEMENT or TARGET-PARAGRAPH
/// scope (never a whole-document short/shared substring). Every renderer <w:t> run carries
/// xml:space="preserve" unconditionally (Ooxml/OoxmlWriter.swift:79), so exact runs take the
/// form <w:t xml:space="preserve">…</w:t>.
final class FirmStyleWireProofTests: XCTestCase {

    // MARK: - Shared fixtures (mirror CourtFLRendererTests / LetterheadRendererTests)

    private func captionModel(judge: String? = nil) -> CaptionModel {
        CaptionModel(
            courtHeader: "IN THE CIRCUIT COURT OF THE FOURTH JUDICIAL CIRCUIT,\nIN AND FOR DUVAL COUNTY, FLORIDA",
            parties: [PartyLine(name: "MCKERNON MOTORS, INC.,", designation: "Plaintiff,"),
                      PartyLine(name: "LIBERTY RAIL, LLC,", designation: "Defendant.")],
            caseNumber: "2026-CA-001847", division: "CV-G", judge: judge)
    }

    private func signature(respectfullySubmitted: DateOnly? = nil,
                           secondary: [String] = ["litdocket@pearsonspecterlitt.example"]) -> SignatureBlockModel {
        SignatureBlockModel(
            respectfullySubmitted: respectfullySubmitted, firmName: "Pearson Specter Litt",
            signingAttorney: "Harvey Specter",
            attorneys: [AttorneyLine(name: "Harvey Specter", barNumber: "Florida Bar No. 100847")],
            office: OfficeBlock(street: "200 West Forsyth Street", suite: "Suite 1400",
                                city: "Jacksonville", state: "Florida", zip: "32202",
                                phone: "(904) 555-0142", fax: "(904) 555-0143"),
            partyRepresented: "Defendant",
            emails: EmailDesignation(primary: "hspecter@pearsonspecterlitt.example",
                                     secondary: secondary))
    }

    private func certificate() -> CertificateModel {
        CertificateModel(
            date: DateOnly(year: 2026, month: 6, day: 25), clause: .flEPortal,
            documentTitle: "NOTICE OF APPEARANCE",
            recipients: [ServiceRecipient(
                name: "Daniel Hardman, Esq.", firm: "Hardman & Tanner, LLP",
                address: OfficeBlock(street: "1 Independent Drive", suite: "Suite 2400",
                                     city: "Jacksonville", state: "Florida", zip: "32202",
                                     phone: "", fax: nil),
                emails: ["dhardman@hardmantanner.example"], role: "Counsel for Plaintiff")],
            signOffAttorney: "Harvey Specter")
    }

    /// Notice: single plain-paragraph body, judge nil, secondary email present.
    private var noticeModel: DocumentModel {
        DocumentModel(caption: captionModel(), title: "NOTICE OF APPEARANCE",
                      body: [.paragraph("PLEASE TAKE NOTICE that the undersigned attorney appears.")],
                      signature: signature(), certificate: certificate())
    }

    /// Caption variant WITH a judge — exercises the judgeLabel line (CourtFLRenderer:133-135).
    private var judgeCaptionModel: DocumentModel {
        DocumentModel(caption: captionModel(judge: "Hon. Jane Roe"), title: "NOTICE OF APPEARANCE",
                      body: [.paragraph("PLEASE TAKE NOTICE that the undersigned attorney appears.")],
                      signature: signature(), certificate: certificate())
    }

    /// Signature variant with NO secondary email — exercises the primary-only emailLabel branch.
    private var noSecondaryEmailModel: DocumentModel {
        DocumentModel(caption: captionModel(), title: "NOTICE OF APPEARANCE",
                      body: [.paragraph("PLEASE TAKE NOTICE that the undersigned attorney appears.")],
                      signature: signature(secondary: []), certificate: certificate())
    }

    /// Motion: numbered allegations + a level-1 point heading + respectfullySubmitted date.
    /// Exercises numberFormat (#25), baseIndent/spaceAfter (#26-29) and submittedLabel (#16).
    private var motionModel: DocumentModel {
        DocumentModel(
            caption: captionModel(), title: "DEFENDANT'S MOTION TO DISMISS",
            body: [
                .numberedAllegation(1, "Plaintiff filed its complaint on June 1, 2026."),
                .numberedAllegation(2, "The complaint fails to state a cause of action."),
                .pointHeading(1, "I.", "THE COMPLAINT FAILS TO STATE A CLAIM"),
                .paragraph("For these reasons the motion should be granted.")
            ],
            signature: signature(respectfullySubmitted: DateOnly(year: 2026, month: 6, day: 25)),
            certificate: certificate())
    }

    private var letterModel: LetterModel {
        LetterModel(
            letterhead: LetterheadFill(firmName: "Pearson Specter Litt",
                office: OfficeBlock(street: "200 West Forsyth Street", suite: "Suite 1400",
                                    city: "Jacksonville", state: "Florida", zip: "32202",
                                    phone: "(904) 555-0142", fax: "(904) 555-0143")),
            date: DateOnly(year: 2026, month: 6, day: 25),
            recipient: AddressBlock(name: "Mr. Charles Forstman", title: nil, firm: "Forstman Capital, LLC",
                                    street: "4820 Southpoint Parkway", city: "Jacksonville", state: "Florida", zip: "32216"),
            reLine: "Outstanding Balance Owed to McKernon Motors — Demand for Payment",
            salutation: "Dear Mr. Forstman:",
            body: ["This firm represents McKernon Motors."],
            closing: "Respectfully,", signerName: "Harvey Specter", signerTitle: nil,
            enclosures: ["Statement of Unpaid Invoices"], cc: ["McKernon Motors"])
    }

    private func style(_ mutate: (inout FirmStyleProfile) -> Void) -> HouseStyleSheet {
        var p = FirmStyleProfile(); mutate(&p); return p.resolved(over: .defaultFL)
    }

    /// Returns the <w:p>…</w:p> fragment that contains `text` — the paragraph-scoping helper the
    /// toggle/format wire-proofs use so an absence assert cannot be contaminated by the same
    /// formatting run on an unrelated element. XCTUnwrap (no silent guard-return).
    private func paragraph(containing text: String, in xml: String) throws -> String {
        let frags = xml.components(separatedBy: "</w:p>")
        let hit = try XCTUnwrap(frags.first(where: { $0.contains(text) }),
                                "no paragraph contained \(text)")
        return hit + "</w:p>"
    }

    // ---- Exact-element glyph/label wire-proofs -------------------------------------------------

    // T-CAP-01 — party separator. RED (unwired): exact <w:t>v.</w:t> run present.
    func testPartySeparatorIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.captionPartySeparator = "vs." })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">vs.</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">v.</w:t>"#))
    }

    // T-CAP-02 — closing-rule glyph. The bare "/" is contaminated by the /s/ signature marks,
    // so assert the EXACT glyph run. RED (unwired): exact <w:t>/</w:t> glyph run present.
    func testClosingRuleGlyphIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.captionClosingRuleGlyph = "§" })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">§</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">/</w:t>"#))   // NOT contains("/")
    }

    // T-CAP-05 — judge label (fixture WITH a judge, else the line never renders).
    func testJudgeLabelIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(judgeCaptionModel, style: style { $0.captionJudgeLabel = "J.: " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">J.: Hon. Jane Roe</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">JUDGE: Hon. Jane Roe</w:t>"#))
    }

    // T-CAP-07 — headerBoldCentered toggle, PARAGRAPH-SCOPED (bold/center appear on many elements).
    // RED (unwired): the court-header paragraph still carries <w:b/> and center.
    func testHeaderBoldCenteredToggleIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.captionHeaderBoldCentered = false })
        let header = try paragraph(containing: "IN THE CIRCUIT COURT", in: xml)
        XCTAssertFalse(header.contains("<w:b/>"))
        XCTAssertFalse(header.contains(#"<w:jc w:val="center"/>"#))
    }

    // T-CAP-08 — closingRuleEndsInSlash=false ⇒ the closing-rule glyph run is gone, rest of the
    // caption remains. RED (unwired): the glyph run is still emitted.
    func testClosingRuleEndsInSlashToggleIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.captionClosingRuleEndsInSlash = false })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">CASE NO.: 2026-CA-001847</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">/</w:t>"#))
    }

    // T-SIG-03 — submittedLabel, MOTION fixture (line renders only when respectfullySubmitted != nil).
    func testSubmittedLabelIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(motionModel, style: style { $0.signatureSubmittedLabel = "Respectfully yours: " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">Respectfully yours: June 25, 2026</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">Respectfully submitted: June 25, 2026</w:t>"#))
    }

    // T-SIG-04 — representationPrefix. RED: <w:t>Attorneys for Defendant</w:t> present.
    func testRepresentationPrefixIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.signatureRepresentationPrefix = "Counsel for " })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">Counsel for Defendant</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">Attorneys for Defendant</w:t>"#))
    }

    // T-SIG-05 (revised per PR #50 review) — barNumberLabel applies ONLY to a BARE number: the
    // notice assembler pre-labels the slot, so an unconditional prefix would duplicate the
    // jurisdiction label. RED: the pre-labeled render carries the duplicated prefix.
    func testBarNumberLabelAppliesOnlyToBareNumbers() throws {
        let labeled = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.signatureBarNumberLabel = "Fla. Bar No. " })
        XCTAssertTrue(labeled.contains(#"<w:t xml:space="preserve">Florida Bar No. 100847</w:t>"#))
        XCTAssertFalse(labeled.contains("Fla. Bar No. Florida Bar No."))

        let bareModel = DocumentModel(caption: captionModel(), title: "NOTICE OF APPEARANCE",
                                      body: [.paragraph("PLEASE TAKE NOTICE that the undersigned attorney appears.")],
                                      signature: signature(barNumber: "100847"), certificate: certificate())
        let bare = try CourtFLRenderer().documentXML(bareModel, style: style { $0.signatureBarNumberLabel = "Fla. Bar No. " })
        XCTAssertTrue(bare.contains(#"<w:t xml:space="preserve">Fla. Bar No. 100847</w:t>"#))
        XCTAssertFalse(bare.contains(#"<w:t xml:space="preserve">100847</w:t>"#))
    }

    // T-SIG-08 — email labels: TWO renders so BOTH branches (primary-only + with-secondary) are proven.
    func testEmailLabelsAreWired() throws {
        let withSecondary = try CourtFLRenderer().documentXML(
            noticeModel, style: style { $0.signatureEmailLabelWithSecondary = "E1/E2: " })
        XCTAssertTrue(withSecondary.contains(#"<w:t xml:space="preserve">E1/E2: </w:t>"#))
        XCTAssertFalse(withSecondary.contains(#"<w:t xml:space="preserve">Primary and Secondary E-Mail: </w:t>"#))

        let primaryOnly = try CourtFLRenderer().documentXML(
            noSecondaryEmailModel, style: style { $0.signatureEmailLabel = "E: " })
        XCTAssertTrue(primaryOnly.contains(#"<w:t xml:space="preserve">E: </w:t>"#))
        XCTAssertFalse(primaryOnly.contains(#"<w:t xml:space="preserve">Primary E-Mail: </w:t>"#))
    }

    // T-SIG-09 — firmNameBoldCaps toggle, PARAGRAPH-SCOPED to the bold-caps firm-name paragraph
    // (the FIRST paragraph containing the firm name; the office-line one is plain).
    func testFirmNameBoldCapsToggleIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.signatureFirmNameBoldCaps = false })
        let firm = try paragraph(containing: "Pearson Specter Litt", in: xml)
        XCTAssertFalse(firm.contains("<w:b/>"))
        XCTAssertFalse(firm.contains("<w:caps/>"))
    }

    // T-SIG-10 — representationLineItalic toggle, PARAGRAPH-SCOPED to the representation line.
    func testRepresentationLineItalicToggleIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.signatureRepresentationLineItalic = false })
        let rep = try paragraph(containing: "Attorneys for Defendant", in: xml)
        XCTAssertFalse(rep.contains("<w:i/>"))
    }

    // T-CERT-04 — headingCenteredBoldCaps toggle, PARAGRAPH-SCOPED to the certificate heading.
    func testCertificateHeadingBoldCapsToggleIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(noticeModel, style: style { $0.certificateHeadingCenteredBoldCaps = false })
        let heading = try paragraph(containing: "CERTIFICATE OF SERVICE", in: xml)
        XCTAssertFalse(heading.contains("<w:b/>"))
        XCTAssertFalse(heading.contains("<w:caps/>"))
        XCTAssertFalse(heading.contains(#"<w:jc w:val="center"/>"#))
    }

    // T-BODY-01 — numberFormat, MOTION fixture (allegation renders only for .numberedAllegation).
    // Non-default .numberParen ⇒ "1)"; default "1." must be absent. RED: <w:t>1.</w:t> present.
    func testNumberFormatIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(motionModel, style: style { $0.bodyNumberFormat = .numberParen })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">1)</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">1.</w:t>"#))
    }

    // T-BODY-03 — spaceAfterTwips, MOTION fixture (.pointHeading), PARAGRAPH-SCOPED to the heading.
    func testHeadingSpaceAfterIsWired() throws {
        let xml = try CourtFLRenderer().documentXML(motionModel, style: style { $0.bodySpaceAfterTwips = 360 })
        let heading = try paragraph(containing: "THE COMPLAINT FAILS TO STATE A CLAIM", in: xml)
        XCTAssertTrue(heading.contains(#"w:after="360""#))
        XCTAssertFalse(heading.contains(#"w:after="240""#))
    }

    // T-LH-01 — letterhead tagline. RED: exact <w:t>Attorneys at Law</w:t> present.
    func testTaglineIsWired() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: style { $0.letterheadTagline = "Counselors at Law" })
        XCTAssertTrue(xml.contains(#"<w:t xml:space="preserve">Counselors at Law</w:t>"#))
        XCTAssertFalse(xml.contains(#"<w:t xml:space="preserve">Attorneys at Law</w:t>"#))
    }

    // T-LH-05 — RE indent/hanging: assert the CONTIGUOUS attribute pair (w:left=1440 alone is
    // contaminated by the signature indent).
    func testREIndentHangingWired() {
        let xml = LetterheadRenderer().documentXML(letterModel, style: style {
            $0.letterheadREIndentTwips = 1000; $0.letterheadREHangingTwips = 300 })
        XCTAssertTrue(xml.contains(#"w:left="1000" w:hanging="300""#))
        XCTAssertFalse(xml.contains(#"w:left="1440" w:hanging="720""#))
    }

    // T-LH-09 — bodyParagraphStyle .indented ⇒ first-line indent on the body paragraph (M1-T6 wire-up).
    func testLetterheadParagraphStyleIsWired() throws {
        let xml = LetterheadRenderer().documentXML(letterModel, style: style { $0.letterheadBodyParagraphStyle = .indented })
        let body = try paragraph(containing: "This firm represents McKernon Motors.", in: xml)
        XCTAssertTrue(body.contains(#"<w:ind w:firstLine="720"/>"#))
        XCTAssertFalse(body.contains("w:firstLine=\"0\""))
    }
}
```

> The remaining §4.2 wire-proofs (`T-CAP-03/04/06`, `T-SIG-01/02/06/07`, `T-CERT-01/02/03`,
> `T-BODY-02`, `T-LH-02/03/04/06/07/08`) follow the identical shape shown above: one
> `style { $0.<field> = <non-default> }`, assert the **exact `<w:t>` element** (or the
> **paragraph-scoped fragment** for a formatting toggle or geometry attribute) present, assert the
> **exact default element/fragment** absent, on a fixture whose model shape emits the target block
> (per the checklist #3 table). Add each before its literal is lifted in M1-T5/T6.

---

## GOLDEN / FIXTURE MANAGEMENT rules

- **Provenance & xml:space.** `Docs/Fixtures/*.document.xml` are **Word-roundtripped** goldens
  (R1) — the **independent** oracle. Every renderer `<w:t>` run is written with
  `xml:space="preserve"` **unconditionally** (`Ooxml/OoxmlWriter.swift:79`), which is why the
  exact-element assertions above take the form `<w:t xml:space="preserve">…</w:t>` (including the
  `>RE:<` / `>v.<` absent-tokens, which are the tail of that element) — this is intentional and
  stable writer behavior, not a bug.
- **Two oracles, distinct roles.** The pre-lift `*-baseline.wml.txt` (M1-T0) is a **no-drift
  regression** oracle (produced by the very renderer that M1-T5/T6 change — **NOT** an independent
  correctness oracle). The Word-roundtripped `*.document.xml` is the **independent** oracle,
  used for `visibleText` containment. Correctness rests on the wire-proofs plus the independent
  golden; the baseline only catches accidental byte drift.
- **Baseline WML goldens (M1-T0).** `*-baseline.wml.txt` (notice/letter/**motion**) are captured
  **once** from the **pre-lift** renderers on a clean HEAD, then committed. **They are never
  regenerated from post-lift code** (PARITY RULE). If a parity test fails, the renderer changed
  output — investigate the renderer, do not refresh the baseline.
- **Anchors extracted from the golden, not inline.** `T-PARITY-01/02/03` assert that every
  non-empty line of `OoxmlNormalizer.visibleText(<name>-golden.document.xml)` is contained in the
  render's `visibleText` — anchors are **read from the independent golden**, never duplicated as
  inline string constants (TAUTOLOGY BAN). This makes the independent golden load-bearing and
  widens coverage beyond a hand-picked three anchors to every visible lifted string.
- **No write-then-read.** No test writes into `Docs/Fixtures/` (STATIC CHECKLIST #8). There is no
  "regenerate on mismatch" branch and none may be introduced (R1 §1).
- **`loadGolden` reuse.** A new SupraExports test needing a golden copies the private
  `#filePath`-walk `loadGolden` (five `deletingLastPathComponent()` to repo root, then
  `Docs/Fixtures/<name>`), since it is not a shared helper. Text comparison uses the public
  `OoxmlNormalizer.visibleText` / `OoxmlNormalizer.normalize` (`DocxPackage.swift:139`).
- **Wire in the unused fixtures.** `motionToDismiss-golden.*` and `letterDemand-golden.*` are
  currently loaded by **no** test (R1 §4.5); `T-PARITY-02/03` bring them into real
  `loadGolden`+`visibleText` comparisons, closing the "golden-theater" footgun.

---

## COVERAGE MATRIX

**§2 invariants → tests:**

| Invariant | Covered by | Type |
|---|---|---|
| 1 — 2.520(a) floor un-overridable | T-FLOOR-01, T-FLOOR-02 (idempotence, standing), T-FLOOR-03, **T-FLOOR-04**, T-CTRL-04 | invariant/wire-proof |
| 2 — golden-lock reproducibility | T-PARITY-01/02/03, T-PARSE-09 | parity/determinism |
| 3 — no model-originated structure | T-VOICE-02 (standing guard), T-PARSE-08 | invariant |
| 4 — identity slot-only | T-PARSE-06 | invariant |
| 5 — default byte-parity | T-RESOLVE-01, T-PARITY-01/02/03, T-CTRL-01, T-DEFAULT-01 | parity |

**§4.2 lifted literals → wire-proof (WP) + parity coverage.** Every literal has a WP test that
renders a **non-default** value on a fixture that emits it; no literal is covered by parity alone
(any such row would be a **GAP**, flagged below).

| §4.2 # | Literal / element | WP test | Fixture emitting it | Parity |
|---|---|---|---|---|
| 1 tagline | T-LH-01 | letterModel | T-PARITY-02 |
| 2 lh phoneLabel | T-LH-02 | letterModel | T-PARITY-02 |
| 3 lh faxLabel | T-LH-03 | letterModel | T-PARITY-02 |
| 4 reLabel | T-LH-04 | letterModel | T-PARITY-02 |
| 5 reIndent/Hanging | T-LH-05 | letterModel | T-PARITY-02 |
| 6 enclosurePrefix | T-LH-06 | letterModel | T-PARITY-02 |
| 7 ccPrefix | T-LH-07 | letterModel | T-PARITY-02 |
| 8 partySeparator | T-CAP-01 | noticeModel | T-PARITY-01 |
| 9 closingRuleGlyph | T-CAP-02 | noticeModel | T-PARITY-01 |
| 10 caseNumberLabel | T-CAP-03 | noticeModel | T-PARITY-01 |
| 11 divisionLabel | T-CAP-04 | noticeModel | T-PARITY-01 |
| 12 judgeLabel | T-CAP-05 | **judgeCaptionModel** | T-PARITY-01 |
| 13 designationIndent | T-CAP-06 | noticeModel (no L1 heading) | T-PARITY-01 |
| 14 /s/ mark | T-SIG-01 | noticeModel | T-PARITY-01 |
| 15 byPrefix | T-SIG-02 | noticeModel | T-PARITY-01 |
| 16 submittedLabel | T-SIG-03 | **motionModel** | T-PARITY-03 (motion) |
| 17 representationPrefix | T-SIG-04 | noticeModel | T-PARITY-01 |
| 18 barNumberLabel | T-SIG-05 | noticeModel | T-PARITY-01 |
| 19 sig phoneLabel | T-SIG-06 | noticeModel | T-PARITY-01 |
| 20 sig faxLabel | T-SIG-07 | noticeModel | T-PARITY-01 |
| 21 email labels (both branches) | T-SIG-08 | noticeModel + **noSecondaryEmailModel** | T-PARITY-01 |
| 22 cert heading | T-CERT-01 | noticeModel | T-PARITY-01 |
| 23 attestation prefix/suffix (+middle preserved) | T-CERT-02 | noticeModel | T-PARITY-01 |
| 24 clauseText | T-CERT-03 | noticeModel | T-PARITY-01 |
| 25 numberFormat (`.numberParen`) | T-BODY-01 | **motionModel** | T-PARITY-01/03 |
| 26–28 baseIndentTwips | T-BODY-02 | **motionModel** | T-PARITY-01/03 |
| 29 spaceAfterTwips | T-BODY-03 | **motionModel** | T-PARITY-01/03 |
| wire-up headerBoldCentered | T-CAP-07 (para-scoped) | noticeModel | T-PARITY-01 |
| wire-up closingRuleEndsInSlash | T-CAP-08 (glyph run) | noticeModel | T-PARITY-01 |
| wire-up firmNameBoldCaps | T-SIG-09 (para-scoped) | noticeModel | T-PARITY-01 |
| wire-up representationLineItalic | T-SIG-10 (para-scoped) | noticeModel | T-PARITY-01 |
| wire-up headingCenteredBoldCaps | T-CERT-04 (para-scoped) | noticeModel | T-PARITY-01 |
| wire-up letterhead bottomRule | T-LH-08 | letterModel | T-PARITY-02 |
| wire-up bodyParagraphStyle (in-scope, M1-T6) | T-LH-09 | letterModel | T-PARITY-02 |
| existing bodyJustify overlay | **T-BODY-04 (gates M1-T2/M1-T4, not M1-T5)** | noticeModel | T-PARITY-01 |

**Accepted GAPs (no automated coverage — documented, not silent):**
- **M2-T2 `FirmStyleSection`** and **M3-T3 review-pane UI** — the app target has **no unit test
  target** (R1/R2); verified by the manual macOS UI gate only. Their data path is covered by
  `T-PERSIST-*` (autosave) and `T-PARSE-09` (preview determinism); only the SwiftUI view bodies
  are uncovered.
- **`letterhead.dateFormat`** (§4.2) is the documented **dead** field — intentionally has **no**
  wire-proof (there is no second `DateStyle` case to switch to; open-question 2). This is the
  **only** dead field: `bodyParagraphStyle` is a **live** wire-up (T-LH-09, M1-T6) and
  `numberFormat` is a **live** wire-up (T-BODY-01, `NumberFormat.numberParen`), so neither is a GAP.

**No literal in the §4.2 table is covered by a parity test without an accompanying, emittable
wire-proof.** If review finds one — including a wire-proof whose fixture cannot emit its token, an
absence-assert on a short/shared token, or a single-case enum with no non-default value — it is a
GAP and blocks the milestone Definition of Done.
