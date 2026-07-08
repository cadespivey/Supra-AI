# Implementation Spec — Firm Style Profile (per-firm structural style + voice)

> **Companion to** `Docs/Drafting-Catalog-SPEC.md` (the design spec). Bare `§N`
> references point there. Sibling impl specs are cited by name + section, e.g.
> **NoticeAppearance §3.2** (`HouseStyleSheet`) and **CoreTypes §1** (reconciled
> protocols). This file is the canonical home for the **`FirmStyleProfile`** type,
> the lift of the renderers' hardcoded structural literals into style fields, and
> the exemplar-parse ingestion flow. Where it touches shared types already pinned
> in **CoreTypes**, that file wins; where it adds new style fields, **this file wins.**
>
> **Purpose:** let a firm control its own letterhead, caption, signature block, and
> certificate of service — deterministically and reproducibly — without ever feeding
> an exemplar document into the model's prompt context. Structure is data; voice is
> the model's job. The two are kept strictly separate.
>
> **Why this slice matters:** today every draft renders against `HouseStyleSheet.defaultFL`
> (`DraftingCore.swift:570`). A firm cannot change "Attorneys at Law", the `RE:` label,
> the `/s/` mark, the certificate heading, or any of ~29 other baked structural strings.
> This spec makes all of them style-driven while guaranteeing byte-for-byte parity for
> any firm that has configured nothing.

---

## 0. Scope of the slice

**In scope:**

- A new persisted, `Codable` **`FirmStyleProfile`** — a *user-overridable subset* of
  `HouseStyleSheet`, merged over `.defaultFL` into an **effective `HouseStyleSheet`**
  applied by the renderers every draft.
- Lifting the ~29 hardcoded structural literals from `CourtFLRenderer.swift` and
  `LetterheadRenderer.swift` (inventory in §4.2) into new style fields whose **defaults
  equal today's literals**, so default output is unchanged.
- A floor-clamp step (Fla. R. Jud. Admin. 2.520(a)) applied to the effective sheet.
- Controller wiring: resolve the effective sheet in `MatterDraftingController` and pass
  it to `runNotice` / `runLetter` (and `runMotion` when it lands) at the exact call
  sites that today pass `.defaultFL`.
- An exemplar-parse ingestion flow (upload → extract → LLM-assisted **structured**
  extraction → user review → rendered `.docx` preview → confirm-writes-profile).
- A "Firm Style" Settings section mirroring the `AssistantProfileSection` autosave pattern.

**Out of slice (stubbed/deferred):**

- Image/graphic letterhead assets (logos, scanned mastheads). Only a **text masthead**
  is in scope; image assets are deferred (§5.4).
- Per-matter or per-jurisdiction style *overrides* beyond a single firm-level profile.
  (`courtMDFL` / `courtGA` shells exist in `RenderShell` but this slice targets the FL
  path the renderers implement.)
- Grammar/JSON-schema-constrained decoding — **the runtime has none** (R3). The parse
  flow is built on the existing prompt-contract + parse/validate/repair pattern.
- Track B (voice) beyond a minimal wiring note (§8); the writing-sample firewall in
  `AssistantProfile.composedSystemPrompt` already exists and is not re-specified here.

---

## 1. Background — how the pipeline produces STRUCTURE vs PROSE today

The drafting engine already separates **structure** from **prose**, and this separation
is the load-bearing invariant the whole spec builds on.

**Structure is rendered 100% deterministically in Swift** from typed data. Letterhead,
caption (court header + party block), signature block, and certificate of service are
each produced by a renderer reading two inputs:

1. **Identity slots** — a `FirmProfile` (`Packages/SupraDrafting/Sources/SupraDrafting/FirmProfile.swift:9`),
   projected from the user's `AssistantProfile` by
   `MatterDraftingController.firmProfile(from:jurisdiction:)` (`MatterDraftingController.swift:453`).
   Slots only: `firmName`, `signingAttorney`, `barNumber`, `barLabel`, `office`,
   `primaryEmail`, `secondaryEmails`, `tagline`. **No names are ever baked into a template.**
2. **A `HouseStyleSheet`** (`DraftingCore.swift:543`) — page/body/caption/headings/
   signature/certificate/letterhead style structs, all `Codable`. Today this is always
   `.defaultFL` (`DraftingCore.swift:570`).

**Prose is the only thing the model writes.** The letter path calls
`RuntimeLetterGenerator.generateLetter(parts)` and the model returns a `GeneratedLetter`
(`DraftingCore.swift:769`) whose *entire* surface is:

```swift
public struct GeneratedLetter: Sendable, Equatable {
    public var paragraphs: [String]
    public var assertedFacts: [FactRef]
    public var citesUsed: [CitationRef]
}
```

**The invariant — no model-originated structural element can reach a draft — is
mechanical, not probabilistic.** It holds because the generation output types have *no
fields* for structure. `GeneratedLetter` carries `paragraphs` and provenance, nothing
else. The render-model types the renderer consumes (`CaptionModel` `:583`,
`SignatureBlockModel` `:606`, `CertificateModel` `:626`, `LetterheadFill` `:658`,
`LetterModel` `:668`, wrapped in `RenderInput` `:696`) are populated from typed slots
and the style sheet, never from model output. (`LetterModel.body` does carry the model's
prose, but prose is not a *structural* element — no letterhead, caption cell, `/s/` line,
or service clause can arrive through it.) A model cannot emit a letterhead, a caption
cell, a `/s/` line, or a service clause, because there is no channel that would carry one
into the render model. Renders are **golden-locked** — same inputs, same bytes.

This spec preserves that invariant absolutely. `FirmStyleProfile` changes only the
**style sheet** input (track A). It never adds a structural field to any generation
output type, and it never routes exemplar text into a generation prompt.

---

## 2. Design thesis — two tracks

The correct way to let a user control letterhead/caption/signature is **not** to feed
exemplars to the model. It is **two tracks**, kept strictly separate:

**Track A — STRUCTURE (data).** A persisted, per-firm `FirmStyleProfile`: a
user-overridable subset of `HouseStyleSheet` (`LetterheadStyle` / `CaptionStyle` /
`SignatureStyle` / `CertificateStyle` plus a few safe body/page knobs), merged over
`.defaultFL` and applied **deterministically by the renderer every time**. This is the
maximally-directed guidance: what the firm sets is exactly what renders. The guarantee
is mechanical.

**Track B — VOICE (model).** Writing samples and `voiceNotes` bias the model's **prose
only**, via `AssistantProfile.composedSystemPrompt` and (for the structured drafting
engine) `AssistantVoiceProfile` (§8). This can be *improved* but never *guaranteed*.
It never touches structure.

**An uploaded exemplar is a PARSE SOURCE, not prompt context.** "Just my letterhead",
"just my caption", "just my signature" → extract text → LLM-assisted **structured**
extraction → reviewed structured data that populates Track A's fields at import time.
The exemplar's text does **not** ride into every draft. It is parsed once, reviewed
once, and discarded from the generation path.

**Consistency = deterministic render + one-time confirm.** The user's trust surface is
(1) a **parse review** of the extracted structured fields, and (2) a **rendered preview**
of the exact `.docx` the candidate profile produces. The user confirms once; deterministic
rendering reproduces it identically thereafter. There is no per-draft variance to trust.

**Invariants that must survive (do not violate):**

1. The Fla. R. Jud. Admin. 2.520(a) floor (≥ 12 pt, ≥ 1″ margins) cannot be overridden
   below the floor (§4.3).
2. Golden-lock reproducibility — same profile + same slots ⇒ same bytes.
3. No model-originated structural element reaches a draft (§1).
4. Identity is slot-only — no baked names (§5.4).
5. When a firm has no custom style profile, output is **byte-for-byte identical** to
   today's `.defaultFL` (zero regression).

---

## 3. Module & file layout

```
Packages/SupraDraftingCore/Sources/SupraDraftingCore/
    DraftingCore.swift              # + new style fields on Caption/Signature/
                                    #   Letterhead/Certificate/Heading styles (§4.2)
    FirmStyleProfile.swift          # NEW — the Codable subset DTO + merge (§4.1)
    StyleSheetFloor.swift           # NEW — 2.520(a) clamp (§4.3); or fold into
                                    #   the existing StyleSheetCompiler.validateFloor

Packages/SupraSessions/Sources/SupraSessions/
    FirmStyleProfileController.swift # NEW — autosave, load/merge, exemplar parse (§4.4, §5)
    FirmStyleExemplarParser.swift    # NEW — extract + structured-extraction + repair (§5.2)
    MatterDraftingController.swift   # EDIT — resolve effective sheet; pass at :160/:307

Apps/SupraAI/SupraAI/
    SettingsView.swift               # EDIT — add FirmStyleSection (§7)
    FirmStyleSection.swift           # NEW — per-element controls + importer + preview
```

> Renderers touched: `CourtFLRenderer.swift` and `LetterheadRenderer.swift` (read new
> style fields; §4.2, §6). The renderer files are the only structural authors and remain
> the only structural authors.

---

## 4. Data model

### 4.1 `FirmStyleProfile` — the user-overridable subset (design §4)

**Units:** twips (1/1440 inch) unless noted; font size in **half-points** (24 = 12 pt),
matching `PageSetup.fontHalfPoints` (`DraftingCore.swift:349`).

`FirmStyleProfile` is **not** a `HouseStyleSheet` and **not** a full replacement. It is a
sparse, all-`Optional`, `Codable` DTO: every field is "unset ⇒ inherit `.defaultFL`". A
firm that touches nothing serializes to an essentially empty object and resolves to
`.defaultFL` byte-for-byte (invariant 5). New type, in `FirmStyleProfile.swift`:

```swift
// Packages/SupraDraftingCore/Sources/SupraDraftingCore/FirmStyleProfile.swift
//
// A sparse, user-overridable subset of HouseStyleSheet. Every field is Optional:
// nil ⇒ inherit HouseStyleSheet.defaultFL. Resolves to an *effective* HouseStyleSheet
// via `resolved(over:)`, which the renderers consume. Track A (structure) only —
// never carries identity (names/addresses live in FirmProfile slots) and never
// carries prose.
public struct FirmStyleProfile: Codable, Sendable, Equatable {

    /// Bumped when the shape changes so decode can migrate. Absent ⇒ treat as 1.
    public var schemaVersion: Int

    // --- Letterhead (masthead text + labels + geometry) ---
    public var letterheadTagline: String?          // "Attorneys at Law"
    public var letterheadPhoneLabel: String?        // "Telephone: "
    public var letterheadFaxLabel: String?          // "Facsimile: "
    public var letterheadRELabel: String?           // "RE:"
    public var letterheadREIndentTwips: Int?        // 1440
    public var letterheadREHangingTwips: Int?       // 720
    public var letterheadEnclosurePrefix: String?   // "Enclosure: "
    public var letterheadCCPrefix: String?          // "cc:  " (note double space)
    public var letterheadBottomRule: Bool?          // honor LetterheadBlock.bottomRule
    public var letterheadParagraphStyle: LetterParaStyle? // .block / .indented

    // --- Caption (party block labels + geometry) ---
    public var captionPartySeparator: String?       // "v."
    public var captionClosingRuleGlyph: String?     // "/"
    public var captionCaseNumberLabel: String?      // "CASE NO.: "
    public var captionDivisionLabel: String?        // "DIVISION: "
    public var captionJudgeLabel: String?           // "JUDGE: "
    public var captionDesignationIndentTwips: Int?  // 720
    public var captionHeaderBoldCentered: Bool?     // honor CaptionStyle.headerBoldCentered

    // --- Signature block (labels + marks + prefixes) ---
    public var signatureESignatureMark: String?     // "/s/ "
    public var signatureByPrefix: String?           // "By: "
    public var signatureSubmittedLabel: String?     // "Respectfully submitted: "
    public var signatureRepresentationPrefix: String? // "Attorneys for "
    public var signatureBarNumberLabel: String?     // "" today (no label baked)
    public var signaturePhoneLabel: String?         // "Telephone: "
    public var signatureFaxLabel: String?           // "Facsimile: "
    public var signatureEmailLabel: String?         // "Primary E-Mail: "
    public var signatureEmailLabelWithSecondary: String? // "Primary and Secondary E-Mail: "
    public var signatureFirmNameBoldCaps: Bool?     // honor SignatureStyle.firmNameBoldCaps
    public var signatureRepresentationLineItalic: Bool? // honor SignatureStyle.representationLineItalic

    // --- Certificate of service ---
    public var certificateHeading: String?          // "CERTIFICATE OF SERVICE"
    public var certificateAttestationPrefix: String? // "I HEREBY CERTIFY that on "
    public var certificateAttestationSuffix: String? // " to the following:"
    public var certificateHeadingCenteredBoldCaps: Bool? // honor CertificateStyle field
    /// Optional per-clause rewording. nil / missing key ⇒ built-in FL boilerplate.
    public var certificateClauseText: [ServiceMethodClause: String]?

    // --- Headings / body geometry ---
    public var headingBaseIndentTwips: Int?         // 720 (already exists; wire it)
    public var headingSpaceAfterTwips: Int?         // 240
    public var numberedAllegationFormat: NumberFormat? // "N." → period-after

    // --- Safe page/body knobs (subject to the 2.520(a) floor, §4.3) ---
    public var pageFontHalfPoints: Int?             // 24 (>= 24 after clamp)
    public var pageMarginTwips: EdgeInsets?         // 1440 all sides (>= 1440 after clamp)
    public var bodyJustify: Bool?                   // true

    public init(schemaVersion: Int = FirmStyleProfile.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        // all style fields default nil
    }

    public static let currentSchemaVersion = 1
}
```

> **Access-control note (per CoreTypes §, "every public DTO needs an explicit
> `public init`"):** because Swift would otherwise synthesize an internal memberwise
> init, `FirmStyleProfile` declares an explicit `public init` (above) that sets only
> `schemaVersion`; every style field is left `nil`. Callers mutate fields directly (they
> are `public var`). `ServiceMethodClause` (`DraftingCore.swift:452`) is already `Codable`,
> so a `[ServiceMethodClause: String]` map encodes as a keyed dictionary. `NumberFormat`
> is a small new `Codable` enum (`case numberDot // "1."`, extensible) added alongside.

**Resolution / merge into an effective `HouseStyleSheet`.** The profile never *is* the
sheet; it produces one by overlaying non-nil fields onto a base (always `.defaultFL`
for this slice):

```swift
extension FirmStyleProfile {
    /// Overlay non-nil overrides onto `base` and return the effective sheet the
    /// renderers consume. Pure; deterministic; total (never throws).
    public func resolved(over base: HouseStyleSheet = .defaultFL) -> HouseStyleSheet {
        var s = base

        // Letterhead — base.letterhead is non-nil in .defaultFL (DraftingCore:559).
        if var lh = s.letterhead {
            var hb = lh.headerBlock
            letterheadTagline.map { hb.tagline = $0 }          // new field (§4.2 #1)
            letterheadPhoneLabel.map { hb.phoneLabel = $0 }     // #2
            letterheadFaxLabel.map   { hb.faxLabel = $0 }       // #3
            letterheadBottomRule.map { hb.bottomRule = $0 }
            lh.headerBlock = hb
            letterheadRELabel.map        { lh.reLabel = $0 }        // #4
            letterheadREIndentTwips.map  { lh.reIndentTwips = $0 }  // #5
            letterheadREHangingTwips.map { lh.reHangingTwips = $0 } // #5
            letterheadEnclosurePrefix.map{ lh.enclosurePrefix = $0 }// #6
            letterheadCCPrefix.map       { lh.ccPrefix = $0 }       // #7
            letterheadParagraphStyle.map { lh.bodyParagraphStyle = $0 }
            s.letterhead = lh
        }

        // Caption
        captionPartySeparator.map        { s.caption.partySeparator = $0 }        // #8
        captionClosingRuleGlyph.map      { s.caption.closingRuleGlyph = $0 }      // #9
        captionCaseNumberLabel.map       { s.caption.caseNumberLabel = $0 }       // #10
        captionDivisionLabel.map         { s.caption.divisionLabel = $0 }         // #11
        captionJudgeLabel.map            { s.caption.judgeLabel = $0 }            // #12
        captionDesignationIndentTwips.map{ s.caption.designationIndentTwips = $0 }// #13
        captionHeaderBoldCentered.map    { s.caption.headerBoldCentered = $0 }

        // Signature
        signatureESignatureMark.map          { s.signature.eSignature.mark = $0 }        // #14
        signatureByPrefix.map                { s.signature.byPrefix = $0 }               // #15
        signatureSubmittedLabel.map          { s.signature.submittedLabel = $0 }         // #16
        signatureRepresentationPrefix.map    { s.signature.representationPrefix = $0 }   // #17
        signatureBarNumberLabel.map          { s.signature.barNumberLabel = $0 }         // #18
        signaturePhoneLabel.map              { s.signature.phoneLabel = $0 }             // #19
        signatureFaxLabel.map                { s.signature.faxLabel = $0 }               // #20
        signatureEmailLabel.map              { s.signature.emailLabel = $0 }             // #21
        signatureEmailLabelWithSecondary.map { s.signature.emailLabelWithSecondary = $0 }// #21
        signatureFirmNameBoldCaps.map        { s.signature.firmNameBoldCaps = $0 }
        signatureRepresentationLineItalic.map{ s.signature.representationLineItalic = $0 }

        // Certificate
        certificateHeading.map                 { s.certificate.heading = $0 }             // #22
        certificateAttestationPrefix.map       { s.certificate.attestationPrefix = $0 }   // #23
        certificateAttestationSuffix.map       { s.certificate.attestationSuffix = $0 }   // #23
        certificateHeadingCenteredBoldCaps.map { s.certificate.headingCenteredBoldCaps = $0 }
        certificateClauseText.map              { s.certificate.clauseText = $0 }          // #24

        // Headings / body geometry
        headingBaseIndentTwips.map   { s.headings.baseIndentTwips = $0 }   // #26–28
        headingSpaceAfterTwips.map   { s.headings.spaceAfterTwips = $0 }   // #29
        numberedAllegationFormat.map { s.body.numberFormat = $0 }          // #25

        // Safe page/body knobs (clamped by §4.3 afterward)
        pageFontHalfPoints.map { s.page.fontHalfPoints = $0 }
        pageMarginTwips.map    { s.page.marginTwips = $0 }
        bodyJustify.map        { s.body.justify = $0 }

        return s
    }
}
```

> **Zero-regression proof obligation:** `FirmStyleProfile().resolved(over: .defaultFL)
> == HouseStyleSheet.defaultFL` must hold exactly (unit test, §10). Because every field
> is nil, no `.map` closure fires, and the returned sheet is `.defaultFL` unchanged. This
> is invariant 5, enforced by construction.

### 4.2 Lifting hardcoded literals — inventory & new fields

Each row is a structural literal currently baked into a renderer. The new style field's
**default equals today's literal**, so default output is unchanged. Field homes:
`CaptionStyle` (`DraftingCore.swift:388`), `SignatureStyle` (`:436`), `ESignatureStyle`
(`:424`), `LetterheadStyle` (`:509`), `LetterheadBlock` (`:488`), `CertificateStyle`
(`:460`), `HeadingLadder` (`:416`), `BodyStyle` (`:374`).

| # | Literal (today) | Current file:line | Element | New style field (default = literal) |
|---|---|---|---|---|
| 1 | `"Attorneys at Law"` | LetterheadRenderer.swift:43 | letterhead | `LetterheadBlock.tagline = "Attorneys at Law"` |
| 2 | `"Telephone: "` | LetterheadRenderer.swift:50 | letterhead | `LetterheadBlock.phoneLabel = "Telephone: "` |
| 3 | `"Facsimile: "` | LetterheadRenderer.swift:51 | letterhead | `LetterheadBlock.faxLabel = "Facsimile: "` |
| 4 | `"RE:"` | LetterheadRenderer.swift:71 | letterhead | `LetterheadStyle.reLabel = "RE:"` |
| 5 | `indLeftTwips: 1440, hangingTwips: 720` | LetterheadRenderer.swift:70 | letterhead | `LetterheadStyle.reIndentTwips = 1440`, `reHangingTwips = 720` |
| 6 | `"Enclosure: "` | LetterheadRenderer.swift:120 | letterhead | `LetterheadStyle.enclosurePrefix = "Enclosure: "` |
| 7 | `"cc:  "` (double space) | LetterheadRenderer.swift:123 | letterhead | `LetterheadStyle.ccPrefix = "cc:  "` |
| 8 | `"v."` | CourtFLRenderer.swift:116 | caption | `CaptionStyle.partySeparator = "v."` |
| 9 | `"/"` closing rule glyph | CourtFLRenderer.swift:124 | caption | `CaptionStyle.closingRuleGlyph = "/"` (emitted unconditionally today; gating on `closingRuleEndsInSlash` is a wire-up item, see below) |
| 10 | `"CASE NO.: "` | CourtFLRenderer.swift:128 | caption | `CaptionStyle.caseNumberLabel = "CASE NO.: "` |
| 11 | `"DIVISION: "` | CourtFLRenderer.swift:131 | caption | `CaptionStyle.divisionLabel = "DIVISION: "` |
| 12 | `"JUDGE: "` | CourtFLRenderer.swift:134 | caption | `CaptionStyle.judgeLabel = "JUDGE: "` |
| 13 | `indLeftTwips: 720` (designation) | CourtFLRenderer.swift:110 | caption | `CaptionStyle.designationIndentTwips = 720` |
| 14 | `"/s/ "` | CourtFLRenderer.swift:296 | signature | `ESignatureStyle.mark = "/s/ "` |
| 15 | `"By: "` | CourtFLRenderer.swift:210 | signature | `SignatureStyle.byPrefix = "By: "` |
| 16 | `"Respectfully submitted: "` | CourtFLRenderer.swift:200 | signature | `SignatureStyle.submittedLabel = "Respectfully submitted: "` |
| 17 | `"Attorneys for "` | CourtFLRenderer.swift:241 | signature | `SignatureStyle.representationPrefix = "Attorneys for "` (italic now read from existing `representationLineItalic`) |
| 18 | bar number, no label | CourtFLRenderer.swift:215 | signature | `SignatureStyle.barNumberLabel = ""` (empty ⇒ today's no-label behavior) |
| 19 | `"Telephone: "` | CourtFLRenderer.swift:223 | signature | `SignatureStyle.phoneLabel = "Telephone: "` |
| 20 | `"Facsimile: "` | CourtFLRenderer.swift:225 | signature | `SignatureStyle.faxLabel = "Facsimile: "` |
| 21 | `"Primary E-Mail: "` / `"Primary and Secondary E-Mail: "` | CourtFLRenderer.swift:229 | signature | `SignatureStyle.emailLabel = "Primary E-Mail: "`, `emailLabelWithSecondary = "Primary and Secondary E-Mail: "` |
| 22 | `"CERTIFICATE OF SERVICE"` | CourtFLRenderer.swift:254 | certificate | `CertificateStyle.heading = "CERTIFICATE OF SERVICE"` |
| 23 | `"I HEREBY CERTIFY that on "` / `", I "` / `" to the following:"` | CourtFLRenderer.swift:259 | certificate | `CertificateStyle.attestationPrefix` / `attestationSuffix` (defaults = the first and last substrings). The full literal is `"I HEREBY CERTIFY that on \(date), I \(clause) to the following:"`; the middle connective `", I "` between the date and clause interpolations stays **hardcoded** in the renderer (no field), so a naive prefix+suffix split does not drop it and byte-parity is preserved. |
| 24 | five service-method sentences | CourtFLRenderer.swift:317–327 | certificate | `CertificateStyle.clauseText: [ServiceMethodClause:String]` — empty/missing key ⇒ built-in boilerplate (unchanged) |
| 25 | `"N."` numbering format | CourtFLRenderer.swift:168 | body | `BodyStyle.numberFormat: NumberFormat = .numberDot` |
| 26 | `TabStop(positionTwips: 720)` allegation | CourtFLRenderer.swift:167 | body | read existing `HeadingLadder.baseIndentTwips` (720) — wire-up, no new field |
| 27 | `level * 720` point-heading indent | CourtFLRenderer.swift:173 | heading | read `HeadingLadder.baseIndentTwips` — wire-up |
| 28 | `hangingTwips: 720` point-heading | CourtFLRenderer.swift:176 | heading | read `HeadingLadder.baseIndentTwips` — wire-up |
| 29 | `spaceAfterTwips: 240` point-heading | CourtFLRenderer.swift:177 | heading | `HeadingLadder.spaceAfterTwips = 240` |

**Resulting struct additions (defaults shown; each preserves today's output):**

- `LetterheadBlock` (+3): `var tagline = "Attorneys at Law"`, `var phoneLabel = "Telephone: "`, `var faxLabel = "Facsimile: "`.
- `LetterheadStyle` (+5): `var reLabel = "RE:"`, `var reIndentTwips = 1440`, `var reHangingTwips = 720`, `var enclosurePrefix = "Enclosure: "`, `var ccPrefix = "cc:  "`.
- `CaptionStyle` (+6): `var partySeparator = "v."`, `var closingRuleGlyph = "/"`, `var caseNumberLabel = "CASE NO.: "`, `var divisionLabel = "DIVISION: "`, `var judgeLabel = "JUDGE: "`, `var designationIndentTwips = 720`.
- `ESignatureStyle` (+1): `var mark = "/s/ "`.
- `SignatureStyle` (+8): `var byPrefix = "By: "`, `var submittedLabel = "Respectfully submitted: "`, `var representationPrefix = "Attorneys for "`, `var barNumberLabel = ""`, `var phoneLabel = "Telephone: "`, `var faxLabel = "Facsimile: "`, `var emailLabel = "Primary E-Mail: "`, `var emailLabelWithSecondary = "Primary and Secondary E-Mail: "`.
- `CertificateStyle` (+4): `var heading = "CERTIFICATE OF SERVICE"`, `var attestationPrefix = "I HEREBY CERTIFY that on "`, `var attestationSuffix = " to the following:"`, `var clauseText: [ServiceMethodClause: String] = [:]`.
- `HeadingLadder` (+1): `var spaceAfterTwips = 240`.
- `BodyStyle` (+1): `var numberFormat: NumberFormat = .numberDot`.

> **Codable-compatibility caveat:** every added field carries a default value in the
> `init`, and the `Codable` synthesis for these style structs must decode missing keys.
> Because these structs currently rely on synthesized `Codable`, adding a non-optional
> stored property **without** custom `init(from:)` would make old JSON (missing the new
> key) fail to decode. To preserve resilient decoding of any already-persisted sheet,
> either (a) give each new field a hand-written `decodeIfPresent(...) ?? default` in a
> custom `init(from:)` (the pattern `AssistantProfile.init(from:)` uses,
> `AssistantProfile.swift:195`), or (b) rely on the fact that in this slice
> `HouseStyleSheet` itself is never persisted — only `FirmStyleProfile` is — so the base
> is always constructed in code via `.defaultFL` and new defaults apply automatically.
> **This slice takes route (b):** `HouseStyleSheet` is a compile-time value, never stored;
> only the sparse `FirmStyleProfile` (all-Optional, §4.1) is persisted, and it already
> decodes resiliently. Custom `Codable` on the style structs is therefore **not required**
> for correctness, only if a future slice persists a full sheet.

**Fields that already exist but the renderer ignores (wire-up, not new field).** Lift
these to read the sheet as part of the same pass, so a firm's derived sheet actually
flows through: `caption.headerBoldCentered` (hardcoded center+bold at
CourtFLRenderer:44–46), `caption.closingRuleEndsInSlash` (rule emitted unconditionally
:121–125), `signature.firmNameBoldCaps` (:207), `signature.representationLineItalic`
(:241), `certificate.headingCenteredBoldCaps` (:254), `letterhead.headerBlock.bottomRule`
(LetterheadRenderer:54), and `headings.baseIndentTwips` (#26–28). One style field is
**dead** and stays dead this slice (documented so it isn't miscounted):
`letterhead.dateFormat` (both `format()` helpers hardcode long-form dates; `DateStyle`
has only `.monthDayYear`, `DraftingCore.swift:137–139`, so there is nothing to switch
to). Note that `letterhead.closing` is **not** dead: `LetterDemand.assemble`
(`LetterDemand.swift:48`) sources `LetterModel.closing` from
`style.letterhead?.closing ?? "Respectfully,"`, and the renderer prints `model.closing`
(`LetterheadRenderer.swift:97–98`), so a firm-set `letterhead.closing` **does** change
the rendered closing. Default parity is unaffected because the default
`LetterheadStyle.closing` equals the `"Respectfully,"` fallback.

### 4.3 Floor & invariant enforcement (Fla. R. Jud. Admin. 2.520(a))

The effective sheet is **clamped** before any render so a firm cannot go below the
typography floor:

- `page.fontHalfPoints >= 24` (12 pt).
- Every side of `page.marginTwips >= 1440` (1″): `top`, `leading`, `bottom`, `trailing`.

```swift
// StyleSheetFloor.swift
extension HouseStyleSheet {
    /// Clamp to the Fla. R. Jud. Admin. 2.520(a) floor. Pure, total, idempotent.
    public func clampedToFloor() -> HouseStyleSheet {
        var s = self
        s.page.fontHalfPoints = max(s.page.fontHalfPoints, 24)
        let m = s.page.marginTwips
        s.page.marginTwips = EdgeInsets(
            top: max(m.top, 1440), leading: max(m.leading, 1440),
            bottom: max(m.bottom, 1440), trailing: max(m.trailing, 1440))
        return s
    }
}
```

**Where it runs.** The resolution pipeline is
`profile.resolved(over: .defaultFL).clampedToFloor()`, and the result is what the
controller hands the pipeline (§6). If the codebase already exposes
`StyleSheetCompiler.validateFloor` (NoticeAppearance references a 2.520(a) refusal path,
`:377`), the clamp is placed **immediately before** that validator so `validateFloor`
still runs as a defense-in-depth *assertion* (it should now always pass, because the
clamp guarantees the floor). If a firm-set value was below floor, the clamp silently
raises it; the Settings UI (§7) additionally shows an inline notice that the value was
raised to the 2.520(a) minimum, so the behavior is visible rather than mysterious.

> Only `pageFontHalfPoints` and `pageMarginTwips` can violate the floor; the label/prefix/
> geometry string fields cannot. The clamp is deliberately narrow. Golden-lock (invariant
> 2) is preserved because the clamp is deterministic and idempotent.

### 4.4 Persistence & versioning

Reuse the existing settings infrastructure (R3/R4) — no new store:

- **Key:** `FirmStyleProfile.profileKey = "firm.styleProfile"`, stored via
  `AppSettingsRepository.setSetting/getSetting` (`AppSettingsRepository.swift:11,:20`),
  exposed as `store.appSettings` (`SupraStore.swift:6`).
- **Autosave:** a `FirmStyleProfileController` (`@MainActor`, `ObservableObject`) mirrors
  `AssistantProfileController` exactly — `@Published var profile: FirmStyleProfile { didSet
  { persist() } }` so every edit autosaves; load at `init` via `getSetting(..., as:
  FirmStyleProfile.self) ?? FirmStyleProfile()`; `persist()` sets `message` only on write
  failure. The initial-assignment-doesn't-fire-`didSet` behavior is relied on to avoid a
  load loop (same note as `AssistantProfileController.swift:11–13`).
- **Migration from absent profile:** `getSetting` returns `nil` for a never-configured
  firm ⇒ `FirmStyleProfile()` ⇒ `resolved` ⇒ `.defaultFL`. Zero regression, no migration
  code path needed for first run.
- **`schemaVersion` migration:** on decode, if `schemaVersion < currentSchemaVersion`,
  run field-wise migration in a resilient `init(from:)` (decodeIfPresent everywhere, like
  `AssistantProfile.init(from:)` `:195`), then stamp `currentSchemaVersion`. Because all
  fields are Optional, an older payload missing new fields decodes cleanly to `nil`
  (inherit default) — the common case needs no explicit migration.

---

## 5. Exemplar ingestion flow

Goal: turn "here is my letterhead / caption / signature" into **structured Track A
fields**, reviewed by the user, with the exemplar text **never** entering a drafting
prompt.

### 5.1 Upload → text extraction (reuse R3)

Reuse `ExtractionService` as-is (`Packages/SupraDocuments/.../DocumentExtraction.swift:112`).
The importer accepts the same UTTypes as writing samples (`SettingsView.swift:525–530`):
pdf, rtf, plainText/text, docx, doc. Call
`try await extraction.extract(fileURL: url)` and read `result.combinedText`
(`DocumentExtraction.swift:87`). This is the exact idiom
`AssistantProfileController.addWritingSample` already uses (`:68`), injected as
`extraction: ExtractionService = ExtractionService()`.

The user picks the **exemplar kind** at upload time — `letterhead`, `caption`, or
`signature` (a small enum) — so the parser knows which structured schema to target.

### 5.2 LLM-assisted STRUCTURED extraction

**There is no schema-constrained decoding in the runtime (R3).** Structured output is
achieved by the house pattern: a prompt-contract that demands a fixed shape + app-side
parse/validate/repair. Two existing patterns to build on:

- The `StructuredOutputContract` heading-list + `StructuredOutputSections.analyze` +
  `buildRepairPrompt` pattern (`StructuredOutput/StructuredOutputContract.swift`), and
- The **billing** JSON pattern — `BillingDraftPrompt.system()` instructs "Output STRICT
  JSON only … of exactly this shape: {…}" and the app decodes with
  `JSONDecoder().decode(BillingDraftPayload.self, …)` then validates/repairs
  (`BillingDraftService.swift:201`).

The exemplar parser follows the **billing (STRICT JSON) pattern**, because the target is
a set of typed fields, not prose sections. Define a per-kind extraction payload:

```swift
// FirmStyleExemplarParser.swift — decoded from the model's STRICT-JSON answer.
struct LetterheadExtraction: Codable {
    var tagline: String?         // e.g. "Counselors at Law"
    var phoneLabel: String?      // e.g. "Tel: " / "Phone: "
    var faxLabel: String?        // e.g. "Fax: "
    var reLabel: String?         // e.g. "Re:" / "RE:"
    var enclosurePrefix: String? // e.g. "Enclosures: "
    var ccPrefix: String?        // e.g. "cc: "
    var bottomRule: Bool?        // is there a rule under the masthead?
}
struct CaptionExtraction: Codable {
    var partySeparator: String?  // "v." / "vs."
    var caseNumberLabel: String? // "CASE NO.: " / "Case No. "
    var divisionLabel: String?
    var judgeLabel: String?
    var closingRuleGlyph: String?
}
struct SignatureExtraction: Codable {
    var eSignatureMark: String?          // "/s/ " / "s/"
    var byPrefix: String?                // "By: "
    var submittedLabel: String?          // "Respectfully submitted, "
    var representationPrefix: String?    // "Counsel for " / "Attorneys for "
    var barNumberLabel: String?          // "Fla. Bar No. " / "FBN "
    var phoneLabel: String?; var faxLabel: String?
    var emailLabel: String?; var emailLabelWithSecondary: String?
}
```

Call shape reuses the canonical idiom: build a `GenerateRequest` (`GenerateRequest.swift:4`)
with a `systemPrompt` that is the STRICT-JSON contract and a `prompt` that is
`result.combinedText`; route via `ModelRouter` (a greedy/temp-0 route, mirroring the
document-grounded route at `ModelRouting.swift:284–287`, since we want faithful
extraction, not creativity); drain with `collectGeneratedText` (`GenerationStreamCollector.swift:40`);
strip reasoning via `ReasoningContent.answer(from:)`; `JSONDecoder().decode(...)`. On
decode failure or missing-brace, issue one repair prompt ("Return STRICT JSON only,
exactly this shape…"), then give up gracefully (§5.4).

**The extracted payload is data, not prompt context.** It maps field-by-field into a
*candidate* `FirmStyleProfile` (nil fields ⇒ leave the profile's field nil ⇒ inherit
default). The exemplar's `combinedText` is used **only** during this parse and is then
dropped. It is never stored on the profile, never composed into a system prompt, and
never carried into `runLetter`/`runNotice`. This is the hard line that distinguishes
Track A (parse-source) from Track B (voice exemplar).

### 5.3 Review & confirm

The confirm step is the trust surface (design thesis §2). Two panes:

1. **Parsed fields** — each extracted value shown next to its target field, editable, with
   the current default displayed for any field the parser left nil. This mirrors the
   `AssistantProfileSection` field layout (`SettingsView.swift`), reusing `LabeledTextField`
   / `MultilineField` (`MultilineField.swift:412,:114`).
2. **Rendered `.docx` preview** — the app builds the *candidate effective sheet*
   (`candidate.resolved(over: .defaultFL).clampedToFloor()`), renders a sample document
   through the **same** `CourtFLRenderer` / `LetterheadRenderer` used in production, using
   placeholder-but-real slot data projected from the user's `AssistantProfile`
   (`firmProfile(from:)`), and shows the exact bytes the profile will produce.

**Confirm writes the `FirmStyleProfile`** (autosave via the controller `didSet`). Because
rendering is deterministic, what the user confirmed in preview is reproduced identically
on every later draft (invariant 2). There is no per-draft variance to re-verify — this is
the whole point: **the guarantee is mechanical, not probabilistic.**

### 5.4 Guardrails

- **Identity stays slot-only (invariant 4).** The parser extracts **labels, prefixes,
  marks, and geometry** — never names, addresses, phone *numbers*, emails, or bar
  *numbers*. Those remain `AssistantProfile` → `FirmProfile` slots. If the exemplar
  contains "Telephone: (305) 555-1212", the parser captures the label `"Telephone: "` and
  discards the number. The candidate-profile mapping ignores any extracted field that
  looks like identity content; the review UI does not surface identity fields at all.
- **Text masthead vs. image asset.** A text masthead (firm name / tagline / contact line)
  is in scope and lifts into `LetterheadBlock` fields. A **graphic/logo/scanned** masthead
  is **deferred** — `ExtractionService` flags image content (`needsOCR`), and for an
  image-only letterhead the flow surfaces "We can capture your letterhead text but not a
  logo image yet" and captures whatever text OCR yields, leaving image placement to a
  future slice. No image bytes are ever stored on `FirmStyleProfile`.
- **Partial / failed parse fallback.** If extraction yields empty text, the flow shows the
  same "No text was found in …" message pattern `addWritingSample` uses
  (`AssistantProfileController.swift:71`). If the model returns unparseable JSON after one
  repair attempt, the flow degrades to **manual entry** — the review pane opens with all
  fields at their defaults and a note "We couldn't read this automatically; you can set
  the fields by hand." A failed parse **never** silently mutates the stored profile; only
  an explicit confirm writes.

---

## 6. Renderer & controller wiring

**Resolve once, pass everywhere.** `MatterDraftingController` gains a
`FirmStyleProfileController` (injected, optional like `runtimeClient` at
`MatterDraftingController.swift:85`) and a resolver:

```swift
// MatterDraftingController — new helper.
private func effectiveStyle() -> HouseStyleSheet {
    let profile = firmStyle?.profile ?? FirmStyleProfile()   // absent ⇒ default
    return profile.resolved(over: .defaultFL).clampedToFloor()
}
```

**Exact call-site edits** (replace the literal `.defaultFL`):

- **Notice path — `MatterDraftingController.swift:160`:**
  `result = try await pipeline.runNotice(inputs, profile: firm, style: effectiveStyle())`
  (was `style: .defaultFL`). `firm` still built at `:141` via `firmProfile(from:…)`.
- **Letter path — `MatterDraftingController.swift:307`:**
  `result = try await pipelineFactory().runLetter(inputs, generated: generated, profile:
  firm, style: effectiveStyle())` (was `style: .defaultFL`). `firm` from `:288`;
  `generated` from `:297`.
- **Motion path (`runMotion`) — when it lands:** pass `style: effectiveStyle()` the same
  way. (Not present at a fixed line today; wire identically.)

**Renderers read the new fields.** `CourtFLRenderer` and `LetterheadRenderer` replace each
baked literal (§4.2 table) with a read of the corresponding style field on the sheet they
already receive — e.g. `block.tagline` instead of `"Attorneys at Law"` at
LetterheadRenderer:43; `style.caption.partySeparator` instead of `"v."` at
CourtFLRenderer:116; `style.signature.eSignature.mark` instead of `"/s/ "` at
CourtFLRenderer:296; `style.certificate.heading` instead of `"CERTIFICATE OF SERVICE"` at
CourtFLRenderer:254; `style.headings.baseIndentTwips` instead of the three `720`s at
:167/:173/:176; `style.headings.spaceAfterTwips` instead of `240` at :177. The wire-up
items (bottomRule, headerBoldCentered, firmNameBoldCaps, representationLineItalic,
headingCenteredBoldCaps, closingRuleEndsInSlash) are changed from hardcoded to reading the
already-present bool.

**Zero behavior change when no profile is set (invariant 5).** `effectiveStyle()` with an
absent/empty profile returns `.defaultFL.clampedToFloor()`, and `.defaultFL` already
satisfies the floor (font 24, margins 1440), so it equals `.defaultFL`. Every new field's
default equals the old literal. Therefore the renderer emits identical bytes. This is the
golden-file assertion in §10.

---

## 7. Settings UI — "Firm Style" section

Add a `FirmStyleSection` to `SettingsView.swift` (instantiated near the
`AssistantProfileSection` at `:17`), taking `@ObservedObject var firmStyle:
FirmStyleProfileController`. It mirrors the `AssistantProfileSection` autosave pattern
exactly: every control binds to `$firmStyle.profile.<field>`; the controller's `didSet`
persists on each keystroke; there is **no Save button** ("Your changes save automatically
as you type.", like `SettingsView.swift:761`).

Layout (per-element subsections, reusing `LabeledTextField` `:412` and `MultilineField`
`:114`):

- **Letterhead** — tagline, phone/fax labels, RE label + indent/hanging, enclosure/cc
  prefixes, bottom-rule toggle, block/indented paragraph style.
- **Caption** — party separator, case-number/division/judge labels, closing-rule glyph +
  the `closingRuleEndsInSlash` toggle, designation indent, header bold-centered toggle.
- **Signature** — `/s/` mark, By-prefix, "Respectfully submitted" label, representation
  prefix + italic toggle, bar-number label, phone/fax labels, email labels, firm-name
  bold-caps toggle.
- **Certificate** — heading text, attestation prefix/suffix, per-clause rewording for the
  five `ServiceMethodClause` cases (empty ⇒ built-in FL boilerplate), heading bold-caps
  toggle.
- **Page/body (floored)** — font size and margins, with an inline notice when a value is
  raised to the Fla. R. Jud. Admin. 2.520(a) minimum (§4.3); body justify toggle.

**Exemplar importer.** An "Upload letterhead / caption / signature exemplar…" button using
`.fileImporter` with the same accepted types as writing samples (`SettingsView.swift:525–530`,
`748`); the sheet asks which element the file represents, then runs §5's parse → review →
preview → confirm. This is visually parallel to the existing "Add writing sample…" button
(`:736`) but routes to the Track A parser, **not** `addWritingSample`.

**Preview.** A "Preview what your firm's documents look like" control (parallel to the
"Preview what the assistant receives" `DisclosureGroup` at `SettingsView.swift:766`)
renders a sample `.docx` from the current effective sheet and offers it via
`SendUserFile`/save, so the user can eyeball the exact output at any time — not only during
exemplar confirm. `firmStyle.message` (autosave error / parse status) is surfaced above it,
matching `profile.message` at `:763`.

---

## 8. Secondary — Track B (voice) wiring

**This affects PROSE only, never structure.** Kept deliberately separate from everything
above.

Today the structured drafting engine's voice input is thin: only the demand-letter path
builds an `AssistantVoiceProfile`, and only from a canned per-letter tone phrase —
`MatterDraftingController.swift:290` `AssistantVoiceProfile(registerNotes:
Self.toneRegister(input.tone))`, where `toneRegister` (`:375–381`) maps `"final"` /
`"measured"` / default to three fixed strings. `AssistantVoiceProfile`
(`Packages/SupraDrafting/.../Generation.swift:25`) is a single `registerNotes: String`,
consumed at `RuntimeLetterGenerator.swift:53` as "Tone/register: … Match the register only
— never copy wording from examples." The Notice path builds no voice profile (it is
deterministic, no LLM).

**Track B improvement (M4, optional):** enrich `registerNotes` from the user's
`AssistantProfile` style surface — `formality` / `length` / `voiceNotes`
(`AssistantProfile.swift:99–101`) and the writing-sample firewall block already assembled
by `composedSystemPrompt` (declared at `AssistantProfile.swift:246`; the firewall block at
`:296–307`). This biases the model's prose toward the firm's voice. It **can be improved
but never guaranteed**, so it stays out of the trust contract (§9). Two hard rules carry
over unchanged: writing samples are STYLE-EXEMPLAR-only ("never treat their content as
fact", `AssistantProfile.swift:301`), and voice never produces a structural element —
`GeneratedLetter` still has no structural fields (§1).

---

## 9. Consistency & trust contract

**The guarantee is mechanical, not probabilistic.** A firm's letterhead/caption/signature
is data in `FirmStyleProfile`, resolved into a `HouseStyleSheet`, and applied by a pure,
deterministic renderer. Same profile + same slots ⇒ same bytes, every time (invariant 2).
The user's one-time trust surface is: **parse review** (the extracted fields are correct)
+ **rendered `.docx` preview** (the exact output is correct) → **confirm once**. After
confirm, there is nothing left to trust — determinism reproduces the confirmed output
verbatim.

**Contrast with the rejected approach.** Feeding exemplars into the model's prompt would
make every draft's structure a *probabilistic* generation the user must re-verify each
time, and it would violate invariant 3 (a model-originated structural element could reach
a draft). It cannot even work here: `GeneratedLetter` has no structural fields and the
render models are populated from slots + sheet, so exemplar-in-prompt would change nothing
structural anyway — it would only pollute the prose channel with layout text. Track A
(deterministic data) is therefore both **safer** and **the only thing that actually
controls structure.** Exemplars are a parse-source for Track A, full stop.

---

## 10. Testing & verification

> **No Swift toolchain in this repo.** Compilation, `.docx` golden diffs, and renderer
> round-trips must run on macOS (Xcode/SwiftPM). The assertions below are specified so a
> macOS CI run can execute them; this environment can only author them.

- **Zero-regression golden parity (invariant 5).** For every kind currently covered by a
  golden `.docx`, render with `style: FirmStyleProfile().resolved(over: .defaultFL).clampedToFloor()`
  and assert **byte-for-byte** equality with the committed golden produced under
  `.defaultFL`. This is the leakage-equivalent invariant for style: an empty profile
  changes nothing.
- **`resolved` identity unit test.** `FirmStyleProfile().resolved(over: .defaultFL) ==
  HouseStyleSheet.defaultFL` (exact `Equatable`, since `HouseStyleSheet` is `Equatable`
  `DraftingCore.swift:543`).
- **Codable round-trip.** `FirmStyleProfile` encode→decode→`==` for (a) an empty profile,
  (b) a fully-populated profile, (c) a payload with a lower `schemaVersion` and missing
  new keys (must decode to `nil`s / defaults, not throw), and (d) the
  `[ServiceMethodClause: String]` map (keys are the enum raw values).
- **Floor-clamp units.** `clampedToFloor()` raises `fontHalfPoints` 20→24 and each margin
  1080→1440; leaves 24/1440 untouched (idempotent); a mixed `EdgeInsets` clamps per-side.
- **Per-literal override tests.** For each row in §4.2, set exactly that one field on the
  profile, render, and assert the golden diff is confined to that literal (e.g. `"v."` →
  `"vs."` changes only the party-separator run).
- **Parse-extraction units with fixtures.** Feed fixture exemplar texts (a FL letterhead,
  a 15th-Circuit caption, a signature block) to the parser with a **stubbed** runtime
  client returning canned STRICT-JSON, and assert the resulting candidate
  `FirmStyleProfile` fields; add a malformed-JSON fixture asserting the single-repair path
  then graceful manual-entry fallback (§5.4); add an identity-bearing fixture asserting no
  name/number/email is captured (invariant 4).
- **Preview determinism.** Render the same candidate sheet twice; assert identical bytes.

---

## 11. Phasing / milestones

- **M1 — Lift literals + `FirmStyleProfile` + wiring, default parity.** Add the ~22 new
  style fields (§4.2) with defaults = today's literals; add the wire-up reads (#26–28,
  bottomRule, the bool toggles); add `FirmStyleProfile` + `resolved` + `clampedToFloor`;
  swap `.defaultFL` → `effectiveStyle()` at `MatterDraftingController.swift:160` and `:307`.
  **Exit criterion:** golden `.docx` bytes unchanged for an empty profile (§10). No UI yet.
- **M2 — Settings manual controls + preview.** `FirmStyleSection` with per-element controls
  (autosave) and a live `.docx` preview (§7). No exemplar parsing yet.
- **M3 — Exemplar parse + confirm.** `ExtractionService` reuse, the STRICT-JSON extractor,
  review pane + rendered preview, confirm-writes-profile, guardrails (§5).
- **M4 — Voice track (Track B).** Enrich `AssistantVoiceProfile.registerNotes` from the
  `AssistantProfile` style surface (§8). Prose-only; outside the trust contract.

> **Implemented / deferred markers** (fill in as milestones land):
> `> **Implemented (M1).** …` / `> **Still deferred:** image-asset letterhead (§5.4);
> per-jurisdiction style overrides; `runMotion` style pass until the motion path exists.`

---

## 12. Risks, non-goals, and open questions

**Non-goals.**

- **N/A this slice — image/logo letterhead assets.** Text masthead only (§5.4). Reason:
  no image-placement channel in the render models; deferred.
- **N/A — grammar/JSON-schema-constrained decoding.** The runtime has none (R3); the parse
  flow is prompt-contract + parse/validate/repair. Not a regression — it is the house
  pattern (billing).
- **N/A — per-matter / per-jurisdiction style.** One firm-level profile; `courtMDFL` /
  `courtGA` shells are untouched.
- **N/A — persisting a full `HouseStyleSheet`.** Only the sparse `FirmStyleProfile` is
  stored (§4.2 route (b)); the base sheet stays a compile-time value.

**Risks.**

- **Codable resilience if a full sheet is ever persisted.** Adding non-optional stored
  properties to the style structs would break decode of an old stored sheet. Mitigated by
  never persisting the sheet this slice; a future slice that does must add resilient
  `init(from:)` (§4.2 caveat).
- **Parse fidelity.** LLM extraction can misread an unusual masthead; mitigated by the
  mandatory review + rendered-preview confirm (§5.3) — nothing is written without an
  explicit confirm, so a bad parse is caught by the human, not shipped.
- **Floor confusion.** A firm setting 11 pt and seeing 12 pt could be surprised; mitigated
  by the inline "raised to the 2.520(a) minimum" notice (§4.3, §7).
- **Golden churn.** Any renderer edit risks accidental byte drift; mitigated by the M1 exit
  criterion (empty-profile parity) gating the whole slice.

**Open questions.**

1. Should the per-clause certificate rewording (§4.2 #24) be blocked from removing the
   rule-required substance of a Fla. R. Jud. Admin. 2.516 e-service attestation, or is
   free rewording acceptable with a warning? (Leaning: warn, do not block — the firm is a
   licensed attorney; the built-in default remains one tap away.)
2. Does the letter path want a second `DateStyle` case so the currently-dead
   `letterhead.dateFormat` field (§4.2) becomes honorable, or leave it dead until then?
   (Deferred; out of this slice. `letterhead.closing` is already live via
   `LetterDemand.assemble`, so no action is needed there.)
3. Where exactly does `StyleSheetCompiler.validateFloor` live, and should `clampedToFloor()`
   fold into it or precede it? (Spec assumes precede-then-assert, §4.3; confirm on macOS.)
